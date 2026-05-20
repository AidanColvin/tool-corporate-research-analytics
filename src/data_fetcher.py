"""Multi-registry query engine.

One private method per data source. Each returns (partial_dict, refs).
fetch() merges all partials into one unified company_data payload.
All failures are silent — each fetcher returns ({}, []) on any error.
"""

import urllib.parse
import requests
from src import config, env

# Type alias for the standard return type of every _fetch_* method
Payload = tuple[dict, list[dict]]


class DataFetcher:
    """Queries external registries and returns structured company data.

    Attributes:
        ncbi_key:    NCBI API key (None if not set — PubMed degrades gracefully).
        timeout:     HTTP request timeout in seconds.
        max_sources: Maximum results per registry call.
    """

    def __init__(self) -> None:
        """Load env values once. Fail fast on missing required keys."""
        self.ncbi_key = env.get_ncbi_key_optional()
        self.timeout = env.get_timeout()
        self.max_sources = env.get_max_sources()

    # ── Public interface ──────────────────────────────────────────────────────

    def fetch(self, name: str, url: str) -> Payload:
        """Orchestrate all registry queries and merge results.

        Calls each private registry method. Merges partial company_data
        dicts via dict.update(). Concatenates all reference lists.
        Never raises — individual fetcher failures are silently skipped.

        Args:
            name: Exact legal company name (e.g. 'Eli Lilly and Company').
            url:  Company primary domain without scheme (e.g. 'lilly.com').

        Returns:
            Tuple of (merged company_data dict, combined references list).
        """
        methods = [
            self._fetch_edgar,
            self._fetch_pubmed,
            self._fetch_nih,
            self._fetch_sbir,
        ]
        company_data: dict = {}
        references: list[dict] = []

        for method in methods:
            partial, refs = method(name)
            company_data.update(partial)
            references.extend(refs)

        # Set url from argument — never fetched from registries
        company_data.setdefault("url", url)
        return company_data, references

    # ── Private registry methods ──────────────────────────────────────────────

    def _fetch_edgar(self, name: str) -> Payload:
        """Query SEC EDGAR for company filing data.

        Extracts: company type, IPO status, ticker symbol, location,
        and approximate employee count from the most recent 10-K filing.

        Args:
            name: Company name to search.

        Returns:
            (partial_dict, [reference]) or ({}, []) on any failure.
        """
        try:
            params = {
                "q":         f'"{name}"',
                "dateRange": "custom",
                "startdt":   "2020-01-01",
                "forms":     "10-K",
            }
            resp = requests.get(
                config.API_URLS["edgar"],
                params=params,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            data = resp.json()
            hits = data.get("hits", {}).get("hits", [])
            if not hits:
                return {}, []

            source = hits[0].get("_source", {})
            entity = source.get("entity_name", name)
            period = source.get("period_of_report", "")
            year = period[:4] if period else "unknown"
            tickers = source.get("ticker", "")
            location = source.get("business_address", {})
            city  = location.get("city", "")
            state = location.get("state_or_country", "")

            # Determine IPO status from ticker presence
            if tickers:
                ipo_status = f"Yes (Ticker: {tickers}) approx. {year}"
                co_type = "Public"
            else:
                ipo_status = "No public filing ticker found"
                co_type = "Private"

            partial = {
                "ipo_status": ipo_status,
                "type":       co_type,
            }
            if city and state:
                partial["location"] = f"{city}, {state}"

            ref = self._build_reference(
                author   = "U.S. Securities and Exchange Commission",
                year     = year,
                title    = f"{entity} — 10-K Annual Filing",
                registry = "SEC EDGAR Full-Text Search",
                url      = (
                    f"https://www.sec.gov/cgi-bin/browse-edgar"
                    f"?company={urllib.parse.quote(name)}"
                    f"&action=getcompany&type=10-K"
                ),
            )
            return partial, [ref]

        except (requests.RequestException, KeyError, ValueError, IndexError):
            return {}, []

    def _fetch_pubmed(self, name: str) -> Payload:
        """Query NCBI PubMed for publications affiliated with the company.

        Uses NCBI API key if available (10 req/s vs 3 req/s without).
        Returns publication references only — no company_data fields added.

        Args:
            name: Company name for affiliation search.

        Returns:
            ({}, [references]) or ({}, []) if no results or no API key.
        """
        if not self.ncbi_key:
            return {}, []

        try:
            # Step 1: ESearch — get PMIDs
            search_params = {
                "db":      "pubmed",
                "term":    f'"{name}"[Affiliation]',
                "retmax":  str(self.max_sources),
                "retmode": "json",
                "api_key": self.ncbi_key,
            }
            search_resp = requests.get(
                config.API_URLS["pubmed_s"],
                params=search_params,
                timeout=self.timeout,
            )
            search_resp.raise_for_status()
            pmids = (
                search_resp.json()
                .get("esearchresult", {})
                .get("idlist", [])
            )
            if not pmids:
                return {}, []

            # Step 2: ESummary — get article metadata
            summary_params = {
                "db":      "pubmed",
                "id":      ",".join(pmids[:self.max_sources]),
                "retmode": "json",
                "api_key": self.ncbi_key,
            }
            # reuse pubmed_s base, swap to esummary endpoint
            summary_url = config.API_URLS["pubmed_s"].replace(
                "esearch.fcgi", "esummary.fcgi"
            )
            sum_resp = requests.get(
                summary_url,
                params=summary_params,
                timeout=self.timeout,
            )
            sum_resp.raise_for_status()
            result = sum_resp.json().get("result", {})

            refs: list[dict] = []
            for pmid in pmids[:self.max_sources]:
                article = result.get(pmid, {})
                title   = article.get("title", "Untitled")
                authors = article.get("authors", [{}])
                author  = authors[0].get("name", "Unknown") if authors else "Unknown"
                year    = article.get("pubdate", "")[:4]
                refs.append(
                    self._build_reference(
                        author   = author,
                        year     = year,
                        title    = title,
                        registry = "PubMed / NCBI",
                        url      = f"https://pubmed.ncbi.nlm.nih.gov/{pmid}/",
                    )
                )
            return {}, refs

        except (requests.RequestException, KeyError, ValueError):
            return {}, []

    def _fetch_nih(self, name: str) -> Payload:
        """Query NIH Reporter for active research grants.

        Extracts award amounts, fiscal years, and project titles.
        Adds a talking point if grants with dollar values are found.

        Args:
            name: Organization name to search in NIH Reporter.

        Returns:
            (partial_dict_with_optional_talking_point, [references])
        """
        try:
            payload = {
                "criteria":  {"org_names": [name]},
                "offset":    0,
                "limit":     self.max_sources,
                "sort_field": "fiscal_year",
                "sort_order": "desc",
            }
            resp = requests.post(
                config.API_URLS["nih"],
                json=payload,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            results = resp.json().get("results", [])
            if not results:
                return {}, []

            refs: list[dict] = []
            total_awarded = 0.0

            for project in results[:self.max_sources]:
                award = project.get("award_amount", 0) or 0
                total_awarded += award
                pi_name  = project.get("principal_investigators", [{}])
                pi       = pi_name[0].get("full_name", "NIH") if pi_name else "NIH"
                year     = str(project.get("fiscal_year", ""))
                title    = project.get("project_title", "NIH Grant")
                proj_num = project.get("project_num", "")
                refs.append(
                    self._build_reference(
                        author   = pi,
                        year     = year,
                        title    = title,
                        registry = "NIH Reporter",
                        url      = (
                            f"https://reporter.nih.gov/project-details/{proj_num}"
                            if proj_num else config.API_URLS["nih"]
                        ),
                    )
                )

            partial: dict = {}
            if total_awarded > 0:
                amt_str = f"${total_awarded / 1_000_000:.1f}M" if total_awarded >= 1_000_000 \
                    else f"${total_awarded:,.0f}"
                partial["_nih_grant_summary"] = (
                    f"NIH Reporter records {len(results)} active or recent "
                    f"grant(s) totaling approximately {amt_str} "
                    f"awarded to {name}."
                )
            return partial, refs

        except (requests.RequestException, KeyError, ValueError):
            return {}, []

    def _fetch_sbir(self, name: str) -> Payload:
        """Query SBIR.gov for Small Business Innovation Research awards.

        Args:
            name: Company name to search.

        Returns:
            (partial_dict, [references]) or ({}, []) on failure.
        """
        try:
            params = {
                "company": name,
                "rows":    str(self.max_sources),
            }
            resp = requests.get(
                config.API_URLS["sbir"],
                params=params,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            awards = resp.json()
            if not awards:
                return {}, []

            refs: list[dict] = []
            for award in awards[:self.max_sources]:
                amount = award.get("award_amount", 0) or 0
                year   = str(award.get("award_year", ""))
                title  = award.get("title", "SBIR Award")
                firm   = award.get("firm", name)
                refs.append(
                    self._build_reference(
                        author   = firm,
                        year     = year,
                        title    = title,
                        registry = "SBIR.gov",
                        url      = "https://www.sbir.gov/search",
                    )
                )
            return {}, refs

        except (requests.RequestException, KeyError, ValueError):
            return {}, []

    # ── Reference factory ─────────────────────────────────────────────────────

    def _build_reference(
        self,
        author:   str,
        year:     str,
        title:    str,
        registry: str,
        url:      str,
    ) -> dict:
        """Build a standardized reference dict.

        Single schema definition. All _fetch_* methods call this.
        Changing the schema means editing only this method.

        Args:
            author:   Author or organization name.
            year:     Publication or filing year as a string.
            title:    Document or article title.
            registry: Name of the source registry or database.
            url:      Full URL to the source document.

        Returns:
            Dict with exactly five keys: author, year, title, registry, url.
        """
        return {
            "author":   author,
            "year":     year,
            "title":    title,
            "registry": registry,
            "url":      url,
        }

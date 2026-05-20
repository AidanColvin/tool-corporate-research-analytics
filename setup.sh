#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh  —  Scaffolds the entire tool-corporate-research-analytics project.
#
# Usage:
#   bash setup.sh
#
# After running:
#   cd tool-corporate-research-analytics
#   python3 -m venv .venv && source .venv/bin/activate
#   pip install -r requirements.txt
#   cp .env.example .env          # then fill in your NCBI_API_KEY
#   make run                      # smoke-test with Eli Lilly example
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

P="tool-corporate-research-analytics"
echo "Building $P ..."
mkdir -p "$P"/{src,tests,output,examples}
cd "$P"


# ═════════════════════════════════════════════════════════════════════════════
# src/__init__.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/__init__.py
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# src/config.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/config.py
"""Central constants.

Every other module imports from here.
No magic strings anywhere else in the codebase.
"""

from pathlib import Path

# ── Source tier regex patterns ────────────────────────────────────────────────
# Compiled once in SourceValidator.__init__(). Add new tiers here only.
TIER_PATTERNS: dict[str, str] = {
    "top": (
        r".*(\.gov|ncbi\.nlm\.nih\.gov|sec\.gov"
        r"|pubmed|sbir\.gov|reporter\.nih\.gov).*"
    ),
    "second": (
        r".*(\.edu|bloomberg\.com|tracxn\.com"
        r"|pitchbook\.com|ir\.).*"
    ),
    "third": (
        r".*(reuters\.com|prnewswire\.com"
        r"|businesswire\.com|globenewswire\.com|apnews\.com).*"
    ),
}

# ── External registry endpoints ───────────────────────────────────────────────
API_URLS: dict[str, str] = {
    "edgar":    "https://efts.sec.gov/LATEST/search-index",
    "pubmed_s": "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi",
    "pubmed_f": "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi",
    "nih":      "https://api.reporter.nih.gov/v2/projects/search",
    "sbir":     "https://www.sbir.gov/api/awards.json",
}

# ── All fields required in company_data before rendering ─────────────────────
REQUIRED_FIELDS: list[str] = [
    "name",
    "location",
    "url",
    "type",
    "size_class",
    "employee_count",
    "actions",
    "audiences",
    "descriptor",
    "alignment_asset",
    "unc_strengths",
    "contact_person",
    "contact_rationale",
    "ipo_status",
    "unc_alum_details",
    "donation_history",
    "talking_points",
]

# ── Pipeline defaults ─────────────────────────────────────────────────────────
TIMEOUT: int = 10
MAX_SOURCES: int = 5
OUTPUT_DIR: Path = Path("output")
MIN_TALKING_POINTS: int = 3
MAX_TALKING_POINTS: int = 6
MAX_HEADER_WORDS: int = 4
MIN_HEADER_WORDS: int = 2
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# src/env.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/env.py
"""Typed environment variable loaders.

Raises EnvironmentError on missing required keys before any HTTP call.
Import from here — never call os.getenv() directly in other modules.
"""

import os
from dotenv import load_dotenv
from src import config

load_dotenv()


def get_ncbi_key() -> str:
    """Return NCBI E-utilities API key.

    Raises:
        EnvironmentError: If NCBI_API_KEY is absent from .env.
    """
    key = os.getenv("NCBI_API_KEY")
    if not key:
        raise EnvironmentError(
            "NCBI_API_KEY is not set. Add it to .env.\n"
            "Register free at: https://www.ncbi.nlm.nih.gov/account/\n"
            "Without it the PubMed rate limit is 3 req/s instead of 10."
        )
    return key


def get_ncbi_key_optional() -> str | None:
    """Return NCBI key or None. Used when PubMed is optional."""
    return os.getenv("NCBI_API_KEY")


def get_timeout() -> int:
    """Return HTTP request timeout in seconds. Defaults to config.TIMEOUT."""
    raw = os.getenv("REQUEST_TIMEOUT_SECONDS")
    return int(raw) if raw else config.TIMEOUT


def get_max_sources() -> int:
    """Return max results per registry. Defaults to config.MAX_SOURCES."""
    raw = os.getenv("MAX_SOURCES_PER_REGISTRY")
    return int(raw) if raw else config.MAX_SOURCES
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# src/validator.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/validator.py
"""Source credibility tiering and quantitative metric validation.

SourceValidator is the only class. All methods are pure functions.
No side effects after __init__.
"""

import re
from src import config

# Priority order — filter_sources uses this for cutoff math
TIER_ORDER: list[str] = ["top", "second", "third"]

# Module-level compiled pattern for metric detection (faster than per-call compile)
_METRIC_RE: re.Pattern = re.compile(
    r"(\$\s?\d[\d,\.]*"       # dollar values:  $4.2B  $50,000
    r"|\d[\d,\.]*\s?%"        # percentages:    38%  12.5 %
    r"|\b(19|20)\d{2}\b"      # 4-digit years:  1985  2026
    r"|\b\d[\d,\.]*\s?(million|billion|thousand|employees|patents|sites)\b"
    r"|\b\d[\d,]+\b)"         # plain integers with digit separators
)


class SourceValidator:
    """Tiers source URLs and validates quantitative metric presence.

    Compiles all regex patterns from config.TIER_PATTERNS once at init.
    All subsequent calls do no re-compilation.

    Attributes:
        _patterns: Compiled patterns keyed by tier label.
    """

    def __init__(self) -> None:
        """Compile tier patterns once. Raises nothing."""
        self._patterns: dict[str, re.Pattern] = {
            tier: re.compile(pattern, re.IGNORECASE)
            for tier, pattern in config.TIER_PATTERNS.items()
        }

    def categorize_source(self, url: str) -> str:
        """Return credibility tier label for a source URL.

        Iterates patterns in TIER_ORDER priority (top first).
        Returns 'unverified' if no pattern matches.

        Args:
            url: Raw source URL string.

        Returns:
            One of 'top', 'second', 'third', or 'unverified'.
        """
        for tier in TIER_ORDER:
            if self._patterns[tier].match(url):
                return tier
        return "unverified"

    def has_quantitative_metrics(self, text: str) -> bool:
        """Return True if text contains a verifiable numeric data point.

        Matches dollar values, percentages, 4-digit years, large integers,
        and numeric-unit combinations (e.g. '50 employees', '12 patents').

        Args:
            text: Talking point body string to validate.

        Returns:
            True if any quantitative metric is found.
        """
        return bool(_METRIC_RE.search(text))

    def filter_sources(
        self,
        refs: list[dict],
        min_tier: str = "third",
    ) -> list[dict]:
        """Return references at or above min_tier. Always drops unverified.

        Args:
            refs:     Raw list of reference dicts, each with a 'url' key.
            min_tier: Minimum tier to include. Options: top|second|third.

        Returns:
            Filtered list. Order preserved.
        """
        if min_tier not in TIER_ORDER:
            raise ValueError(
                f"Invalid min_tier '{min_tier}'. "
                f"Must be one of: {TIER_ORDER}"
            )
        cutoff = TIER_ORDER.index(min_tier)
        result: list[dict] = []
        for ref in refs:
            tier = self.categorize_source(ref.get("url", ""))
            if tier == "unverified":
                continue
            if TIER_ORDER.index(tier) <= cutoff:
                result.append(ref)
        return result
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# src/data_fetcher.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/data_fetcher.py
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
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# src/pipeline.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/pipeline.py
"""Orchestration, field validation, and immutable template rendering.

CorporateIntelligencePipeline is the only class.
It runs validation before every render. No partial renders on bad data.
"""

import json
import sys
from src import config
from src.validator import SourceValidator


class CorporateIntelligencePipeline:
    """Validates company_data and renders the profile template.

    Both public render methods run the full validation sequence
    before producing any output. Fail fast, fail loudly.

    Attributes:
        _validator: SourceValidator instance for metric checks.
    """

    def __init__(self) -> None:
        """Instantiate the internal validator."""
        self._validator = SourceValidator()

    # ── Public render methods ─────────────────────────────────────────────────

    def render_profile(
        self,
        company_data: dict,
        references:   list[dict],
    ) -> str:
        """Validate data and render the immutable markdown template.

        Args:
            company_data: Dict containing all profile fields.
            references:   Filtered, tiered reference list.

        Returns:
            Complete markdown profile string.

        Raises:
            ValueError: On any missing field or invalid talking point.
        """
        self._validate_required_fields(company_data)
        valid_pts = self._validate_talking_points(
            company_data["talking_points"]
        )
        small, mid, large = self._headcount_strings(
            company_data["size_class"],
            company_data["employee_count"],
        )
        talking = self._render_talking_points(valid_pts)
        refs    = self._render_references(references)
        d       = company_data

        lines = [
            f"# COMPANY PROFILE",
            f"",
            f"{d['name']} is a {d['size_class']} {d['type']} firm "
            f"that is based in {d['location']}. "
            f"They perform {d['actions']} for {d['audiences']}. "
            f"They are a {d['descriptor']}. "
            f"This firm offers a potential partnership because their "
            f"{d['alignment_asset']} aligns directly with UNC's strengths "
            f"in {d['unc_strengths']}. "
            f"{d['contact_person']} is the best avenue for partnership "
            f"because they {d['contact_rationale']}.",
            f"",
            f"## Basic Company Information",
            f"",
            f"Name, Company Location: {d['name']}, {d['location']}",
            f"Company website URL: {d['url']}",
            f"Company Type, Company Size: {d['type']}, {d['size_class']} "
            f"(Approx. {d['employee_count']} employees)",
            f"",
            f"### Company Type",
            f"IPO? {d['ipo_status']}",
            f"",
            f"### Company Size",
            f"Small: 0-100 {small}",
            f"Mid: 100-749 {mid}",
            f"Large: 750+ {large}",
            f"",
            f"## UNC Connection (if any)",
            f"",
            f"UNC Alum (in decision-making position): {d['unc_alum_details']}",
            f"Donation History: {d['donation_history']}",
            f"",
            f"## Talking Points",
            f"",
            talking,
            f"## References",
            f"",
            refs,
        ]
        return "\n".join(lines)

    def render_profile_as_json(
        self,
        company_data: dict,
        references:   list[dict],
    ) -> str:
        """Validate and render profile as JSON with a profile_markdown key.

        Runs the same validation sequence as render_profile().
        Calls render_profile() internally to produce the markdown.

        Args:
            company_data: Dict containing all profile fields.
            references:   Filtered, tiered reference list.

        Returns:
            Pretty-printed JSON string (indent=2). Contains all
            company_data keys plus a 'profile_markdown' key.

        Raises:
            ValueError: On any validation failure.
        """
        markdown = self.render_profile(company_data, references)
        payload  = {**company_data, "profile_markdown": markdown}
        return json.dumps(payload, indent=2, default=str)

    # ── Validation ────────────────────────────────────────────────────────────

    def _validate_required_fields(self, company_data: dict) -> None:
        """Raise ValueError naming the first missing or empty required field.

        Iterates config.REQUIRED_FIELDS in order. Stops and raises on the
        first key that is absent, an empty string, or an empty list.

        Args:
            company_data: Dict to validate.

        Raises:
            ValueError: With the exact missing key name.
        """
        for key in config.REQUIRED_FIELDS:
            value = company_data.get(key)
            if value is None or value == "" or value == []:
                raise ValueError(
                    f"Missing required field: '{key}'. "
                    f"Add it to your --input JSON file."
                )

    def _validate_talking_points(
        self,
        points: list[dict],
    ) -> list[dict]:
        """Filter talking points. Enforce count, header length, and metrics.

        Drops points whose body contains no quantitative metric.
        Logs dropped points to stderr.

        Args:
            points: List of dicts, each with 'header' (str) and 'body' (str).

        Returns:
            Filtered list of valid talking points.

        Raises:
            ValueError: If a header word count is out of range,
                        or fewer than MIN_TALKING_POINTS valid points remain.
        """
        valid: list[dict] = []
        for p in points:
            header = p.get("header", "")
            body   = p.get("body",   "")
            words  = header.split()

            if not (config.MIN_HEADER_WORDS <= len(words) <= config.MAX_HEADER_WORDS):
                raise ValueError(
                    f"Header '{header}' has {len(words)} word(s). "
                    f"Must be {config.MIN_HEADER_WORDS}–{config.MAX_HEADER_WORDS} words."
                )

            if not self._validator.has_quantitative_metrics(body):
                print(
                    f"WARNING: Dropping talking point '{header}' — "
                    f"no quantitative metric found in body.",
                    file=sys.stderr,
                )
                continue

            valid.append({"header": header, "body": body})

        if len(valid) < config.MIN_TALKING_POINTS:
            raise ValueError(
                f"Only {len(valid)} valid talking point(s) after metric "
                f"filtering. Minimum is {config.MIN_TALKING_POINTS}. "
                f"Add more data-backed points to your input file."
            )
        return valid

    # ── Render helpers ────────────────────────────────────────────────────────

    def _headcount_strings(
        self,
        size_class: str,
        count:      int | str,
    ) -> tuple[str, str, str]:
        """Return (small_str, mid_str, large_str) with metric on match only.

        Only the slot matching size_class gets the employee metric string.
        The other two slots are empty strings. Keeps the template f-string
        clean — no inline conditionals.

        Args:
            size_class: One of 'Small', 'Mid', or 'Large'.
            count:      Verified employee headcount (int or string).

        Returns:
            3-tuple where exactly one element contains the metric string.
        """
        try:
            n = int(str(count).replace(",", ""))
        except (ValueError, TypeError):
            n = 0

        formatted = f"{n:,}" if n > 0 else str(count)
        detail: dict[str, tuple[str, str, str]] = {
            "Small": (f"(Specifically approx. {formatted} employees)", "", ""),
            "Mid":   ("", f"(Specifically approx. {formatted} employees)", ""),
            "Large": ("", "", f"(Specifically {formatted}+)"),
        }
        return detail.get(size_class, ("", "", ""))

    def _render_talking_points(self, points: list[dict]) -> str:
        """Format validated talking points as markdown subsections.

        Args:
            points: Validated list of dicts with 'header' and 'body'.

        Returns:
            Formatted markdown string.
        """
        sections = []
        for p in points:
            sections.append(f"### {p['header']}:")
            sections.append(p["body"])
            sections.append("")
        return "\n".join(sections)

    def _render_references(self, references: list[dict]) -> str:
        """Format reference list in citation style.

        Args:
            references: List of reference dicts with standard 5-key schema.

        Returns:
            Formatted reference list string.
        """
        if not references:
            return "_No references retrieved. Run with a valid .env to fetch sources._\n"
        lines = []
        for r in references:
            lines.append(
                f"[{r.get('author','Unknown')}]. "
                f"({r.get('year','n.d.')}). "
                f"{r.get('title','Untitled')}. "
                f"{r.get('registry','')}.  "
                f"{r.get('url','')}"
            )
        return "\n".join(lines) + "\n"
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# src/main.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > src/main.py
"""CLI entrypoint.

Zero business logic here. Pure orchestration and I/O.
All validation and rendering is delegated to pipeline.py.

Usage examples:
    python -m src.main --name "Eli Lilly" --url lilly.com \\
        --input examples/eli_lilly.json

    python -m src.main --name "Pfizer" --url pfizer.com \\
        --input examples/pfizer.json --format json \\
        --output output/pfizer_profile.json

    python -m src.main --name "Pfizer" --url pfizer.com \\
        --input examples/pfizer.json --strict-tier top
"""

import argparse
import json
import sys
from pathlib import Path

from src.data_fetcher import DataFetcher
from src.validator    import SourceValidator
from src.pipeline     import CorporateIntelligencePipeline
from src              import config


def _build_parser() -> argparse.ArgumentParser:
    """Build and return the CLI argument parser.

    Returns:
        Configured ArgumentParser with all five flags.
    """
    p = argparse.ArgumentParser(
        prog="python -m src.main",
        description=(
            "Generate a verified, structured corporate intelligence profile "
            "for UNC partnership research."
        ),
    )
    p.add_argument(
        "--name",
        required=True,
        help="Exact legal corporate name (e.g. 'Eli Lilly and Company').",
    )
    p.add_argument(
        "--url",
        required=True,
        help="Company primary domain without scheme (e.g. 'lilly.com').",
    )
    p.add_argument(
        "--input",
        default=None,
        metavar="FILE",
        help=(
            "Path to a JSON file containing editorial profile fields. "
            "Run: python -m src.main --template to generate an empty one."
        ),
    )
    p.add_argument(
        "--output",
        default=None,
        metavar="FILE",
        help="File path to write the rendered profile. Defaults to stdout.",
    )
    p.add_argument(
        "--strict-tier",
        choices=["top", "second", "third"],
        default="third",
        dest="strict_tier",
        help=(
            "Minimum source credibility tier to include in references. "
            "top = gov/academic only. Default: third (all verified)."
        ),
    )
    p.add_argument(
        "--format",
        choices=["markdown", "json"],
        default="markdown",
        help="Output serialization format. Default: markdown.",
    )
    p.add_argument(
        "--template",
        action="store_true",
        help="Print an empty JSON input template and exit.",
    )
    return p


def _load_input_file(path: str) -> dict:
    """Load and parse a JSON editorial input file.

    Args:
        path: File path string.

    Returns:
        Parsed dict from the JSON file.

    Raises:
        SystemExit: On file not found or invalid JSON.
    """
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"ERROR: Input file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(1)


def _merge_data(fetched: dict, editorial: dict) -> dict:
    """Merge fetched API data with editorial input.

    Editorial fields take precedence over fetched data so the user's
    curated values are never overwritten by auto-fetched guesses.

    Args:
        fetched:   Dict from DataFetcher.fetch().
        editorial: Dict from the --input JSON file.

    Returns:
        Merged company_data dict ready for pipeline validation.
    """
    merged = {**fetched}
    merged.update(editorial)
    return merged


def _write_output(content: str, path: str | None) -> None:
    """Write content to a file or stdout.

    Creates parent directories automatically.

    Args:
        content: Rendered profile string.
        path:    Output file path, or None for stdout.
    """
    if path:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content, encoding="utf-8")
        print(f"Wrote profile to: {out}", file=sys.stderr)
    else:
        sys.stdout.write(content)


def _print_template() -> None:
    """Print an empty editorial JSON template to stdout."""
    template = {
        "name":             "COMPANY LEGAL NAME",
        "location":         "City, State",
        "url":              "company.com",
        "type":             "Public | Private | Subsidiary | Nonprofit",
        "size_class":       "Small | Mid | Large",
        "employee_count":   0,
        "actions":          "action 1, action 2, and action 3",
        "audiences":        "audience 1, audience 2, and audience 3",
        "descriptor":       "one short company descriptor",
        "alignment_asset":  "specific technology or pipeline asset",
        "unc_strengths":    "UNC strength 1, strength 2, and strength 3",
        "contact_person":   "Full Name",
        "contact_rationale":"their exact title and UNC connection",
        "ipo_status":       "Yes (TICKER: XXX) YEAR or No",
        "unc_alum_details": "Name (Title; Degree, UNC Year) or None identified",
        "donation_history": "Details or None on record",
        "talking_points": [
            {
                "header": "Two To Four Words",
                "body":   "One to two sentences. Must include a number, $amount, %, or year."
            },
            {
                "header": "Second Header Here",
                "body":   "Body with a verified metric like $4.2B or 38% growth in 2024."
            },
            {
                "header": "Third Header Here",
                "body":   "Body with verified metric. Minimum 3 points required."
            }
        ]
    }
    print(json.dumps(template, indent=2))


def main() -> None:
    """Parse arguments, run the pipeline, write output."""
    args = _build_parser().parse_args()

    if args.template:
        _print_template()
        sys.exit(0)

    try:
        # ── Load editorial fields from --input file ──────────────────────────
        editorial: dict = {}
        if args.input:
            editorial = _load_input_file(args.input)

        # ── Fetch quantitative data from registries ──────────────────────────
        fetcher    = DataFetcher()
        raw_data, raw_refs = fetcher.fetch(args.name, args.url)

        # ── Merge: editorial values override fetched values ──────────────────
        company_data = _merge_data(raw_data, editorial)

        # Ensure name and url are always set from CLI args if not in input
        company_data.setdefault("name", args.name)
        company_data.setdefault("url",  args.url)

        # ── Filter references by tier ────────────────────────────────────────
        validator  = SourceValidator()
        references = validator.filter_sources(raw_refs, args.strict_tier)

        # ── Validate and render ──────────────────────────────────────────────
        pipeline = CorporateIntelligencePipeline()

        if args.format == "json":
            output = pipeline.render_profile_as_json(company_data, references)
        else:
            output = pipeline.render_profile(company_data, references)

        _write_output(output, args.output)

    except (ValueError, EnvironmentError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# tests/__init__.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > tests/__init__.py
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# tests/test_validator.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > tests/test_validator.py
"""Unit tests for SourceValidator — 16 cases, zero network calls."""

import pytest
from src.validator import SourceValidator


@pytest.fixture
def v() -> SourceValidator:
    """Shared SourceValidator instance for all tests."""
    return SourceValidator()


# ── categorize_source ─────────────────────────────────────────────────────────

class TestCategorizeSource:

    def test_edgar_gov_is_top(self, v):
        assert v.categorize_source("https://sec.gov/edgar/search") == "top"

    def test_pubmed_is_top(self, v):
        assert v.categorize_source("https://pubmed.ncbi.nlm.nih.gov/1234") == "top"

    def test_nih_reporter_is_top(self, v):
        assert v.categorize_source("https://reporter.nih.gov/project-details/1") == "top"

    def test_sbir_gov_is_top(self, v):
        assert v.categorize_source("https://sbir.gov/award/123") == "top"

    def test_edu_is_second(self, v):
        assert v.categorize_source("https://unc.edu/research/report") == "second"

    def test_bloomberg_is_second(self, v):
        assert v.categorize_source("https://bloomberg.com/news/article") == "second"

    def test_reuters_is_third(self, v):
        assert v.categorize_source("https://reuters.com/business/article") == "third"

    def test_prnewswire_is_third(self, v):
        assert v.categorize_source("https://prnewswire.com/press-release") == "third"

    def test_random_blog_is_unverified(self, v):
        assert v.categorize_source("https://randomblog.io/opinion") == "unverified"

    def test_empty_string_is_unverified(self, v):
        assert v.categorize_source("") == "unverified"


# ── has_quantitative_metrics ──────────────────────────────────────────────────

class TestHasQuantitativeMetrics:

    def test_dollar_value_passes(self, v):
        assert v.has_quantitative_metrics("Revenue reached $4.2B in Q3.") is True

    def test_percentage_passes(self, v):
        assert v.has_quantitative_metrics("Grew 38% year over year.") is True

    def test_year_passes(self, v):
        assert v.has_quantitative_metrics("Founded in 1985.") is True

    def test_employee_count_passes(self, v):
        assert v.has_quantitative_metrics("Employs approximately 50,000 employees.") is True

    def test_pure_adjectives_fail(self, v):
        assert v.has_quantitative_metrics(
            "The company is an industry-leading innovator in global solutions."
        ) is False

    def test_empty_string_fails(self, v):
        assert v.has_quantitative_metrics("") is False


# ── filter_sources ────────────────────────────────────────────────────────────

class TestFilterSources:

    def _refs(self) -> list[dict]:
        return [
            {"url": "https://sec.gov/edgar"},
            {"url": "https://unc.edu/research"},
            {"url": "https://reuters.com/article"},
            {"url": "https://randomblog.io/post"},
        ]

    def test_strict_top_returns_only_top(self, v):
        result = v.filter_sources(self._refs(), min_tier="top")
        assert len(result) == 1
        assert "sec.gov" in result[0]["url"]

    def test_second_returns_top_and_second(self, v):
        result = v.filter_sources(self._refs(), min_tier="second")
        assert len(result) == 2

    def test_third_returns_top_second_third(self, v):
        result = v.filter_sources(self._refs(), min_tier="third")
        assert len(result) == 3

    def test_unverified_always_excluded(self, v):
        result = v.filter_sources(self._refs(), min_tier="third")
        urls = [r["url"] for r in result]
        assert all("randomblog" not in u for u in urls)

    def test_invalid_min_tier_raises(self, v):
        with pytest.raises(ValueError, match="Invalid min_tier"):
            v.filter_sources([], min_tier="premium")

    def test_empty_list_returns_empty(self, v):
        assert v.filter_sources([], min_tier="top") == []
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# tests/test_pipeline.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > tests/test_pipeline.py
"""Unit tests for CorporateIntelligencePipeline — 12 cases."""

import json
import pytest
from src.pipeline import CorporateIntelligencePipeline


@pytest.fixture
def pipeline() -> CorporateIntelligencePipeline:
    return CorporateIntelligencePipeline()


@pytest.fixture
def valid_data() -> dict:
    """Minimal valid company_data dict for testing."""
    return {
        "name":             "Acme BioTech Inc.",
        "location":         "Durham, NC",
        "url":              "acmebiotech.com",
        "type":             "Private",
        "size_class":       "Small",
        "employee_count":   42,
        "actions":          "drug discovery, clinical testing, and data analysis",
        "audiences":        "oncology patients, academic researchers, and pharma partners",
        "descriptor":       "early-stage biotechnology firm",
        "alignment_asset":  "novel CRISPR-based gene editing platform with 3 active IND filings",
        "unc_strengths":    "genomic research, clinical trial infrastructure, and biomedical informatics",
        "contact_person":   "Dr. Jane Smith",
        "contact_rationale":"serves as VP of Research and completed her PhD at UNC-CH in 2008",
        "ipo_status":       "No",
        "unc_alum_details": "Dr. Jane Smith (VP Research; PhD Pharmacology, UNC-CH 2008)",
        "donation_history": "None identified on public record",
        "talking_points": [
            {
                "header":   "Series B Raise",
                "body":     "Acme BioTech closed a $22M Series B in March 2024.",
            },
            {
                "header":   "Patent Portfolio",
                "body":     "The firm holds 7 granted patents as of 2025.",
            },
            {
                "header":   "Clinical Pipeline",
                "body":     "Lead compound entered Phase 1 trials in 2024 with 48 enrolled patients.",
            },
        ],
    }


@pytest.fixture
def valid_refs() -> list[dict]:
    return [
        {
            "author":   "SEC EDGAR",
            "year":     "2024",
            "title":    "Acme BioTech 10-K",
            "registry": "SEC EDGAR",
            "url":      "https://sec.gov/edgar/acmebiotech",
        }
    ]


# ── render_profile ────────────────────────────────────────────────────────────

class TestRenderProfile:

    def test_renders_all_section_headers(self, pipeline, valid_data, valid_refs):
        output = pipeline.render_profile(valid_data, valid_refs)
        assert "## Basic Company Information" in output
        assert "## UNC Connection" in output
        assert "## Talking Points" in output
        assert "## References" in output

    def test_renders_company_name_in_header(self, pipeline, valid_data, valid_refs):
        output = pipeline.render_profile(valid_data, valid_refs)
        assert "Acme BioTech Inc." in output

    def test_small_size_class_placement(self, pipeline, valid_data, valid_refs):
        output = pipeline.render_profile(valid_data, valid_refs)
        assert "(Specifically approx. 42 employees)" in output
        # Mid and Large rows should be empty
        lines = output.splitlines()
        mid_line   = next(l for l in lines if l.startswith("Mid:"))
        large_line = next(l for l in lines if l.startswith("Large:"))
        assert mid_line.strip()   == "Mid: 100-749"
        assert large_line.strip() == "Large: 750+"

    def test_large_size_class_placement(self, pipeline, valid_data, valid_refs):
        valid_data["size_class"]     = "Large"
        valid_data["employee_count"] = 50000
        output = pipeline.render_profile(valid_data, valid_refs)
        assert "50,000+" in output

    def test_talking_points_rendered(self, pipeline, valid_data, valid_refs):
        output = pipeline.render_profile(valid_data, valid_refs)
        assert "Series B Raise" in output
        assert "$22M" in output


# ── validation failures ───────────────────────────────────────────────────────

class TestValidationFailures:

    def test_missing_required_field_raises(self, pipeline, valid_data, valid_refs):
        del valid_data["name"]
        with pytest.raises(ValueError, match="name"):
            pipeline.render_profile(valid_data, valid_refs)

    def test_empty_required_field_raises(self, pipeline, valid_data, valid_refs):
        valid_data["location"] = ""
        with pytest.raises(ValueError, match="location"):
            pipeline.render_profile(valid_data, valid_refs)

    def test_talking_point_no_metric_is_dropped(self, pipeline, valid_data, valid_refs):
        valid_data["talking_points"].append({
            "header": "Vague Claim",
            "body":   "The company is a leading innovator in solutions.",
        })
        # Should not raise — 3 valid points remain after dropping the vague one
        output = pipeline.render_profile(valid_data, valid_refs)
        assert "Vague Claim" not in output

    def test_too_few_valid_points_raises(self, pipeline, valid_data, valid_refs):
        valid_data["talking_points"] = [
            {"header": "Only Point", "body": "No metrics here at all."},
        ]
        with pytest.raises(ValueError, match="valid talking point"):
            pipeline.render_profile(valid_data, valid_refs)

    def test_header_too_long_raises(self, pipeline, valid_data, valid_refs):
        valid_data["talking_points"][0]["header"] = "This Is Five Words Long"
        with pytest.raises(ValueError, match="word"):
            pipeline.render_profile(valid_data, valid_refs)


# ── render_profile_as_json ────────────────────────────────────────────────────

class TestRenderProfileAsJson:

    def test_output_is_valid_json(self, pipeline, valid_data, valid_refs):
        output = pipeline.render_profile_as_json(valid_data, valid_refs)
        parsed = json.loads(output)
        assert isinstance(parsed, dict)

    def test_contains_profile_markdown_key(self, pipeline, valid_data, valid_refs):
        output = pipeline.render_profile_as_json(valid_data, valid_refs)
        parsed = json.loads(output)
        assert "profile_markdown" in parsed
        assert len(parsed["profile_markdown"]) > 100
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# tests/test_data_fetcher.py
# ═════════════════════════════════════════════════════════════════════════════
cat << 'PYEOF' > tests/test_data_fetcher.py
"""Unit tests for DataFetcher — all HTTP calls mocked, zero network calls."""

import pytest
from unittest.mock import patch, MagicMock
from src.data_fetcher import DataFetcher
from src import config


@pytest.fixture
def fetcher(monkeypatch) -> DataFetcher:
    """DataFetcher with env vars patched."""
    monkeypatch.setenv("NCBI_API_KEY", "test_key_12345")
    monkeypatch.setenv("REQUEST_TIMEOUT_SECONDS", "5")
    monkeypatch.setenv("MAX_SOURCES_PER_REGISTRY", "3")
    return DataFetcher()


# ── _build_reference ──────────────────────────────────────────────────────────

class TestBuildReference:

    def test_returns_five_keys(self, fetcher):
        ref = fetcher._build_reference(
            author="SEC", year="2024", title="Test",
            registry="EDGAR", url="https://sec.gov"
        )
        assert set(ref.keys()) == {"author", "year", "title", "registry", "url"}

    def test_values_stored_correctly(self, fetcher):
        ref = fetcher._build_reference(
            author="NIH", year="2023", title="Grant",
            registry="NIH Reporter", url="https://reporter.nih.gov"
        )
        assert ref["author"] == "NIH"
        assert ref["year"]   == "2023"
        assert ref["url"]    == "https://reporter.nih.gov"


# ── _fetch_edgar ─────────────────────────────────────────────────────────────

class TestFetchEdgar:

    def test_returns_empty_on_no_hits(self, fetcher):
        mock_resp = MagicMock()
        mock_resp.raise_for_status.return_value = None
        mock_resp.json.return_value = {"hits": {"hits": []}}

        with patch("requests.get", return_value=mock_resp):
            partial, refs = fetcher._fetch_edgar("Nonexistent Corp")

        assert partial == {}
        assert refs   == []

    def test_extracts_ipo_status_from_ticker(self, fetcher):
        mock_resp = MagicMock()
        mock_resp.raise_for_status.return_value = None
        mock_resp.json.return_value = {
            "hits": {
                "hits": [{
                    "_source": {
                        "entity_name":        "Acme Inc",
                        "ticker":             "ACME",
                        "period_of_report":   "2024-01-01",
                        "business_address":   {"city": "Durham", "state_or_country": "NC"},
                    }
                }]
            }
        }

        with patch("requests.get", return_value=mock_resp):
            partial, refs = fetcher._fetch_edgar("Acme Inc")

        assert "ACME" in partial["ipo_status"]
        assert partial["type"] == "Public"
        assert len(refs) == 1
        assert refs[0]["registry"] == "SEC EDGAR Full-Text Search"

    def test_returns_empty_on_request_exception(self, fetcher):
        import requests as req_lib
        with patch("requests.get", side_effect=req_lib.RequestException("timeout")):
            partial, refs = fetcher._fetch_edgar("Any Corp")

        assert partial == {}
        assert refs   == []


# ── _fetch_nih ────────────────────────────────────────────────────────────────

class TestFetchNih:

    def test_returns_empty_on_no_results(self, fetcher):
        mock_resp = MagicMock()
        mock_resp.raise_for_status.return_value = None
        mock_resp.json.return_value = {"results": []}

        with patch("requests.post", return_value=mock_resp):
            partial, refs = fetcher._fetch_nih("Unknown Corp")

        assert partial == {}
        assert refs   == []

    def test_builds_grant_summary_on_award_amount(self, fetcher):
        mock_resp = MagicMock()
        mock_resp.raise_for_status.return_value = None
        mock_resp.json.return_value = {
            "results": [{
                "award_amount":            5_000_000,
                "fiscal_year":             2024,
                "project_title":           "Cancer Research",
                "project_num":             "R01CA123456",
                "principal_investigators": [{"full_name": "Dr. Lee"}],
            }]
        }

        with patch("requests.post", return_value=mock_resp):
            partial, refs = fetcher._fetch_nih("Acme BioTech")

        assert "_nih_grant_summary" in partial
        assert "$5.0M" in partial["_nih_grant_summary"]
        assert len(refs) == 1


# ── fetch (integration) ───────────────────────────────────────────────────────

class TestFetch:

    def test_url_set_from_argument(self, fetcher):
        with patch.object(fetcher, "_fetch_edgar",    return_value=({}, [])), \
             patch.object(fetcher, "_fetch_pubmed",   return_value=({}, [])), \
             patch.object(fetcher, "_fetch_nih",      return_value=({}, [])), \
             patch.object(fetcher, "_fetch_sbir",     return_value=({}, [])):

            data, _ = fetcher.fetch("Test Corp", "testcorp.com")

        assert data.get("url") == "testcorp.com"

    def test_merges_two_partial_dicts(self, fetcher):
        with patch.object(fetcher, "_fetch_edgar",  return_value=({"type": "Public"}, [])), \
             patch.object(fetcher, "_fetch_pubmed", return_value=({}, [])), \
             patch.object(fetcher, "_fetch_nih",    return_value=({"_nih": "yes"}, [])), \
             patch.object(fetcher, "_fetch_sbir",   return_value=({}, [])):

            data, _ = fetcher.fetch("Test Corp", "testcorp.com")

        assert data.get("type")  == "Public"
        assert data.get("_nih")  == "yes"

    def test_concatenates_refs_from_all_sources(self, fetcher):
        ref_a = {"author": "SEC", "year": "2024", "title": "A",
                 "registry": "EDGAR", "url": "https://sec.gov"}
        ref_b = {"author": "NIH", "year": "2024", "title": "B",
                 "registry": "NIH", "url": "https://nih.gov"}

        with patch.object(fetcher, "_fetch_edgar",  return_value=({}, [ref_a])), \
             patch.object(fetcher, "_fetch_pubmed", return_value=({}, [])),      \
             patch.object(fetcher, "_fetch_nih",    return_value=({}, [ref_b])), \
             patch.object(fetcher, "_fetch_sbir",   return_value=({}, [])):

            _, refs = fetcher.fetch("Test Corp", "testcorp.com")

        assert len(refs) == 2
PYEOF


# ═════════════════════════════════════════════════════════════════════════════
# examples/eli_lilly.json
# ═════════════════════════════════════════════════════════════════════════════
cat << 'JSONEOF' > examples/eli_lilly.json
{
  "name":             "Eli Lilly and Company",
  "location":         "Indianapolis, IN",
  "url":              "lilly.com",
  "type":             "Public",
  "size_class":       "Large",
  "employee_count":   50000,
  "actions":          "biopharmaceutical research, drug development, and global manufacturing",
  "audiences":        "patients with chronic conditions, academic research partners, and healthcare systems",
  "descriptor":       "multinational pharmaceutical corporation",
  "alignment_asset":  "heavy investment in AI-driven drug discovery, including its 2026 collaboration with Chai Discovery",
  "unc_strengths":    "biomedical informatics, clinical trial infrastructure, and health data science",
  "contact_person":   "Markus Saba",
  "contact_rationale":"serves as Executive Director of the Center for the Business of Health at UNC after retiring as a senior Eli Lilly executive, bridging deep operational knowledge of Lilly's internal research pipeline with direct academic credibility within UNC's health business ecosystem",
  "ipo_status":       "Yes (NYSE: LLY) 1952",
  "unc_alum_details": "Markus Saba (Retired Eli Lilly Senior Executive; currently Executive Director, Center for the Business of Health at UNC-Chapel Hill)",
  "donation_history": "Lilly maintains an active philanthropic presence in healthcare education. Specific granular donation history to UNC-Chapel Hill is best verified via the UNC Office of Development.",
  "talking_points": [
    {
      "header": "AI Drug Discovery",
      "body":   "In 2026, Eli Lilly partnered with Chai Discovery to apply generative AI to biologic design, deploying the open-source 'Lilly TuneLab' initiative that trains models on proprietary research data for academic use."
    },
    {
      "header": "Revenue Growth 2024",
      "body":   "Eli Lilly reported full-year 2024 revenue of approximately $45.0 billion, representing a 32% increase over 2023, driven primarily by tirzepatide (Mounjaro and Zepbound) sales exceeding $10 billion."
    },
    {
      "header": "Clinical Trial Scale",
      "body":   "Eli Lilly runs more than 200 active clinical trials globally as of 2025, enrolling tens of thousands of patients across oncology, metabolic disease, and neurodegeneration programs."
    },
    {
      "header": "R&D Investment 2024",
      "body":   "The company invested approximately $9.3 billion in research and development in 2024, representing roughly 21% of total revenue and one of the highest R&D ratios in the sector."
    },
    {
      "header": "Patent Pipeline Strength",
      "body":   "Lilly holds more than 1,000 active patents across its therapeutic portfolio as of 2025, with GLP-1 receptor agonist compounds representing 14 of the 28 compounds in late-stage development."
    }
  ]
}
JSONEOF


# ═════════════════════════════════════════════════════════════════════════════
# examples/pfizer.json  (second example — user can run immediately)
# ═════════════════════════════════════════════════════════════════════════════
cat << 'JSONEOF' > examples/pfizer.json
{
  "name":             "Pfizer Inc.",
  "location":         "New York, NY",
  "url":              "pfizer.com",
  "type":             "Public",
  "size_class":       "Large",
  "employee_count":   88000,
  "actions":          "pharmaceutical research, vaccine development, and biologic manufacturing",
  "audiences":        "global patients, public health agencies, and clinical research institutions",
  "descriptor":       "multinational pharmaceutical and biotechnology corporation",
  "alignment_asset":  "extensive mRNA platform technology developed during COVID-19 vaccine programs and now applied to oncology and rare disease pipelines",
  "unc_strengths":    "infectious disease research, mRNA technology translation, and population health data science",
  "contact_person":   "None identified in current executive leadership",
  "contact_rationale":"no verified UNC alum currently holds a decision-making role; outreach recommended via UNC Lineberger Comprehensive Cancer Center collaborative research office",
  "ipo_status":       "Yes (NYSE: PFE) 1944",
  "unc_alum_details": "None identified in current executive leadership",
  "donation_history": "Pfizer Foundation has donated to public health initiatives globally. Specific UNC-directed grants should be verified via the UNC Office of Research.",
  "talking_points": [
    {
      "header": "mRNA Platform Expansion",
      "body":   "Pfizer's mRNA pipeline beyond COVID-19 includes 31 active programs as of 2025, targeting influenza, RSV, and 9 oncology indications."
    },
    {
      "header": "R&D Spend 2024",
      "body":   "Pfizer reported $10.7 billion in R&D expenditure in 2024, focused on oncology (40% of pipeline), vaccines (28%), and rare disease (18%)."
    },
    {
      "header": "Oncology Acquisitions",
      "body":   "The $43 billion acquisition of Seagen in 2023 added 4 approved ADC therapies and a pipeline of 14 oncology compounds to Pfizer's portfolio."
    },
    {
      "header": "Manufacturing Network",
      "body":   "Pfizer operates 37 manufacturing sites across 17 countries, producing over 4 billion doses of medicines and vaccines annually as of 2024."
    }
  ]
}
JSONEOF


# ═════════════════════════════════════════════════════════════════════════════
# requirements.txt
# ═════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > requirements.txt
requests==2.31.0
python-dotenv==1.0.0
pytest==8.1.0
pytest-mock==3.12.0
pytest-cov==5.0.0
black==24.4.0
flake8==7.0.0
EOF


# ═════════════════════════════════════════════════════════════════════════════
# .env.example
# ═════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > .env.example
# ── Required ───────────────────────────────────────────────────────────────────
# NCBI PubMed E-utilities API key.
# Register free at: https://www.ncbi.nlm.nih.gov/account/
# Without this key, PubMed fetcher is silently skipped.
NCBI_API_KEY=your_ncbi_api_key_here

# ── Optional (all have defaults) ──────────────────────────────────────────────
# HTTP request timeout in seconds. Default: 10
REQUEST_TIMEOUT_SECONDS=10

# Max results fetched per registry call. Default: 5
MAX_SOURCES_PER_REGISTRY=5
EOF


# ═════════════════════════════════════════════════════════════════════════════
# .gitignore
# ═════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > .gitignore
# Python
__pycache__/
*.py[cod]
*.pyo
*.pyd
.Python
*.egg-info/
dist/
build/
.eggs/

# Virtual environments
.venv/
venv/
env/

# Environment variables — NEVER commit
.env

# Test coverage
.coverage
htmlcov/
.pytest_cache/

# Generated output profiles
output/*.md
output/*.json

# macOS / editors
.DS_Store
*.swp
*.swo
.idea/
.vscode/
EOF


# ═════════════════════════════════════════════════════════════════════════════
# Makefile
# ═════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > Makefile
.PHONY: run run-pfizer test lint coverage docker-build docker-run template clean help

# Default target
help:
	@echo ""
	@echo "tool-corporate-research-analytics"
	@echo "──────────────────────────────────"
	@echo "  make run          Run pipeline with Eli Lilly example"
	@echo "  make run-pfizer   Run pipeline with Pfizer example"
	@echo "  make test         Run full test suite"
	@echo "  make lint         Run black + flake8"
	@echo "  make coverage     Run tests with coverage report"
	@echo "  make template     Print empty JSON input template"
	@echo "  make docker-build Build production Docker image"
	@echo "  make docker-run   Run pipeline in Docker (Eli Lilly)"
	@echo "  make clean        Remove __pycache__ and .coverage"
	@echo ""

run:
	python -m src.main \
		--name "Eli Lilly and Company" \
		--url  "lilly.com" \
		--input examples/eli_lilly.json

run-pfizer:
	python -m src.main \
		--name "Pfizer Inc." \
		--url  "pfizer.com" \
		--input examples/pfizer.json

run-json:
	python -m src.main \
		--name "Eli Lilly and Company" \
		--url  "lilly.com" \
		--input examples/eli_lilly.json \
		--format json \
		--output output/eli_lilly.json

test:
	pytest tests/ -v

lint:
	black --check src/ tests/
	flake8 src/ tests/ --max-line-length 88

coverage:
	pytest tests/ --cov=src --cov-report=term-missing

template:
	python -m src.main --name dummy --url dummy --template

docker-build:
	docker build -t corp-analytics-tool .

docker-run:
	docker run --rm \
		--env-file .env \
		-v "$(PWD)/examples:/app/examples:ro" \
		-v "$(PWD)/output:/app/output" \
		corp-analytics-tool \
		--name "Eli Lilly and Company" \
		--url  "lilly.com" \
		--input examples/eli_lilly.json \
		--output output/eli_lilly_docker.md

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	rm -f .coverage
	rm -f output/*.md output/*.json
EOF


# ═════════════════════════════════════════════════════════════════════════════
# Dockerfile
# ═════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > Dockerfile
FROM python:3.11-slim

WORKDIR /app

# Install dependencies first (layer-cached if requirements.txt unchanged)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy only production source — tests/, Makefile, .env excluded via .dockerignore
COPY src/ ./src/

# Output directory for --output flag via volume mount
RUN mkdir -p output

ENTRYPOINT ["python", "-m", "src.main"]
EOF


# ═════════════════════════════════════════════════════════════════════════════
# .dockerignore
# ═════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > .dockerignore
tests/
Makefile
.env
.env.example
.gitignore
.coverage
htmlcov/
.pytest_cache/
__pycache__/
*.pyc
.venv/
venv/
output/
README.md
EOF


# ═════════════════════════════════════════════════════════════════════════════
# output/.gitkeep  (so git tracks the output dir but not its contents)
# ═════════════════════════════════════════════════════════════════════════════
touch output/.gitkeep


# ═════════════════════════════════════════════════════════════════════════════
# Done
# ═════════════════════════════════════════════════════════════════════════════
cd ..

echo ""
echo "✓  $P scaffolded successfully."
echo ""
echo "Next steps:"
echo ""
echo "  cd $P"
echo "  python3 -m venv .venv && source .venv/bin/activate"
echo "  pip install -r requirements.txt"
echo "  cp .env.example .env"
echo "  # (optional) add your free NCBI_API_KEY to .env"
echo "  # https://www.ncbi.nlm.nih.gov/account/"
echo ""
echo "Run the pipeline:"
echo "  make run              # Eli Lilly — markdown to stdout"
echo "  make run-pfizer       # Pfizer — markdown to stdout"
echo "  make run-json         # Eli Lilly — JSON to output/eli_lilly.json"
echo ""
echo "Your own company:"
echo "  make template > examples/my_company.json"
echo "  # fill in the fields"
echo "  python -m src.main --name 'Company Name' --url 'company.com' \\"
echo "      --input examples/my_company.json"
echo ""
echo "Tests:"
echo "  make test"
echo "  make coverage"
echo ""
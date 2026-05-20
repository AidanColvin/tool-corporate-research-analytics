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

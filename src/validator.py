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

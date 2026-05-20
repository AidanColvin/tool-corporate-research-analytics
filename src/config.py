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

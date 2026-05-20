# tool-corporate-research-analytics

> An automated data pipeline that extracts and structures verified corporate intelligence using a strict source hierarchy.

---

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Project Structure](#project-structure)
4. [Module Reference](#module-reference)
5. [Source Hierarchy Engine](#source-hierarchy-engine)
6. [Profile Template Specification](#profile-template-specification)
7. [Installation](#installation)
8. [Usage](#usage)
9. [CLI Reference](#cli-reference)
10. [Environment Variables](#environment-variables)
11. [Docker Deployment](#docker-deployment)
12. [Testing](#testing)
13. [Output Format](#output-format)
14. [Extending the Pipeline](#extending-the-pipeline)
15. [Known Limitations](#known-limitations)
16. [Contributing](#contributing)
17. [License](#license)

---

## Overview

`tool-corporate-research-analytics` is a terminal-first Python data pipeline that automates the workflow of a corporate research analyst.

The program accepts a target company name and domain URL as CLI arguments. It queries verified external data registries, filters all extracted claims through a tiered credibility hierarchy, and renders the validated output into a strict, immutable markdown profiling template.

**Core design constraints:**

- Every factual claim must contain a quantitative metric (dollar amount, headcount, date, or statistical percentage).
- All source URLs are scored against a three-tier credibility hierarchy before inclusion.
- The output template structure is immutable. No heading, field order, or bolding rule may be altered at runtime.
- Zero marketing buzzwords or vague descriptors are permitted in generated output.

**Primary use case:** Accelerating institutional partnership research for academic programs (e.g., UNC Chapel Hill) by producing standardized, citation-backed corporate intelligence profiles.

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        CLI Entrypoint                        │
│                  python -m src.main --name --url             │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                      data_fetcher.py                         │
│   Multi-source registry query engine                         │
│   Targets: SEC EDGAR · PubMed · .edu · Bloomberg · Reuters  │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                       validator.py                           │
│   Source credibility tiering (Top / Second / Third)          │
│   Quantitative metric presence detection                     │
│   Unverified source rejection                                │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                       pipeline.py                            │
│   Orchestration logic                                        │
│   Inline citation mapping                                    │
│   Template rendering engine                                  │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                     stdout / .md file                        │
│   Structured markdown company profile with bracketed         │
│   inline citations and a full reference list                 │
└──────────────────────────────────────────────────────────────┘
```

**Key architectural decisions:**

| Decision | Rationale |
|---|---|
| Modular single-responsibility modules | Each file owns exactly one pipeline stage. Enables isolated unit testing and independent module replacement. |
| CLI-first execution | Enables integration into CI/CD pipelines, cron jobs, and shell scripts without modification. |
| Regex-based source tiering in `validator.py` | Deterministic, zero-latency classification without external API dependency. |
| Immutable template string in `pipeline.py` | Prevents accidental field reordering or structural drift across output versions. |
| Docker support | Ensures reproducible execution across macOS, Linux, and Windows environments. |

---

## Project Structure

```
tool-corporate-research-analytics/
│
├── src/
│   ├── __init__.py              # Package namespace declaration
│   ├── main.py                  # CLI entrypoint; argument parsing; pipeline trigger
│   ├── pipeline.py              # Orchestration logic; template rendering engine
│   ├── data_fetcher.py          # Multi-source external registry query engine
│   └── validator.py             # Source hierarchy enforcement; metric verification
│
├── tests/
│   ├── __init__.py
│   ├── test_validator.py        # Unit tests for source tiering and metric detection
│   ├── test_pipeline.py         # Unit tests for template rendering and field mapping
│   └── test_data_fetcher.py     # Unit tests for registry query logic (mocked responses)
│
├── output/
│   └── .gitkeep                 # Output directory for generated .md profile files
│
├── Dockerfile                   # Containerized runtime environment definition
├── .dockerignore                # Excludes test files and output dir from image
├── requirements.txt             # Hardened, version-pinned dependency list
├── .env.example                 # Template for required environment variable keys
├── .gitignore                   # Excludes __pycache__, .env, output/*.md
├── Makefile                     # Convenience targets: run, test, lint, docker-build
└── README.md                    # This file
```

---

## Module Reference

### `src/main.py`

**Responsibility:** CLI entrypoint. Parses arguments, constructs the ingestion payload, and triggers the pipeline.

**Key functions:**

```python
def main() -> None
```

- Parses `--name` and `--url` via `argparse`.
- Calls `data_fetcher.fetch()` with the provided arguments.
- Passes the fetched payload and validated references to `pipeline.render_profile()`.
- Writes the rendered markdown string to `stdout` or an optional `--output` file path.

---

### `src/data_fetcher.py`

**Responsibility:** Queries external data registries. Returns a structured dictionary of raw company facts and a list of source reference objects.

**Key functions:**

```python
def fetch(company_name: str, url: str) -> tuple[dict, list[dict]]
```

- Constructs targeted search queries against the following registry tiers:
  - **Top Tier:** SEC EDGAR full-text search API, PubMed E-utilities API, NIH Reporter, SBIR.gov awards database.
  - **Second Tier:** Official company investor relations subdomains, `.edu` domain searches, PitchBook and Tracxn scrape-safe endpoints.
  - **Third Tier:** Reuters, PR Newswire, BusinessWire press wire registries.
- Returns a raw `company_data` dict and a `references` list before validation filtering.

**External APIs used:**

| Registry | Endpoint | Tier |
|---|---|---|
| SEC EDGAR | `https://efts.sec.gov/LATEST/search-index?q=` | Top |
| PubMed E-utilities | `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/` | Top |
| NIH Reporter | `https://api.reporter.nih.gov/v2/projects/search` | Top |
| SBIR.gov | `https://www.sbir.gov/api/` | Top |
| Reuters | `https://www.reuters.com/search/` | Third |

---

### `src/validator.py`

**Responsibility:** Enforces the source credibility hierarchy. Rejects unverified sources and validates that extracted claim strings contain quantitative metrics.

**Key functions:**

```python
def categorize_source(self, url: str) -> str
```

- Matches the source URL against compiled regex patterns for each tier.
- Returns `'top'`, `'second'`, `'third'`, or `'unverified'`.
- `'unverified'` sources are excluded from the final reference list automatically.

```python
def has_quantitative_metrics(self, text: str) -> bool
```

- Scans the extracted text string for the presence of numeric data.
- Matches: integers, percentages (`%`), dollar values (`$`), and four-digit year strings.
- Returns `False` for text containing only descriptive or qualitative language.
- Talking points that fail this check are flagged and excluded from the output.

**Tier classification regex patterns:**

| Tier | Matched Domains |
|---|---|
| Top | `*.gov`, `ncbi.nlm.nih.gov`, `sec.gov/edgar`, `pubmed.*` |
| Second | `*.edu`, `bloomberg.com`, `tracxn.com`, `pitchbook.com` |
| Third | `reuters.com`, `prnewswire.com`, `businesswire.com` |
| Unverified | All other domains |

---

### `src/pipeline.py`

**Responsibility:** Orchestrates the full pipeline. Accepts validated data and renders the immutable markdown output template.

**Key functions:**

```python
def render_profile(self, company_data: dict, references: list[dict]) -> str
```

- Applies headcount placement logic: only the matching size class (`Small`, `Mid`, or `Large`) receives the specific employee metric. The other two classes render blank.
- Maps all validated `talking_points` list entries into the `### Header: Body` format.
- Appends the full reference list in the specified citation format.
- Returns a single markdown string ready for `stdout` or file write.

---

## Source Hierarchy Engine

All facts in the generated profile are graded before inclusion. The hierarchy is enforced in `validator.py` and applied during `pipeline.py` orchestration.

```
┌─────────────────────────────────────────────────────────────┐
│  TIER 1 — TOP (Highest Priority)                            │
│  Peer-reviewed academic journals: JAMA, PubMed, Nature      │
│  Official government databases: SEC EDGAR, NIH, FDA,        │
│  NASA, SBIR.gov                                             │
├─────────────────────────────────────────────────────────────┤
│  TIER 2 — SECOND                                            │
│  Official university sites (.edu)                           │
│  Corporate investor relations pages (official IR subdomain) │
│  Reputable industry tracking: PitchBook, Tracxn, Bloomberg  │
├─────────────────────────────────────────────────────────────┤
│  TIER 3 — THIRD                                             │
│  Established news registries: Reuters                       │
│  Press wires: PR Newswire, BusinessWire                     │
├─────────────────────────────────────────────────────────────┤
│  UNVERIFIED — REJECTED                                      │
│  All other domains. Excluded from output. Not cited.        │
└─────────────────────────────────────────────────────────────┘
```

**Conflict resolution rule:** When two sources report the same metric with conflicting values, the higher-tier source takes precedence. The lower-tier source is still listed in the reference section but is marked `[Lower-tier, secondary confirmation only]`.

---

## Profile Template Specification

The output template is immutable. The following fields are required for a valid render. Missing required fields cause the pipeline to exit with a non-zero status code and a descriptive error message.

| Field Key | Type | Required | Description |
|---|---|---|---|
| `name` | `str` | ✅ | Exact legal company name |
| `location` | `str` | ✅ | City, State or Country |
| `url` | `str` | ✅ | Domain only (e.g., `lilly.com`) |
| `type` | `str` | ✅ | `Public`, `Private`, `Subsidiary`, or `Nonprofit` |
| `size_class` | `str` | ✅ | `Small`, `Mid`, or `Large` |
| `employee_count` | `int` | ✅ | Approximate verified headcount |
| `actions` | `str` | ✅ | 3 core operational actions, comma-separated |
| `audiences` | `str` | ✅ | 3 target audience descriptors, comma-separated |
| `descriptor` | `str` | ✅ | Single plain-English company type label |
| `alignment_asset` | `str` | ✅ | Specific technology, pipeline asset, or market strategy |
| `unc_strengths` | `str` | ✅ | 3 UNC institutional strengths, comma-separated |
| `contact_person` | `str` | ✅ | Full name of best partnership avenue contact |
| `contact_rationale` | `str` | ✅ | Exact title, UNC connection, and institutional bridge |
| `ipo_status` | `str` | ✅ | `Yes (TICKER: XXX) YEAR` or `No` |
| `unc_alum_details` | `str` | ✅ | Full name, title, degree, and graduation year |
| `donation_history` | `str` | ✅ | Verified donation metrics or `None identified` |
| `talking_points` | `list[dict]` | ✅ | 3–6 dicts, each with `header` (str) and `body` (str) |

**Talking point validation rules:**

- Minimum: 3 talking points. Maximum: 6.
- Every `body` string must pass `has_quantitative_metrics()` or it is excluded.
- Every `header` string must be 2–4 words. Longer headers raise a `ValueError`.

---

## Installation

### Prerequisites

- Python `3.10` or greater
- `pip` package manager
- Docker (optional, for containerized execution)

### Standard Setup

```bash
# 1. Clone the repository
git clone https://github.com/AidanColvin/tool-corporate-research-analytics.git
cd tool-corporate-research-analytics

# 2. Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate        # macOS / Linux
.venv\Scripts\activate           # Windows

# 3. Install pinned dependencies
pip install -r requirements.txt

# 4. Copy the environment variable template
cp .env.example .env
# Edit .env and populate required API keys (see Environment Variables section)
```

---

## Usage

### Basic Execution

```bash
python -m src.main --name "Eli Lilly and Company" --url "lilly.com"
```

Renders the structured markdown profile to `stdout`.

### Save Output to File

```bash
python -m src.main --name "Eli Lilly and Company" --url "lilly.com" --output output/eli_lilly_profile.md
```

Writes the rendered profile to `output/eli_lilly_profile.md`.

### Suppress Unverified Sources

```bash
python -m src.main --name "Pfizer" --url "pfizer.com" --strict-tier top
```

Restricts the reference list to Top Tier sources only. Excludes Second and Third Tier citations.

### Makefile Shortcuts

```bash
make run       # Runs the pipeline with default test arguments
make test      # Executes the full pytest test suite
make lint      # Runs flake8 and black formatting checks
make docker-build  # Builds the Docker container image
```

---

## CLI Reference

```
usage: python -m src.main [-h] --name NAME --url URL [--output OUTPUT] [--strict-tier {top,second,third}] [--format {markdown,json}]

Required Arguments:
  --name          Exact legal corporate name of the target company.
  --url           Primary domain URL of the target company (domain only, no https://).

Optional Arguments:
  --output        File path for the rendered profile output. Defaults to stdout.
  --strict-tier   Restrict included sources to a minimum credibility tier.
                  Options: top | second | third
                  Default: third (includes all verified tiers)
  --format        Output serialization format.
                  Options: markdown | json
                  Default: markdown

Help:
  -h, --help      Show this message and exit.
```

---

## Environment Variables

Copy `.env.example` to `.env` and populate the following keys before running the pipeline.

```bash
# .env.example

# Required: SEC EDGAR full-text search API (no key required, but set base URL)
EDGAR_BASE_URL=https://efts.sec.gov/LATEST/search-index

# Required: NCBI PubMed E-utilities API key (register free at: https://www.ncbi.nlm.nih.gov/account/)
NCBI_API_KEY=your_ncbi_api_key_here

# Required: NIH Reporter API base URL
NIH_REPORTER_URL=https://api.reporter.nih.gov/v2/projects/search

# Optional: Request timeout in seconds for all external registry calls
REQUEST_TIMEOUT_SECONDS=10

# Optional: Maximum number of source results to fetch per registry
MAX_SOURCES_PER_REGISTRY=5
```

---

## Docker Deployment

### Build the Image

```bash
docker build -t corp-analytics-tool .
```

### Run a Profile Generation

```bash
docker run --rm \
  --env-file .env \
  corp-analytics-tool \
  --name "Eli Lilly and Company" \
  --url "lilly.com"
```

### Save Output from Container to Host

```bash
docker run --rm \
  --env-file .env \
  -v "$(pwd)/output:/app/output" \
  corp-analytics-tool \
  --name "Eli Lilly and Company" \
  --url "lilly.com" \
  --output output/eli_lilly_profile.md
```

### Dockerfile Overview

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

ENTRYPOINT ["python", "-m", "src.main"]
```

---

## Testing

The test suite uses `pytest`. All tests are isolated and use mocked HTTP responses via `pytest-mock` to avoid live API calls during CI.

### Run All Tests

```bash
pytest tests/ -v
```

### Run a Specific Test Module

```bash
pytest tests/test_validator.py -v
```

### Coverage Report

```bash
pytest tests/ --cov=src --cov-report=term-missing
```

### Test Module Summary

| File | Tests | Coverage Target |
|---|---|---|
| `test_validator.py` | Source tier classification, metric detection | `validator.py` |
| `test_pipeline.py` | Template rendering, field mapping, size logic | `pipeline.py` |
| `test_data_fetcher.py` | Registry query construction, mocked responses | `data_fetcher.py` |

### Example Test: Source Tier Classification

```python
# tests/test_validator.py

from src.validator import SourceValidator

def test_top_tier_gov_domain():
    v = SourceValidator()
    assert v.categorize_source("https://sec.gov/edgar/search") == "top"

def test_second_tier_edu_domain():
    v = SourceValidator()
    assert v.categorize_source("https://unc.edu/research/report") == "second"

def test_unverified_domain_rejected():
    v = SourceValidator()
    assert v.categorize_source("https://randomblog.com/article") == "unverified"

def test_metric_detection_dollar_value():
    v = SourceValidator()
    assert v.has_quantitative_metrics("Revenue reached $4.2 billion in Q3 2024.") is True

def test_metric_detection_fails_on_vague_text():
    v = SourceValidator()
    assert v.has_quantitative_metrics("The company is a leader in innovative solutions.") is False
```

---

## Output Format

### Markdown (Default)

The default output is a structured markdown file conforming to the immutable profile template. Example excerpt:

```markdown
# COMPANY PROFILE TEMPLATE

Eli Lilly and Company is a Large Public firm that is based in Indianapolis, Indiana...

## Basic Company Information

Name, Company Location: Eli Lilly and Company, Indianapolis, IN
Company website URL: lilly.com

### Company Type
IPO? Yes (NYSE: LLY) 1952

### Company Size
Small: 0-100
Mid: 100 - 749
Large: 750+ (Specifically 50,000+)

## Talking Points

### AI-Driven Drug Discovery:
Eli Lilly is actively integrating generative AI for biologic design through its 2026 collaboration with Chai Discovery [1].

## References
[Chai Discovery & Eli Lilly Partnership]. (2026). AI Biologics Design. Intuition Labs. https://...
```

### JSON (Optional via `--format json`)

Useful for downstream processing or API integration. The JSON output mirrors the validated `company_data` dict with a top-level `profile_markdown` key containing the rendered string.

```json
{
  "name": "Eli Lilly and Company",
  "url": "lilly.com",
  "size_class": "Large",
  "employee_count": 50000,
  "talking_points": [...],
  "references": [...],
  "profile_markdown": "# COMPANY PROFILE TEMPLATE\n\n..."
}
```

---

## Extending the Pipeline

### Add a New Data Registry

1. Open `src/data_fetcher.py`.
2. Define a new private fetch method: `def _fetch_from_new_registry(self, query: str) -> list[dict]`.
3. Add the registry's base URL as a constant at the top of the module.
4. Call the new method inside `fetch()` and append results to the raw source list.
5. Add the registry's domain pattern to `src/validator.py` under the appropriate tier.
6. Write a corresponding test in `tests/test_data_fetcher.py` with a mocked response.

### Add a New Output Format

1. Open `src/pipeline.py`.
2. Add a new rendering method: `def render_profile_as_csv(self, ...)` or your target format.
3. Register the new format string in `src/main.py`'s `--format` argument choices.
4. Route the `--format` flag to the correct rendering method in `main()`.

---

## Known Limitations

| Limitation | Detail |
|---|---|
| No live web scraping | `data_fetcher.py` targets structured API endpoints only. Pages without a queryable API require manual input via the mock ingestion payload in `main.py`. |
| PitchBook / Tracxn paywalls | Second-tier industry tracking platforms require active subscription credentials. Results fall back to public investor relations pages if credentials are absent. |
| UNC connection detection | Alumni and donation history identification is not automated. These fields require manual verification via the UNC Office of Development. |
| Rate limiting | NCBI PubMed E-utilities enforces 3 requests/second without an API key and 10 requests/second with one. The `REQUEST_TIMEOUT_SECONDS` variable does not override rate limits. |
| No hallucination guardrail | The pipeline validates sources and metrics structurally but does not cross-check factual accuracy between registries. Human review of all generated profiles is required before institutional use. |

---

## Contributing

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/your-feature-name`.
3. Write tests for any new module behavior before implementation.
4. Confirm all existing tests pass: `pytest tests/ -v`.
5. Confirm formatting compliance: `black src/ tests/` and `flake8 src/ tests/`.
6. Submit a pull request with a plain-English description of the change and its rationale.

**Naming conventions:**

- All functions: `snake_case`
- All constants: `UPPER_SNAKE_CASE`, defined in the module-level scope
- All classes: `PascalCase`
- All files: `snake_case.py`

---

## License

MIT License. See `LICENSE` for full terms.

---

*Built for the UNC Chapel Hill Partnership Research & Intelligence track — Innovate Carolina IEED Summer Internship 2026.*

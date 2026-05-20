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

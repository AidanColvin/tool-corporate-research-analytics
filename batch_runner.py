import sys
import json
from pathlib import Path
from src.pipeline import CorporateIntelligencePipeline

INPUT_DIR = Path("data/input")
MD_DIR = Path("data/output/markdown")
PDF_DIR = Path("data/output/PDF")
JSON_DIR = Path("data/output/json")


def _load_company(path: Path) -> dict:
    """Load a company JSON, handling flat and wrapped shapes."""
    data = json.loads(path.read_text())
    if "overview" in data:
        return data
    key = next(iter(data))
    val = data[key]
    return val if isinstance(val, dict) else data


def run(stems=None):
    """Process JSONs in data/input/ into MD, JSON, and PDF.

    given / stems: optional iterable of file stems (no .json) to limit processing
    """
    for d in [MD_DIR, PDF_DIR, JSON_DIR]:
        d.mkdir(parents=True, exist_ok=True)

    pipeline = CorporateIntelligencePipeline()
    all_files = sorted(INPUT_DIR.glob("*.json"))
    if stems:
        wanted = set(stems)
        all_files = [p for p in all_files if p.stem in wanted]
        missing = wanted - {p.stem for p in all_files}
        for m in sorted(missing):
            print(f"  SKIP  {m} (not found in data/input/)")

    for p in all_files:
        stem = p.stem
        try:
            company = _load_company(p)
            refs = company.get("references", [])
            ov = company.get("overview", {})
            company_name = ov.get("company", company.get("name", stem))

            md_text = pipeline.render_profile(company, refs)

            (MD_DIR / f"{stem}.md").write_text(md_text)
            (JSON_DIR / f"{stem}.json").write_text(json.dumps(company, indent=2))
            pipeline.render_pdf(
                md_text,
                str(PDF_DIR / f"{stem}.pdf"),
                company_name=company_name,
            )
            print(f"  OK  {stem}")
        except Exception as e:
            print(f"  FAIL  {stem}: {e}")


if __name__ == "__main__":
    args = sys.argv[1:]
    run(stems=args if args else None)

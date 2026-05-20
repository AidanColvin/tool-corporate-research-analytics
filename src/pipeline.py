import markdown as md_lib
from weasyprint import HTML


def _pdf_css(company_name: str) -> str:
    """Return page CSS with company name in header and page number top right."""
    safe = company_name.replace('"', "'")
    return f"""
<style>
  @page {{
    margin: 2.2cm 2.2cm 2.2cm 2.2cm;
    @top-left {{
      content: "{safe}";
      font-family: Georgia, serif;
      font-size: 9pt;
      color: #444;
    }}
    @top-right {{
      content: counter(page);
      font-family: Georgia, serif;
      font-size: 9pt;
      color: #444;
    }}
  }}
  body {{
    font-family: Georgia, serif;
    font-size: 11pt;
    color: #111;
    line-height: 1.55;
  }}
  h1 {{
    font-size: 1.6rem;
    border-bottom: 2px solid #333;
    padding-bottom: 0.3rem;
    margin-bottom: 0.4rem;
    margin-top: 0.2rem;
  }}
  h2 {{
    font-size: 1.15rem;
    margin-top: 1.4rem;
    margin-bottom: 0.3rem;
    color: #222;
  }}
  ul {{
    padding-left: 1.4rem;
    margin: 0.4rem 0;
  }}
  li {{
    margin-bottom: 0.5rem;
  }}
  p {{
    margin: 0.4rem 0;
  }}
  a {{
    color: #1a0dab;
    word-break: break-all;
  }}
</style>
"""


def _has_unc_info(unc: dict) -> bool:
    """Return True only if there is confirmed UNC connection data to show.

    given / unc: the unc_connection dict from the company JSON
    returns / bool
    """
    alum = unc.get("unc_alum")
    if alum:
        return True
    donation = unc.get("donation_history", "")
    skip_phrases = [
        "no confirmed",
        "verify via",
        "best verified",
        "not available",
    ]
    if donation and not any(p in donation.lower() for p in skip_phrases):
        return True
    return False


class CorporateIntelligencePipeline:

    def render_profile(self, d: dict, refs: list) -> str:
        """Build markdown from a company dict and references list.

        given / d: company dict matching the JSON schema
        given / refs: list of reference dicts
        returns / markdown string
        """
        ov = d.get("overview", {})
        name = ov.get("company", d.get("name", "Company"))

        lines = []

        ### HEADER ###
        lines.append(f"# {name}")

        ### OVERVIEW ###
        lines.append("\n## Overview")

        size = ov.get("size", d.get("size_class", ""))
        kind = ov.get("type", d.get("type", ""))
        location = ov.get("location", "")
        service = ov.get("service", "")
        consumer = ov.get("consumer_base", "")
        rationale = ov.get("partnership_rationale", "")
        contact = ov.get("primary_contact", "")
        contact_reason = ov.get("contact_reasoning", "")

        # Bold key descriptors in the opening sentence
        sentence = f"**{name}** is a **{size} {kind}** firm"
        if location:
            sentence += f" based in **{location}**"
        sentence += "."
        lines.append(sentence)

        if service and consumer:
            lines.append(
                f"They perform **{service}** for **{consumer}**."
            )

        if rationale:
            lines.append(f"\n{rationale}")

        if contact and contact_reason:
            lines.append(
                f"\n**{contact}** is the best avenue for partnership because "
                f"{contact_reason}"
            )

        ### BASIC INFO ###
        bi = d.get("basic_info", {})
        if bi:
            lines.append("\n## Basic Company Information")
            if bi.get("name_and_location"):
                lines.append(
                    f"- **Name, Company Location:** {bi['name_and_location']}"
                )
            if bi.get("website_url"):
                lines.append(
                    f"- **Company Website URL:** {bi['website_url']}"
                )
            if bi.get("company_type") or bi.get("company_size"):
                lines.append(
                    f"- **Company Type, Company Size:** "
                    f"{bi.get('company_type', '')}, "
                    f"{bi.get('company_size', '')}"
                )

        ### COMPANY TYPE ###
        ct = d.get("company_type", {})
        if ct:
            lines.append("\n## Company Type")
            ipo = ct.get("ipo")
            ticker = ct.get("ticker", "")
            year = ct.get("ipo_year", "")
            if ipo is True:
                lines.append(f"- **IPO?** Yes ({ticker}) — {year}")
            elif ipo is False:
                lines.append("- **IPO?** No")

        ### COMPANY SIZE ###
        csb = d.get("company_size_bands", {})
        if csb:
            lines.append("\n## Company Size")
            category = csb.get("category", "")
            headcount = csb.get("headcount", "")
            if category and headcount:
                lines.append(f"- **{category}:** {headcount:,}+")
            else:
                for band, val in csb.items():
                    lines.append(f"- **{band}:** {val}")

        ### UNC CONNECTION — only if confirmed data exists ###
        unc = d.get("unc_connection", {})
        if unc and _has_unc_info(unc):
            lines.append("\n## UNC Connection")
            alum = unc.get("unc_alum")
            if isinstance(alum, dict):
                alum_name = alum.get("name", "")
                former = alum.get("former_role", "")
                current = alum.get("current_role", "")
                lines.append(
                    f"- **UNC Alum:** {alum_name} — {former}; {current}"
                )
            elif alum:
                lines.append(f"- **UNC Alum:** {alum}")
            donation = unc.get("donation_history", "")
            skip_phrases = [
                "no confirmed", "verify via", "best verified", "not available"
            ]
            if donation and not any(
                p in donation.lower() for p in skip_phrases
            ):
                lines.append(f"- **Donation History:** {donation}")

        ### TALKING POINTS ###
        tps = d.get("talking_points", [])
        if tps:
            lines.append("\n## Talking Points")
            for i, p in enumerate(tps, 1):
                topic = p.get("topic", p.get("header", "Point"))
                detail = p.get("detail", p.get("body", ""))
                citation = f" [{i}]" if refs else ""
                lines.append(f"- **{topic}:** {detail}{citation}")

        ### REFERENCES — one bullet per reference ###
        if refs:
            lines.append("\n## References")
            for i, r in enumerate(refs, 1):
                authors = r.get("authors", r.get("author", "Unknown"))
                year = r.get("year", "n.d.")
                title = r.get("title", "Untitled")
                url = r.get("url", "")
                doi = r.get("doi", "")
                journal = r.get("journal", "")

                entry = f"- {authors}. ({year}). *{title}*."
                if journal:
                    entry += f" {journal}."
                if doi:
                    entry += f" https://doi.org/{doi}"
                elif url:
                    entry += f" {url}"
                lines.append(entry)

        return "\n".join(lines)

    def render_pdf(self, markdown_text: str, output_path: str,
                   company_name: str = "") -> None:
        """Convert markdown to PDF with running page headers.

        given / markdown_text: rendered markdown string
        given / output_path: destination file path string
        given / company_name: used in page header
        returns / None; writes file to disk
        """
        body = md_lib.markdown(
            markdown_text, extensions=["tables", "fenced_code"]
        )
        css = _pdf_css(company_name)
        html = f"<html><head>{css}</head><body>{body}</body></html>"
        HTML(string=html).write_pdf(output_path)

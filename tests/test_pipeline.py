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

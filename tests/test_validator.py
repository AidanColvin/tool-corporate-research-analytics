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

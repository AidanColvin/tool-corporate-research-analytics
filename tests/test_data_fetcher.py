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

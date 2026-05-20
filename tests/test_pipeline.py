import pytest
from src.pipeline import CorporateIntelligencePipeline

def test_pipeline_instantiation():
    pipeline = CorporateIntelligencePipeline()
    assert pipeline is not None

def test_render_profile_empty_data():
    pipeline = CorporateIntelligencePipeline()
    result = pipeline.render_profile({})
    assert "## Overview" in result
    assert "## Basic Company Information" in result
    assert "## Talking Points" in result

def test_render_profile_with_data():
    pipeline = CorporateIntelligencePipeline()
    data = {
        "overview": {
            "company": "TestCorp",
            "size": "Large",
            "type": "Public",
            "location": "New York, NY"
        },
        "talking_points": [
            {"topic": "Revenue Growth", "detail": "Increased by 15 percent."}
        ],
        "references": [
            {"authors": "Smith, J.", "year": "2026", "title": "Annual Report", "url": "test.com"}
        ]
    }
    result = pipeline.render_profile(data)
    assert "# TestCorp" in result
    assert "TestCorp is a Large Public firm based in New York, NY." in result
    assert "- **Revenue Growth:** Increased by 15 percent." in result
    assert "- Smith, J.. (2026). Annual Report. test.com" in result

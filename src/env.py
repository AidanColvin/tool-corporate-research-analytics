"""Typed environment variable loaders.

Raises EnvironmentError on missing required keys before any HTTP call.
Import from here — never call os.getenv() directly in other modules.
"""

import os
from dotenv import load_dotenv
from src import config

load_dotenv()


def get_ncbi_key() -> str:
    """Return NCBI E-utilities API key.

    Raises:
        EnvironmentError: If NCBI_API_KEY is absent from .env.
    """
    key = os.getenv("NCBI_API_KEY")
    if not key:
        raise EnvironmentError(
            "NCBI_API_KEY is not set. Add it to .env.\n"
            "Register free at: https://www.ncbi.nlm.nih.gov/account/\n"
            "Without it the PubMed rate limit is 3 req/s instead of 10."
        )
    return key


def get_ncbi_key_optional() -> str | None:
    """Return NCBI key or None. Used when PubMed is optional."""
    return os.getenv("NCBI_API_KEY")


def get_timeout() -> int:
    """Return HTTP request timeout in seconds. Defaults to config.TIMEOUT."""
    raw = os.getenv("REQUEST_TIMEOUT_SECONDS")
    return int(raw) if raw else config.TIMEOUT


def get_max_sources() -> int:
    """Return max results per registry. Defaults to config.MAX_SOURCES."""
    raw = os.getenv("MAX_SOURCES_PER_REGISTRY")
    return int(raw) if raw else config.MAX_SOURCES

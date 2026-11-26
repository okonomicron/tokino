"""The no-silent-substitution rule, enforced on the Python side.

Mirrors packages/TokinoKit/Tests/TokinoKitTests/ProviderTests.swift. Both sides
need this because either can be the one holding a credential.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import REGISTERED, app
from app.providers import (
    Capability,
    MockRefusedError,
    ProviderIdentity,
    ProviderSelectionError,
    resolve,
)

LIVE_LLM = ProviderIdentity("live-language-model", Capability.LANGUAGE_MODEL, is_mock=False)
MOCK_LLM = ProviderIdentity("mock-language-model", Capability.LANGUAGE_MODEL, is_mock=True)


def test_a_mock_is_refused_when_a_credential_is_configured():
    """The rule that matters: a configured key means real output is expected."""
    with pytest.raises(MockRefusedError) as excinfo:
        resolve(Capability.LANGUAGE_MODEL, [MOCK_LLM], has_credential=True)
    # The message has to be actionable: this fires in a deploy, not a test run.
    assert "Refusing to use mock provider" in str(excinfo.value)
    assert "mock-language-model" in str(excinfo.value)


def test_a_mock_is_allowed_when_no_credential_is_configured():
    chosen = resolve(Capability.LANGUAGE_MODEL, [MOCK_LLM], has_credential=False)
    assert chosen.is_mock


@pytest.mark.parametrize("has_credential", [True, False])
def test_a_live_provider_always_wins_over_a_mock(has_credential):
    chosen = resolve(
        Capability.LANGUAGE_MODEL, [MOCK_LLM, LIVE_LLM], has_credential=has_credential
    )
    assert not chosen.is_mock


def test_an_unregistered_capability_raises():
    with pytest.raises(ProviderSelectionError):
        resolve(Capability.PLACES, [MOCK_LLM], has_credential=False)


def test_resolution_never_crosses_capabilities():
    mock_places = ProviderIdentity("mock-places", Capability.PLACES, is_mock=True)
    chosen = resolve(Capability.PLACES, [MOCK_LLM, mock_places], has_credential=False)
    assert chosen.capability is Capability.PLACES


def test_every_registered_mock_is_visibly_labelled():
    for identity in REGISTERED:
        if identity.is_mock:
            assert "MOCK" in identity.display_label
            assert "not a real integration" in identity.display_label


def test_a_live_identity_is_not_labelled_as_a_mock():
    assert LIVE_LLM.display_label == "live-language-model"


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

def test_settings_report_no_credentials_by_default(monkeypatch):
    for name in (
        "SUPABASE_URL",
        "SUPABASE_SERVICE_ROLE_KEY",
        "ANTHROPIC_API_KEY",
        "GOOGLE_MAPS_API_KEY",
    ):
        monkeypatch.delenv(name, raising=False)

    settings = Settings()
    assert settings.configured_capabilities == []
    assert not settings.has_credential(Capability.LANGUAGE_MODEL)


def test_a_present_key_is_detected(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-a-real-key")
    settings = Settings()
    assert settings.has_credential(Capability.LANGUAGE_MODEL)
    assert Capability.LANGUAGE_MODEL in settings.configured_capabilities


def test_publishing_credentials_are_never_satisfied_by_configuration(monkeypatch):
    """Publishing tokens are per account and live in the database, not the env."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "x")
    monkeypatch.setenv("GOOGLE_MAPS_API_KEY", "y")
    assert not Settings().has_credential(Capability.PUBLISHING)


# --------------------------------------------------------------------------
# HTTP surface
# --------------------------------------------------------------------------

def test_health_endpoint():
    with TestClient(app) as client:
        response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_capabilities_endpoint_reports_mock_usage(monkeypatch):
    """A deployment on mocks must not look like one on real integrations."""
    for name in ("ANTHROPIC_API_KEY", "GOOGLE_MAPS_API_KEY"):
        monkeypatch.delenv(name, raising=False)

    with TestClient(app) as client:
        payload = client.get("/capabilities").json()

    by_capability = {row["capability"]: row for row in payload}
    assert set(by_capability) == {c.value for c in Capability}

    llm = by_capability["languageModel"]
    assert llm["is_mock"] is True
    assert "MOCK" in llm["provider"]
    assert llm["has_credential"] is False
    assert llm["error"] is None


def test_capabilities_endpoint_surfaces_a_refused_mock(monkeypatch):
    """With a key present but only mocks registered, the endpoint must say so
    rather than reporting a healthy mock."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-a-real-key")

    with TestClient(app) as client:
        payload = client.get("/capabilities").json()

    llm = next(row for row in payload if row["capability"] == "languageModel")
    assert llm["provider"] is None
    assert llm["error"] is not None
    assert "Refusing to use mock provider" in llm["error"]

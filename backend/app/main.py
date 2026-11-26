"""FastAPI application.

Scope is deliberately narrow: this service exists only for work that needs a
secret the iOS client must not hold — language-model calls, place matching and
publishing. Ordinary reads and writes go straight from the app to Supabase under
RLS, which is why this service is not deployed until Milestone 4.
"""

from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel

from . import __version__
from .config import Settings
from .providers import Capability, ProviderIdentity, ProviderSelectionError, resolve

# Registered providers. Live implementations are added in M4; until then only
# mocks exist, and `resolve` refuses them if a credential shows up.
REGISTERED: list[ProviderIdentity] = [
    ProviderIdentity("mock-language-model", Capability.LANGUAGE_MODEL, is_mock=True),
    ProviderIdentity("mock-places", Capability.PLACES, is_mock=True),
    ProviderIdentity("mock-publishing", Capability.PUBLISHING, is_mock=True),
]

app = FastAPI(
    title="Tokino API",
    version=__version__,
    summary="AI orchestration, place matching and publishing for Tokino.",
)


class HealthResponse(BaseModel):
    status: str
    version: str


class CapabilityStatus(BaseModel):
    capability: str
    provider: str | None
    is_mock: bool
    has_credential: bool
    # Populated when no provider can be selected safely, so a misconfiguration
    # is visible from the outside rather than only in logs.
    error: str | None = None


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", version=__version__)


@app.get("/capabilities", response_model=list[CapabilityStatus])
def capabilities() -> list[CapabilityStatus]:
    """Reports which provider serves each capability, and whether it is a mock.

    Exposed so that a deployment running on mocks cannot look like one running
    on real integrations.
    """
    settings = Settings()
    statuses: list[CapabilityStatus] = []

    for capability in Capability:
        has_credential = settings.has_credential(capability)
        try:
            chosen = resolve(capability, REGISTERED, has_credential)
        except ProviderSelectionError as error:
            statuses.append(
                CapabilityStatus(
                    capability=capability.value,
                    provider=None,
                    is_mock=False,
                    has_credential=has_credential,
                    error=str(error),
                )
            )
            continue

        statuses.append(
            CapabilityStatus(
                capability=capability.value,
                provider=chosen.display_label,
                is_mock=chosen.is_mock,
                has_credential=has_credential,
            )
        )

    return statuses

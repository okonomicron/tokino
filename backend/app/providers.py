"""Provider abstraction and the no-silent-substitution rule.

Mirrors TokinoKit's `ProviderSelector` (packages/TokinoKit/Sources/TokinoKit/
Providers/Providers.swift). Both sides enforce the same rule because either side
can be the one holding a credential, and the brief (§15) forbids silently
serving mock output in place of a real integration.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass


class Capability(enum.StrEnum):
    LANGUAGE_MODEL = "languageModel"
    PLACES = "places"
    PUBLISHING = "publishing"


@dataclass(frozen=True)
class ProviderIdentity:
    name: str
    capability: Capability
    is_mock: bool

    @property
    def display_label(self) -> str:
        """Deliberately shouty: this appears in logs and in the UI."""
        if self.is_mock:
            return f"MOCK · {self.name} · not a real integration"
        return self.name


class ProviderSelectionError(RuntimeError):
    """Raised when no provider can be chosen safely."""


class MockRefusedError(ProviderSelectionError):
    """A credential is configured, so mock output would be mistaken for real output."""


def resolve(
    capability: Capability,
    candidates: list[ProviderIdentity],
    has_credential: bool,
) -> ProviderIdentity:
    """Resolve a capability to exactly one provider.

    Prefers a live provider whenever one is registered, regardless of credential
    state: a live provider missing its credential fails with a clear auth error,
    which is more honest than fabricated output.
    """
    relevant = [c for c in candidates if c.capability is capability]
    if not relevant:
        raise ProviderSelectionError(f"No provider registered for {capability.value}.")

    for candidate in relevant:
        if not candidate.is_mock:
            return candidate

    mock = relevant[0]
    if has_credential:
        raise MockRefusedError(
            f"Refusing to use mock provider '{mock.name}' for {capability.value}: "
            "a real credential is configured, so mock output would be mistaken "
            "for real output. Register a live provider or remove the credential."
        )
    return mock

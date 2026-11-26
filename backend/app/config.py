"""Runtime configuration, read from the environment only.

Nothing here has a default that is a real credential, and nothing is read from a
committed file. The repository is public, so a secret in source would be
immediately exploitable.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from .providers import Capability


@dataclass
class Settings:
    """Which credentials this deployment actually holds.

    Presence, not validity, is what drives provider selection. A key that is
    present but wrong should fail loudly at call time rather than quietly
    falling back to a mock.
    """

    supabase_url: str | None = field(default_factory=lambda: os.environ.get("SUPABASE_URL"))
    # Service-role key: server-side only, and never sent to the iOS client.
    supabase_service_key: str | None = field(
        default_factory=lambda: os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    )
    anthropic_api_key: str | None = field(
        default_factory=lambda: os.environ.get("ANTHROPIC_API_KEY")
    )
    google_maps_api_key: str | None = field(
        default_factory=lambda: os.environ.get("GOOGLE_MAPS_API_KEY")
    )

    def has_credential(self, capability: Capability) -> bool:
        match capability:
            case Capability.LANGUAGE_MODEL:
                return bool(self.anthropic_api_key)
            case Capability.PLACES:
                return bool(self.google_maps_api_key)
            case Capability.PUBLISHING:
                # Publishing credentials are per social account, held in the
                # database rather than the environment, so this is never
                # satisfied by configuration alone.
                return False
        return False

    @property
    def configured_capabilities(self) -> list[Capability]:
        return [c for c in Capability if self.has_credential(c)]

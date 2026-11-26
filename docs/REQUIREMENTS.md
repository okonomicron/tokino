# Product requirements

Condensed from [PROMPT.md](PROMPT.md), which remains the authoritative brief.
This page records how each requirement is being met, and where one has been
interpreted or constrained.

## The proposition

Tokino turns a user's existing photo library into an ongoing social media
content strategy, driven by natural language. The user describes a goal; Tokino
finds the relevant photos, reconstructs the experiences behind them, proposes a
strategy, generates platform-specific content, and manages approval and
publishing.

Nothing is hardcoded for any topic. The initial acceptance test is Japanese
kaisendon photography, but a user might equally build a strategy around pets,
hiking or architecture. `MockLanguageModelProvider` derives pillars from the
library's own themes, and a test asserts it does so for a non-food library
specifically to catch topic-shaped hardcoding.

## Functional requirements and their status

| Requirement | Status | Notes |
|---|---|---|
| Native iOS app, Swift + SwiftUI | M1 skeleton | iOS 26+; not a WebView |
| Photo library scan, resumable | Logic done, UI in M2 | `ScanPlanner`, `ScanCheckpoint` |
| Incremental scanning, no rescans | Logic done and tested | deletion detection, dedupe, model upgrades |
| Semantic index, reused across strategies | M2 | on-device MobileCLIP; index once |
| Natural-language photo search | M2 | local vector search |
| Experience reconstruction | M3 | `Experience`, grouping signals |
| Place matching with confidence | M3 | `PlaceMatch`; never asserts an unverified venue |
| Prompt-driven strategies | M4 | `ContentStrategy` keeps the prompt verbatim |
| Voice and tone profiles | M4 | `VoiceProfile`, per-platform languages |
| Multiple independent strategies | Schema ready | per-strategy calendars and rules |
| Photo and carousel generation | M5 | |
| EN + ZH captions | M5 | adapted per audience, not translated |
| Video / Reels | M7 | deterministic ffmpeg rendering first |
| Instagram publishing | M6 | official API; own account needs no App Review |
| Xiaohongshu | M6 | assisted handoff; no publishing API exists |
| Approval workflow | Logic done | state machine with 12 states |
| Backend scheduling without the app | M6 | `pg_cron` + `pg_net` |
| Three automation levels | Logic done | defaults to manual |

## Non-functional requirements

- **Privacy first.** Embeddings and metadata sync; pixels stay on device except
  for images in an approved draft. Per-asset and per-album exclusion.
- **The original library is never modified** (§17.5). Nothing in the codebase
  writes to PhotoKit; derivatives are separate `media_asset` rows.
- **No fabricated experiences** (§17.11). Captions are generated from grounding
  facts, and a venue may only be named when confirmed or strongly corroborated.
- **Production engineering standards.** Idempotent publishing, explicit state
  transitions, adversarial security tests, injected time so tests are
  deterministic.
- **Accessibility and Dynamic Type.** M2, with the real UI.

## Interpretations and departures from the brief

Recorded because the brief asked to be challenged where justified.

1. **One extra publication state.** `awaitingReconciliation`, because the
   brief's own requirement to handle a lost publish confirmation (§14) cannot be
   met with the listed states alone. See
   [DECISIONS.md D6](DECISIONS.md#d6-add-an-awaitingreconciliation-publication-state).
2. **Embeddings leave the device.** The brief prefers keeping photo data local
   but also requires backend scheduling without the app open. Vectors sync;
   pixels do not. See
   [D3](DECISIONS.md#d3-embeddings-sync-pixels-do-not).
3. **iOS 26 only, for now.** Narrows the audience to avoid maintaining two scan
   paths. See [D1](DECISIONS.md#d1-target-ios-26-only).
4. **The iOS app talks to Supabase directly** rather than through our own API
   for everything. Fewer moving parts and no deployment needed for M1–M2, at the
   cost of making RLS load-bearing. See
   [D5](DECISIONS.md#d5-ios-talks-to-supabase-directly-the-backend-holds-only-secrets).
5. **Publishing dry-runs first**, at the user's direction: the full pipeline is
   exercised against a mock adapter before anything reaches a real account.

## Commercial context

Addressed at a hypothesis level only, per §13's warning against
overengineering before product-market fit. [COSTS.md](COSTS.md) carries the unit
economics. The short version: on-device indexing makes marginal cost per user
under $2/month, which is what would make a consumer price point viable. Pricing
tiers are deliberately not implemented.

# Decision log

Each entry records what was decided, what was rejected, and the evidence. Dates
are when the decision was taken. Where a claim was verified against a primary
source, that is stated; where it is an assumption, that is stated too.

---

## D1. Target iOS 26 only

**2026-11-26.** Decided: minimum deployment target iOS 26.0.

`BGContinuedProcessingTask` is new in iOS 26.0 (verified from Apple's
documentation data: *"A task that starts in the foreground and can continue
running in the background as needed… The system displays the progress of this
task in a Live Activity and a person can cancel it."*). It is close to
purpose-built for the initial library scan.

Supporting iOS 18 would mean writing and maintaining two scan paths — the
continued-processing path and a foreground-only fallback — roughly a milestone
of extra work plus permanent dual-path testing.

Accepted cost: a narrower audience if this ever launches commercially.
Back-porting the scan is an explicit later milestone, and the scan engine sits
behind an interface so a fallback can be added without rework.

---

## D2. Reject the PhotoKit background upload extension

**2026-11-26.** Rejected: `com.apple.photos.background-upload` /
`PHAssetResourceUploadJob` (iOS 26.1+).

It would let iOS upload library assets without the app running, which sounds
ideal. Three reasons not to use it:

1. **It uploads full asset resources.** The app controls the destination — URL,
   method, headers — but never the bytes. That is the inverse of our privacy
   model, which sends derived vectors rather than originals.
2. **It requires full library access**, which we do not want to demand.
3. **Reliability.** Developers report jobs being created successfully on iOS 26.2
   but never triggered, having worked on 26.1.

Evidence is from Apple Developer Forums, an open radar and third-party code
rather than Apple documentation, so points 1 and 3 should be re-checked if this
is ever revisited. It is not needed for our architecture either way.

---

## D3. Embeddings sync; pixels do not

**2026-11-26.** Decided: 512-dimension vectors and metadata sync to Postgres;
original pixels stay on device except for images in a user-approved draft.

This resolves the tension between "keep originals on the device" (§2.2) and
"scheduled publishing must run on the backend without the app open" (§9). A
backend with no knowledge of the library cannot propose content or publish on a
schedule.

Alternative considered: keep the index entirely on-device. Rejected because it
would confine all strategy and content generation to moments when the app is
open, which removes the product's central promise of working unattended.

---

## D4. On-device embeddings with MobileCLIP-S2

**2026-11-26.** Decided: generate image embeddings on-device via Core ML.

This is the decision that makes the economics work. Indexing 20,000 photos costs
**nothing** and never sends an image anywhere. Cloud vision inference over a
whole library would be the single largest operating cost in the product.

Cloud vision stays available, used selectively on a shortlist of candidate
photos for OCR and richer description — tens of images a month, not tens of
thousands.

**Open risk:** Apple publishes the Core ML exports under the ASCL licence, a
custom non-OSI licence. It must be read before any commercial release. Apple's
Vision framework feature prints are the fallback if its terms do not permit our
use.

---

## D5. iOS talks to Supabase directly; the backend holds only secrets

**2026-11-26.** Decided: the app uses `supabase-swift` with the anon key under
RLS for all ordinary reads and writes. `tokino-api` exists only for operations
needing a secret.

Consequences: Milestones 1 and 2 need nothing deployed and cost nothing, and
API keys are never in the client (§10 security).

Accepted cost: **RLS becomes load-bearing security rather than defence in
depth.** A missing or permissive policy is a data leak. Mitigations: RLS is
enabled *and forced* on every table, and the tests are adversarial — they
attempt cross-user reads by primary key, cross-user inserts on every table,
ownership reassignment, and unauthenticated access.

---

## D6. Add an `awaitingReconciliation` publication state

**2026-11-26.** Decided: one state beyond the brief's list.

The brief requires handling the case where "the external publication may have
succeeded but the confirmation response was lost" (§14). With only `publishing`,
`published` and `failed`, a lost response leaves two bad options: retry and risk
a duplicate post, or mark it failed and lose a real post.

In `awaitingReconciliation` nothing may publish. A reconciliation job asks the
platform whether the idempotency key already produced a post and settles the row
as `published` or `failed`. Only from a confirmed `failed` may a retry proceed.

---

## D7. Generate the Xcode project; do not commit it

**2026-11-26.** Decided: `ios/project.yml` is the source of truth; XcodeGen
generates `Tokino.xcodeproj` in CI and locally.

A `.pbxproj` is not reviewable or editable as text in a cloud container. A YAML
manifest is both.

Accepted cost: Xcode Cloud needs a project file present when its first workflow
is created, so the one-time Mac setup in M3 includes running `xcodegen generate`
locally. Noted in [IOS_BUILD.md](IOS_BUILD.md).

---

## D8. Xiaohongshu is assisted handoff, not an API integration

**2026-11-26.** Decided: model XHS as `publishingMode == .assistedHandoff`, and
refuse fully automatic publishing on it.

`open.xiaohongshu.com` is an e-commerce/merchant platform covering orders,
products and inventory. There is no public note-publishing API and no open
registration. Sources are third-party rather than XHS's own documentation, but
they agree.

The adapter interface is shared with Instagram's, so official publishing can be
dropped in if access ever becomes available. No scraping or UI automation: the
brief rules it out, and it risks the user's account.

`AutomationLevel.fullyAutomatic.isPermitted(on:)` returns false for handoff
platforms, so the app cannot promise automation it cannot deliver.

---

## D9. Public repository, for free macOS CI

**2026-11-26.** Decided by the user: public until near completion, then private.

Standard GitHub-hosted runners — including macOS 3/4-core — are free for public
repositories and do not draw down included compute. On a private repo, GitHub
Free includes $12/month of compute, about 193 macOS minutes at $0.062/min.

This is what lets `ios.yml` run on every push, which in turn is why the iOS
target exists in Milestone 1 rather than Milestone 2: SwiftUI gets compiled from
its first line instead of accumulating unverified.

Accepted risks, and mitigations: see D5 for RLS, and
`scripts/scan-secrets.sh` runs over full history in CI. The scanner was verified
against a planted key rather than assumed to work.

---

## D10. Mocks must be refused when a credential exists

**2026-11-26.** Decided: `ProviderSelector` (Swift) and `resolve` (Python) raise
rather than return a mock when a real credential is configured.

The failure this prevents: a deployment with a valid API key but a
misconfigured provider registry quietly producing fabricated captions that look
plausible. That is exactly the silent substitution the brief forbids (§15), and
it is far worse than an outage because nobody notices.

Mocks are deterministic, carry `isMock` in their identity, label themselves
"MOCK · … · not a real integration", and their captions say "not for
publishing" so one cannot be posted by accident.

---

## D11. No HNSW index on the embedding table yet

**2026-11-26.** Decided: leave the vector index commented out in the migration.

Building an approximate-nearest-neighbour index on an empty table is wasted
work, and it is substantially cheaper to build once after a library is indexed.
Exact search is fine at one user's scale. Revisit in M2 once there is a real
index to measure.

---

## D12. No down-migrations

**2026-11-26.** Decided: migrations are forward-only and idempotent.

What matters for a Supabase deploy is that a migration can be safely re-applied
to a database that already holds part of the schema — which is tested
(`test_migrations_are_idempotent`). Hand-written down-migrations for a
pre-release schema are maintenance burden for a rollback path that would
destroy data anyway. Revisit when there is production data worth preserving.

---

## D13. A native Postgres test cluster rather than Docker

**2026-11-26.** Decided: `scripts/pg-test-cluster.sh` starts a throwaway cluster
using the system Postgres.

The cloud dev container has no Docker daemon, so Docker-based tests cannot run
where most development happens. A native cluster starts faster, and CI uses the
`pgvector/pgvector` service container for the same tests. Both run real
Postgres 16 with real pgvector, so neither path is a simulation.

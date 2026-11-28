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

---

## D14. OpenCLIP ViT-B/32 instead of MobileCLIP, on licence grounds

**2026-11-28.** Decided: on-device embeddings come from OpenCLIP ViT-B/32
trained on LAION-2B, converted to Core ML by `tools/convert-openclip.py`.

**MobileCLIP was the obvious choice and cannot be used.** Apple's
`LICENSE_MODELS` governs the weights:

> "'Research Purposes' does not include any commercial exploitation, product
> development or use in any commercial product or service."

That excludes *product development*, not merely shipping, so it is unusable
even for an MVP. The Hugging Face model card's `apple-ascl` tag contradicts the
repository's licence file; the repository text is operative. This was logged as
risk D4 in Milestone 1 and has now materialised.

**SigLIP 2 was the accuracy-first alternative and was rejected on size.** It is
Apache-2.0 and well converted — published reports show Core ML matching PyTorch
at 0.9999 mean cosine, ImageNet top-1 0.76764 against 0.76794, and 5.6 ms per
image on the Neural Engine. But its text tower is 539 MB, because its
vocabulary is 256k tokens against OpenCLIP's 49,408. Keeping search working
offline mattered more than the roughly 11-point zero-shot gap.

**What the choice bought us**, beyond the licence:

- 512-dimension output, which matches `PhotoEmbedding.dimensions` and the
  `vector(512)` column from Milestone 1 exactly. **No migration.** SigLIP 2
  would have forced 512 to 768.
- 137 MB for both towers at 8-bit (image 79.2 MB, text 58.1 MB), better than
  the 150 MB the plan estimated.
- Verified parity: all 8 checks at cosine ≥ 0.9992 against the PyTorch
  reference, so 8-bit palettization costs almost nothing.

The model sits behind `ImageEmbedding` with a versioned identifier, so moving
to SigLIP 2 later is a re-index rather than a rewrite.

**Outstanding:** the MobileCLIP ASCL risk recorded in D4 is now closed — we do
not use those weights. The LAION dataset's provenance is a separate question;
the weights are MIT, and Re-LAION exists if a cleaner lineage is ever wanted.

---

## D15. Palettized model checksums are not reproducible

**2026-11-28.** Noted during the first macOS parity run: the same conversion
script produces **different** SHA-256 checksums on Linux x86 and macOS arm64.

k-means palettization is not bit-reproducible across platforms — the cluster
centroids differ. The zip archiving is deterministic (fixed timestamps, sorted
entries), so the difference is genuinely in the weights.

The consequence is procedural rather than technical. The checksum in
`EmbeddingModelDescriptor` must come from the **exact artifact that is
published**, not from any re-run of the conversion. So the release flow is:

1. Run the `model-parity` workflow and confirm it passes.
2. Download its `openclip-coreml` artifact.
3. Publish those exact files as a release asset.
4. Copy that artifact's checksums into the descriptor.

The parity workflow therefore *reports* a checksum mismatch rather than failing
on one, and the app verifies the download against whatever the descriptor says.

An alternative would be to disable palettization for reproducibility, at the
cost of roughly doubling the download to about 300 MB. Not worth it.

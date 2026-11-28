# Roadmap

Each milestone leaves the repository in a working state and reports real test
results. Nothing claims to be verified unless it actually ran.

## M1 — Foundation ✅ complete

Domain logic, schema, backend skeleton, CI, docs. No Apple account, no API keys,
no paid infrastructure, nothing deployed.

**Delivered:** `TokinoKit` with the publishing state machine, scan planner,
checkpointing and provider abstraction; 19-table Supabase schema with RLS
enabled and forced; FastAPI skeleton with the mock-refusal guard; Linux and
macOS CI; secret scanning.

**Authentication, precisely:** the brief lists this under M1, and what exists is
the groundwork only — an `app_user` table mirroring `auth.users`, and every RLS
policy written against `auth.uid()` so Supabase Auth drops straight in. There is
**no sign-in flow**; that belongs with onboarding in M2. The migration provides a
stand-in `auth.uid()` for CI and never replaces Supabase's own.

**Test results:** 89 TokinoKit tests (Swift 6.4.3, Linux), 51 backend tests
(real Postgres 16 + pgvector 0.8.7), and 5 iOS XCTest cases on an iOS 26
simulator — all passing, locally and in CI.

## M2a — Photo discovery (in progress)

Split from the original M2 because the background scan and real throughput
cannot be verified without a device. This covers what CI can prove.

**Done and verified:**

- `CLIPTokenizer` and `CLIPTextCleaner` — a from-scratch byte-level BPE port,
  matching `open_clip`'s own output on all 37 reference cases.
- `SimilaritySearch`, `AssetCriteriaFilter` and `EmptyResultDiagnosis`.
- `ScanEngine` — resumable, cancellable, condition-gated, with a documented
  retry policy for failed and iCloud-deferred assets.
- `IndexSyncPlanner` — push-only diff with deletion propagation.
- **Model conversion, with parity proven**: OpenCLIP ViT-B/32 to Core ML,
  all 8 checks at cosine ≥ 0.9992 against PyTorch on a macOS runner.
  137 MB for both towers at 8-bit.
- `PHPersistentChangeToken` confirmed by compiling, closing M1's open question.

**Written, being compiled:** onboarding and the permission flow, the PhotoKit
adapter, the Core ML embedder, the SQLite index, the scan coordinator, and the
search UI.

**Still to do:** the end-to-end semantic search test on a simulator seeded via
`simctl addmedia` — the one that proves retrieval works without the user's
photos or phone — and model hosting so the app can fetch the towers.

**Needs:** nothing external.

## M2b — Background scanning (needs a device)

- `BGContinuedProcessingTask` with the system progress UI. Apple requires
  submission from the foreground in response to a user action, and background
  tasks do not run in the simulator at all.
- Incremental catch-up via `BGProcessingTaskRequest`.
- Neural Engine throughput and battery cost, measured rather than assumed.
- A full scan of the user's real library, as the first genuine acceptance test.

**Needs:** Apple Developer enrolment, then TestFlight.

## M3 — Experience and location intelligence

- Grouping by GPS, time, visual similarity and capture sequence.
- Google Places matching with confidence and evidence.
- Confirmation UI for uncertain matches.
- **Apple Developer enrolment → Xcode Cloud → TestFlight → the app on your
  iPhone.** The first time background scanning can actually be verified.

**Needs:** Apple $99/year; Google Cloud billing account. Start enrolment during
M2 — identity verification takes days and waiting does not help.

## M4 — Content strategy

- Natural-language strategy creation and structured interpretation.
- Voice profiles; content pillars; idea generation.
- Deploy `tokino-api`.

**Needs:** one LLM API key; a container host.

## M5 — Content generation

- Photo selection and ranking; carousel assembly.
- English and Chinese captions, grounded in verified facts only.
- Hashtags; draft preview; edit and approve workflow.

**Needs:** nothing new.

## M6 — Publishing

- Scheduler on `pg_cron` + `pg_net`, running without the phone.
- Full publishing state machine against the **mock** adapter, per the decision
  to dry-run first.
- Xiaohongshu assisted-publishing handoff.
- Real Instagram publishing **only on explicit go-ahead**, after reviewing
  generated content quality.

**Needs:** an Instagram professional account, only if going live. No App Review
required for your own account.

## M7 — Video and advanced automation

- Short-form video rendering with ffmpeg on a worker.
- Editorial calendar automation; performance analytics.
- Optional fully automatic publishing, where the platform supports it.

**Needs:** compute for rendering — the first real hosting cost.

## Before any public launch

Not a milestone, but tracked:

- ~~Read the MobileCLIP ASCL licence~~ — **resolved in M2a**: the weights are
  research-only and are not used. OpenCLIP ViT-B/32 (MIT) replaced them.
- Back-port the scan to iOS 18 if a wider audience matters.
- Instagram **Advanced Access**: App Review plus Business Verification, 2–4
  weeks.
- Account deletion and data export flows.
- Make the repository private, and rotate anything that was ever exposed.

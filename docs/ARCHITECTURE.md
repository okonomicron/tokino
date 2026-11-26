# Architecture

## The problem this shape solves

Two requirements in the brief pull against each other:

- Photo originals should stay on the device, and privacy is an architectural
  priority (§2.2).
- Scheduled publishing must run on the backend, independently of the iPhone
  being open (§9).

A backend that knows nothing about the library cannot propose content or publish
on a schedule. A backend that holds every photo is the privacy problem the brief
is trying to avoid. The resolution is to split on *what* leaves the device
rather than on *whether* anything does.

## The privacy boundary

```
iPhone                                  Supabase (direct, under RLS)      tokino-api (M4+)
──────                                  ────────────────────────────      ────────────────
PhotoKit enumerate ─┐
MobileCLIP encode   ├─> local SQLite ─> photo_asset  (metadata)      ──>  language model
thumbnails (local)  ┘   instant search  photo_embedding (512 floats)      places
                                        experience, strategy, draft       publishing
         │
         └── original pixels never leave, except the specific images
             in a draft the user has approved for publishing
```

Stated plainly: **embeddings and metadata leave the device; pixels do not**,
except for images in an approved draft, which are rendered into purpose-built
derivatives (`media_asset`) in private storage.

A 512-float vector is not a photograph. It cannot be viewed, and reconstructing
a recognisable image from one is not practical. That is what makes it acceptable
to sync, and syncing it is what lets the backend reason about the library while
the phone is asleep.

### What the user controls

- Per-asset and per-album exclusion (`photo_asset.is_excluded`).
- A pause switch that overrides every other scan condition.
- Wi-Fi-only processing, and a battery floor.

## The cloud-first lever: split Swift by platform

`TokinoKit` imports only Foundation. No UIKit, no SwiftUI, no PhotoKit. It
therefore compiles and runs its tests under the Linux Swift toolchain, which
means:

- The logic with real bug risk — state machines, scan planning, checkpointing,
  scheduling arithmetic, platform constraints — is verified on free Linux CI on
  every push.
- macOS CI only has to prove that the thin SwiftUI shell compiles and links.

This is not an aesthetic preference. It is what makes developing an iOS app
almost entirely in a Linux container practical.

The iOS layer's job is narrow: PhotoKit enumeration, Core ML embedding,
SwiftUI presentation, and background task registration. It holds no business
rules that could be tested on Linux instead.

## Components

### iOS app

- **Talks to Supabase directly** using `supabase-swift` and the anon key, with
  Row Level Security enforcing isolation. This is the pattern Supabase is built
  for, and it means Milestones 1 and 2 need nothing deployed.
- **Embeds on-device** with MobileCLIP-S2 via Core ML on the Neural Engine. Free,
  private, and the reason indexing a 20,000-photo library costs nothing.
- **Keeps a local vector index** in SQLite for instant offline search, in
  addition to syncing vectors to Postgres for backend use.
- **Scans with `BGContinuedProcessingTask`** (iOS 26): the user starts a scan,
  leaves the app, and watches a Live Activity. The system can terminate it, and
  prioritises terminating tasks showing no progress, so progress reporting is
  load-bearing rather than decorative.

### tokino-api (FastAPI, from M4)

Exists only for work requiring a secret the client must not hold: language-model
calls, Google Places, and publishing. Containerised so the host stays swappable,
and not deployed until there is something that needs it.

`/capabilities` reports which provider serves each capability and whether it is
a mock, so a deployment running on mocks cannot be mistaken for one running on
real integrations.

### Supabase Postgres

Schema, indexes and RLS in `supabase/migrations/`. `pgvector` holds the
embeddings. `pg_cron` plus `pg_net` will drive the publishing scheduler from
inside the database — durable, free, and independent of the app.

## Provider abstraction and the mock rule

`LanguageModelProvider`, `PlaceProvider` and `PublishingAdapter` are protocols.
Each has a mock implementation that is deterministic and loudly labelled.

The rule, enforced in both Swift and Python: **if a real credential is
configured, a mock must not be selected.** A misconfigured deployment fails
loudly instead of quietly producing plausible-looking fabricated captions. This
is the brief's "do not silently substitute mock integrations" (§15) made
mechanical rather than aspirational.

A live provider is preferred even when its credential is missing: failing with a
clear authentication error is more honest than serving fake output.

## Publishing correctness

The lifecycle is `idea → draft → review → approved → scheduled → publishing →
published`, plus `rejected`, `needsRevision`, `failed` and `cancelled`.

One state was added beyond the brief: **`awaitingReconciliation`**. When a
publish call's outcome is unknown — a timeout, or a 5xx after the request was
accepted — the post may or may not be live. Without a distinct state, the only
options are retrying (risking a duplicate post) or giving up (losing a real
post). In this state nothing may publish; a reconciliation job asks the platform
whether the idempotency key already produced a post, then settles the row.

A retry carries the failure it is retrying, so the state machine refuses one
that cannot succeed — an expired credential needs the user to reconnect, and
retrying it would burn attempts and risk tripping platform abuse heuristics.
Passing no failure means a person asked, and a person may retry whatever they
like. This rule lives in the state machine rather than in each caller.

Three layers guard against duplicate posts:

1. Only a `scheduled` row may issue a publish call (`mayIssuePublishCall`).
2. States that may already hold a post refuse cancellation and retry.
3. `publication (social_account_id, idempotency_key)` is unique in Postgres, so
   the guarantee holds even if application logic is wrong.

## What is deliberately absent

- **No `.xcodeproj` in the repository.** Generated from `ios/project.yml` by
  XcodeGen so the project is editable as text. See [IOS_BUILD.md](IOS_BUILD.md).
- **No PhotoKit background upload extension.** Evaluated and rejected; see
  [DECISIONS.md](DECISIONS.md).
- **No password column anywhere.** Social credentials are referenced, never
  stored in the application schema.
- **No HNSW index yet.** Building one on an empty table is wasted work.

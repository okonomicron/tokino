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
OpenCLIP encode     ├─> local SQLite ─> photo_asset  (metadata)      ──>  language model
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
- **Embeds on-device** with OpenCLIP ViT-B/32 via Core ML on the Neural Engine.
  Free, private, and the reason indexing a 20,000-photo library costs nothing.
  MobileCLIP would have been the obvious choice and is licensed for research
  only; see [DECISIONS.md D14](DECISIONS.md#d14-openclip-vit-b32-instead-of-mobileclip-on-licence-grounds).
  The weights are not bundled: they are converted by `tools/convert-openclip.py`,
  published as a release asset, and fetched during onboarding with their
  SHA-256 verified. 137 MB for both towers.
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

## Search, and why the tokenizer is in TokinoKit

Natural-language search needs CLIP's text tower, and the tower only takes token
IDs. Apple ships no text-to-image search API and no CLIP tokenizer, so the
tokenizer is ours to write — a byte-level BPE implementation with CLIP's exact
text cleaning.

It lives in `TokinoKit`, not the app, for one reason: **a tokenizer mismatch
does not fail, it just makes every search slightly worse.** There is no crash
and no error to notice. The only way to catch it is to compare against a
reference, so `tools/ref_openclip.py` generates token IDs from `open_clip`'s own
tokenizer and the Swift implementation is asserted against them on Linux, free,
on every push.

That comparison earned its keep immediately. `open_clip` splits digits one at a
time, so "2024" is four tokens where original OpenAI CLIP gives one. It folds
curly quotes to straight, which matters because **iOS keyboards emit a curly
apostrophe by default** — without the fold, "don't" typed on a phone lands
somewhere different in the embedding space from "don't" in training. And it
applies `html.unescape` twice. A second reference, Hugging Face's
`CLIPTokenizerFast`, disagrees on 9 of 37 inputs because it skips the cleaning
step entirely; `open_clip` wins, since it trained these weights.

Ranking is brute-force exact cosine over the whole index. At one user's scale —
tens of thousands of 512-float vectors, about 40 MB — that is a few tens of
milliseconds, where an approximate index would add a dependency, a build step
and recall error to solve a problem we do not have.

## Verifying the model without a Mac in the loop

`coremltools` converts anywhere but can only `predict()` on macOS. So conversion
correctness is established in two halves:

1. On Linux, `tools/convert-openclip.py` produces the `.mlpackage`s, and
   `tools/reference-vectors.py` records what the PyTorch model computes for a
   fixed set of inputs.
2. On a macOS runner, `tools/verify-parity.py` asserts the converted model
   reproduces those vectors to cosine ≥ 0.99.

The reference inputs are **synthetic pixels from a formula**, not photographs:
nothing to license, and no JPEG decoder differences muddying a comparison meant
to test the conversion. Measured result: all 8 checks at cosine ≥ 0.9992, so
8-bit palettization costs almost nothing.

What this does *not* prove is that the model finds the right photos. That is a
separate question, answered by searching a seeded simulator library and
ultimately by the user's own library.

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

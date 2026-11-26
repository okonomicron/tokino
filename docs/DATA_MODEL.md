# Data model

Swift types live in `packages/TokinoKit/Sources/TokinoKit/`; the schema is
`supabase/migrations/0001_foundation.sql`. The two are kept aligned by
`test_publication_state_values_match_the_swift_enum`, which fails if the
`publication.state` CHECK constraint and `PublicationState` drift apart — a
drift that would otherwise surface at publish time, the worst possible moment.

## Entities

```
app_user
├── device
│   └── photo_asset ─── photo_embedding        (512-dim vector)
├── experience ──┬── experience_asset ──> photo_asset
│                └── place_match              (candidate, with confidence)
├── voice_profile
├── content_strategy ──┬── content_pillar
│                      └── content_idea ──┬── content_idea_experience
│                                         └── content_draft ──┬── content_draft_media ──> media_asset
│                                                             └── publication ──> approval
├── social_account ──> publication
└── processing_job
```

## Design notes worth knowing

### Identity and scoping

`Identifier<Subject>` is a phantom-typed UUID wrapper, so `Identifier<PhotoAsset>`
cannot be passed where `Identifier<ContentDraft>` is expected. The publishing
pipeline threads a dozen different IDs through similar signatures, and the
compiler catches the mix-ups for free.

It encodes as a bare UUID string to match Postgres `uuid` columns, and a
malformed value **fails decoding** rather than becoming a fresh random UUID,
which would silently orphan a row.

`Identifier.deterministic(from:)` derives a stable v5-shaped UUID from a string,
for reproducible fixtures and for idempotency keys a retry must recompute
identically after a process restart.

### Photo index

- `photo_asset (device_id, local_identifier)` is **unique**. PhotoKit's
  `localIdentifier` is stable per device library, not globally — the same string
  can legitimately appear on two of a user's devices. This uniqueness is the
  database-level half of "avoid duplicate indexing".
- `source_modified_at` stores the asset's modification date *as it was when
  indexed*. Comparing it against the library's current value is how the scan
  detects edits without re-embedding everything.
- Coordinates are constrained to be complete (`(latitude is null) = (longitude
  is null)`) and in range. Half a coordinate is meaningless and would corrupt
  experience grouping.
- `photo_embedding.model_identifier` lets a model upgrade find stale rows
  without a full scan. Vectors from different models are not comparable.

### Experience and place matching

`place_match` is deliberately **not a fact**. It carries `confidence`, an
`evidence` set, and separate `is_user_confirmed` / `is_user_rejected` flags.

`PlaceMatch.mayBeStatedAsFact` is the gate on whether content may name a venue:
either the user confirmed it, or confidence ≥0.85 **with corroboration beyond
GPS proximity**. Proximity alone is never enough — the brief is explicit that
the nearest restaurant is not necessarily the right one, and current listings
may not reflect a business that existed years ago.

`place_match_one_confirmed_per_experience` is a partial unique index: at most one
*confirmed* place per experience, while unconfirmed candidates coexist freely.
Two confirmed venues for one visit is a contradiction a caption cannot resolve.

Cached display fields expire after 30 days (`cached_at`), because Google Maps
Platform grants no indefinite caching exception for them, unlike place IDs.

### Strategy

`original_prompt` is the user's own words and is **never rewritten**. The
structured fields are an interpretation of it, so keeping the original means a
better interpreter can re-derive them later.

`selection_criteria` and `cadence` are JSONB because those shapes are still
settling; they become columns when they stop moving. `objectives`, `platforms`
and `exclusions` are arrays because they are only ever read whole.

`automation_level` defaults to `'manual'` in the database as well as in Swift,
so approval-required is the default even for a row inserted by hand.

### Content and publishing

- `content_draft (idea_id, platform)` is unique. Platform-specific content is
  the point, but two drafts for one platform would race to publish.
- `content_draft_media` carries `position`, unique per draft: it is the carousel
  order, and position 0 is the cover.
- `media_asset` is separate from `photo_asset` because originals are never
  modified and never uploaded wholesale. A `media_asset` is a purpose-built
  derivative — a cropped JPEG, a rendered video — created only for an approved
  draft, with `source_asset_id` null for generated media like a title card.
- `social_account` has **no password column**, by design. It holds a
  `credential_reference` to a token kept in the Keychain or encrypted
  server-side.

### The duplicate-post guarantees

Three independent layers, deliberately:

1. `PublicationStateMachine.mayIssuePublishCall` returns true only for
   `scheduled`.
2. States that may already hold a post refuse both cancellation and retry.
3. **In the database:** `publication (social_account_id, idempotency_key)` is
   unique, and `publication_one_published_per_draft` is a partial unique index
   permitting one `published` row per draft and account while letting failed and
   cancelled attempts coexist.

Layer 3 holds even if the application logic is wrong, which is the point.

### Indexes and why each exists

| Index | Serves |
|---|---|
| `photo_asset_device_indexed_idx` | the incremental scan diff |
| `photo_asset_user_created_idx` (partial, excludes excluded assets) | date-ranged strategy queries |
| `photo_asset_user_geo_idx` (partial, where latitude is not null) | geo filtering; most libraries are mostly ungeotagged |
| `photo_embedding_model_idx` | finding stale embeddings after a model upgrade |
| `publication_due_idx` (partial, where state = 'scheduled') | the scheduler's hot path |
| `publication_reconcile_idx` (partial) | sweeping rows awaiting reconciliation |
| `processing_job_claimable_idx` (partial, where pending) | worker job claiming |

The HNSW vector index is deliberately left commented out — see
[DECISIONS.md](DECISIONS.md#d11-no-hnsw-index-on-the-embedding-table-yet).

## Row Level Security

Covered in [SECURITY.md](SECURITY.md#row-level-security). Every table has RLS
enabled *and forced*; the iOS client connects directly, so these policies are
the entirety of the access control story.

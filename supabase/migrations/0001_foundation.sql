-- Tokino foundation schema.
--
-- Targets Supabase Postgres. Two things shape every table here:
--
-- 1. Row Level Security is the ONLY barrier between users. The iOS app talks to
--    Postgres directly with the anon key (see docs/ARCHITECTURE.md), so a
--    missing or permissive policy is a data leak, not a defence-in-depth gap.
--    Every table therefore enables RLS and owns an explicit per-user policy.
--
-- 2. Pixels do not live here. Only metadata and embeddings. Originals stay in
--    the user's photo library; derivatives for an approved post live in object
--    storage and are referenced by path.

create extension if not exists "vector";
create extension if not exists "pgcrypto";

-- Supabase provides auth.uid(). Define a local stand-in only when absent, so
-- the same migration runs against a bare Postgres in CI. Supabase's own
-- auth.uid() is never overwritten.
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    create schema auth;
    -- CI stand-in: reads the user id from a session setting that tests set.
    execute $fn$
      create function auth.uid() returns uuid
      language sql stable
      as 'select nullif(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
    $fn$;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- Mirrors auth.users so application tables can carry a real foreign key.
-- Supabase populates auth.users; this row is created on first sign-in.
create table if not exists app_user (
  id          uuid primary key,
  email       text not null,
  created_at  timestamptz not null default now()
);

create table if not exists device (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references app_user(id) on delete cascade,
  name          text not null,
  model         text not null,
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now()
);
create index if not exists device_user_idx on device(user_id);

-- ---------------------------------------------------------------------------
-- Photo index
-- ---------------------------------------------------------------------------

create table if not exists photo_asset (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references app_user(id) on delete cascade,
  device_id          uuid not null references device(id) on delete cascade,
  -- PhotoKit's localIdentifier. Unique per device, not globally: the same
  -- string can legitimately appear on two of a user's devices.
  local_identifier   text not null,
  media_kind         text not null check (media_kind in ('image', 'video')),
  created_at_source  timestamptz,
  latitude           double precision,
  longitude          double precision,
  pixel_width        integer not null check (pixel_width >= 0),
  pixel_height       integer not null check (pixel_height >= 0),
  duration_seconds   double precision,
  album_names        text[] not null default '{}',
  is_cloud_only      boolean not null default false,
  is_excluded        boolean not null default false,
  source_modified_at timestamptz,
  indexed_at         timestamptz,
  created_at         timestamptz not null default now(),
  -- The dedupe guarantee behind "avoid duplicate indexing".
  unique (device_id, local_identifier),
  -- Coordinates are meaningless one at a time.
  constraint photo_asset_coordinate_complete
    check ((latitude is null) = (longitude is null)),
  constraint photo_asset_latitude_range
    check (latitude is null or latitude between -90 and 90),
  constraint photo_asset_longitude_range
    check (longitude is null or longitude between -180 and 180)
);
create index if not exists photo_asset_user_idx on photo_asset(user_id);
-- Supports the incremental-scan diff: find what this device has indexed.
create index if not exists photo_asset_device_indexed_idx
  on photo_asset(device_id, indexed_at);
-- Supports date-ranged strategy queries.
create index if not exists photo_asset_user_created_idx
  on photo_asset(user_id, created_at_source desc)
  where is_excluded = false;
-- Partial index for the geo-filtered path; most libraries are mostly ungeotagged.
create index if not exists photo_asset_user_geo_idx
  on photo_asset(user_id, latitude, longitude)
  where latitude is not null;

-- 512 dimensions matches MobileCLIP-S2's image encoder.
create table if not exists photo_embedding (
  asset_id          uuid primary key references photo_asset(id) on delete cascade,
  user_id           uuid not null references app_user(id) on delete cascade,
  embedding         vector(512) not null,
  model_identifier  text not null,
  created_at        timestamptz not null default now()
);
-- Lets a model upgrade find stale rows without a full scan.
create index if not exists photo_embedding_model_idx
  on photo_embedding(user_id, model_identifier);
-- Cosine distance, matching how CLIP embeddings are compared. Deliberately not
-- created here: an HNSW index on an empty table is wasted work, and it is far
-- cheaper to build once the library is indexed. See docs/DECISIONS.md.
-- create index photo_embedding_hnsw_idx
--   on photo_embedding using hnsw (embedding vector_cosine_ops);

-- ---------------------------------------------------------------------------
-- Experiences and places
-- ---------------------------------------------------------------------------

create table if not exists experience (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references app_user(id) on delete cascade,
  title             text,
  started_at        timestamptz not null,
  ended_at          timestamptz not null,
  centroid_lat      double precision,
  centroid_lon      double precision,
  grouping_signals  text[] not null default '{}',
  created_at        timestamptz not null default now(),
  constraint experience_time_order check (ended_at >= started_at)
);
create index if not exists experience_user_time_idx
  on experience(user_id, started_at desc);

create table if not exists experience_asset (
  experience_id  uuid not null references experience(id) on delete cascade,
  asset_id       uuid not null references photo_asset(id) on delete cascade,
  -- Capture order within the experience, which carries narrative meaning.
  position       integer not null,
  primary key (experience_id, asset_id)
);
create index if not exists experience_asset_asset_idx on experience_asset(asset_id);

create table if not exists place_match (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references app_user(id) on delete cascade,
  experience_id      uuid not null references experience(id) on delete cascade,
  -- Google Maps Platform permits storing place IDs indefinitely.
  provider_place_id  text not null,
  -- Display fields have no indefinite caching exception under Google's terms,
  -- so cached_at drives a refresh rather than being decorative.
  cached_name        text not null,
  cached_address     text,
  cached_at          timestamptz not null default now(),
  distance_metres    double precision,
  confidence         double precision not null check (confidence between 0 and 1),
  evidence           text[] not null default '{}',
  is_user_confirmed  boolean not null default false,
  is_user_rejected   boolean not null default false,
  created_at         timestamptz not null default now()
);
create index if not exists place_match_experience_idx on place_match(experience_id);
-- At most one confirmed place per experience: two confirmed venues for one
-- visit is a contradiction, and captions would have to pick arbitrarily.
create unique index if not exists place_match_one_confirmed_per_experience
  on place_match(experience_id) where is_user_confirmed;

-- ---------------------------------------------------------------------------
-- Strategies and voice
-- ---------------------------------------------------------------------------

create table if not exists voice_profile (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references app_user(id) on delete cascade,
  name        text not null,
  instruction text not null default '',
  -- Tone axes, emoji and hashtag style, per-platform languages, banned phrases.
  -- JSONB because this shape is still settling; promoted to columns when it stops.
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists voice_profile_user_idx on voice_profile(user_id);

create table if not exists content_strategy (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references app_user(id) on delete cascade,
  name              text not null,
  -- The user's own words, never rewritten. Source of truth for re-interpretation.
  original_prompt   text not null,
  objectives        text[] not null default '{}',
  target_audience   text,
  platforms         text[] not null default '{}',
  selection_criteria jsonb not null default '{}'::jsonb,
  cadence           jsonb not null default '{}'::jsonb,
  voice_profile_id  uuid references voice_profile(id) on delete set null,
  automation_level  text not null default 'manual'
                    check (automation_level in ('manual', 'semiAutomatic', 'fullyAutomatic')),
  exclusions        text[] not null default '{}',
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists content_strategy_user_idx on content_strategy(user_id);

create table if not exists content_pillar (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references app_user(id) on delete cascade,
  strategy_id     uuid not null references content_strategy(id) on delete cascade,
  name            text not null,
  description     text not null default '',
  search_queries  text[] not null default '{}',
  weight          double precision not null default 1 check (weight >= 0),
  created_at      timestamptz not null default now()
);
create index if not exists content_pillar_strategy_idx on content_pillar(strategy_id);

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

create table if not exists content_idea (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references app_user(id) on delete cascade,
  strategy_id  uuid not null references content_strategy(id) on delete cascade,
  pillar_id    uuid references content_pillar(id) on delete set null,
  headline     text not null,
  rationale    text not null default '',
  suggested_format text not null default 'carousel'
                   check (suggested_format in ('singleImage', 'carousel', 'video')),
  score        double precision not null default 0.5 check (score between 0 and 1),
  created_at   timestamptz not null default now()
);
create index if not exists content_idea_strategy_score_idx
  on content_idea(strategy_id, score desc);

create table if not exists content_idea_experience (
  idea_id        uuid not null references content_idea(id) on delete cascade,
  experience_id  uuid not null references experience(id) on delete cascade,
  primary key (idea_id, experience_id)
);

create table if not exists media_asset (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references app_user(id) on delete cascade,
  -- Null for generated media such as a title card.
  source_asset_id  uuid references photo_asset(id) on delete set null,
  kind             text not null check (kind in ('image', 'video')),
  -- Path in private object storage. Served only via short-lived signed URLs.
  storage_path     text not null unique,
  mime_type        text not null,
  byte_count       bigint not null check (byte_count >= 0),
  pixel_width      integer not null,
  pixel_height     integer not null,
  duration_seconds double precision,
  created_at       timestamptz not null default now()
);
create index if not exists media_asset_user_idx on media_asset(user_id);

create table if not exists content_draft (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references app_user(id) on delete cascade,
  idea_id          uuid not null references content_idea(id) on delete cascade,
  strategy_id      uuid not null references content_strategy(id) on delete cascade,
  platform         text not null,
  format           text not null check (format in ('singleImage', 'carousel', 'video')),
  caption          text not null default '',
  hashtags         text[] not null default '{}',
  location_text    text,
  place_match_id   uuid references place_match(id) on delete set null,
  language         text not null default 'en',
  was_edited_by_user boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- One draft per idea per platform: platform-specific content is the point,
  -- but two drafts for the same platform would race to publish.
  unique (idea_id, platform)
);
create index if not exists content_draft_strategy_idx on content_draft(strategy_id);

create table if not exists content_draft_media (
  draft_id        uuid not null references content_draft(id) on delete cascade,
  media_asset_id  uuid not null references media_asset(id) on delete cascade,
  -- Carousel order; position 0 is the cover image.
  position        integer not null check (position >= 0),
  primary key (draft_id, media_asset_id),
  unique (draft_id, position)
);

-- ---------------------------------------------------------------------------
-- Publishing
-- ---------------------------------------------------------------------------

create table if not exists social_account (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references app_user(id) on delete cascade,
  platform           text not null,
  remote_account_id  text not null,
  handle             text not null,
  -- A reference to a credential held elsewhere, never the credential. No
  -- password column exists anywhere in this schema, by design (§8).
  credential_reference text,
  token_expires_at   timestamptz,
  connected_at       timestamptz not null default now(),
  is_active          boolean not null default true,
  unique (user_id, platform, remote_account_id)
);
create index if not exists social_account_user_idx on social_account(user_id);

create table if not exists publication (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references app_user(id) on delete cascade,
  draft_id           uuid not null references content_draft(id) on delete cascade,
  social_account_id  uuid not null references social_account(id) on delete cascade,
  platform           text not null,
  state              text not null default 'idea' check (state in (
                       'idea', 'draft', 'review', 'approved', 'scheduled',
                       'publishing', 'published', 'rejected', 'needsRevision',
                       'failed', 'cancelled', 'awaitingReconciliation')),
  scheduled_for      timestamptz,
  -- Sent to the platform so a retry cannot create a second post. Unique per
  -- account: this is the database-level duplicate-post guard, and it holds even
  -- if application logic is wrong.
  idempotency_key    text,
  remote_id          text,
  attempt_count      integer not null default 0 check (attempt_count >= 0),
  last_failure       jsonb,
  published_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (social_account_id, idempotency_key),
  -- One live post per draft per account. Partial so that failed and cancelled
  -- attempts can coexist with a later successful one.
  constraint publication_published_needs_remote_id
    check (state <> 'published' or remote_id is not null),
  constraint publication_scheduled_needs_time
    check (state <> 'scheduled' or scheduled_for is not null)
);
create index if not exists publication_user_idx on publication(user_id);
-- The scheduler's hot path: what is due now.
create index if not exists publication_due_idx
  on publication(scheduled_for)
  where state = 'scheduled';
-- Rows needing reconciliation must never be lost; this makes sweeping them cheap.
create index if not exists publication_reconcile_idx
  on publication(updated_at)
  where state = 'awaitingReconciliation';
-- At most one live post per draft and account.
create unique index if not exists publication_one_published_per_draft
  on publication(draft_id, social_account_id)
  where state = 'published';

create table if not exists approval (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references app_user(id) on delete cascade,
  publication_id  uuid not null references publication(id) on delete cascade,
  decision        text not null check (decision in ('approved', 'rejected', 'revisionRequested')),
  note            text,
  decided_at      timestamptz not null default now()
);
create index if not exists approval_publication_idx on approval(publication_id);

create table if not exists processing_job (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references app_user(id) on delete cascade,
  kind          text not null,
  state         text not null default 'pending'
                check (state in ('pending', 'running', 'succeeded', 'failed', 'cancelled')),
  payload       jsonb not null default '{}'::jsonb,
  -- Lets a worker claim a job exactly once; a stale lease can be reclaimed.
  claimed_by    text,
  claimed_until timestamptz,
  attempt_count integer not null default 0,
  last_error    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists processing_job_claimable_idx
  on processing_job(kind, created_at)
  where state = 'pending';

-- ---------------------------------------------------------------------------
-- Row Level Security
--
-- Applied to every table. The iOS client connects directly, so these policies
-- are the whole of the access control story.
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
  -- Tables owning a direct user_id column get the same policy shape.
  direct_tables text[] := array[
    'device', 'photo_asset', 'photo_embedding', 'experience', 'place_match',
    'voice_profile', 'content_strategy', 'content_pillar', 'content_idea',
    'media_asset', 'content_draft', 'social_account', 'publication',
    'approval', 'processing_job'
  ];
begin
  foreach t in array direct_tables loop
    execute format('alter table %I enable row level security', t);
    -- FORCE so that even the table owner is subject to the policy. Without it,
    -- a migration or a privileged connection silently bypasses RLS, which is
    -- exactly the hole a public repo makes easy to find.
    execute format('alter table %I force row level security', t);
    execute format('drop policy if exists %I on %I', t || '_owner_rw', t);
    execute format($p$
      create policy %I on %I
        using (user_id = auth.uid())
        with check (user_id = auth.uid())
    $p$, t || '_owner_rw', t);
  end loop;
end $$;

-- app_user is keyed by id rather than user_id.
alter table app_user enable row level security;
alter table app_user force row level security;
drop policy if exists app_user_self_rw on app_user;
create policy app_user_self_rw on app_user
  using (id = auth.uid())
  with check (id = auth.uid());

-- Join tables carry no user_id, so they inherit access from their parent.
-- Written as EXISTS against the parent, which is itself RLS-protected.
alter table experience_asset enable row level security;
alter table experience_asset force row level security;
drop policy if exists experience_asset_owner_rw on experience_asset;
create policy experience_asset_owner_rw on experience_asset
  using (exists (
    select 1 from experience e
    where e.id = experience_asset.experience_id and e.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from experience e
    where e.id = experience_asset.experience_id and e.user_id = auth.uid()
  ));

alter table content_idea_experience enable row level security;
alter table content_idea_experience force row level security;
drop policy if exists content_idea_experience_owner_rw on content_idea_experience;
create policy content_idea_experience_owner_rw on content_idea_experience
  using (exists (
    select 1 from content_idea i
    where i.id = content_idea_experience.idea_id and i.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from content_idea i
    where i.id = content_idea_experience.idea_id and i.user_id = auth.uid()
  ));

alter table content_draft_media enable row level security;
alter table content_draft_media force row level security;
drop policy if exists content_draft_media_owner_rw on content_draft_media;
create policy content_draft_media_owner_rw on content_draft_media
  using (exists (
    select 1 from content_draft d
    where d.id = content_draft_media.draft_id and d.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from content_draft d
    where d.id = content_draft_media.draft_id and d.user_id = auth.uid()
  ));

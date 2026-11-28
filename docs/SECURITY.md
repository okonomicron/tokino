# Security model

## Threat model in one line

A public repository, a mobile client that cannot keep a secret, and a database
the client reaches directly. Row Level Security is therefore the primary
control, not a secondary one.

## Secrets

**Never committed.** `scripts/scan-secrets.sh` runs in CI over the full history
— a credential removed in a later commit is still exposed in a public repo. The
scanner was verified by planting a key and confirming it fails the build, rather
than assumed to work.

| Secret | Where it lives | May it be public? |
|---|---|---|
| Supabase **anon** key | iOS client, repo | **Yes** — designed for this; RLS does the work |
| Supabase **service-role** key | backend host env only | **No** — bypasses RLS entirely |
| LLM API key | backend host env only | No |
| Google Maps key | backend host env only | No |
| Social OAuth tokens | referenced by `social_account.credential_reference`; held in Keychain or encrypted server-side | No |
| Apple signing certificates | never in the repo; Xcode Cloud manages them | No |

`backend/.env.example` documents the variables with empty values. `.env` is
gitignored, as are `*.p8`, `*.p12`, `*.mobileprovision` and `*.cer`.

## Row Level Security

Every table in `public` has RLS **enabled and FORCED**. Forcing matters: without
it the table owner silently bypasses policies, so a privileged connection or a
migration would see everything.

Policies come in two shapes:

- Tables with a `user_id` column: `using (user_id = auth.uid())` and the same
  expression in `with check`.
- Join tables with no `user_id` (`experience_asset`, `content_idea_experience`,
  `content_draft_media`): an `EXISTS` against the parent, which is itself
  RLS-protected.

`app_user` is keyed by `id` rather than `user_id` and has its own policy.

### How this is tested

`backend/tests/test_rls.py` is written adversarially. Every test runs as an
unprivileged role, because **RLS is not enforced for superusers even with FORCE**
— testing as `postgres` would pass vacuously and prove nothing.

It asserts:

- Every table in `public` has RLS enabled *and* forced, and at least one policy.
  A table added later without a policy fails the build.
- A user cannot read another user's row **by its exact primary key** — the
  strongest form, needing no enumeration.
- A user cannot insert a row owned by someone else. Parametrised across all 15
  user-owned tables, because planting data in another account is arguably worse
  than reading from it.
- A user cannot reassign their own row to another user.
- A user cannot delete another user's rows.
- An unauthenticated connection, where `auth.uid()` is null, sees nothing.
- Join-table policies deny both reads and writes across users.

`test_schema.py` holds the positive cases, which keep the above honest: a policy
set that denied everything would pass every negative test.

## Defence beyond RLS

- **No password is stored anywhere.** The schema has no column for one.
- **Private object storage.** `media_asset.storage_path` references private
  storage; access is via short-lived signed URLs. Instagram requires a publicly
  fetchable URL at publish time, so those URLs are narrow in scope and lifetime.
- **Duplicate-post prevention in the database**, not only in application code:
  `publication (social_account_id, idempotency_key)` is unique, and a partial
  unique index permits at most one `published` row per draft and account.
- **Constraints that prevent corrupt state:** a published row must have a
  `remote_id`; a scheduled row must have a time; coordinates must be complete
  and in range; experiences cannot end before they start.
- **Credential expiry is anticipated.** `SocialAccount.needsReauthentication`
  treats a token expiring within the hour as already expired, so a publish does
  not begin with a credential that dies mid-flight. An
  `authenticationExpired` failure is deliberately **not** retryable: retrying
  burns attempts and can trip platform abuse heuristics.

## Privacy

See [ARCHITECTURE.md](ARCHITECTURE.md#the-privacy-boundary). In short:
embeddings and metadata sync; pixels stay on the device except for images in a
draft the user approved. The photo-library permission string explains this
before access is requested.

## Still to do

- Account deletion and data export endpoints (brief §10). Deletion is partly
  covered by `on delete cascade` throughout the schema, but there is no
  user-facing flow yet.
- Rate limiting on `tokino-api`, when it is deployed in M4.
- Webhook signature verification, when publishing callbacks arrive in M6.
- ~~Read the MobileCLIP ASCL licence~~ — **resolved**: those weights are
  licensed for research only and are not used. The embedding weights are now
  OpenCLIP ViT-B/32 under MIT, redistributed with the required notice in
  `packages/TokinoKit/Sources/TokinoKit/Resources/NOTICE.md`.
- Model downloads are verified against a SHA-256 in `EmbeddingModelDescriptor`
  before use. A model file is executable content as far as the Neural Engine is
  concerned, and it arrives over the network.

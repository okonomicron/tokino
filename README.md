# Tokino (ときの)

An AI-powered personal content strategist for iPhone. It turns your existing
photo library into an ongoing social media content strategy, driven by what you
describe in your own words.

> Your memories. Your stories. Your voice. Automatically.

**Status: Milestone 1 — foundation.** The domain logic, database schema and
backend skeleton are built and tested. The iOS app is a structural placeholder;
real screens arrive in Milestone 2. Nothing is deployed and no third-party
service is connected yet.

## Repository layout

| Path | What it is | Where it is tested |
|---|---|---|
| `packages/TokinoKit/` | Platform-agnostic Swift domain logic. Imports only Foundation. | Linux, free, every push |
| `ios/` | SwiftUI + PhotoKit app shell. Deliberately thin. | macOS runner, simulator |
| `backend/` | FastAPI service for work needing secrets. Not deployed until M4. | Linux, free, every push |
| `supabase/migrations/` | Schema, indexes and Row Level Security policies. | Real Postgres + pgvector |
| `scripts/` | Test cluster and secret scanning. | — |
| `docs/` | Architecture, decisions, constraints, costs. | — |

The split between `packages/` and `ios/` is the most important structural
decision in the project: it lets most of the code be verified in the cloud for
free. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Running the tests

Everything below runs on Linux with no Apple hardware and no API keys.

```bash
cd packages/TokinoKit && swift test
```

```bash
scripts/pg-test-cluster.sh start
```

```bash
cd backend && uv venv && uv pip install -e '.[dev]' && .venv/bin/python -m pytest -q
```

```bash
scripts/pg-test-cluster.sh stop
```

The iOS app is built and tested on a macOS runner by `.github/workflows/ios.yml`.
See [docs/IOS_BUILD.md](docs/IOS_BUILD.md) for what needs a Mac and what does not.

## Documentation

- [Product requirements](docs/REQUIREMENTS.md)
- [Architecture](docs/ARCHITECTURE.md) — including the privacy boundary
- [Data model](docs/DATA_MODEL.md)
- [Decision log](docs/DECISIONS.md) — what was chosen, rejected, and why
- [Known constraints](docs/CONSTRAINTS.md) — what the platforms will not let us do
- [Security model](docs/SECURITY.md)
- [iOS build and testing](docs/IOS_BUILD.md)
- [Development environment](docs/DEVELOPMENT.md)
- [API specification](docs/API.md)
- [Costs](docs/COSTS.md)
- [Roadmap](docs/ROADMAP.md)
- [Original brief](docs/PROMPT.md)

## A note on this repository being public

It is public so that GitHub's macOS runners are free, which is what makes
cloud-first iOS development affordable. Two consequences follow:

1. Row Level Security is the only barrier protecting user data, and anyone can
   read the policies to look for a gap. The RLS tests are written adversarially
   for that reason.
2. No credential may ever be committed. `scripts/scan-secrets.sh` runs in CI
   over the full history. The Supabase **anon** key is designed to be public;
   the **service-role** key must never appear here.

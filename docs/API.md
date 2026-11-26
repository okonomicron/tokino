# API specification

`tokino-api` is intentionally small. Most of the app's data access goes straight
from the iOS client to Supabase under Row Level Security, so this service exists
only for work that needs a secret the client must not hold.

**Not deployed yet.** It is built and tested in Milestone 1 and deployed in
Milestone 4, when there is a language-model key for it to use.

## Source of truth

The OpenAPI document is generated from the code, not hand-maintained:

```bash
cd backend && .venv/bin/python -c "import json; from app.main import app; print(json.dumps(app.openapi(), indent=2))"
```

With the service running, `/docs` and `/redoc` serve it interactively.

## Current endpoints (Milestone 1)

### `GET /health`

Liveness. Returns `{"status": "ok", "version": "0.1.0"}`.

### `GET /capabilities`

Reports which provider serves each capability and whether it is a mock. This
exists so that **a deployment running on mocks cannot be mistaken for one
running on real integrations**, which the brief requires (§15).

```json
[
  {
    "capability": "languageModel",
    "provider": "MOCK · mock-language-model · not a real integration",
    "is_mock": true,
    "has_credential": false,
    "error": null
  }
]
```

When a credential is configured but only mocks are registered, `provider` is
null and `error` explains the refusal, rather than reporting a healthy mock:

```json
{
  "capability": "languageModel",
  "provider": null,
  "is_mock": false,
  "has_credential": true,
  "error": "Refusing to use mock provider 'mock-language-model' for languageModel: a real credential is configured, so mock output would be mistaken for real output. Register a live provider or remove the credential."
}
```

## Planned endpoints

Listed so the shape is visible; none is implemented.

| Milestone | Endpoint | Purpose |
|---|---|---|
| M3 | `POST /experiences/{id}/match-places` | Google Places candidates with confidence |
| M4 | `POST /strategies/interpret` | prompt + library summary → structured strategy |
| M4 | `POST /strategies/{id}/ideas` | generate content ideas from the index |
| M5 | `POST /drafts/{id}/caption` | platform- and voice-specific caption |
| M6 | `POST /publications/{id}/publish` | idempotent publish, called by the scheduler |
| M6 | `POST /publications/{id}/reconcile` | resolve `awaitingReconciliation` |
| M6 | `POST /internal/scheduler/tick` | invoked by `pg_cron` via `pg_net` |

## Conventions

- **Authentication** is the caller's Supabase JWT, forwarded as a bearer token.
  The service never accepts a user id as a parameter; it derives identity from
  the token, so a caller cannot act as someone else.
- **No endpoint returns a secret**, including `/capabilities`, which reports only
  whether a credential is present.
- **Publishing endpoints are idempotent**, keyed by
  `publication.idempotency_key`. A retried call must never create a second post.
- **Scheduling is ours.** Neither Instagram nor Xiaohongshu offers a scheduling
  API, so `pg_cron` drives `/internal/scheduler/tick` from inside Postgres,
  independent of the app being open.

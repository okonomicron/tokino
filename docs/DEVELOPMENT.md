# Development environment

Everything here runs on Linux. No Apple hardware, no API keys, no paid services.

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Swift | 6.4.3 | Linux toolchain from swift.org |
| Python | 3.13 | with `uv` |
| PostgreSQL | 16 | plus `postgresql-16-pgvector` |
| XcodeGen | any recent | macOS only, for the iOS project |

### Swift on Linux

```bash
curl -L -o /tmp/swift.tar.gz https://download.swift.org/swift-6.4.3-release/ubuntu2404/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE-ubuntu24.04.tar.gz
```

```bash
sudo mkdir -p /opt/swift && sudo tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components=1
```

```bash
export PATH=/opt/swift/usr/bin:$PATH
```

### Postgres with pgvector

```bash
sudo apt-get install -y postgresql-16-pgvector
```

## Running the tests

### TokinoKit

```bash
cd packages/TokinoKit && swift test
```

Fast — the whole suite runs in milliseconds, because it is pure logic with no
I/O, no clock and no actors in the hot paths. Time is always injected, so
nothing is flaky.

### Backend, migrations and RLS

Start a throwaway cluster:

```bash
scripts/pg-test-cluster.sh start
```

```bash
cd backend && uv venv && uv pip install -e '.[dev]'
```

```bash
.venv/bin/python -m pytest -q
```

```bash
scripts/pg-test-cluster.sh stop
```

The database tests **skip rather than fail** when no cluster is reachable, so
`pytest` still works with nothing running. If you see skips where you expected
passes, the cluster is not up.

`scripts/pg-test-cluster.sh` re-execs itself as the `postgres` user, since
Postgres refuses to run as root. Data lives in `/tmp/tokino-pgdata` and is
destroyed on every start, so a stale run cannot mask a broken migration.

### Secret scan

```bash
scripts/scan-secrets.sh
```

Also runs in CI over full history. To convince yourself it works, plant a fake
key in a tracked file and watch it fail.

## Conventions

- **Logic belongs in `TokinoKit`**, not in the iOS app. If something can be
  tested on Linux, it should be, because that testing is free and fast. Ask of
  any new iOS code: could this be a pure function in TokinoKit instead?
- **Inject time.** Every function that needs the current moment takes a `now`
  parameter. This is why the test suite is deterministic.
- **Comments explain why, not what.** The code says what it does.
- **Mocks announce themselves.** Any new provider mock must carry
  `isMock: true` and be refused when a credential exists.
- **Migrations are forward-only and idempotent**, and numbered `NNNN_name.sql`.
  CI asserts both the numbering and the idempotency.

## Project layout rationale

`packages/TokinoKit` imports only Foundation. That constraint is deliberate and
load-bearing — it is what lets the majority of the codebase be verified in a
Linux container for free. Adding `import UIKit` or `import Photos` to TokinoKit
would break Linux CI immediately, which is the intended feedback.

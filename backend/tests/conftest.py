"""Shared fixtures, including the Postgres test cluster wiring.

Database tests run against a real Postgres with real pgvector. Two very
different clusters have to work:

- Locally, `scripts/pg-test-cluster.sh` starts a throwaway cluster with `trust`
  auth over a unix socket, where passwords are ignored.
- In CI, the `pgvector/pgvector` service container listens on TCP with
  `scram-sha-256`, where a role without a password cannot connect at all.

So the unprivileged test role is given an explicit password, and admin and app
connections are separate fixtures rather than one DSN with the username
substituted — substitution silently carried the wrong password across and only
failed on the TCP cluster.

Tests skip rather than fail when no cluster is reachable, so `pytest` still
works with nothing running.
"""

from __future__ import annotations

import os
import pathlib
import uuid

import psycopg
import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS_DIR = REPO_ROOT / "supabase" / "migrations"

# Matches the defaults in scripts/pg-test-cluster.sh; CI overrides via env.
PG_HOST = os.environ.get("PGSOCKET", "/tmp/tokino-pgsock")
PG_PORT = os.environ.get("PGPORT", "55432")
PG_DB = os.environ.get("PGDATABASE", "tokino_test")
# Empty locally (trust auth ignores it); set to `postgres` by CI.
PG_SUPERUSER_PASSWORD = os.environ.get("PGPASSWORD", "")

# RLS is not enforced for superusers even with FORCE ROW LEVEL SECURITY, so
# every policy test must connect as this unprivileged role. Testing as postgres
# would pass vacuously and prove nothing.
APP_ROLE = "tokino_app_test"
# A throwaway credential for a local test cluster that never accepts external
# connections. Not a secret, and deliberately obvious about that.
APP_ROLE_PASSWORD = "not-a-secret-test-only"

ADMIN_DSN = (
    f"host={PG_HOST} port={PG_PORT} user=postgres dbname={PG_DB} "
    f"password={PG_SUPERUSER_PASSWORD}"
)
APP_DSN = (
    f"host={PG_HOST} port={PG_PORT} user={APP_ROLE} dbname={PG_DB} "
    f"password={APP_ROLE_PASSWORD}"
)


def _cluster_available() -> bool:
    try:
        with psycopg.connect(ADMIN_DSN, connect_timeout=5):
            return True
    except (psycopg.Error, OSError):
        # psycopg raises OperationalError when nothing is listening; OSError
        # covers a missing socket directory. Anything else is a real bug and
        # should surface rather than silently skipping the whole suite.
        return False


requires_db = pytest.mark.skipif(
    not _cluster_available(),
    reason="no Postgres test cluster; run scripts/pg-test-cluster.sh start",
)


@pytest.fixture(scope="session")
def admin_dsn() -> str:
    """Superuser connection string. Bypasses RLS, so never used to test policies."""
    return ADMIN_DSN


@pytest.fixture(scope="session")
def migrated_database(admin_dsn: str) -> str:
    """Applies every migration in order, then hands back the app-role DSN."""
    with psycopg.connect(admin_dsn, autocommit=True) as conn:
        # Start from a clean schema so a stale run cannot mask a broken migration.
        conn.execute("drop schema if exists public cascade")
        conn.execute("create schema public")
        conn.execute("drop schema if exists auth cascade")

        for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
            conn.execute(path.read_text())

        # An unprivileged role standing in for Supabase's `authenticated` role.
        # The password is required on a password-authenticating cluster and
        # harmlessly ignored on a trust-auth one.
        conn.execute(f"drop role if exists {APP_ROLE}")
        conn.execute(
            f"create role {APP_ROLE} login nosuperuser nobypassrls "
            f"password '{APP_ROLE_PASSWORD}'"
        )
        conn.execute(f"grant usage on schema public, auth to {APP_ROLE}")
        conn.execute(
            "grant select, insert, update, delete on all tables "
            f"in schema public to {APP_ROLE}"
        )
        conn.execute(f"grant execute on all functions in schema auth to {APP_ROLE}")

    return APP_DSN


@pytest.fixture
def as_user(migrated_database: str):
    """Opens a connection acting as a given user id, the way Supabase would.

    Sets `request.jwt.claim.sub`, which auth.uid() reads. This is the same
    mechanism Supabase uses, so the policies under test are the real ones.
    """
    connections: list[psycopg.Connection] = []

    def _connect(user_id: uuid.UUID) -> psycopg.Connection:
        conn = psycopg.connect(migrated_database, autocommit=True)
        conn.execute("select set_config('request.jwt.claim.sub', %s, false)", (str(user_id),))
        connections.append(conn)
        return conn

    yield _connect

    for conn in connections:
        conn.close()


@pytest.fixture
def seeded_users(migrated_database: str, admin_dsn: str):
    """Creates two distinct users with a device each, for isolation tests."""
    alice, bob = uuid.uuid4(), uuid.uuid4()
    devices: dict[uuid.UUID, uuid.UUID] = {}

    with psycopg.connect(admin_dsn, autocommit=True) as conn:
        for user_id, email in ((alice, "alice@example.test"), (bob, "bob@example.test")):
            conn.execute("insert into app_user (id, email) values (%s, %s)", (user_id, email))
            device_id = uuid.uuid4()
            conn.execute(
                "insert into device (id, user_id, name, model) values (%s, %s, %s, %s)",
                (device_id, user_id, "test-iphone", "iPhone17,1"),
            )
            devices[user_id] = device_id

    return {"alice": alice, "bob": bob, "devices": devices}

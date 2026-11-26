"""Adversarial Row Level Security tests.

The repository is public and the iOS app talks to Postgres directly, so RLS is
the only barrier between one user's photo library and another's. These tests try
to break through it rather than merely confirming the happy path works.

Every test runs as an unprivileged role, because RLS is not enforced for
superusers even with FORCE ROW LEVEL SECURITY.
"""

from __future__ import annotations

import uuid

import psycopg
import pytest

from .conftest import requires_db

pytestmark = [requires_db, pytest.mark.db]

# Tables owning a direct user_id column, which must all behave identically.
DIRECT_USER_TABLES = [
    "device",
    "photo_asset",
    "photo_embedding",
    "experience",
    "place_match",
    "voice_profile",
    "content_strategy",
    "content_pillar",
    "content_idea",
    "media_asset",
    "content_draft",
    "social_account",
    "publication",
    "approval",
    "processing_job",
]


def test_every_public_table_has_rls_enabled_and_forced(migrated_database):
    """A table added later without RLS would be an open door, so assert on all."""
    with psycopg.connect(migrated_database.replace("tokino_app_test", "postgres")) as conn:
        rows = conn.execute(
            """
            select c.relname, c.relrowsecurity, c.relforcerowsecurity
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
            order by c.relname
            """
        ).fetchall()

    assert rows, "expected tables in the public schema"
    missing = [name for name, enabled, _ in rows if not enabled]
    unforced = [name for name, _, forced in rows if not forced]

    assert not missing, f"tables without RLS enabled: {missing}"
    # FORCE matters because without it the table owner silently bypasses policies.
    assert not unforced, f"tables without RLS forced: {unforced}"


def test_every_public_table_has_at_least_one_policy(migrated_database):
    """RLS enabled with no policy denies everything, which is safe but broken."""
    with psycopg.connect(migrated_database.replace("tokino_app_test", "postgres")) as conn:
        rows = conn.execute(
            """
            select c.relname, count(p.polname)
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            left join pg_policy p on p.polrelid = c.oid
            where n.nspname = 'public' and c.relkind = 'r'
            group by c.relname
            order by c.relname
            """
        ).fetchall()

    without = [name for name, count in rows if count == 0]
    assert not without, f"tables with RLS but no policy: {without}"


def test_a_user_sees_only_their_own_rows(as_user, seeded_users):
    alice, bob = seeded_users["alice"], seeded_users["bob"]

    alice_conn = as_user(alice)
    bob_conn = as_user(bob)

    alice_rows = alice_conn.execute("select id from app_user").fetchall()
    bob_rows = bob_conn.execute("select id from app_user").fetchall()

    assert alice_rows == [(alice,)]
    assert bob_rows == [(bob,)]


def test_a_user_cannot_read_another_users_devices(as_user, seeded_users):
    alice, bob = seeded_users["alice"], seeded_users["bob"]
    bob_device = seeded_users["devices"][bob]

    alice_conn = as_user(alice)
    # Ask for Bob's device by its exact primary key: the strongest form of the
    # attack, since it needs no enumeration.
    rows = alice_conn.execute("select id from device where id = %s", (bob_device,)).fetchall()
    assert rows == [], "Alice read Bob's device row"

    # And confirm Alice can see her own, so the policy is not simply denying all.
    own = alice_conn.execute("select count(*) from device").fetchone()
    assert own == (1,)


@pytest.mark.parametrize("table", DIRECT_USER_TABLES)
def test_a_user_cannot_insert_rows_owned_by_another_user(as_user, seeded_users, table):
    """The WITH CHECK half of each policy.

    Without it a user could write rows attributed to someone else, which is
    arguably worse than reading: it plants data in another account.
    """
    alice, bob = seeded_users["alice"], seeded_users["bob"]
    alice_conn = as_user(alice)

    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        # Minimal insert: it should be refused by the policy before any
        # not-null or foreign-key constraint is reached.
        alice_conn.execute(f"insert into {table} (user_id) values (%s)", (bob,))


def test_a_user_cannot_reassign_their_row_to_another_user(as_user, seeded_users):
    """An UPDATE that changes user_id must fail the policy's WITH CHECK."""
    alice, bob = seeded_users["alice"], seeded_users["bob"]
    alice_conn = as_user(alice)

    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        alice_conn.execute("update device set user_id = %s", (bob,))


def test_a_user_cannot_delete_another_users_rows(as_user, seeded_users):
    alice, bob = seeded_users["alice"], seeded_users["bob"]
    bob_device = seeded_users["devices"][bob]

    alice_conn = as_user(alice)
    # A delete that matches nothing visible silently affects zero rows rather
    # than erroring, so assert the row survives.
    alice_conn.execute("delete from device where id = %s", (bob_device,))

    with psycopg.connect(
        alice_conn.info.dsn.replace("tokino_app_test", "postgres"), autocommit=True
    ) as admin:
        remaining = admin.execute(
            "select count(*) from device where id = %s", (bob_device,)
        ).fetchone()
    assert remaining == (1,), "Alice deleted Bob's device"


def test_an_unauthenticated_connection_sees_nothing(migrated_database, seeded_users):
    """With no JWT claim set, auth.uid() is null and every policy must fail shut."""
    with psycopg.connect(migrated_database, autocommit=True) as conn:
        for table in ["app_user", "device", "photo_asset", "publication"]:
            rows = conn.execute(f"select count(*) from {table}").fetchone()
            assert rows == (0,), f"{table} leaked rows to an unauthenticated connection"


def test_join_tables_inherit_access_from_their_parent(as_user, seeded_users):
    """Join tables carry no user_id, so their policies go through the parent."""
    alice, bob = seeded_users["alice"], seeded_users["bob"]
    alice_conn = as_user(alice)
    bob_conn = as_user(bob)

    # Bob creates an experience with one asset.
    bob_device = seeded_users["devices"][bob]
    bob_experience = uuid.uuid4()
    bob_asset = uuid.uuid4()
    bob_conn.execute(
        """
        insert into photo_asset
          (id, user_id, device_id, local_identifier, media_kind, pixel_width, pixel_height)
        values (%s, %s, %s, 'bob-asset-1', 'image', 100, 100)
        """,
        (bob_asset, bob, bob_device),
    )
    bob_conn.execute(
        """
        insert into experience (id, user_id, started_at, ended_at)
        values (%s, %s, now(), now())
        """,
        (bob_experience, bob),
    )
    bob_conn.execute(
        "insert into experience_asset (experience_id, asset_id, position) values (%s, %s, 0)",
        (bob_experience, bob_asset),
    )

    # Bob sees his own join row.
    assert bob_conn.execute("select count(*) from experience_asset").fetchone() == (1,)

    # Alice sees none of it, and cannot attach her own asset to his experience.
    assert alice_conn.execute("select count(*) from experience_asset").fetchone() == (0,)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        alice_conn.execute(
            "insert into experience_asset (experience_id, asset_id, position) "
            "values (%s, %s, 1)",
            (bob_experience, bob_asset),
        )

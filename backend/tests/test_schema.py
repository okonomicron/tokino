"""Schema-level tests: legitimate writes, constraints, and migration hygiene.

These exist partly to keep test_rls.py honest. A policy set that denied every
operation would pass every negative RLS test, so the positive cases here prove
the policies permit the access they are supposed to.
"""

from __future__ import annotations

import uuid

import psycopg
import pytest

from .conftest import MIGRATIONS_DIR, requires_db

pytestmark = [requires_db, pytest.mark.db]


# --------------------------------------------------------------------------
# Positive cases: the policies must permit a user's own work
# --------------------------------------------------------------------------

def test_a_user_can_write_and_read_their_own_photo_index(as_user, seeded_users):
    alice = seeded_users["alice"]
    device = seeded_users["devices"][alice]
    conn = as_user(alice)

    asset_id = uuid.uuid4()
    conn.execute(
        """
        insert into photo_asset
          (id, user_id, device_id, local_identifier, media_kind,
           pixel_width, pixel_height, latitude, longitude)
        values (%s, %s, %s, 'alice-asset-1', 'image', 4032, 3024, 35.6655, 139.7707)
        """,
        (asset_id, alice, device),
    )
    row = conn.execute(
        "select local_identifier, pixel_width from photo_asset where id = %s", (asset_id,)
    ).fetchone()
    assert row == ("alice-asset-1", 4032)


def test_a_user_can_store_and_search_a_real_embedding(as_user, seeded_users):
    """Exercises pgvector end to end, including a cosine-distance query."""
    alice = seeded_users["alice"]
    device = seeded_users["devices"][alice]
    conn = as_user(alice)

    for index in range(3):
        asset_id = uuid.uuid4()
        conn.execute(
            """
            insert into photo_asset
              (id, user_id, device_id, local_identifier, media_kind,
               pixel_width, pixel_height)
            values (%s, %s, %s, %s, 'image', 100, 100)
            """,
            (asset_id, alice, device, f"vec-asset-{index}"),
        )
        # A distinct unit-ish vector per asset so ordering is meaningful.
        vector = [0.0] * 512
        vector[index] = 1.0
        conn.execute(
            """
            insert into photo_embedding (asset_id, user_id, embedding, model_identifier)
            values (%s, %s, %s, 'mobileclip-s2-v1')
            """,
            (asset_id, alice, str(vector)),
        )

    query = [0.0] * 512
    query[1] = 1.0
    rows = conn.execute(
        """
        select a.local_identifier
        from photo_embedding e
        join photo_asset a on a.id = e.asset_id
        order by e.embedding <=> %s::vector
        limit 1
        """,
        (str(query),),
    ).fetchall()
    assert rows == [("vec-asset-1",)], "nearest-neighbour search returned the wrong asset"


def test_embedding_rejects_the_wrong_dimension_count(as_user, seeded_users):
    """A 512-dim column must refuse anything else, close to the cause."""
    alice = seeded_users["alice"]
    device = seeded_users["devices"][alice]
    conn = as_user(alice)

    asset_id = uuid.uuid4()
    conn.execute(
        """
        insert into photo_asset
          (id, user_id, device_id, local_identifier, media_kind, pixel_width, pixel_height)
        values (%s, %s, %s, 'dim-test', 'image', 10, 10)
        """,
        (asset_id, alice, device),
    )
    with pytest.raises(psycopg.errors.DataException):
        conn.execute(
            """
            insert into photo_embedding (asset_id, user_id, embedding, model_identifier)
            values (%s, %s, %s, 'm')
            """,
            (asset_id, alice, str([0.0] * 128)),
        )


# --------------------------------------------------------------------------
# Constraints that protect correctness
# --------------------------------------------------------------------------

def test_duplicate_local_identifiers_are_rejected_per_device(as_user, seeded_users):
    """The database-level half of 'avoid duplicate indexing'."""
    alice = seeded_users["alice"]
    device = seeded_users["devices"][alice]
    conn = as_user(alice)

    for _ in range(1):
        conn.execute(
            """
            insert into photo_asset
              (user_id, device_id, local_identifier, media_kind, pixel_width, pixel_height)
            values (%s, %s, 'dup-1', 'image', 10, 10)
            """,
            (alice, device),
        )
    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            """
            insert into photo_asset
              (user_id, device_id, local_identifier, media_kind, pixel_width, pixel_height)
            values (%s, %s, 'dup-1', 'image', 10, 10)
            """,
            (alice, device),
        )


def test_a_half_present_coordinate_is_rejected(as_user, seeded_users):
    """One of latitude/longitude alone is meaningless and would corrupt grouping."""
    alice = seeded_users["alice"]
    device = seeded_users["devices"][alice]
    conn = as_user(alice)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            insert into photo_asset
              (user_id, device_id, local_identifier, media_kind,
               pixel_width, pixel_height, latitude)
            values (%s, %s, 'half-coord', 'image', 10, 10, 35.0)
            """,
            (alice, device),
        )


def test_an_out_of_range_coordinate_is_rejected(as_user, seeded_users):
    alice = seeded_users["alice"]
    device = seeded_users["devices"][alice]
    conn = as_user(alice)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            insert into photo_asset
              (user_id, device_id, local_identifier, media_kind,
               pixel_width, pixel_height, latitude, longitude)
            values (%s, %s, 'bad-coord', 'image', 10, 10, 999.0, 0.0)
            """,
            (alice, device),
        )


def test_only_one_confirmed_place_per_experience(as_user, seeded_users):
    """Two confirmed venues for one visit is a contradiction captions can't resolve."""
    alice = seeded_users["alice"]
    conn = as_user(alice)

    experience_id = uuid.uuid4()
    conn.execute(
        "insert into experience (id, user_id, started_at, ended_at) values (%s, %s, now(), now())",
        (experience_id, alice),
    )
    for name in ("First", "Second"):
        statement = """
            insert into place_match
              (user_id, experience_id, provider_place_id, cached_name,
               confidence, is_user_confirmed)
            values (%s, %s, %s, %s, 0.9, true)
        """
        if name == "First":
            conn.execute(statement, (alice, experience_id, f"place_{name}", name))
        else:
            with pytest.raises(psycopg.errors.UniqueViolation):
                conn.execute(statement, (alice, experience_id, f"place_{name}", name))

    # Unconfirmed candidates may coexist freely.
    conn.execute(
        """
        insert into place_match
          (user_id, experience_id, provider_place_id, cached_name, confidence)
        values (%s, %s, 'place_candidate', 'Maybe', 0.4)
        """,
        (alice, experience_id),
    )


def test_experience_time_order_is_enforced(as_user, seeded_users):
    alice = seeded_users["alice"]
    conn = as_user(alice)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            insert into experience (user_id, started_at, ended_at)
            values (%s, now(), now() - interval '1 hour')
            """,
            (alice,),
        )


def test_publication_state_values_match_the_swift_enum(migrated_database, admin_dsn):
    """The CHECK constraint and PublicationState must not drift apart.

    If they do, a state the app can produce would be rejected by the database at
    publish time, which is the worst possible moment to find out.
    """
    swift_states = {
        "idea", "draft", "review", "approved", "scheduled", "publishing",
        "published", "rejected", "needsRevision", "failed", "cancelled",
        "awaitingReconciliation",
    }
    with psycopg.connect(admin_dsn) as conn:
        # Several CHECK constraints mention `state`, so combine them all rather
        # than guessing which one enumerates the values.
        definitions = conn.execute(
            """
            select pg_get_constraintdef(oid)
            from pg_constraint
            where conrelid = 'publication'::regclass and contype = 'c'
            """
        ).fetchall()

    assert definitions, "publication has no CHECK constraints"
    combined = " ".join(row[0] for row in definitions)
    for state in swift_states:
        assert f"'{state}'" in combined, f"{state} missing from the state CHECK constraint"

    # And the reverse direction: the database must not accept a state the Swift
    # enum cannot represent, or a stray row would be unreadable by the app.
    quoted = {
        token.strip("'")
        for token in combined.replace("::text", "").split()
        if token.startswith("'") and token.endswith("'")
    }
    unexpected = quoted - swift_states - {"published"}
    assert not unexpected, f"database allows states the Swift enum lacks: {unexpected}"


def test_a_published_publication_requires_a_remote_id(as_user, seeded_users):
    """A published row without a remote id cannot be reconciled or audited."""
    alice = seeded_users["alice"]
    conn = as_user(alice)
    account_id = uuid.uuid4()
    conn.execute(
        """
        insert into social_account (id, user_id, platform, remote_account_id, handle)
        values (%s, %s, 'instagram', 'ig-1', '@alice')
        """,
        (account_id, alice),
    )
    # Build the minimum chain a publication needs.
    strategy_id, idea_id, draft_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    conn.execute(
        "insert into content_strategy (id, user_id, name, original_prompt) "
        "values (%s, %s, 'S', 'p')",
        (strategy_id, alice),
    )
    conn.execute(
        "insert into content_idea (id, user_id, strategy_id, headline) values (%s, %s, %s, 'h')",
        (idea_id, alice, strategy_id),
    )
    conn.execute(
        """
        insert into content_draft (id, user_id, idea_id, strategy_id, platform, format)
        values (%s, %s, %s, %s, 'instagram', 'carousel')
        """,
        (draft_id, alice, idea_id, strategy_id),
    )

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            insert into publication
              (user_id, draft_id, social_account_id, platform, state)
            values (%s, %s, %s, 'instagram', 'published')
            """,
            (alice, draft_id, account_id),
        )


def test_the_same_idempotency_key_cannot_be_reused_on_one_account(as_user, seeded_users):
    """The database-level duplicate-post guard, independent of app logic."""
    alice = seeded_users["alice"]
    conn = as_user(alice)

    account_id = uuid.uuid4()
    conn.execute(
        """
        insert into social_account (id, user_id, platform, remote_account_id, handle)
        values (%s, %s, 'instagram', 'ig-2', '@alice2')
        """,
        (account_id, alice),
    )
    strategy_id, idea_id = uuid.uuid4(), uuid.uuid4()
    conn.execute(
        "insert into content_strategy (id, user_id, name, original_prompt) "
        "values (%s, %s, 'S', 'p')",
        (strategy_id, alice),
    )
    conn.execute(
        "insert into content_idea (id, user_id, strategy_id, headline) values (%s, %s, %s, 'h')",
        (idea_id, alice, strategy_id),
    )

    draft_ids = []
    for platform in ("instagram", "xiaohongshu"):
        draft_id = uuid.uuid4()
        draft_ids.append(draft_id)
        conn.execute(
            """
            insert into content_draft (id, user_id, idea_id, strategy_id, platform, format)
            values (%s, %s, %s, %s, %s, 'carousel')
            """,
            (draft_id, alice, idea_id, strategy_id, platform),
        )

    conn.execute(
        """
        insert into publication
          (user_id, draft_id, social_account_id, platform, state, idempotency_key)
        values (%s, %s, %s, 'instagram', 'failed', 'tokino-key-1')
        """,
        (alice, draft_ids[0], account_id),
    )
    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            """
            insert into publication
              (user_id, draft_id, social_account_id, platform, state, idempotency_key)
            values (%s, %s, %s, 'instagram', 'failed', 'tokino-key-1')
            """,
            (alice, draft_ids[1], account_id),
        )


# --------------------------------------------------------------------------
# Migration hygiene
# --------------------------------------------------------------------------

def test_migrations_are_idempotent(migrated_database, admin_dsn):
    """Re-applying every migration must be a no-op.

    This is what actually matters for a Supabase deploy, where a migration may
    be re-run against a database that already has part of the schema. There are
    deliberately no down-migrations: see docs/DECISIONS.md.
    """
    with psycopg.connect(admin_dsn, autocommit=True) as conn:
        before = conn.execute(
            "select count(*) from information_schema.tables where table_schema = 'public'"
        ).fetchone()

        for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
            conn.execute(path.read_text())

        after = conn.execute(
            "select count(*) from information_schema.tables where table_schema = 'public'"
        ).fetchone()

    assert before == after, "re-applying migrations changed the table count"


def test_migration_files_are_ordered_and_named_consistently():
    """A mis-numbered migration applies in the wrong order, which is hard to spot."""
    paths = sorted(MIGRATIONS_DIR.glob("*.sql"))
    assert paths, "no migrations found"
    for path in paths:
        prefix = path.name.split("_", 1)[0]
        assert prefix.isdigit() and len(prefix) == 4, (
            f"{path.name} should start with a four-digit sequence number"
        )
    numbers = [int(p.name.split("_", 1)[0]) for p in paths]
    assert numbers == sorted(numbers)
    assert len(set(numbers)) == len(numbers), "duplicate migration numbers"


def test_no_migration_contains_a_literal_secret():
    """A public repo makes a committed credential immediately exploitable."""
    suspicious = ["service_role", "sk-", "eyJ", "password ="]
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        text = path.read_text()
        for needle in suspicious:
            assert needle not in text, f"{path.name} may contain a secret ({needle!r})"

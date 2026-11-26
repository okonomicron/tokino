#!/usr/bin/env bash
# Starts a throwaway Postgres cluster for migration and RLS tests.
#
# Deliberately not Docker: the cloud dev container has no Docker daemon, and a
# native cluster starts faster anyway. Postgres refuses to run as root, so when
# invoked as root this re-execs itself as the `postgres` system user.
set -euo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PGDATA="${PGDATA:-/tmp/tokino-pgdata}"
PGPORT="${PGPORT:-55432}"
PGSOCKET="${PGSOCKET:-/tmp/tokino-pgsock}"
export PGBIN PGDATA PGPORT PGSOCKET

if [ "$(id -u)" = "0" ]; then
  # Hand ownership over before dropping privileges, or the unprivileged
  # re-exec cannot clean up directories root created.
  rm -rf "$PGDATA" "$PGSOCKET"
  mkdir -p "$PGDATA" "$PGSOCKET"
  chown -R postgres:postgres "$PGDATA" "$PGSOCKET"
  exec su postgres -s /bin/bash -c "PGBIN='$PGBIN' PGDATA='$PGDATA' PGPORT='$PGPORT' PGSOCKET='$PGSOCKET' bash '$(readlink -f "$0")' ${1:-start}"
fi

case "${1:-start}" in
  start)
    rm -rf "$PGDATA" "$PGSOCKET"
    mkdir -p "$PGDATA" "$PGSOCKET"
    # Trust auth over a local unix socket only; this cluster never listens on TCP.
    "$PGBIN/initdb" -D "$PGDATA" -A trust -U postgres >/dev/null
    "$PGBIN/pg_ctl" -D "$PGDATA" \
      -o "-p $PGPORT -k $PGSOCKET -c listen_addresses=''" \
      -w -l "$PGDATA/server.log" start >/dev/null
    "$PGBIN/createdb" -h "$PGSOCKET" -p "$PGPORT" -U postgres tokino_test
    echo "started on $PGSOCKET:$PGPORT (db: tokino_test)"
    ;;
  stop)
    "$PGBIN/pg_ctl" -D "$PGDATA" -w stop >/dev/null 2>&1 || true
    rm -rf "$PGDATA" "$PGSOCKET"
    echo "stopped"
    ;;
  *)
    echo "usage: $0 {start|stop}" >&2
    exit 2
    ;;
esac

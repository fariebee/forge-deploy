#!/bin/bash
set -e

# For PostgreSQL 18+, data is stored in a version-specific subdirectory
# Find the actual data directory
PGDATA_DIR="/var/lib/postgresql/data"
if [ -d "$PGDATA_DIR" ]; then
    # Check if it's a directory (pg17 and earlier) or find the actual data dir
    if [ ! -f "$PGDATA_DIR/PG_VERSION" ] && [ -d "$PGDATA_DIR/pgdata" ]; then
        PGDATA_DIR="$PGDATA_DIR/pgdata"
    fi
fi

# Create the data directory if it doesn't exist
mkdir -p "$PGDATA_DIR"

# TLS keypair. The repo no longer ships a committed server.key/server.crt —
# they were shared across every install, so a compromise on one box exposed
# every other install's transport key. Two sources, in order:
#
#   1. A pre-seeded keypair in the mounted postgres-ssl/ dir (advanced setups
#      that bring their own CA-signed certs). Copied into the data dir.
#   2. A per-install self-signed keypair generated here, so a fresh boot still
#      has TLS with a key that exists only on this host's pgforge_data volume.
#
# The keypair lives in the data dir (a writable volume), NOT the read-only
# mount, so it persists across container restarts. Existing installs that
# already have the old committed key in their data dir keep it until the
# operator rotates (delete data/server.key + data/server.crt, restart).
if [ -f /etc/postgresql/ssl/server.crt ] && [ -f /etc/postgresql/ssl/server.key ]; then
    cp /etc/postgresql/ssl/server.crt "$PGDATA_DIR/"
    cp /etc/postgresql/ssl/server.key "$PGDATA_DIR/"
fi

if [ ! -f "$PGDATA_DIR/server.crt" ] || [ ! -f "$PGDATA_DIR/server.key" ]; then
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "$PGDATA_DIR/server.key" \
        -out "$PGDATA_DIR/server.crt" \
        -days 3650 \
        -subj "/CN=pgforge-postgres"
fi

chmod 600 "$PGDATA_DIR/server.key"
chown postgres:postgres "$PGDATA_DIR/server.key" "$PGDATA_DIR/server.crt"

# Run the original entrypoint
exec docker-entrypoint.sh "$@"

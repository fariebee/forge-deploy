#!/usr/bin/env bash
# Install the `pgforge` CLI on the host by copying it out of the running
# pgforge-app container. Run this once after each Forge upgrade so the
# operator's CLI version matches the running server.
set -euo pipefail

CONTAINER="${PGFORGE_CONTAINER:-pgforge-app}"
DEST="${PGFORGE_BIN:-/usr/local/bin/pgforge}"
SRC_IN_CONTAINER="/app/pgforge"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found in PATH" >&2
    exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "container '$CONTAINER' not found — is Forge running?" >&2
    echo "set PGFORGE_CONTAINER to override" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

docker cp "$CONTAINER:$SRC_IN_CONTAINER" "$tmp"
install -m 0755 "$tmp" "$DEST"

echo "installed pgforge → $DEST"
"$DEST" --version 2>/dev/null || true

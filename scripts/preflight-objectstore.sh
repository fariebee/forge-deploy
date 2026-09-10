#!/bin/sh
# Blocks a deploy from silently swapping a host's populated MinIO volume for
# an empty SeaweedFS store. Passes on a fresh install (no MinIO volume yet)
# and once the operator has finished the cutover runbook and touched the
# marker file; otherwise the operator must run the cutover runbook first.
#
# The marker (not the seaweedfs_data volume's existence) is the signal: the
# runbook creates that volume mid-migration, before the data copy and
# cutover are done, so gating on it let a CI deploy land in that window and
# recreate "minio" as an empty SeaweedFS store while the copy was still in
# flight.
set -eu

MARKER=.seaweedfs-cutover-done
MINIO_VOL=$(docker volume ls --filter label=com.docker.compose.volume=minio_data --format '{{.Name}}')

if [ -z "$MINIO_VOL" ] || [ -f "$MARKER" ]; then
    exit 0
fi

cat >&2 <<EOF
ERROR: object store cutover not done — refusing to deploy.

This host still has a populated MinIO volume ($MINIO_VOL) and the
cutover marker ($MARKER) is missing. Deploying now would recreate the
"minio" compose service and replace it with an empty SeaweedFS store,
losing all bucket data.

Run the cutover runbook first:
  docs/runbooks/seaweedfs-cutover.md

Once the runbook's final step touches $MARKER, re-run this deploy.
EOF
exit 1

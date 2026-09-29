#!/usr/bin/env bash
# Run the BuildKit daemon that builds the images of every app outside the
# default org once TENANT_BUILDKIT is set: under gVisor (runsc-netstack), with
# CPU, memory and PID caps, on a network of its own. Forge registers it as a
# remote buildx builder itself, inside its own container.
#
# Needs runsc-netstack registered first (scripts/install-gvisor.sh). Re-running
# recreates the container with the current settings — the build cache is in a
# volume and survives, but builds in flight fail and are retried at the app's
# next deploy.
#   sudo bash scripts/install-tenant-builder.sh
#   sudo CPUS=4 MEMORY=8g bash scripts/install-tenant-builder.sh
# The build cache lives on a fixed-size loop-mounted ext4 filesystem
# (BUILDER_DISK_GB, default sized from free space) so an oversized build
# fails with ENOSPC instead of filling the host disk; BUILDER_DISK_GB=0
# reverts to the old uncapped-host-fs behaviour.
#   sudo BUILDER_DISK_GB=40 bash scripts/install-tenant-builder.sh
# Runbook: docs/runbooks/gvisor.md ("Tenant builds" / "Builder disk").
set -euo pipefail

# The dot keeps the name out of reach of every container name Forge derives
# from an app name (forge-<app>, …): app names are [a-z0-9_-] only, and a
# tenant container answering to this name would receive every org's builds.
NAME=${NAME:-forge.tenant-buildkit}
CPUS=${CPUS:-2}
MEMORY=${MEMORY:-4g}
PIDS=${PIDS:-4096}
MAX_PARALLELISM=${MAX_PARALLELISM:-2}
NAMESERVERS=${NAMESERVERS:-1.1.1.1 8.8.8.8}
# Build-cache caps in GB (10^9), fixed rather than buildkitd's default
# percentages of whatever disk holds the cache. After a build, GC trims the
# cache to CACHE_GB, and further (never below 2 GB) while the cache's
# filesystem has less than MIN_FREE_GB free. A build's own peak comes on top:
# docs/runbooks/gvisor.md "Builder disk".
CACHE_GB=${CACHE_GB:-10}
MIN_FREE_GB=${MIN_FREE_GB:-20}
# Bounds the loop filesystem the build cache lives on (td-9673e7): a fixed
# ext4 image at LOOP_IMG, mounted at LOOP_MNT, so one oversized build gets
# ENOSPC inside the loop fs instead of filling the host disk. 0 = old
# behaviour (cache in a plain docker volume, host-fs WARNING only).
# Unset (default): sized from the host's free space, capped at 50 GB.
BUILDER_DISK_GB=${BUILDER_DISK_GB:-}
LOOP_IMG=/var/lib/forge-tenant-buildkit.img
LOOP_MNT=/var/lib/forge-tenant-buildkit
IMAGE=moby/buildkit:v0.32.2
NETWORK=forge-tenant-build
VOLUME=forge-tenant-buildkit

die() { echo "install-tenant-builder: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must be run as root"
command -v docker >/dev/null || die "docker not found"
docker info --format '{{json .Runtimes}}' | grep -q '"runsc-netstack"' \
    || die "runsc-netstack is not registered with dockerd — run scripts/install-gvisor.sh first"
[[ $CACHE_GB =~ ^[0-9]+$ && $CACHE_GB -ge 2 ]] || die "CACHE_GB must be a whole number of GB, at least 2"
[[ $MIN_FREE_GB =~ ^[0-9]+$ ]] || die "MIN_FREE_GB must be a whole number of GB"
[[ -z $BUILDER_DISK_GB || $BUILDER_DISK_GB =~ ^[0-9]+$ ]] || die "BUILDER_DISK_GB must be a whole number of GB (0 disables it)"

free_gb=$(df --output=avail -BG /var/lib 2>/dev/null | tail -1 | tr -dc '0-9')
free_gb=${free_gb:-0}
if [[ -z $BUILDER_DISK_GB ]]; then
    BUILDER_DISK_GB=$(( free_gb / 4 ))
    [[ $BUILDER_DISK_GB -gt 50 ]] && BUILDER_DISK_GB=50
    [[ $BUILDER_DISK_GB -ge 15 ]] \
        || die "only ${free_gb}G free under /var/lib — too little for a 15G+ builder disk; free space, or set BUILDER_DISK_GB explicitly (0 disables the cap)"
fi

if [[ $BUILDER_DISK_GB -gt 0 ]]; then
    # Cache caps must leave room inside the loop fs, not just below
    # buildkitd's percentage-of-disk defaults.
    if (( CACHE_GB + MIN_FREE_GB > BUILDER_DISK_GB )); then
        MIN_FREE_GB=$(( BUILDER_DISK_GB / 5 ))
        [[ $MIN_FREE_GB -lt 1 ]] && MIN_FREE_GB=1
        CACHE_GB=$(( BUILDER_DISK_GB / 2 ))
        [[ $CACHE_GB -lt 2 ]] && CACHE_GB=2
        echo "install-tenant-builder: CACHE_GB/MIN_FREE_GB didn't fit BUILDER_DISK_GB=${BUILDER_DISK_GB}G — clamped to CACHE_GB=$CACHE_GB MIN_FREE_GB=$MIN_FREE_GB" >&2
    fi

    # Idempotent: an existing image/mount from a previous run is reused as-is
    # (no resize) so a re-run doesn't lose the cache or need a bigger disk.
    if [[ ! -f $LOOP_IMG ]]; then
        # fallocate reserves the whole size now, so keep 10G of headroom.
        (( free_gb >= BUILDER_DISK_GB + 10 )) \
            || die "BUILDER_DISK_GB=${BUILDER_DISK_GB}G needs ${BUILDER_DISK_GB}G + 10G headroom, only ${free_gb}G free under /var/lib"
        fallocate -l "${BUILDER_DISK_GB}G" "$LOOP_IMG"
        mkfs.ext4 -q "$LOOP_IMG"
    fi
    mkdir -p "$LOOP_MNT"
    grep -qF "$LOOP_IMG" /etc/fstab \
        || echo "$LOOP_IMG $LOOP_MNT ext4 loop,nofail 0 0" >> /etc/fstab
    mountpoint -q "$LOOP_MNT" || mount "$LOOP_MNT"
    mountpoint -q "$LOOP_MNT" || die "$LOOP_MNT did not mount — check /etc/fstab and $LOOP_IMG"

    if ! device=$(docker volume inspect --format '{{index .Options "device"}}' "$VOLUME" 2>/dev/null) \
        || [[ $device != "$LOOP_MNT" ]]; then
        # The old builder holds the volume; it is recreated below anyway.
        docker rm -f "$NAME" >/dev/null 2>&1 || true
        docker volume rm "$VOLUME" >/dev/null 2>&1 || true
        ! docker volume inspect "$VOLUME" >/dev/null 2>&1 \
            || die "could not remove volume $VOLUME to rebind it to $LOOP_MNT — check what still uses it (docker ps -a --filter volume=$VOLUME)"
        docker volume create --driver local --opt type=none --opt o=bind \
            --opt device="$LOOP_MNT" "$VOLUME" >/dev/null
    fi
else
    docker volume create "$VOLUME" >/dev/null
fi

# A cache on the filesystem Postgres and every container write to lets one
# tenant build fill it. With BUILDER_DISK_GB=0 this only warns — the
# fixed-size loop fs above (default on) is what actually bounds it.
cache_dir=$(docker volume inspect --format '{{index .Options "device"}}' "$VOLUME")
docker_root=$(docker info --format '{{.DockerRootDir}}')
cache_dev=$(stat -c %d "${cache_dir:-$docker_root}")
if [[ $cache_dev == "$(stat -c %d /)" || $cache_dev == "$(stat -c %d "$docker_root")" ]]; then
    echo "install-tenant-builder: WARNING: the build cache (${cache_dir:-volume $VOLUME in $docker_root}) shares a filesystem with the host root or Docker's data — a tenant build can fill it (a .NET SDK build peaked above 11.5 GB). Give it its own: docs/runbooks/gvisor.md \"Builder disk\"." >&2
fi

# ICC off: nothing else belongs on this network, and a build must not reach
# whatever someone attaches to it later.
if ! icc=$(docker network inspect "$NETWORK" --format '{{index .Options "com.docker.network.bridge.enable_icc"}}' 2>/dev/null); then
    docker network create -o com.docker.network.bridge.enable_icc=false "$NETWORK" >/dev/null
elif [[ "$icc" != false ]]; then
    die "network $NETWORK exists with inter-container traffic on — remove it (docker network rm $NETWORK, after docker rm -f $NAME) and re-run"
fi

# runsc-netstack keeps gVisor's own network stack (runsc, for tenant apps,
# passes through to the host kernel's) and so cannot reach Docker's embedded
# DNS (127.0.0.11) on a user-defined network: buildkitd gets plain upstream
# resolvers instead, which is all a build needs.
mkdir -p /etc/forge
resolv=/etc/forge/$NAME-resolv.conf
# shellcheck disable=SC2086 # one line per word of NAMESERVERS
printf 'nameserver %s\n' $NAMESERVERS > "$resolv"

# No --allow-insecure-entitlement: buildkitd itself then refuses
# RUN --network=host / --security=insecure from any client. Capabilities are
# the sandbox's own under gVisor, not the host's.
# Native snapshotter: buildkitd would pick overlayfs, but gVisor has no
# trusted.*/user.overlay.* xattrs, so any base image with an opaque whiteout
# (e.g. mcr.microsoft.com/dotnet/*) fails with "failed to convert whiteout
# file ... operation not supported". Native copies each step's parent
# instead: far more disk mid-build (CACHE_GB above).
docker rm -f "$NAME" >/dev/null 2>&1 || true
# A builder from before the native snapshotter kept its cache in
# runc-overlayfs/, which the native worker (runc-native/) never collects.
docker run --rm -v "$VOLUME:/cache" --entrypoint rm "$IMAGE" -rf /cache/runc-overlayfs
docker run -d --name "$NAME" \
    --runtime runsc-netstack --cap-add ALL \
    --restart unless-stopped \
    --network "$NETWORK" -v "$resolv:/etc/resolv.conf:ro" \
    --cpus "$CPUS" --memory "$MEMORY" --memory-swap "$MEMORY" --pids-limit "$PIDS" \
    -v "$VOLUME:/var/lib/buildkit" \
    "$IMAGE" --oci-max-parallelism "$MAX_PARALLELISM" --oci-worker-snapshotter=native \
    --oci-worker-gc-keepstorage "2000,$((MIN_FREE_GB * 1000)),$((CACHE_GB * 1000))" >/dev/null

for _ in $(seq 1 30); do
    docker exec "$NAME" buildctl debug workers >/dev/null 2>&1 && break
    sleep 1
done
docker exec "$NAME" buildctl debug workers >/dev/null 2>&1 \
    || die "buildkitd did not come up — docker logs $NAME"
runtime=$(docker inspect "$NAME" --format '{{.HostConfig.Runtime}}')
[[ "$runtime" == runsc-netstack ]] || die "$NAME runs under '$runtime', not runsc-netstack"
dmesg=$(docker exec "$NAME" dmesg 2>/dev/null) || dmesg="(no dmesg in $IMAGE; runtime check above passed)"
echo "${dmesg%%$'\n'*}"
disk_desc="cache in a plain volume, no size cap (BUILDER_DISK_GB=0)"
[[ $BUILDER_DISK_GB -gt 0 ]] && disk_desc="cache on a ${BUILDER_DISK_GB}G loop fs at $LOOP_MNT"
echo "install-tenant-builder: $NAME ready (runtime $runtime, $CPUS CPUs, $MEMORY, max $MAX_PARALLELISM parallel steps, cache ≤ ${CACHE_GB} GB, GC below ${MIN_FREE_GB} GB free, $disk_desc)"
echo "Enable: echo 'TENANT_BUILDKIT=$NAME' >> /opt/forge/.env && cd /opt/forge && docker compose up -d app"

#!/usr/bin/env bash
# Install gVisor's runsc and register it with Docker as the "runsc" runtime
# (tenant apps) and "runsc-netstack" (the tenant builder). default-runtime is
# left alone, so platform containers keep runc; Forge only puts tenant apps
# on runsc once TENANT_RUNTIME=runsc is set in .env.
# Idempotent. Run as root: sudo bash scripts/install-gvisor.sh
# Runbook (verify, enable, roll back): docs/runbooks/gvisor.md
set -euo pipefail

die() { echo "install-gvisor: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must be run as root"
command -v docker >/dev/null || die "docker not found"
command -v dockerd >/dev/null || die "dockerd not found (needed to validate daemon.json)"

# The operator's own daemon.json, kept once before anything here or the runsc
# package's postinst rewrites it (runsc install keeps only one daemon.json~,
# overwritten on every call). Never overwritten by a re-run.
daemon_json=/etc/docker/daemon.json
if [[ -f $daemon_json ]] && ! compgen -G "$daemon_json.pre-forge-gvisor.*" >/dev/null; then
    cp -a "$daemon_json" "$daemon_json.pre-forge-gvisor.$(date +%Y%m%d%H%M%S)"
fi

# The gVisor Authors' apt signing key (rsa4096, 2019-07-10, no expiry). A key
# rotation fails the install here rather than trusting whatever was served.
GVISOR_KEY_FPR=6F1DF85E3A71C24918E727D56FC6D554E32BD943

if ! command -v runsc >/dev/null; then
    keyring=/usr/share/keyrings/gvisor-archive-keyring.gpg
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    key=$(mktemp)
    trap 'rm -f "$key"' EXIT
    curl -fsSL https://gvisor.dev/archive.key -o "$key"
    fprs=$(gpg --show-keys --with-colons "$key" | awk -F: '/^pub/ {want=1; next} want && /^fpr/ {print $10; want=0}')
    [[ "$fprs" == "$GVISOR_KEY_FPR" ]] \
        || die "gVisor apt key fingerprint is '${fprs//$'\n'/ }', expected $GVISOR_KEY_FPR — refusing to trust it"
    gpg --dearmor --yes -o "$keyring" "$key"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://storage.googleapis.com/gvisor/releases release main" \
        > /etc/apt/sources.list.d/gvisor.list
    apt-get update -qq
    apt-get install -y -qq runsc
fi

runsc_args() { docker info --format '{{json (index .Runtimes "runsc").Args}}' 2>/dev/null || true; }
runtimes_ready() {
    [[ "$(runsc_args)" == '["--network=host"]' ]] \
        && docker info --format '{{json .Runtimes}}' | grep -q '"runsc-netstack"'
}

# Tenant containers sit on user-defined networks, whose DNS is Docker's
# embedded resolver on 127.0.0.11 in the container's netns. gVisor's own
# netstack has its own loopback and can't reach it (--reproduce-nat and
# --reproduce-nftables copy Docker's DNAT rule but not the socket behind it),
# so sibling service names don't resolve. --network=host makes runsc use the
# host kernel's network stack, still inside the container's own netns.
# Isolation cost and evidence: docs/runbooks/gvisor.md ("DNS and
# --network=host"). runsc-netstack (no args) is for containers that don't
# need Docker's DNS: the tenant builder and static-site builds.
#
# This script owns runtimes.runsc: it is rewritten to exactly that, replacing
# the argument-less entry the package's postinst writes (which never clobbers
# it back). Every other daemon.json key is kept, default-address-pools
# included. Nothing is rewritten when dockerd already has both.
if ! runtimes_ready; then
    echo "install-gvisor: runsc runtimeArgs were $(runsc_args), setting [\"--network=host\"] and adding runsc-netstack"
    rollback=$(mktemp)
    cp -a "$daemon_json" "$rollback" 2>/dev/null || rm -f "$rollback"
    runsc install -- --network=host
    runsc install --clobber=false --runtime=runsc-netstack
    if ! dockerd --validate --config-file "$daemon_json"; then
        if [[ -f $rollback ]]; then mv "$rollback" "$daemon_json"; else rm -f "$daemon_json"; fi
        die "the rewritten $daemon_json does not validate — restored the previous file, dockerd not reloaded"
    fi
    rm -f "$rollback"
    # runtimes is reloadable: SIGHUP, no restart, running containers untouched.
    # Changed runtimeArgs apply to containers created after the reload.
    systemctl reload docker
    sleep 2
fi
runtimes_ready || die "runsc (with --network=host) and runsc-netstack are not both registered with dockerd — check $daemon_json and journalctl -u docker"
default_runtime=$(docker info --format '{{.DefaultRuntime}}')
[[ $default_runtime == runc ]] \
    || die "dockerd's default runtime is '$default_runtime', not runc — platform containers must stay on runc"
dmesg=$(docker run --rm --runtime=runsc alpine:3.20 dmesg) \
    || die "runsc is registered but cannot start a container on this host — see docs/runbooks/gvisor.md"
echo "${dmesg%%$'\n'*}"

check=forge-gvisor-dnscheck
cleanup() { docker rm -f "$check-peer" >/dev/null 2>&1 || true; docker network rm "$check" >/dev/null 2>&1 || true; }
cleanup
docker network create "$check" >/dev/null
docker run -d --name "$check-peer" --network "$check" alpine:3.20 sleep 60 >/dev/null
if ! docker run --rm --runtime=runsc --network "$check" alpine:3.20 getent hosts "$check-peer" >/dev/null; then
    cleanup
    die "a runsc container cannot resolve a sibling by name on a user-defined network — see docs/runbooks/gvisor.md"
fi
cleanup
echo "install-gvisor: runsc ready, sibling DNS ok (default runtime still: $default_runtime)"

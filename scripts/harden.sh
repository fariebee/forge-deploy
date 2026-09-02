#!/usr/bin/env bash
set -euo pipefail

# PG Forge — Server hardening script for Ubuntu/Debian on Hetzner
# Run as root: sudo bash scripts/harden.sh
#
# What this does:
#   1. Updates system packages
#   2. Configures UFW firewall (SSH + HTTP/S + PgBouncer + Redis only)
#   3. Hardens SSH (disable password auth, disable root login)
#   4. Enables automatic security updates
#   5. Sets up fail2ban for SSH brute-force protection

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || err "This script must be run as root (sudo)"

# ---------------------------------------------------------------------------
# 1. System updates
# ---------------------------------------------------------------------------
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ufw fail2ban unattended-upgrades curl

# ---------------------------------------------------------------------------
# 2. UFW Firewall
# ---------------------------------------------------------------------------
log "Configuring UFW firewall..."
ufw --force reset

# Default: deny incoming, allow outgoing
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment "SSH"

# HTTP/HTTPS (Caddy)
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow 443/udp comment "HTTPS QUIC"

# PgBouncer — restrict to specific IPs by editing after setup
# For now, allow from anywhere (user should tighten this)
ufw allow 6432/tcp comment "PgBouncer"

# Redis — restrict to specific IPs by editing after setup
ufw allow 6379/tcp comment "Redis"

ufw --force enable
log "UFW enabled. Run 'ufw status verbose' to verify."
warn "Tighten PgBouncer/Redis rules to specific IPs:"
warn "  ufw delete allow 6432/tcp"
warn "  ufw allow from <your-app-ip> to any port 6432 proto tcp"
warn "  ufw delete allow 6379/tcp"
warn "  ufw allow from <your-app-ip> to any port 6379 proto tcp"

# ---------------------------------------------------------------------------
# 3. SSH hardening
# ---------------------------------------------------------------------------
log "Hardening SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Disable root login
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"

# Disable password auth (ensure you have SSH keys set up first!)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"

# Disable empty passwords
sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CONFIG"

# Limit auth attempts
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"

systemctl restart sshd
warn "SSH password auth is now DISABLED. Make sure your SSH key works before disconnecting!"

# ---------------------------------------------------------------------------
# 4. Automatic security updates
# ---------------------------------------------------------------------------
log "Enabling automatic security updates..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ---------------------------------------------------------------------------
# 5. Fail2ban
# ---------------------------------------------------------------------------
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
log "Server hardening complete."
log "Summary of open ports:"
ufw status numbered
echo ""
warn "Next steps:"
warn "  1. Verify SSH key access works before closing this session"
warn "  2. Restrict PgBouncer (6432) and Redis (6379) to your app server IPs"
warn "  3. Copy .env.example to .env and set production values"
warn "  4. Run: task deploy"

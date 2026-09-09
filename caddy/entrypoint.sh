#!/bin/sh
set -e

PROVIDER="${DNS_PROVIDER:-godaddy}"

if [ "$PROVIDER" = "cloudflare" ] && [ -n "$CLOUDFLARE_API_TOKEN" ]; then
    TLS_BLOCK="dns cloudflare $CLOUDFLARE_API_TOKEN"
elif [ -n "$GODADDY_API_TOKEN" ]; then
    TLS_BLOCK="dns godaddy $GODADDY_API_TOKEN"
else
    # No DNS provider token: DNS-01 is unavailable, so a wildcard cert for
    # *.{$DOMAIN} cannot be issued. Fall back to on-demand HTTP-01, which
    # mints a per-hostname cert on first request (gated by /api/tls-check).
    # Requires the concrete subdomains to resolve to this host — e.g. a
    # wildcard A record *.{$DOMAIN} at your DNS provider.
    TLS_BLOCK="on_demand"
fi

# The token lands in a sed replacement: escape its metacharacters (&, |, \)
# so a token containing one can't corrupt the rendered Caddyfile.
TLS_BLOCK_ESC=$(printf '%s' "$TLS_BLOCK" | sed 's/[\\&|]/\\&/g')
sed "s|##DNS_BLOCK##|$TLS_BLOCK_ESC|" /etc/caddy/Caddyfile > /tmp/Caddyfile

if [ "$TLS_BLOCK" = "on_demand" ]; then
    # No DNS token path. The Caddyfile's explicit single-label subdomain blocks
    # (registry, s3, search, monitor, ...) carry no tls directive, so Caddy
    # manages their certs and — because a *.{$DOMAIN} wildcard site also exists
    # — treats them as covered by the wildcard cert. But that wildcard cert
    # can't be obtained without DNS-01, so those hosts would otherwise serve NO
    # cert (TLS handshake fails) even though the wildcard's own subdomains work
    # on-demand. Inject on-demand HTTP-01 into each so they mint their own
    # per-host cert on first request, exactly like the wildcard block. With a
    # DNS token present these blocks are left bare and the wildcard DNS-01 cert
    # covers them.
    #
    # Matches any explicit "<label>.{$DOMAIN} {" header (not a hardcoded list,
    # so a subdomain block added later doesn't silently regress) while
    # excluding the wildcard (`*` isn't in the class, and it already has tls),
    # the apex ({$DOMAIN} — no label prefix), and :443.
    awk '
      { print }
      /^[a-z0-9-]+[.][{][$]DOMAIN[}][ \t]+[{][ \t\r]*$/ {
        print "\ttls {"
        print "\t\ton_demand"
        print "\t}"
      }
    ' /tmp/Caddyfile > /tmp/Caddyfile.tmp && mv /tmp/Caddyfile.tmp /tmp/Caddyfile
fi

exec caddy run --config /tmp/Caddyfile --adapter caddyfile

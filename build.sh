#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT="$ROOT/SSH-Hardening.sh"
CHECKSUM="$ROOT/SSH-Hardening.sh.sha256"
MANIFEST="$ROOT/SSH-Hardening.manifest.json"
MODE="${1:-build}"

PARTS=(
    src/lib/core.sh
    src/modules/ssh.sh
    src/modules/users.sh
    src/modules/fail2ban.sh
    src/modules/bbr.sh
    src/modules/firewall.sh
    src/modules/ssh-menu.sh
    src/modules/dns.sh
    src/modules/mirrors.sh
    src/modules/ip.sh
    src/modules/network.sh
    src/modules/caddy.sh
    src/modules/time.sh
    src/modules/swap.sh
    src/modules/stun.sh
    src/modules/toolbox.sh
    src/modules/software-reinstall.sh
    src/modules/docker.sh
    src/modules/self-update.sh
    src/modules/nft.sh
    src/modules/ddns.sh
    src/modules/main.sh
)

TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-build.XXXXXX")
trap 'rm -f "$TMP"' EXIT

for part in "${PARTS[@]}"; do
    [ -f "$ROOT/$part" ] || { echo "Missing source part: $part" >&2; exit 1; }
    # Git Bash may expose CRLF files in older Windows worktrees. Always publish Linux LF.
    LC_ALL=C sed 's/\r$//' "$ROOT/$part" >> "$TMP"
done

bash -n "$TMP"

if [ "$MODE" = "--check" ]; then
    cmp -s "$TMP" "$OUTPUT" || {
        echo "SSH-Hardening.sh is stale; run ./build.sh" >&2
        exit 1
    }
    echo "Generated script is up to date."
    exit 0
fi

mv "$TMP" "$OUTPUT"
trap - EXIT
chmod 755 "$OUTPUT"

if command -v sha256sum >/dev/null 2>&1; then
    HASH=$(sha256sum "$OUTPUT" | awk '{print $1}')
else
    HASH=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
fi
printf '%s  SSH-Hardening.sh\n' "$HASH" > "$CHECKSUM"
VERSION=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$OUTPUT" | head -1)
cat > "$MANIFEST" <<EOF
{
  "name": "SSH-Hardening",
  "version": "${VERSION:-unknown}",
  "file": "SSH-Hardening.sh",
  "sha256": "$HASH",
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "urls": [
    "https://raw.githubusercontent.com/TonyJsonson-8748/SSH-Hardening/refs/heads/main/SSH-Hardening.sh",
    "https://github.com/TonyJsonson-8748/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh",
    "https://cdn.jsdelivr.net/gh/TonyJsonson-8748/SSH-Hardening@main/SSH-Hardening.sh"
  ]
}
EOF

echo "Built SSH-Hardening.sh and refreshed SHA256/manifest."

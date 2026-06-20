#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT="$ROOT/SSH-Hardening.sh"
MODE="${1:-build}"

PARTS=(
    src/lib/core.sh
    src/modules/ssh.sh
    src/modules/fail2ban.sh
    src/modules/bbr.sh
    src/modules/firewall.sh
    src/modules/ssh-menu.sh
    src/modules/dns.sh
    src/modules/mirrors.sh
    src/modules/ip.sh
    src/modules/caddy.sh
    src/modules/time.sh
    src/modules/swap.sh
    src/modules/toolbox.sh
    src/modules/software-reinstall.sh
    src/modules/self-update.sh
    src/modules/nft.sh
    src/modules/ddns.sh
    src/modules/main.sh
)

TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-build.XXXXXX")
trap 'rm -f "$TMP"' EXIT

for part in "${PARTS[@]}"; do
    [ -f "$ROOT/$part" ] || { echo "Missing source part: $part" >&2; exit 1; }
    cat "$ROOT/$part" >> "$TMP"
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
    (cd "$ROOT" && sha256sum SSH-Hardening.sh > SSH-Hardening.sh.sha256)
else
    HASH=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
    printf '%s  SSH-Hardening.sh\n' "$HASH" > "$ROOT/SSH-Hardening.sh.sha256"
fi

echo "Built SSH-Hardening.sh and refreshed SHA256."

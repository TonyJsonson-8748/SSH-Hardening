#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"

confirm_change_preview "test" "reject" <<< "n" >/dev/null 2>&1 && { echo "Preview accepted rejection" >&2; exit 1; }
confirm_change_preview "test" "accept" <<< "y" >/dev/null 2>&1 || { echo "Preview rejected confirmation" >&2; exit 1; }

# Reinstall must reject container environments and malformed downloads.
systemd-detect-virt() { echo lxc; }
reinstall_is_container || { echo "Container detection did not reject LXC" >&2; exit 1; }
curl() {
    local OUT="" PREV="" arg
    for arg in "$@"; do [ "$PREV" = "-o" ] && OUT="$arg"; PREV="$arg"; done
    printf 'if broken\n' > "$OUT"
}
reinstall_download_engine "$TMP/broken-reinstall.sh" >/dev/null 2>&1 && {
    echo "Malformed reinstall engine passed validation" >&2
    exit 1
}

# The Docker installer must reject malformed downloaded scripts.
docker_download_installer "$TMP/broken-docker.sh" >/dev/null 2>&1 && {
    echo "Malformed Docker installer passed validation" >&2
    exit 1
}
docker() { [ "$1" = "inspect" ] && printf '<no value>\n'; }
[ -z "$(docker_inspect_label fake-id com.docker.compose.project)" ] || {
    echo "Missing Compose label was treated as a real value" >&2
    exit 1
}

# A broken sshd validation must restore the previous configuration.
SSHD_CONFIG="$TMP/sshd_config"
LAST_SSHD_BACKUP="$TMP/sshd_config.bak"
printf 'Port 2222\n' > "$SSHD_CONFIG"
printf 'Port 22\n' > "$LAST_SSHD_BACKUP"
sshd() { return 1; }
restart_ssh() { return 0; }
apply_and_restart >/dev/null 2>&1 && { echo "Expected SSH validation failure" >&2; exit 1; }
grep -qx 'Port 22' "$SSHD_CONFIG" || { echo "SSH rollback did not restore backup" >&2; exit 1; }

# A tar failure must not leave a partial backup archive.
VPS_DATA_DIR="$TMP/data"
VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
export VPS_AUDIT_LOG="$TMP/audit.log"
config_backup_paths() { printf 'tmp/does-not-exist-vps-tools-test\n'; }
config_backup_create injected_failure true >/dev/null 2>&1 && { echo "Expected backup failure" >&2; exit 1; }
if find "$VPS_BACKUP_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q .; then
    echo "Partial backup archive was left behind" >&2
    exit 1
fi

# Retention must remove old archives after the configured limit.
mkdir -p "$TMP/source"
printf 'config\n' > "$TMP/source/value"
config_backup_paths() { printf '%s/source/value\n' "${TMP#/}"; }
export VPS_BACKUP_KEEP=2
config_backup_create one true >/dev/null
config_backup_create two true >/dev/null
config_backup_create three true >/dev/null
COUNT=$(find "$VPS_BACKUP_DIR" -type f -name '*.tar.gz' | wc -l | tr -d ' ')
[ "$COUNT" -eq 2 ] || { echo "Backup retention kept $COUNT archives instead of 2" >&2; exit 1; }

# The real updater must reject a mismatched checksum without replacing the local script.
LOCAL_SCRIPT="$TMP/local-script"
export SCRIPT_URL="mock://script"
CHECKSUM_URL="mock://checksum"
printf 'original\n' > "$LOCAL_SCRIPT"
curl() {
    local URL="" OUT="" PREV=""
    for arg in "$@"; do
        [ "$PREV" = "-o" ] && OUT="$arg"
        case "$arg" in mock://*) URL="$arg" ;; esac
        PREV="$arg"
    done
    if [ "$URL" = "$CHECKSUM_URL" ]; then
        printf '%064d  SSH-Hardening.sh\n' 0 > "$OUT"
    else
        cp "$ROOT/SSH-Hardening.sh" "$OUT"
    fi
}
self_update >/dev/null 2>&1
grep -qx 'original' "$LOCAL_SCRIPT" || { echo "Updater replaced script after checksum mismatch" >&2; exit 1; }

echo "Fault injection tests passed."

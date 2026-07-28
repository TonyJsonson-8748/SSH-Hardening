#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

VPS_DATA_DIR="$TMP/data"
LOCAL_BIN_DIR="$TMP/bin"
LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
# shellcheck disable=SC2034  # read by self-update.sh/main.sh after the dynamic `source` below
UPDATE_NOTICE_FILE="$VPS_DATA_DIR/update_available"
NFT_DDNS_SERVICE_FILE="$TMP/systemd/nftpf-ddns.service"
NFT_DDNS_TIMER_FILE="$TMP/systemd/nftpf-ddns.timer"
mkdir -p "$VPS_DATA_DIR" "$LOCAL_BIN_DIR" "$TMP/systemd"

# shellcheck source=../src/modules/self-update.sh
source "$ROOT/src/modules/self-update.sh"
# shellcheck source=../src/modules/nft.sh
source "$ROOT/src/modules/nft.sh"

INFO_LOG="$TMP/info.log"
ERROR_LOG="$TMP/error.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"
print_header() { :; }
info() { printf '%s\n' "$*" >> "$INFO_LOG"; }
warn() { :; }
error() { printf '%s\n' "$*" >> "$ERROR_LOG"; }
audit_action() { :; }
systemd_available() { return 0; }

# A first-run "skip install" must still be recoverable from the currently
# executing trusted script when a scheduler needs a persistent runner.
CURRENT_SOURCE="$ROOT/SSH-Hardening.sh"
self_resolve_script_source() {
    printf '%s\n' "$CURRENT_SOURCE"
}
self_ensure_local_runner '--nft-refresh-ddns)' \
    || { echo "Local runner was not installed from the trusted current script" >&2; exit 1; }
cmp -s "$CURRENT_SOURCE" "$LOCAL_SCRIPT" \
    || { echo "Local runner content differs from the trusted current script" >&2; exit 1; }
[ -x "$LOCAL_SCRIPT" ] || { echo "Local runner is not executable" >&2; exit 1; }

for interval in 10s 59s 1m 1440m 1h 24h 86400s 00010s; do
    nft_ddns_interval_valid "$interval" \
        || { echo "Valid NFT DDNS interval was rejected: $interval" >&2; exit 1; }
done
for interval in 0s 9s 0m 25h 1441m 86401s 1ms 5 M5 '5 m' garbage; do
    if nft_ddns_interval_valid "$interval"; then
        echo "Invalid NFT DDNS interval was accepted: $interval" >&2
        exit 1
    fi
done

SYSTEMCTL_MODE=success
systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "${1:-}" in
        daemon-reload) [ "$SYSTEMCTL_MODE" != fail_reload ] ;;
        enable)
            if [ "${2:-}" = --now ]; then
                [ "$SYSTEMCTL_MODE" != fail_enable ] \
                    && [ "$SYSTEMCTL_MODE" != fail_enable_active ] \
                    && [ "$SYSTEMCTL_MODE" != fail_restore_state ]
            else
                [ "$SYSTEMCTL_MODE" != fail_restore_state ]
            fi
            ;;
        start) [ "$SYSTEMCTL_MODE" != fail_restore_state ] ;;
        is-active)
            [ "$SYSTEMCTL_MODE" = success ] \
                || [ "$SYSTEMCTL_MODE" = fail_enable_active ] \
                || [ "$SYSTEMCTL_MODE" = fail_restore_state ]
            ;;
        is-enabled)
            [ "$SYSTEMCTL_MODE" = success ] \
                || [ "$SYSTEMCTL_MODE" = fail_enable_active ] \
                || [ "$SYSTEMCTL_MODE" = fail_restore_state ]
            ;;
        *) return 0 ;;
    esac
}

nft_ddns_timer_enable <<< "10s" >/dev/null \
    || { echo "NFT DDNS timer enablement failed" >&2; exit 1; }
grep -Fq "ExecStart=$LOCAL_SCRIPT --nft-refresh-ddns" "$NFT_DDNS_SERVICE_FILE" \
    || { echo "NFT DDNS service points at the wrong runner" >&2; exit 1; }
grep -qx 'OnBootSec=10s' "$NFT_DDNS_TIMER_FILE" \
    || { echo "NFT DDNS timer boot interval is wrong" >&2; exit 1; }
grep -qx 'OnUnitActiveSec=10s' "$NFT_DDNS_TIMER_FILE" \
    || { echo "NFT DDNS timer repeat interval is wrong" >&2; exit 1; }
grep -Fq 'enable --now nftpf-ddns.timer' "$SYSTEMCTL_LOG" \
    || { echo "NFT DDNS timer was not enabled" >&2; exit 1; }
grep -Fq 'DDNS 自动刷新已启用' "$INFO_LOG" \
    || { echo "NFT DDNS success was not reported after activation" >&2; exit 1; }

# Failed activation must restore existing units and never emit a success.
printf 'old service\n' > "$NFT_DDNS_SERVICE_FILE"
printf 'old timer\n' > "$NFT_DDNS_TIMER_FILE"
: > "$INFO_LOG"
SYSTEMCTL_MODE=fail_enable
if nft_ddns_timer_enable <<< "5m" >/dev/null 2>&1; then
    echo "NFT DDNS timer enablement hid a systemctl failure" >&2
    exit 1
fi
grep -qx 'old service' "$NFT_DDNS_SERVICE_FILE" \
    || { echo "Failed NFT enablement did not restore the old service" >&2; exit 1; }
grep -qx 'old timer' "$NFT_DDNS_TIMER_FILE" \
    || { echo "Failed NFT enablement did not restore the old timer" >&2; exit 1; }
if grep -Fq 'DDNS 自动刷新已启用' "$INFO_LOG"; then
    echo "Failed NFT enablement reported success" >&2
    exit 1
fi

# Previously enabled and active timers must be re-enabled and restarted after
# a failed replacement.
: > "$SYSTEMCTL_LOG"
SYSTEMCTL_MODE=fail_enable_active
if nft_ddns_timer_enable <<< "5m" >/dev/null 2>&1; then
    echo "NFT DDNS timer active-state rollback test unexpectedly succeeded" >&2
    exit 1
fi
grep -qx 'enable nftpf-ddns.timer' "$SYSTEMCTL_LOG" \
    || { echo "Failed NFT replacement did not restore enabled state" >&2; exit 1; }
grep -qx 'start nftpf-ddns.timer' "$SYSTEMCTL_LOG" \
    || { echo "Failed NFT replacement did not restore active state" >&2; exit 1; }
grep -qx 'old service' "$NFT_DDNS_SERVICE_FILE" \
    || { echo "Active-state rollback did not restore the old service" >&2; exit 1; }
grep -qx 'old timer' "$NFT_DDNS_TIMER_FILE" \
    || { echo "Active-state rollback did not restore the old timer" >&2; exit 1; }

# A daemon-reload failure follows the same rollback path.
SYSTEMCTL_MODE=fail_reload
: > "$ERROR_LOG"
if nft_ddns_timer_enable <<< "1h" >/dev/null 2>&1; then
    echo "NFT DDNS timer enablement hid a daemon-reload failure" >&2
    exit 1
fi
grep -qx 'old service' "$NFT_DDNS_SERVICE_FILE" \
    || { echo "Daemon-reload failure did not restore the old service" >&2; exit 1; }
grep -qx 'old timer' "$NFT_DDNS_TIMER_FILE" \
    || { echo "Daemon-reload failure did not restore the old timer" >&2; exit 1; }
grep -Fq '回滚不完整' "$ERROR_LOG" \
    || { echo "Daemon-reload rollback failure was not reported as incomplete" >&2; exit 1; }

# Existing unit symlinks must be snapshotted and restored as symlinks, not
# silently converted into regular files.
mkdir -p "$TMP/original-units"
printf 'linked service\n' > "$TMP/original-units/nftpf-ddns.service"
printf 'linked timer\n' > "$TMP/original-units/nftpf-ddns.timer"
rm -f "$NFT_DDNS_SERVICE_FILE" "$NFT_DDNS_TIMER_FILE"
ln -s "$TMP/original-units/nftpf-ddns.service" "$NFT_DDNS_SERVICE_FILE"
ln -s "$TMP/original-units/nftpf-ddns.timer" "$NFT_DDNS_TIMER_FILE"
if [ -L "$NFT_DDNS_SERVICE_FILE" ] && [ -L "$NFT_DDNS_TIMER_FILE" ]; then
    SERVICE_LINK=$(readlink "$NFT_DDNS_SERVICE_FILE")
    TIMER_LINK=$(readlink "$NFT_DDNS_TIMER_FILE")
    SYSTEMCTL_MODE=fail_enable
    if nft_ddns_timer_enable <<< "5m" >/dev/null 2>&1; then
        echo "NFT DDNS symlink rollback test unexpectedly succeeded" >&2
        exit 1
    fi
    [ -L "$NFT_DDNS_SERVICE_FILE" ] \
        && [ "$(readlink "$NFT_DDNS_SERVICE_FILE")" = "$SERVICE_LINK" ] \
        || { echo "Failed NFT replacement did not preserve the service symlink" >&2; exit 1; }
    [ -L "$NFT_DDNS_TIMER_FILE" ] \
        && [ "$(readlink "$NFT_DDNS_TIMER_FILE")" = "$TIMER_LINK" ] \
        || { echo "Failed NFT replacement did not preserve the timer symlink" >&2; exit 1; }
else
    rm -f "$NFT_DDNS_SERVICE_FILE" "$NFT_DDNS_TIMER_FILE"
    printf 'old service\n' > "$NFT_DDNS_SERVICE_FILE"
    printf 'old timer\n' > "$NFT_DDNS_TIMER_FILE"
fi

# A failure while restoring the previous enabled/active state must propagate
# and explicitly tell the operator that rollback is incomplete.
SYSTEMCTL_MODE=fail_restore_state
: > "$ERROR_LOG"
if nft_ddns_timer_enable <<< "5m" >/dev/null 2>&1; then
    echo "NFT DDNS timer hid a state-restoration failure" >&2
    exit 1
fi
grep -Fq '回滚不完整' "$ERROR_LOG" \
    || { echo "NFT state-restoration failure was not reported as incomplete" >&2; exit 1; }

# The low-level unit restore helper must aggregate failures instead of hiding
# them behind best-effort cleanup.
if nft_ddns_units_restore regular "$TMP/missing-service-backup" \
    absent "" >/dev/null 2>&1; then
    echo "NFT unit restore helper hid a missing backup failure" >&2
    exit 1
fi
rm -f "$NFT_DDNS_SERVICE_FILE" "$NFT_DDNS_TIMER_FILE"
printf 'old service\n' > "$NFT_DDNS_SERVICE_FILE"
printf 'old timer\n' > "$NFT_DDNS_TIMER_FILE"

# Invalid input must fail before replacing the existing units.
SYSTEMCTL_MODE=success
if nft_ddns_timer_enable <<< "1ms" >/dev/null 2>&1; then
    echo "NFT DDNS timer accepted an invalid interval through the UI path" >&2
    exit 1
fi
grep -qx 'old service' "$NFT_DDNS_SERVICE_FILE" \
    || { echo "Invalid interval changed the existing service" >&2; exit 1; }
grep -qx 'old timer' "$NFT_DDNS_TIMER_FILE" \
    || { echo "Invalid interval changed the existing timer" >&2; exit 1; }

if find "$TMP/systemd" -maxdepth 1 -type f \
    \( -name '*.tmp.*' -o -name '*.backup.*' \) | grep -q .; then
    echo "NFT DDNS scheduler left temporary unit files behind" >&2
    exit 1
fi

echo "Scheduler regression tests passed."

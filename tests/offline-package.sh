#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$ROOT/build-offline-package.sh" --output "$TMP/out" >/dev/null
OFFICIAL_ARCHIVE=$(find "$TMP/out" -maxdepth 1 -type f -name 'vps-tools-offline-V*.tar.gz' | head -1)
[ -n "$OFFICIAL_ARCHIVE" ] || { echo "Official offline archive missing" >&2; exit 1; }

(
    cd "$TMP/out"
    sha256sum -c vps-tools-offline-*.tar.gz.sha256
)

tar -xzf "$TMP/out"/vps-tools-offline-*.tar.gz -C "$TMP"
PACKAGE_DIR=$(find "$TMP" -maxdepth 1 -type d -name 'vps-tools-offline-V*' | head -1)
[ -n "$PACKAGE_DIR" ] || { echo "Offline package directory missing" >&2; exit 1; }

bash "$PACKAGE_DIR/install.sh" --bin-dir "$TMP/bin" >/dev/null
[ -x "$TMP/bin/vps-tools" ] || { echo "Offline installer did not install the script" >&2; exit 1; }
shortcut_matches() {
    local SHORTCUT="$1"
    if [ -L "$SHORTCUT" ]; then
        [ "$(readlink -f "$SHORTCUT")" = "$(readlink -f "$TMP/bin/vps-tools")" ]
    else
        # Git Bash may emulate symlinks by copying files on Windows.
        cmp -s "$SHORTCUT" "$TMP/bin/vps-tools"
    fi
}
shortcut_matches "$TMP/bin/v" || { echo "Offline installer did not create v shortcut" >&2; exit 1; }
shortcut_matches "$TMP/bin/V" || { echo "Offline installer did not create V shortcut" >&2; exit 1; }
"$TMP/bin/vps-tools" --help >/dev/null

# The in-app importer must accept both the official nested archive and its own
# flat archive format, while enforcing an unambiguous, verified VPS Tools script.
VPS_DATA_DIR="$TMP/self-data"
LOCAL_BIN_DIR="$TMP/self-import-bin"
LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
UPDATE_NOTICE_FILE="$VPS_DATA_DIR/update_available"
# shellcheck source=../src/modules/self-update.sh
source "$ROOT/src/modules/self-update.sh"
print_header() { :; }
info() { :; }
warn() { :; }
error() { :; }
audit_action() { :; }

MODE_ENFORCEMENT_SUPPORTED=yes
mkdir -p "$TMP/mode-probe"
chmod 700 "$TMP/mode-probe"
[ "$(stat -c '%a' "$TMP/mode-probe")" = 700 ] || MODE_ENFORCEMENT_SUPPORTED=no

self_offline_bundle_install "$OFFICIAL_ARCHIVE" >/dev/null \
    || { echo "In-app importer rejected the official nested package" >&2; exit 1; }
cmp -s "$LOCAL_SCRIPT" "$PACKAGE_DIR/SSH-Hardening.sh" \
    || { echo "In-app importer installed the wrong official script" >&2; exit 1; }
self_script_valid "$LOCAL_SCRIPT" \
    || { echo "In-app importer installed an invalid official script" >&2; exit 1; }

LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
FLAT_BUNDLE=$(self_offline_bundle_create | tail -1)
[ -f "$FLAT_BUNDLE" ] || { echo "Flat offline bundle was not created" >&2; exit 1; }
LOCAL_BIN_DIR="$TMP/flat-import-bin"
LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
self_offline_bundle_install "$FLAT_BUNDLE" >/dev/null \
    || { echo "In-app importer rejected its flat package" >&2; exit 1; }
self_script_valid "$LOCAL_SCRIPT" \
    || { echo "Flat package installed an invalid script" >&2; exit 1; }

(
    LOCAL_SCRIPT="$TMP/invalid-installed-script"
    printf '#!/bin/bash\necho truncated\n' > "$LOCAL_SCRIPT"
    if self_offline_bundle_create >/dev/null 2>&1; then
        echo "Flat bundle creator accepted an invalid source script" >&2
        exit 1
    fi
)
(
    LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
    VPS_DATA_DIR="$TMP/checksum-create-failure"
    sha256sum() { return 1; }
    if self_offline_bundle_create >/dev/null 2>&1; then
        echo "Flat bundle creator hid checksum generation failure" >&2
        exit 1
    fi
    ! find "$VPS_DATA_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q . \
        || { echo "Checksum generation failure left a reported bundle" >&2; exit 1; }
)
(
    LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
    VPS_DATA_DIR="$TMP/post-copy-create-failure"
    cp() {
        command cp "$@"
        case "${!#}" in
            */SSH-Hardening.sh) printf '\nif broken\n' >> "${!#}" ;;
        esac
    }
    if self_offline_bundle_create >/dev/null 2>&1; then
        echo "Flat bundle creator did not validate its staged copy" >&2
        exit 1
    fi
    ! find "$VPS_DATA_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q . \
        || { echo "Invalid staged copy left a reported bundle" >&2; exit 1; }
)

mkdir -p "$TMP/missing-checksum"
cp "$ROOT/SSH-Hardening.sh" "$TMP/missing-checksum/SSH-Hardening.sh"
tar -czf "$TMP/missing-checksum.tar.gz" -C "$TMP/missing-checksum" SSH-Hardening.sh
if self_offline_bundle_install "$TMP/missing-checksum.tar.gz" >/dev/null 2>&1; then
    echo "In-app importer accepted an archive without an inner checksum" >&2
    exit 1
fi

mkdir -p "$TMP/ambiguous"
cp "$ROOT/SSH-Hardening.sh" "$TMP/ambiguous/SSH-Hardening.sh"
cp "$ROOT/SSH-Hardening.sh" "$TMP/ambiguous/vps-tools.sh"
(
    cd "$TMP/ambiguous"
    sha256sum SSH-Hardening.sh > SSH-Hardening.sh.sha256
    sha256sum vps-tools.sh > vps-tools.sh.sha256
)
tar -czf "$TMP/ambiguous.tar.gz" -C "$TMP/ambiguous" \
    SSH-Hardening.sh SSH-Hardening.sh.sha256 vps-tools.sh vps-tools.sh.sha256
if self_offline_bundle_install "$TMP/ambiguous.tar.gz" >/dev/null 2>&1; then
    echo "In-app importer accepted multiple script candidates" >&2
    exit 1
fi

mkdir -p "$TMP/bad-checksum"
cp "$ROOT/SSH-Hardening.sh" "$TMP/bad-checksum/SSH-Hardening.sh"
printf '%064d  SSH-Hardening.sh\n' 0 > "$TMP/bad-checksum/SSH-Hardening.sh.sha256"
tar -czf "$TMP/bad-checksum.tar.gz" -C "$TMP/bad-checksum" \
    SSH-Hardening.sh SSH-Hardening.sh.sha256
if self_offline_bundle_install "$TMP/bad-checksum.tar.gz" >/dev/null 2>&1; then
    echo "In-app importer accepted a mismatched inner checksum" >&2
    exit 1
fi

mkdir -p "$TMP/traversal"
cp "$ROOT/SSH-Hardening.sh" "$TMP/traversal/SSH-Hardening.sh"
(
    cd "$TMP/traversal"
    sha256sum SSH-Hardening.sh > SSH-Hardening.sh.sha256
)
tar -czf "$TMP/traversal.tar.gz" --transform='s|^|../|' \
    -C "$TMP/traversal" SSH-Hardening.sh SSH-Hardening.sh.sha256
if self_offline_bundle_install "$TMP/traversal.tar.gz" >/dev/null 2>&1; then
    echo "In-app importer accepted a parent-directory archive member" >&2
    exit 1
fi

printf '#!/bin/bash\necho not-vps-tools\n' > "$TMP/not-vps-tools.sh"
if self_offline_bundle_install "$TMP/not-vps-tools.sh" >/dev/null 2>&1; then
    echo "In-app importer accepted a script without the VPS Tools version marker" >&2
    exit 1
fi
(
    SELF_OFFLINE_MAX_COMPRESSED_BYTES=16
    LOCAL_BIN_DIR="$TMP/oversized-direct-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    if self_offline_bundle_install "$ROOT/SSH-Hardening.sh" >/dev/null 2>&1; then
        echo "In-app importer accepted a package above the compressed-size limit" >&2
        exit 1
    fi
)
(
    SELF_OFFLINE_MAX_RAW_BYTES=1024
    LOCAL_BIN_DIR="$TMP/oversized-raw-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    if self_offline_bundle_install "$OFFICIAL_ARCHIVE" >/dev/null 2>&1; then
        echo "In-app importer accepted an archive above the raw-size limit" >&2
        exit 1
    fi
)

# Direct scripts and archives must be copied into a private staging directory
# before any validator observes them.
(
    DIRECT_SOURCE="$TMP/direct-source.sh"
    cp "$ROOT/SSH-Hardening.sh" "$DIRECT_SOURCE"
    LOCAL_BIN_DIR="$TMP/direct-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    self_script_valid() {
        [ "$1" != "$DIRECT_SOURCE" ] \
            || { echo "Direct source was validated without private staging" >&2; return 1; }
        case "$1" in
            */package.sh)
                if [ "$MODE_ENFORCEMENT_SUPPORTED" = yes ]; then
                    [ "$(stat -c '%a' "$(dirname "$1")")" = 700 ] \
                        || { echo "Direct script staging directory is not private" >&2; return 1; }
                    [ "$(stat -c '%a' "$1")" = 600 ] \
                        || { echo "Direct script staging copy is not private" >&2; return 1; }
                fi
                ;;
        esac
        return 0
    }
    self_offline_bundle_install "$DIRECT_SOURCE" >/dev/null \
        || { echo "Privately staged direct script was not installed" >&2; exit 1; }
)

(
    LOCAL_BIN_DIR="$TMP/archive-stage-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    self_offline_archive_validate() {
        [ "$1" != "$OFFICIAL_ARCHIVE" ] \
            || { echo "Archive source was validated without private staging" >&2; return 1; }
        if [ "$MODE_ENFORCEMENT_SUPPORTED" = yes ]; then
            [ "$(stat -c '%a' "$(dirname "$1")")" = 700 ] \
                || { echo "Archive staging directory is not private" >&2; return 1; }
            [ "$(stat -c '%a' "$1")" = 600 ] \
                || { echo "Archive staging copy is not private" >&2; return 1; }
        fi
        return 0
    }
    self_offline_bundle_install "$OFFICIAL_ARCHIVE" >/dev/null \
        || { echo "Privately staged archive was not installed" >&2; exit 1; }
)

# Archive root metadata and non-file/non-directory members are rejected before
# extraction, including in the BusyBox-compatible extraction path.
mkdir -p "$TMP/root-metadata"
cp "$ROOT/SSH-Hardening.sh" "$TMP/root-metadata/SSH-Hardening.sh"
(
    cd "$TMP/root-metadata"
    sha256sum SSH-Hardening.sh > SSH-Hardening.sh.sha256
)
tar -czf "$TMP/root-metadata.tar.gz" -C "$TMP/root-metadata" .
if self_offline_bundle_install "$TMP/root-metadata.tar.gz" >/dev/null 2>&1; then
    echo "In-app importer accepted archive-root metadata" >&2
    exit 1
fi

mkdir -p "$TMP/symlink-member"
if ln -s SSH-Hardening.sh "$TMP/symlink-member/vps-tools.sh" 2>/dev/null \
    && [ -L "$TMP/symlink-member/vps-tools.sh" ]; then
    tar -czf "$TMP/symlink-member.tar.gz" -C "$TMP/symlink-member" vps-tools.sh
    if self_offline_bundle_install "$TMP/symlink-member.tar.gz" >/dev/null 2>&1; then
        echo "In-app importer accepted a symlink archive member" >&2
        exit 1
    fi
fi
mkdir -p "$TMP/hardlink-member"
cp "$ROOT/SSH-Hardening.sh" "$TMP/hardlink-member/SSH-Hardening.sh"
(
    cd "$TMP/hardlink-member"
    sha256sum SSH-Hardening.sh > SSH-Hardening.sh.sha256
)
if ln "$TMP/hardlink-member/SSH-Hardening.sh" "$TMP/hardlink-member/extra-copy" 2>/dev/null; then
    tar -czf "$TMP/hardlink-member.tar.gz" -C "$TMP/hardlink-member" \
        SSH-Hardening.sh SSH-Hardening.sh.sha256 extra-copy
    if self_offline_bundle_install "$TMP/hardlink-member.tar.gz" >/dev/null 2>&1; then
        echo "In-app importer accepted a hardlink archive member" >&2
        exit 1
    fi
fi

# LOCAL_SCRIPT is a fixed managed path. Existing symlinks/non-regular targets
# and writable non-sticky parent directories must not be replaced.
(
    LOCAL_BIN_DIR="$TMP/wrong-target-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/not-vps-tools"
    mkdir -p "$LOCAL_BIN_DIR"
    if self_offline_bundle_install "$ROOT/SSH-Hardening.sh" >/dev/null 2>&1; then
        echo "In-app importer accepted a non-canonical LOCAL_SCRIPT" >&2
        exit 1
    fi
)
(
    LOCAL_BIN_DIR="$TMP/symlink-target-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    mkdir -p "$LOCAL_BIN_DIR"
    printf 'do not replace\n' > "$TMP/symlink-target"
    if ln -s "$TMP/symlink-target" "$LOCAL_SCRIPT" 2>/dev/null \
        && [ -L "$LOCAL_SCRIPT" ]; then
        if self_offline_bundle_install "$ROOT/SSH-Hardening.sh" >/dev/null 2>&1; then
            echo "In-app importer replaced a symlink LOCAL_SCRIPT" >&2
            exit 1
        fi
        [ -L "$LOCAL_SCRIPT" ] && grep -qx 'do not replace' "$TMP/symlink-target" \
            || { echo "Symlink LOCAL_SCRIPT was changed" >&2; exit 1; }
    fi
)
(
    LOCAL_BIN_DIR="$TMP/nonregular-target-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    mkdir -p "$LOCAL_SCRIPT"
    if self_offline_bundle_install "$ROOT/SSH-Hardening.sh" >/dev/null 2>&1; then
        echo "In-app importer replaced a non-regular LOCAL_SCRIPT" >&2
        exit 1
    fi
    [ -d "$LOCAL_SCRIPT" ] || { echo "Non-regular LOCAL_SCRIPT was changed" >&2; exit 1; }
)
(
    LOCAL_BIN_DIR="$TMP/unsafe-parent-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    mkdir -p "$LOCAL_BIN_DIR"
    chmod 0777 "$LOCAL_BIN_DIR"
    if [ "$MODE_ENFORCEMENT_SUPPORTED" = yes ]; then
        if self_offline_bundle_install "$ROOT/SSH-Hardening.sh" >/dev/null 2>&1; then
            echo "In-app importer accepted an unsafe writable parent directory" >&2
            exit 1
        fi
    fi
)

# If the post-replacement validation fails, the previous regular target must
# be restored. A failed restoration is surfaced with a distinct return code.
(
    LOCAL_BIN_DIR="$TMP/post-validate-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    mkdir -p "$LOCAL_BIN_DIR"
    printf 'previous target\n' > "$LOCAL_SCRIPT"
    self_script_valid() {
        if [ "$1" = "$LOCAL_SCRIPT" ]; then
            return 1
        fi
        return 0
    }
    if self_offline_bundle_install "$ROOT/SSH-Hardening.sh" >/dev/null 2>&1; then
        echo "In-app importer ignored post-replacement validation failure" >&2
        exit 1
    fi
    grep -qx 'previous target' "$LOCAL_SCRIPT" \
        || { echo "Post-validation failure did not restore the previous target" >&2; exit 1; }
)
(
    LOCAL_BIN_DIR="$TMP/failed-restore-bin"
    LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
    mkdir -p "$LOCAL_BIN_DIR"
    printf 'previous target\n' > "$LOCAL_SCRIPT"
    self_runner_file_valid() { return 1; }
    self_local_runner_restore() { return 1; }
    RC=0
    self_local_runner_install "$ROOT/SSH-Hardening.sh" 700 || RC=$?
    [ "$RC" -eq 2 ] \
        || { echo "Incomplete local-runner rollback was not propagated" >&2; exit 1; }
)

printf '# tampered\n' >> "$PACKAGE_DIR/SSH-Hardening.sh"
if bash "$PACKAGE_DIR/install.sh" --bin-dir "$TMP/tampered-bin" >/dev/null 2>&1; then
    echo "Offline installer accepted a tampered script" >&2
    exit 1
fi

echo "Offline package test passed."

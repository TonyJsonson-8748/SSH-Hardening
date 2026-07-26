#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
USER_MOUNTINFO_FILE="$TMP/mountinfo"
printf '1 0 0:1 / / rw - rootfs rootfs rw\n' > "$USER_MOUNTINFO_FILE"
export USER_MOUNTINFO_FILE

# shellcheck source=/dev/null
source "$ROOT/src/modules/users.sh"
# shellcheck source=/dev/null
source "$ROOT/src/modules/swap.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

error() { :; }
warn() { :; }
info() { :; }

assert_home_rejected() {
    local PATH_UNDER_TEST="$1"
    ! user_home_safe_to_remove "$PATH_UNDER_TEST" \
        || fail "unsafe home was accepted: $PATH_UNDER_TEST"
}

for PROTECTED_HOME in / /home /home/ /home// /etc /etc/ //; do
    assert_home_rejected "$PROTECTED_HOME"
done

SAFE_HOME="$TMP/homes/alice"
mkdir -p "$SAFE_HOME"
user_home_safe_to_remove "$SAFE_HOME" || fail "normal home was rejected"
printf '%s\n' \
    '1 0 0:1 / / rw - rootfs rootfs rw' \
    "2 1 0:2 / $SAFE_HOME rw - ext4 /dev/test rw" > "$USER_MOUNTINFO_FILE"
! user_home_mounts_safe "$SAFE_HOME" \
    || fail "home that is itself a mount point was accepted"
mkdir -p "$SAFE_HOME/shared"
printf '%s\n' \
    '1 0 0:1 / / rw - rootfs rootfs rw' \
    "2 1 0:2 / $SAFE_HOME/shared rw - ext4 /dev/test rw" > "$USER_MOUNTINFO_FILE"
! user_home_mounts_safe "$SAFE_HOME" \
    || fail "home containing a nested mount point was accepted"
printf '1 0 0:1 / / rw - rootfs rootfs rw\n' > "$USER_MOUNTINFO_FILE"
assert_home_rejected "$TMP/homes/missing"
SAFE_OWNER=$(stat -c '%u' -- "$SAFE_HOME")
user_home_owned_by_uid "$SAFE_HOME" "$SAFE_OWNER" \
    || fail "home owned by the target uid was rejected"
! user_home_owned_by_uid "$SAFE_HOME" "$((SAFE_OWNER + 1))" \
    || fail "home owned by another uid was accepted"

# A normal temporary tree has /tmp as a world-writable ancestor and must not
# pass the destructive deletion check.
! user_home_ancestors_root_safe "$SAFE_HOME" \
    || fail "home below a non-root-writable ancestor was accepted"

# Exercise the positive branch without requiring the test runner to create
# root-owned directories.
user_home_stat_owner_mode() { printf '0:755\n'; }
user_home_ancestor_acl_safe() { return 0; }
user_home_ancestors_root_safe "$SAFE_HOME" \
    || fail "root-owned non-writable ancestors were rejected"
unset -f user_home_stat_owner_mode
unset -f user_home_ancestor_acl_safe
# Restore the production helpers after removing the test overrides.
# shellcheck source=/dev/null
source "$ROOT/src/modules/users.sh"

HOME_SNAPSHOT_BEFORE=$(user_home_path_snapshot "$SAFE_HOME") \
    || fail "could not snapshot home path identity"
mv "$SAFE_HOME" "$SAFE_HOME.before-replace"
mkdir "$SAFE_HOME"
HOME_SNAPSHOT_AFTER=$(user_home_path_snapshot "$SAFE_HOME") \
    || fail "could not resnapshot home path identity"
[ "$HOME_SNAPSHOT_BEFORE" != "$HOME_SNAPSHOT_AFTER" ] \
    || fail "device/inode snapshot did not detect path replacement"

ln -s "$SAFE_HOME" "$TMP/home-link"
if [ -L "$TMP/home-link" ]; then
    assert_home_rejected "$TMP/home-link"
fi
mkdir -p "$TMP/real-parent/bob"
ln -s "$TMP/real-parent" "$TMP/parent-link"
if [ -L "$TMP/parent-link" ]; then
    assert_home_rejected "$TMP/parent-link/bob"
fi

USER_PASSWD_FILE="$TMP/passwd"
printf '%s\n' \
    "alice:x:1000:1000::${SAFE_HOME}:/bin/bash" \
    "bob:x:1001:1001::${SAFE_HOME}/:/bin/bash" > "$USER_PASSWD_FILE"
user_home_is_shared alice "$SAFE_HOME" \
    || fail "shared home with a trailing slash was not detected"

NESTED_HOME="$SAFE_HOME/projects/bob"
mkdir -p "$NESTED_HOME"
printf '%s\n' \
    "alice:x:1000:1000::${SAFE_HOME}:/bin/bash" \
    "bob:x:1001:1001::${NESTED_HOME}:/bin/bash" > "$USER_PASSWD_FILE"
user_home_is_shared alice "$SAFE_HOME" \
    || fail "nested home below the deletion target was not detected"

printf '%s\n' \
    "alice:x:1000:1000::${NESTED_HOME}:/bin/bash" \
    "bob:x:1001:1001::${SAFE_HOME}:/bin/bash" > "$USER_PASSWD_FILE"
user_home_is_shared alice "$NESTED_HOME" \
    || fail "non-system ancestor home was not detected"

SHARED_LINK="$TMP/shared-link"
ln -s "$SAFE_HOME" "$SHARED_LINK"
if [ -L "$SHARED_LINK" ]; then
    printf '%s\n' \
        "alice:x:1000:1000::${SAFE_HOME}:/bin/bash" \
        "bob:x:1001:1001::${SHARED_LINK}:/bin/bash" > "$USER_PASSWD_FILE"
    user_home_is_shared alice "$SAFE_HOME" \
        || fail "shared home through a symlink alias was not detected"
fi

OTHER_HOME="$TMP/homes/bob"
mkdir -p "$OTHER_HOME"
printf '%s\n' \
    "alice:x:1000:1000::${SAFE_HOME}:/bin/bash" \
    "bob:x:1001:1001::${OTHER_HOME}:/bin/bash" > "$USER_PASSWD_FILE"
! user_home_is_shared alice "$SAFE_HOME" \
    || fail "independent homes were reported as shared"
user_home_path_identity() { printf 'same-mounted-directory\n'; }
user_home_is_shared alice "$SAFE_HOME" \
    || fail "bind/NFS aliases with the same device and inode were not detected"
unset -f user_home_path_identity
# shellcheck source=/dev/null
source "$ROOT/src/modules/users.sh"
user_home_path_identity() {
    case "$1" in
        "$SAFE_HOME") printf 'shared-root\n' ;;
        "$OTHER_HOME") printf 'other-final\n' ;;
        *) printf 'identity-%s\n' "$1" ;;
    esac
}
user_home_component_identities() {
    case "$1" in
        "$SAFE_HOME") printf 'shared-root\n' ;;
        "$OTHER_HOME")
            printf 'shared-root\n'
            printf 'other-final\n'
            ;;
        *) return 1 ;;
    esac
}
user_home_is_shared alice "$SAFE_HOME" \
    || fail "nested home through a bind/NFS alias was not detected"
unset -f user_home_path_identity
unset -f user_home_component_identities
# shellcheck source=/dev/null
source "$ROOT/src/modules/users.sh"
USER_PASSWD_FILE="$TMP/missing-passwd"
user_home_is_shared alice "$SAFE_HOME" \
    || fail "an unreadable account database was not rejected conservatively"

# Session/process checks must be repeated after the destructive confirmation.
USER_PASSWD_FILE="$TMP/delete-passwd"
printf 'alice:x:2000:2000::%s:/bin/bash\n' "$SAFE_HOME" > "$USER_PASSWD_FILE"
VPS_TOOLS_UID_OVERRIDE=0
DIM=""
NC=""
RED=""
BOLD=""
print_header() { :; }
menu_item() { :; }
menu_div() { :; }
ui_prompt() { printf '%s' "$1"; }
ui_hint() { :; }
audit_action() { :; }
DELETE_CALLED="$TMP/delete-called"
SESSION_CALLS="$TMP/session-calls"
printf '0\n' > "$SESSION_CALLS"
user_has_active_session() {
    local COUNT
    COUNT=$(cat "$SESSION_CALLS")
    COUNT=$((COUNT + 1))
    printf '%s\n' "$COUNT" > "$SESSION_CALLS"
    [ "$COUNT" -ge 2 ]
}
user_has_processes() { return 1; }
user_delete_system_account() {
    : > "$DELETE_CALLED"
    return 0
}
if printf 'alice\n1\nalice\n' | user_delete_account; then
    fail "new session after confirmation did not cancel deletion"
fi
[ "$(cat "$SESSION_CALLS")" -eq 2 ] \
    || fail "session check was not repeated after confirmation"
[ ! -e "$DELETE_CALLED" ] \
    || fail "account deletion ran despite a new session"

PROCESS_CALLS="$TMP/process-calls"
printf '0\n' > "$PROCESS_CALLS"
user_has_active_session() { return 1; }
user_has_processes() {
    local COUNT
    COUNT=$(cat "$PROCESS_CALLS")
    COUNT=$((COUNT + 1))
    printf '%s\n' "$COUNT" > "$PROCESS_CALLS"
    [ "$COUNT" -ge 2 ]
}
if printf 'alice\n1\nalice\n' | user_delete_account; then
    fail "new process after confirmation did not cancel deletion"
fi
[ "$(cat "$PROCESS_CALLS")" -eq 2 ] \
    || fail "process check was not repeated after confirmation"
[ ! -e "$DELETE_CALLED" ] \
    || fail "account deletion ran despite a new process"

SWAPPINESS_PROC_FILE="$TMP/swappiness"
SWAPPINESS_SYSCTL_FILE="$TMP/sysctl.conf"
export SWAPPINESS_PROC_FILE SWAPPINESS_SYSCTL_FILE
SYSCTL_CALLED="$TMP/sysctl-called"
sysctl() {
    : > "$SYSCTL_CALLED"
    return 0
}

printf '60\n' > "$SWAPPINESS_PROC_FILE"
printf '%s\n' \
    '# vm.swappiness = 99' \
    '   # vm.swappiness=88' \
    '; vm.swappiness = 77' > "$SWAPPINESS_SYSCTL_FILE"
swap_apply_swappiness 30 || fail "comment-only swappiness update failed"
[ "$(tr -d '[:space:]' < "$SWAPPINESS_PROC_FILE")" = 30 ] \
    || fail "runtime swappiness was not updated"
grep -qx '# vm.swappiness = 99' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "commented swappiness setting was overwritten"
grep -qx '   # vm.swappiness=88' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "indented commented swappiness setting was overwritten"
grep -qx '; vm.swappiness = 77' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "semicolon-commented swappiness setting was overwritten"
[ "$(awk '/^[[:space:]]*vm[.]swappiness[[:space:]]*=/{count++} END{print count+0}' "$SWAPPINESS_SYSCTL_FILE")" -eq 1 ] \
    || fail "comment-only config did not receive exactly one active setting"
grep -qx 'vm.swappiness = 30' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "active swappiness setting was not appended"
[ ! -e "$SYSCTL_CALLED" ] \
    || fail "swappiness update reloaded an entire sysctl file"

printf '60\n' > "$SWAPPINESS_PROC_FILE"
swap_apply_swappiness 010 || fail "leading-zero swappiness input was not normalized"
[ "$(tr -d '[:space:]' < "$SWAPPINESS_PROC_FILE")" = 10 ] \
    || fail "leading-zero swappiness input did not apply decimal 10"
grep -qx 'vm.swappiness = 10' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "leading-zero swappiness input was persisted without normalization"

printf '%s\n' \
    '  vm.swappiness    = 60' \
    $'\tvm.swappiness=40' \
    'vm.dirty_ratio = 15' > "$SWAPPINESS_SYSCTL_FILE"
swap_apply_swappiness 10 || fail "whitespace-normalized swappiness update failed"
[ "$(awk '/^[[:space:]]*vm[.]swappiness[[:space:]]*=/{count++} END{print count+0}' "$SWAPPINESS_SYSCTL_FILE")" -eq 1 ] \
    || fail "duplicate active swappiness settings were not collapsed"
grep -qx 'vm.swappiness = 10' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "indented swappiness setting was not replaced"
grep -qx 'vm.dirty_ratio = 15' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "unrelated sysctl setting changed"

printf '60\n' > "$SWAPPINESS_PROC_FILE"
printf 'vm.swappiness = 60\n' > "$SWAPPINESS_SYSCTL_FILE"
swap_swappiness_runtime_write() {
    local PROC_FILE="$1" VALUE="$2"
    if [ "$VALUE" = 20 ]; then
        printf '77\n' > "$PROC_FILE"
    else
        printf '%s\n' "$VALUE" > "$PROC_FILE"
    fi
    return 0
}
if swap_apply_swappiness 20; then
    fail "runtime verification accepted the wrong swappiness value"
fi
[ "$(tr -d '[:space:]' < "$SWAPPINESS_PROC_FILE")" = 60 ] \
    || fail "runtime swappiness was not rolled back after verification failure"
grep -qx 'vm.swappiness = 60' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "sysctl config was not rolled back after verification failure"

printf '60\n' > "$SWAPPINESS_PROC_FILE"
printf 'vm.swappiness = 60\n' > "$SWAPPINESS_SYSCTL_FILE"
WARN_LOG="$TMP/warnings"
warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
swap_swappiness_runtime_write() {
    local PROC_FILE="$1" VALUE="$2"
    if [ "$VALUE" = 20 ]; then
        printf '77\n' > "$PROC_FILE"
        return 0
    fi
    return 1
}
ROLLBACK_RC=0
swap_apply_swappiness 20 || ROLLBACK_RC=$?
[ "$ROLLBACK_RC" -eq 2 ] \
    || fail "incomplete rollback did not propagate a distinct failure"
grep -q '回滚不完整' "$WARN_LOG" 2>/dev/null \
    || grep -q '备份已保留' "$WARN_LOG" 2>/dev/null \
    || fail "incomplete rollback was not reported clearly"
compgen -G "${SWAPPINESS_SYSCTL_FILE}.vps-tools-backup.*" >/dev/null \
    || fail "original config backup was not retained after rollback failure"
grep -qx 'vm.swappiness = 60' "$SWAPPINESS_SYSCTL_FILE" \
    || fail "config was not restored during a partial rollback"

printf 'User and swappiness regression tests passed.\n'

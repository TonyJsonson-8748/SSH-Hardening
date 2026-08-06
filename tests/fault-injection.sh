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
# shellcheck disable=SC2329 # test stub used indirectly by download helpers
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

# Failed password/admin setup must remove the newly created account.
(
    VPS_TOOLS_UID_OVERRIDE=0
    CREATED_LOG="$TMP/user-created.log"
    REMOVED_LOG="$TMP/user-removed.log"
    user_account_exists() { return 1; }
    user_login_shell() { echo /bin/bash; }
    confirm_change_preview() { return 0; }
    user_create_system_account() { printf '%s\n' "$1" > "$CREATED_LOG"; }
    user_prompt_password() { return 1; }
    user_remove_created_account() { printf '%s\n' "$1" > "$REMOVED_LOG"; }
    ! user_create_account regular <<< "testuser" >/dev/null 2>&1 \
        || { echo "User creation ignored password setup failure" >&2; exit 1; }
    grep -qx testuser "$CREATED_LOG" || { echo "User creation test did not reach account creation" >&2; exit 1; }
    grep -qx testuser "$REMOVED_LOG" || { echo "Failed user creation left the account behind" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=0
    REMOVED_LOG="$TMP/admin-removed.log"
    USER_SUDOERS_DIR="$TMP/admin-sudoers"
    user_account_exists() { return 1; }
    user_login_shell() { echo /bin/bash; }
    confirm_change_preview() { return 0; }
    user_create_system_account() { return 0; }
    user_prompt_password() { return 0; }
    user_grant_admin() { return 1; }
    user_remove_created_account() { printf '%s\n' "$1" > "$REMOVED_LOG"; }
    ! user_create_account admin <<< "adminuser" >/dev/null 2>&1 \
        || { echo "Admin creation ignored sudo setup failure" >&2; exit 1; }
    grep -qx adminuser "$REMOVED_LOG" || { echo "Failed admin creation left the account behind" >&2; exit 1; }
)

# Password changes must target the selected account and propagate failures.
(
    VPS_TOOLS_UID_OVERRIDE=0
    PASSWORD_LOG="$TMP/password-change.log"
    AUDIT_LOG="$TMP/password-audit.log"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    confirm_change_preview() { return 0; }
    user_prompt_password() { printf '%s\n' "$1" > "$PASSWORD_LOG"; }
    audit_action() { printf '%s:%s\n' "$1" "$2" > "$AUDIT_LOG"; }
    user_change_password <<< "testuser" >/dev/null
    grep -qx testuser "$PASSWORD_LOG" || { echo "Password change targeted the wrong account" >&2; exit 1; }
    grep -qx '修改用户密码 testuser:SUCCESS' "$AUDIT_LOG" || { echo "Successful password change was not audited" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=0
    AUDIT_LOG="$TMP/password-failed-audit.log"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    confirm_change_preview() { return 0; }
    user_prompt_password() { return 1; }
    audit_action() { printf '%s:%s\n' "$1" "$2" > "$AUDIT_LOG"; }
    ! user_change_password <<< "testuser" >/dev/null \
        || { echo "Failed password update was reported as successful" >&2; exit 1; }
    grep -qx '修改用户密码 testuser:FAILED' "$AUDIT_LOG" || { echo "Failed password change was not audited" >&2; exit 1; }
)

# Existing users can be promoted, and failed grants must roll back group changes.
(
    VPS_TOOLS_UID_OVERRIDE=0
    GRANT_LOG="$TMP/promote-grant.log"
    AUDIT_LOG="$TMP/promote-audit.log"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    user_is_admin_account() { return 1; }
    confirm_change_preview() { return 0; }
    user_grant_admin() { printf '%s\n' "$1" > "$GRANT_LOG"; }
    audit_action() { printf '%s:%s\n' "$1" "$2" > "$AUDIT_LOG"; }
    user_promote_admin <<< "testuser" >/dev/null
    grep -qx testuser "$GRANT_LOG" || { echo "Admin promotion targeted the wrong account" >&2; exit 1; }
    grep -qx '增加管理员 testuser:SUCCESS' "$AUDIT_LOG" || { echo "Admin promotion was not audited" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=0
    GROUP_LOG="$TMP/grant-group.log"
    ROLLBACK_LOG="$TMP/grant-rollback.log"
    user_ensure_sudo() { return 0; }
    user_group_exists() { [ "$1" = sudo ]; }
    user_in_group() { return 1; }
    user_add_to_group() { printf '%s:%s\n' "$1" "$2" > "$GROUP_LOG"; }
    user_write_sudoers() { return 1; }
    user_remove_from_group() { printf '%s:%s\n' "$1" "$2" > "$ROLLBACK_LOG"; }
    ! user_grant_admin testuser >/dev/null \
        || { echo "Broken sudoers grant was reported as successful" >&2; exit 1; }
    grep -qx 'testuser:sudo' "$GROUP_LOG" || { echo "Admin grant did not add the native group" >&2; exit 1; }
    grep -qx 'testuser:sudo' "$ROLLBACK_LOG" || { echo "Failed admin grant did not roll back the native group" >&2; exit 1; }
)

# Revocation removes managed groups and sudoers, then records the result.
(
    VPS_TOOLS_UID_OVERRIDE=0
    USER_SUDOERS_DIR="$TMP/revoke-sudoers"
    GROUP_LOG="$TMP/revoke-group.log"
    mkdir -p "$USER_SUDOERS_DIR"
    : > "$USER_SUDOERS_DIR/vps-tools-testuser"
    user_group_exists() { [ "$1" = sudo ]; }
    user_in_group() { [ "$2" = sudo ]; }
    user_remove_from_group() { printf '%s:%s\n' "$1" "$2" > "$GROUP_LOG"; }
    user_has_sudo_access() { return 1; }
    user_revoke_admin_rights testuser >/dev/null
    grep -qx 'testuser:sudo' "$GROUP_LOG" || { echo "Admin revocation did not remove the native group" >&2; exit 1; }
    [ ! -e "$USER_SUDOERS_DIR/vps-tools-testuser" ] || { echo "Admin revocation left the managed sudoers rule" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=0
    REVOKE_LOG="$TMP/revoke-account.log"
    AUDIT_LOG="$TMP/revoke-audit.log"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    user_is_elevation_account() { return 1; }
    user_is_admin_account() { return 0; }
    confirm_change_preview() { return 0; }
    user_revoke_admin_rights() { printf '%s\n' "$1" > "$REVOKE_LOG"; }
    audit_action() { printf '%s:%s\n' "$1" "$2" > "$AUDIT_LOG"; }
    user_revoke_admin <<< $'testuser\ntestuser' >/dev/null
    grep -qx testuser "$REVOKE_LOG" || { echo "Admin revocation targeted the wrong account" >&2; exit 1; }
    grep -qx '撤销管理员权限 testuser:SUCCESS' "$AUDIT_LOG" || { echo "Admin revocation was not audited" >&2; exit 1; }
)

# User deletion must preserve or remove the workspace exactly as selected and
# clean up the managed sudoers rule only after successful account deletion.
(
    VPS_TOOLS_UID_OVERRIDE=0
    USER_SUDOERS_DIR="$TMP/delete-preserve-sudoers"
    DELETE_LOG="$TMP/delete-preserve.log"
    mkdir -p "$USER_SUDOERS_DIR"
    : > "$USER_SUDOERS_DIR/vps-tools-testuser"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    user_is_protected_account() { return 1; }
    user_has_active_session() { return 1; }
    user_has_processes() { return 1; }
    user_delete_system_account() { printf '%s:%s\n' "$1" "$2" > "$DELETE_LOG"; }
    audit_action() { :; }
    user_delete_account <<< $'testuser\n1\ntestuser' >/dev/null
    grep -qx 'testuser:no' "$DELETE_LOG" || { echo "User deletion did not preserve the selected workspace" >&2; exit 1; }
    [ ! -e "$USER_SUDOERS_DIR/vps-tools-testuser" ] || { echo "Deleted admin left a managed sudoers rule" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=0
    USER_SUDOERS_DIR="$TMP/delete-all-sudoers"
    DELETE_LOG="$TMP/delete-all.log"
    mkdir -p "$USER_SUDOERS_DIR"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    user_is_protected_account() { return 1; }
    user_has_active_session() { return 1; }
    user_has_processes() { return 1; }
    user_home_is_shared() { return 1; }
    user_delete_system_account() { printf '%s:%s\n' "$1" "$2" > "$DELETE_LOG"; }
    audit_action() { :; }
    user_delete_account <<< $'testuser\n2\ntestuser' >/dev/null
    grep -qx 'testuser:yes' "$DELETE_LOG" || { echo "User deletion did not remove the selected workspace" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=0
    USER_SUDOERS_DIR="$TMP/delete-failed-sudoers"
    mkdir -p "$USER_SUDOERS_DIR"
    : > "$USER_SUDOERS_DIR/vps-tools-testuser"
    user_account_record() { printf 'testuser:x:1000:1000::/home/testuser:/bin/bash\n'; }
    user_is_protected_account() { return 1; }
    user_has_active_session() { return 1; }
    user_has_processes() { return 1; }
    user_delete_system_account() { return 1; }
    user_account_exists() { return 0; }
    audit_action() { :; }
    ! user_delete_account <<< $'testuser\n1\ntestuser' >/dev/null \
        || { echo "Failed account deletion was reported as successful" >&2; exit 1; }
    [ -e "$USER_SUDOERS_DIR/vps-tools-testuser" ] || { echo "Failed account deletion removed the active sudoers rule" >&2; exit 1; }
)
ELEVATION_HELP=$(vps_tools_elevation_help sudo)
[[ "$ELEVATION_HELP" = *"sudo bash -c"* && "$ELEVATION_HELP" = *"sudo v"* ]] \
    || { echo "Non-root elevation guidance is incomplete" >&2; exit 1; }

docker() { [ "$1" = "inspect" ] && printf '<no value>\n'; }
[ -z "$(docker_inspect_label fake-id com.docker.compose.project)" ] || {
    echo "Missing Compose label was treated as a real value" >&2
    exit 1
}

[ "$(docker_compose_basename 'https://example.com/path/app.yml?token=1')" = "app.yml" ] || {
    echo "Compose basename parsing failed" >&2
    exit 1
}
[ "$(docker_compose_basename 'https://example.com/path/unknown')" = "compose.yaml" ] || {
    echo "Compose default filename parsing failed" >&2
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
# shellcheck disable=SC2329 # test stub overrides the sourced function for config_backup_create
config_backup_paths() { printf 'tmp/does-not-exist-vps-tools-test\n'; }
config_backup_create injected_failure true >/dev/null 2>&1 && { echo "Expected backup failure" >&2; exit 1; }
if find "$VPS_BACKUP_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q .; then
    echo "Partial backup archive was left behind" >&2
    exit 1
fi
(
    VPS_DATA_DIR="$TMP/unrestorable-backup"
    VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
    mkdir -p "$TMP/unrestorable-source"
    printf 'config\n' > "$TMP/unrestorable-source/value"
    config_backup_paths() { printf '%s/unrestorable-source/value\n' "${TMP#/}"; }
    config_archive_validate() { return 1; }
    ! config_backup_create invalid_member true >/dev/null 2>&1 \
        || { echo "Backup creation accepted an archive it cannot restore" >&2; exit 1; }
    ! find "$VPS_BACKUP_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q . \
        || { echo "Unrestorable backup archive was retained" >&2; exit 1; }
)

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

# Export/import helpers must validate paths and write archives to a caller-specified destination.
EXPORT_PATH="$TMP/exported-config.tar.gz"
config_export_archive "$EXPORT_PATH" test >/dev/null || { echo "Export helper failed" >&2; exit 1; }
[ -f "$EXPORT_PATH" ] || { echo "Export helper did not create archive" >&2; exit 1; }
config_import_archive() { [ "$1" = "$EXPORT_PATH" ]; }
config_import_archive "$EXPORT_PATH" >/dev/null || { echo "Import helper failed" >&2; exit 1; }

# Imported archives may contain only the explicit VPS Tools configuration allowlist.
mkdir -p "$TMP/archive-source/etc"
printf 'not allowed\n' > "$TMP/archive-source/etc/passwd"
tar -czf "$TMP/malicious-config.tar.gz" -C "$TMP/archive-source" etc/passwd
config_archive_validate "$TMP/malicious-config.tar.gz" >/dev/null 2>&1 && {
    echo "Config import accepted a path outside the allowlist" >&2
    exit 1
}
mkdir -p "$TMP/archive-source/root"
printf 'valid\n' > "$TMP/archive-source/root/.vps-monitor"
tar -czf "$TMP/valid-config.tar.gz" -C "$TMP/archive-source" root/.vps-monitor
config_archive_validate "$TMP/valid-config.tar.gz" >/dev/null \
    || { echo "Config import rejected an allowlisted path" >&2; exit 1; }
(
    export CONFIG_RESTORE_ROOT="$TMP/restored-root"
    config_archive_extract "$TMP/valid-config.tar.gz" >/dev/null
    grep -qx valid "$CONFIG_RESTORE_ROOT/root/.vps-monitor" \
        || { echo "Allowlisted config archive was not restored" >&2; exit 1; }
)

# Present roots are replaced exactly, while omitted roots from a partial import
# must remain untouched.
(
    EXACT_SOURCE="$TMP/exact-archive-source"
    export CONFIG_RESTORE_ROOT="$TMP/exact-restored-root"
    mkdir -p "$EXACT_SOURCE/etc/vps-tools-test-dir"
    printf 'snapshot\n' > "$EXACT_SOURCE/etc/vps-tools-test-dir/kept.conf"
    tar -czf "$TMP/exact-config.tar.gz" -C "$EXACT_SOURCE" etc/vps-tools-test-dir
    mkdir -p \
        "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-dir" \
        "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-absent"
    printf 'stale\n' > "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-dir/stale.conf"
    printf 'new\n' > "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-absent/new.conf"
    config_backup_allowed_roots() {
        printf '%s\n' etc/vps-tools-test-dir etc/vps-tools-test-absent
    }
    config_archive_extract "$TMP/exact-config.tar.gz" >/dev/null
    grep -qx snapshot "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-dir/kept.conf" \
        || { echo "Exact restore lost the snapshotted file" >&2; exit 1; }
    [ ! -e "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-dir/stale.conf" ] \
        || { echo "Exact restore retained a file created after the snapshot" >&2; exit 1; }
    grep -qx new "$CONFIG_RESTORE_ROOT/etc/vps-tools-test-absent/new.conf" \
        || { echo "Partial restore deleted a root omitted from the archive" >&2; exit 1; }
)

# Config archives must reject empty, special, wrongly typed and symlink-pivot members.
tar -czf "$TMP/empty-config.tar.gz" -T /dev/null
! config_archive_validate "$TMP/empty-config.tar.gz" >/dev/null 2>&1 \
    || { echo "Config import accepted an empty archive" >&2; exit 1; }
mkdir -p "$TMP/wrong-type/root/.vps-monitor"
tar -czf "$TMP/wrong-type-config.tar.gz" -C "$TMP/wrong-type" root/.vps-monitor
! config_archive_validate "$TMP/wrong-type-config.tar.gz" >/dev/null 2>&1 \
    || { echo "Config import accepted a directory where a file root was expected" >&2; exit 1; }
mkdir -p "$TMP/wrong-directory-type/etc"
printf 'not a directory\n' > "$TMP/wrong-directory-type/etc/caddy"
tar -czf "$TMP/wrong-directory-type-config.tar.gz" \
    -C "$TMP/wrong-directory-type" etc/caddy
! config_archive_validate "$TMP/wrong-directory-type-config.tar.gz" >/dev/null 2>&1 \
    || { echo "Config import accepted a file where a directory root was expected" >&2; exit 1; }
if command -v mkfifo >/dev/null 2>&1; then
    mkdir -p "$TMP/special/root"
    mkfifo "$TMP/special/root/.vps-monitor"
    tar -czf "$TMP/special-config.tar.gz" -C "$TMP/special" root/.vps-monitor
    ! config_archive_validate "$TMP/special-config.tar.gz" >/dev/null 2>&1 \
        || { echo "Config import accepted a FIFO member" >&2; exit 1; }
fi
if tar --help 2>&1 | grep -q -- '--transform'; then
    mkdir -p "$TMP/pivot/etc/caddy" "$TMP/pivot-payload"
    ln -s safe-target "$TMP/pivot/etc/caddy/pivot"
    printf 'escape\n' > "$TMP/pivot-payload/child"
    tar -czf "$TMP/pivot-config.tar.gz" \
        -C "$TMP/pivot" etc/caddy/pivot \
        -C "$TMP/pivot-payload" \
        --transform='s|^child$|etc/caddy/pivot/child|' child
    ! config_archive_validate "$TMP/pivot-config.tar.gz" >/dev/null 2>&1 \
        || { echo "Config import accepted a symlink with descendant members" >&2; exit 1; }
    tar -czf "$TMP/pivot-dot-config.tar.gz" \
        -C "$TMP/pivot" etc/caddy/pivot \
        -C "$TMP/pivot-payload" \
        --transform='s|^child$|etc/caddy/./pivot/child|' child
    ! config_archive_validate "$TMP/pivot-dot-config.tar.gz" >/dev/null 2>&1 \
        || { echo "Config import accepted an internal dot-component pivot" >&2; exit 1; }
fi
mkdir -p "$TMP/config-hardlink/etc/caddy"
printf 'linked\n' > "$TMP/config-hardlink/etc/caddy/one"
if ln "$TMP/config-hardlink/etc/caddy/one" "$TMP/config-hardlink/etc/caddy/two" 2>/dev/null; then
    tar -czf "$TMP/config-hardlink.tar.gz" -C "$TMP/config-hardlink" \
        etc/caddy/one etc/caddy/two
    ! config_archive_validate "$TMP/config-hardlink.tar.gz" >/dev/null 2>&1 \
        || { echo "Config import accepted a hardlink archive member" >&2; exit 1; }
fi
mkdir -p "$TMP/resolv-link/etc"
if ln -s ../run/systemd/resolve/stub-resolv.conf "$TMP/resolv-link/etc/resolv.conf" 2>/dev/null \
    && [ -L "$TMP/resolv-link/etc/resolv.conf" ]; then
    tar -czf "$TMP/resolv-link-config.tar.gz" -C "$TMP/resolv-link" etc/resolv.conf
    config_archive_validate "$TMP/resolv-link-config.tar.gz" >/dev/null \
        || { echo "Config import rejected a standard relative resolv.conf symlink" >&2; exit 1; }
fi

# Safety snapshots must retain the runtime sysctl values needed after file restore.
(
    SYSCTL_STATE="$TMP/safety-runtime.sysctl"
    sysctl() {
        [ "$1" = -n ] || return 1
        case "$2" in
            net.ipv6.conf.all.disable_ipv6) printf '0\n' ;;
            net.ipv6.conf.default.disable_ipv6) printf '1\n' ;;
            net.ipv6.conf.lo.disable_ipv6) printf '0\n' ;;
            net.ipv4.conf.all.promote_secondaries) printf '1\n' ;;
            *) return 1 ;;
        esac
    }
    safety_snapshot_sysctl_state "$SYSCTL_STATE"
    grep -qx 'net.ipv6.conf.all.disable_ipv6=0' "$SYSCTL_STATE" \
        || { echo "Safety snapshot lost the IPv6 runtime state" >&2; exit 1; }
    grep -qx 'net.ipv4.conf.all.promote_secondaries=1' "$SYSCTL_STATE" \
        || { echo "Safety snapshot lost the IPv4 runtime state" >&2; exit 1; }
)
(
    IPTABLES_STATE="$TMP/safety-runtime.iptables"
    iptables-save() { return 1; }
    safety_snapshot_iptables_state "$IPTABLES_STATE" \
        || { echo "Unreadable iptables state disabled all safety protection" >&2; exit 1; }
    [ ! -s "$IPTABLES_STATE" ] \
        || { echo "Failed iptables snapshot retained partial runtime state" >&2; exit 1; }
)

# Firewall installation must never enable UFW when the SSH allow rule failed.
(
    UFW_LOG="$TMP/ufw.log"
    print_header() { :; }
    info() { :; }
    error() { :; }
    pkg_install() { return 0; }
    safety_arm() { return 0; }
    safety_confirm() { :; }
    get_config() { echo 2222; }
    ufw() {
        printf '%s\n' "$*" >> "$UFW_LOG"
        [ "$1 $2" != "allow 2222/tcp" ]
    }
    fw_install ufw >/dev/null 2>&1 && { echo "UFW install succeeded after SSH allow failure" >&2; exit 1; }
    ! grep -q -- '--force enable' "$UFW_LOG" || { echo "UFW was enabled without its SSH rule" >&2; exit 1; }
)

# Atomic replacement must leave the destination untouched when staging fails.
(
    SOURCE="$TMP/update-source"
    DEST="$TMP/update-dest"
    printf 'new\n' > "$SOURCE"
    printf 'old\n' > "$DEST"
    install() { return 1; }
    ! self_atomic_replace "$SOURCE" "$DEST" || { echo "Atomic update ignored install failure" >&2; exit 1; }
    grep -qx old "$DEST" || { echo "Atomic update damaged the current script" >&2; exit 1; }
)

# Caddy startup failure must propagate instead of reporting success.
(
    CADDYFILE="$TMP/Caddyfile"
    : > "$CADDYFILE"
    info() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    svc_start() { return 1; }
    caddy() { [ "$1" = validate ]; }
    ! caddy_reload_config >/dev/null 2>&1 || { echo "Caddy reload hid a startup failure" >&2; exit 1; }
)

# Fail2ban DEFAULT changes must not rewrite the same key in another jail.
(
    export F2B_JAIL_LOCAL="$TMP/jail.local"
    cat > "$F2B_JAIL_LOCAL" <<'EOF'
[DEFAULT]
bantime = 3600
[sshd]
bantime = 120
enabled = true
EOF
    fail2ban-client() { return 0; }
    f2b_set_param bantime 7200 >/dev/null
    [ "$(awk '/^\[DEFAULT\]/{s=1;next} /^\[/{s=0} s && /^bantime/{print $3}' "$F2B_JAIL_LOCAL")" = 7200 ] || exit 1
    [ "$(awk '/^\[sshd\]/{s=1;next} /^\[/{s=0} s && /^bantime/{print $3}' "$F2B_JAIL_LOCAL")" = 120 ] \
        || { echo "Fail2ban DEFAULT update changed sshd override" >&2; exit 1; }
)

# Fail2ban must follow the effective sshd port instead of the /etc/services ssh alias.
(
    export F2B_JAIL_LOCAL="$TMP/jail-port.local"
    cat > "$F2B_JAIL_LOCAL" <<'EOF'
[DEFAULT]
bantime = 3600
[sshd]
enabled = true
port = 22
EOF
    get_config() { echo 2222; }
    fail2ban-client() { return 0; }
    f2b_status() { echo stopped; }
    [ "$(f2b_effective_ssh_port)" = 2222 ] || { echo "Fail2ban did not read the effective SSH port" >&2; exit 1; }
    f2b_sync_ssh_port 2222 >/dev/null
    [ "$(awk '/^\[sshd\]/{s=1;next} /^\[/{s=0} s && /^port/{print $3}' "$F2B_JAIL_LOCAL")" = 2222 ] \
        || { echo "Fail2ban SSH port synchronization failed" >&2; exit 1; }
)

# A second safety timer must be rejected while the first rollback is pending.
(
    SAFETY_STATE_FILE="$TMP/safety.active"
    SAFETY_SCRIPT="$TMP/rollback-active.sh"
    : > "$SAFETY_SCRIPT"
    SAFETY_PID=$$
    ! safety_arm second_change >/dev/null 2>&1 \
        || { echo "A second safety rollback replaced the active timer" >&2; exit 1; }
    [ "$SAFETY_PID" = "$$" ] || { echo "Active safety PID was overwritten" >&2; exit 1; }
)
(
    SAFETY_STATE_FILE="$TMP/safety-lock.active"
    mkdir "${SAFETY_STATE_FILE}.lock"
    printf '%s\n' "$$" > "${SAFETY_STATE_FILE}.lock/pid"
    ! safety_arm concurrent_change >/dev/null 2>&1 \
        || { echo "Safety rollback ignored a concurrent setup operation" >&2; exit 1; }
)

# A generated safety rollback must be syntactically valid, use an independent
# snapshot that pruning cannot remove, and clean all artifacts on cancellation.
(
    VPS_DATA_DIR="$TMP/generated-safety"
    VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
    SAFETY_STATE_FILE="$VPS_DATA_DIR/rollback.active"
    SAFETY_ROLLBACK_DELAY=600
    SAFETY_RESTORE_ROOT="$TMP/generated-safety-root"
    SAFETY_SNAPSHOT_ROOT="$SAFETY_RESTORE_ROOT"
    mkdir -p "$SAFETY_RESTORE_ROOT/etc/generated-safety"
    printf 'snapshot\n' > "$SAFETY_RESTORE_ROOT/etc/generated-safety/value"
    config_backup_allowed_roots() { printf '%s\n' etc/generated-safety; }
    config_backup_root_is_directory() { [ "$1" = etc/generated-safety ]; }
    safety_snapshot_iptables_state() { : > "$1"; }
    sysctl() {
        [ "$1" = -n ] || return 1
        printf '0\n'
    }
    svc_is_active() { return 1; }
    safety_arm generated_test >/dev/null \
        || { echo "Could not generate a safety rollback task" >&2; exit 1; }
    IFS='|' read -r GENERATED_PID GENERATED_SCRIPT GENERATED_ROOTS GENERATED_SYSCTL \
        GENERATED_SNAPSHOT GENERATED_STATUS \
        < "$SAFETY_STATE_FILE"
    GENERATED_IPTABLES="${GENERATED_SCRIPT%.sh}.iptables"
    [[ "$GENERATED_PID" =~ ^[0-9]+$ ]] \
        && [ -f "$GENERATED_SCRIPT" ] \
        && [ -f "$GENERATED_ROOTS" ] \
        && [ -f "$GENERATED_SYSCTL" ] \
        && [ -f "$GENERATED_IPTABLES" ] \
        && [ -f "$GENERATED_SNAPSHOT" ] \
        && [ "$GENERATED_STATUS" = armed ] \
        || { echo "Safety rollback state did not retain all artifacts" >&2; exit 1; }
    bash -n "$GENERATED_SCRIPT" \
        || { echo "Generated safety rollback script has invalid syntax" >&2; exit 1; }
    grep -Fq 'sysctl -w "$KEY=$VALUE"' "$GENERATED_SCRIPT" \
        || { echo "Generated safety rollback omitted runtime sysctl restore" >&2; exit 1; }
    mkdir -p "$VPS_BACKUP_DIR"
    printf 'ordinary\n' > "$VPS_BACKUP_DIR/20000101_ordinary.tar.gz"
    VPS_BACKUP_KEEP=1
    config_backup_prune
    [ -f "$GENERATED_SNAPSHOT" ] \
        || { echo "Ordinary backup pruning deleted the active safety snapshot" >&2; exit 1; }
    cancel_safety_timer
    [ ! -e "$SAFETY_STATE_FILE" ] \
        && [ ! -e "$GENERATED_SCRIPT" ] \
        && [ ! -e "$GENERATED_ROOTS" ] \
        && [ ! -e "$GENERATED_SYSCTL" ] \
        && [ ! -e "$GENERATED_IPTABLES" ] \
        && [ ! -e "$GENERATED_SNAPSHOT" ] \
        || { echo "Cancelling safety rollback left private artifacts behind" >&2; exit 1; }
)

# A failed rollback must have an explicit recovery-center escape hatch that
# archives a valid snapshot before allowing future safety tasks.
(
    VPS_DATA_DIR="$TMP/failed-safety"
    VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
    SAFETY_STATE_FILE="$VPS_DATA_DIR/rollback.active"
    FAILED_SOURCE="$TMP/failed-safety-source"
    FAILED_SCRIPT="$VPS_DATA_DIR/rollback_failed.sh"
    FAILED_ROOTS="$VPS_DATA_DIR/rollback_failed.roots"
    FAILED_SYSCTL="$VPS_DATA_DIR/rollback_failed.sysctl"
    FAILED_IPTABLES="$VPS_DATA_DIR/rollback_failed.iptables"
    FAILED_SNAPSHOT="$VPS_DATA_DIR/rollback_failed.tar.gz"
    mkdir -p "$VPS_DATA_DIR" "$FAILED_SOURCE/root"
    printf 'recoverable\n' > "$FAILED_SOURCE/root/.vps-monitor"
    tar -czf "$FAILED_SNAPSHOT" -C "$FAILED_SOURCE" root/.vps-monitor
    : > "$FAILED_SCRIPT"
    : > "$FAILED_ROOTS"
    : > "$FAILED_SYSCTL"
    : > "$FAILED_IPTABLES"
    printf '|%s|%s|%s|%s|failed\n' \
        "$FAILED_SCRIPT" "$FAILED_ROOTS" "$FAILED_SYSCTL" "$FAILED_SNAPSHOT" \
        > "$SAFETY_STATE_FILE"
    safety_failed_task_clear <<< "CLEAR" >/dev/null \
        || { echo "Could not clear an explicitly confirmed failed safety task" >&2; exit 1; }
    [ ! -e "$SAFETY_STATE_FILE" ] \
        && [ ! -e "$FAILED_SCRIPT" ] \
        && [ ! -e "$FAILED_ROOTS" ] \
        && [ ! -e "$FAILED_SYSCTL" ] \
        && [ ! -e "$FAILED_IPTABLES" ] \
        && [ ! -e "$FAILED_SNAPSHOT" ] \
        || { echo "Failed safety cleanup left managed blocking artifacts" >&2; exit 1; }
    FAILED_ARCHIVE=$(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f \
        -name '*_failed-safety_*.tar.gz' | head -1)
    [ -n "$FAILED_ARCHIVE" ] && config_archive_validate "$FAILED_ARCHIVE" >/dev/null \
        || { echo "Failed safety cleanup did not retain a valid recovery archive" >&2; exit 1; }
)

# The generated rollback must execute an exact restore and remove files created
# after the snapshot without touching the real system root.
(
    VPS_DATA_DIR="$TMP/executed-safety"
    VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
    SAFETY_STATE_FILE="$VPS_DATA_DIR/rollback.active"
    SAFETY_ROLLBACK_DELAY=1
    SAFETY_RESTORE_ROOT="$TMP/executed-safety-root"
    SAFETY_SNAPSHOT_ROOT="$SAFETY_RESTORE_ROOT"
    mkdir -p "$SAFETY_RESTORE_ROOT/etc/executed-safety"
    printf 'before\n' > "$SAFETY_RESTORE_ROOT/etc/executed-safety/value"
    config_backup_allowed_roots() { printf '%s\n' etc/executed-safety; }
    config_backup_root_is_directory() { [ "$1" = etc/executed-safety ]; }
    safety_snapshot_sysctl_state() { : > "$1"; }
    safety_snapshot_iptables_state() { : > "$1"; }
    sysctl() {
        [ "$1" = -n ] || return 1
        printf '0\n'
    }
    svc_is_active() { return 1; }
    safety_arm executed_test >/dev/null \
        || { echo "Could not arm executable safety rollback" >&2; exit 1; }
    printf 'after\n' > "$SAFETY_RESTORE_ROOT/etc/executed-safety/value"
    printf 'new\n' > "$SAFETY_RESTORE_ROOT/etc/executed-safety/new"
    # A dead owner must not make the at-deadline rollback abandon recovery.
    mkdir "${SAFETY_STATE_FILE}.lock"
    printf 'not-a-live-pid\n' > "${SAFETY_STATE_FILE}.lock/pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ ! -e "$SAFETY_STATE_FILE" ] && break
        sleep 1
    done
    grep -qx before "$SAFETY_RESTORE_ROOT/etc/executed-safety/value" \
        || { echo "Executed safety rollback did not restore the snapshotted value" >&2; exit 1; }
    [ ! -e "$SAFETY_RESTORE_ROOT/etc/executed-safety/new" ] \
        || { echo "Executed safety rollback retained a post-snapshot file" >&2; exit 1; }
    [ ! -e "$SAFETY_STATE_FILE" ] \
        || { echo "Successful safety rollback left an active state file" >&2; exit 1; }
    [ ! -e "${SAFETY_STATE_FILE}.lock" ] \
        || { echo "Successful safety rollback left a stale lock" >&2; exit 1; }
)

grep -Fq 'restart fail2ban' "$ROOT/src/modules/toolbox.sh" \
    || { echo "Safety rollback does not reload restored Fail2ban configuration" >&2; exit 1; }
grep -Fq 'sysctl -w "\$KEY=\$VALUE"' "$ROOT/src/modules/toolbox.sh" \
    || { echo "Safety rollback does not restore snapshotted sysctl values" >&2; exit 1; }
grep -Fq 'STAGE=\$(mktemp -d' "$ROOT/src/modules/toolbox.sh" \
    || { echo "Safety rollback does not stage its snapshot before exact restore" >&2; exit 1; }

# Monitor cron must install a real runner and propagate preparation failures.
(
    LOCAL_SCRIPT="$TMP/monitor runner/vps-tools"
    SVC_PATH=""
    CRON_CAPTURE="$TMP/monitor-cron"
    self_ensure_local_runner() {
        mkdir -p "$(dirname "$LOCAL_SCRIPT")"
        printf '#!/bin/bash\n' > "$LOCAL_SCRIPT"
        chmod 755 "$LOCAL_SCRIPT"
    }
    crontab() {
        case "${1:-}" in
            -l)
                if [ -f "$CRON_CAPTURE" ]; then
                    cat "$CRON_CAPTURE"
                else
                    echo "no crontab for test" >&2
                    return 1
                fi
                ;;
            -r) rm -f "$CRON_CAPTURE" ;;
            -) cat > "$CRON_CAPTURE" ;;
            *) cp "$1" "$CRON_CAPTURE" ;;
        esac
    }
    ddns_start_cron_service() { return 0; }
    monitor_alert_install_cron >/dev/null \
        || { echo "Monitor cron rejected a prepared local runner" >&2; exit 1; }
    grep -Fq -- '--monitor-alert' "$CRON_CAPTURE" \
        || { echo "Monitor cron omitted its background entrypoint" >&2; exit 1; }
    grep -Fq 'monitor\ runner/vps-tools' "$CRON_CAPTURE" \
        || { echo "Monitor cron did not shell-escape its runner path" >&2; exit 1; }
)
(
    LOCAL_SCRIPT="$TMP/monitor-service-failure/vps-tools"
    SVC_PATH=""
    CRON_CAPTURE="$TMP/monitor-service-failure.cron"
    OLD_CRON="$TMP/monitor-service-failure.old"
    printf '5 * * * * old-job # keep-me\n*/15 * * * * old-monitor # vps-tools-monitor-alert\n' > "$OLD_CRON"
    cp "$OLD_CRON" "$CRON_CAPTURE"
    self_ensure_local_runner() {
        mkdir -p "$(dirname "$LOCAL_SCRIPT")"
        printf '#!/bin/bash\n' > "$LOCAL_SCRIPT"
        chmod 755 "$LOCAL_SCRIPT"
    }
    crontab() {
        case "${1:-}" in
            -l) cat "$CRON_CAPTURE" ;;
            -r) rm -f "$CRON_CAPTURE" ;;
            -) cat > "$CRON_CAPTURE" ;;
            *) cp "$1" "$CRON_CAPTURE" ;;
        esac
    }
    ddns_start_cron_service() { return 1; }
    ! monitor_alert_install_cron >/dev/null 2>&1 \
        || { echo "Monitor cron hid cron service startup failure" >&2; exit 1; }
    cmp -s "$OLD_CRON" "$CRON_CAPTURE" \
        || { echo "Monitor cron service failure did not restore the prior crontab" >&2; exit 1; }
)
(
    LOCAL_SCRIPT="$TMP/monitor-read-failure/vps-tools"
    SVC_PATH=""
    CRON_CAPTURE="$TMP/monitor-read-failure.cron"
    CRON_INSTALL_CALLED="$TMP/monitor-read-failure.install"
    mkdir -p "$(dirname "$LOCAL_SCRIPT")"
    printf '#!/bin/bash\n' > "$LOCAL_SCRIPT"
    chmod 755 "$LOCAL_SCRIPT"
    printf '15 3 * * * /usr/local/bin/keep-existing\n' > "$CRON_CAPTURE"
    self_ensure_local_runner() { return 0; }
    crontab() {
        case "${1:-}" in
            -l)
                echo "permission denied while reading crontab" >&2
                return 1
                ;;
            *)
                : > "$CRON_INSTALL_CALLED"
                return 0
                ;;
        esac
    }
    ! monitor_alert_install_cron >/dev/null 2>&1 \
        || { echo "Monitor cron overwrote state after a crontab read error" >&2; exit 1; }
    grep -qx '15 3 \* \* \* /usr/local/bin/keep-existing' "$CRON_CAPTURE" \
        || { echo "Crontab read failure changed the prior table" >&2; exit 1; }
    [ ! -e "$CRON_INSTALL_CALLED" ] \
        || { echo "Crontab read failure still attempted an install" >&2; exit 1; }
)
(
    LOCAL_SCRIPT="$TMP/missing-monitor-runner"
    SVC_PATH=""
    self_ensure_local_runner() { return 1; }
    crontab() { echo "crontab must not run when runner preparation fails" >&2; return 1; }
    ! monitor_alert_install_cron >/dev/null 2>&1 \
        || { echo "Monitor cron hid local runner preparation failure" >&2; exit 1; }
)

# DDNS cron write errors must propagate.
(
    crontab() { return 1; }
    ! ddns_install_cron_job '* * * * * /root/ddns.sh' >/dev/null 2>&1 \
        || { echo "DDNS cron helper hid a write failure" >&2; exit 1; }
)
(
    CRONTAB_DATA="$TMP/ddns-cron-start"
    : > "$CRONTAB_DATA"
    crontab() {
        if [ "${1:-}" = -l ]; then cat "$CRONTAB_DATA"; elif [ "${1:-}" = - ]; then cat > "$CRONTAB_DATA"; else cp "$1" "$CRONTAB_DATA"; fi
    }
    ddns_start_cron_service() { return 1; }
    ! ddns_install_cron_job '* * * * * /root/ddns.sh # VPS_TOOLS_DDNS' >/dev/null 2>&1 \
        || { echo "DDNS cron helper accepted a stopped daemon" >&2; exit 1; }
    ! grep -Fq VPS_TOOLS_DDNS "$CRONTAB_DATA" || { echo "DDNS cron startup failure left a managed job" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-status-script"
    : > "$DDNS_SCRIPT"
    crontab() { [ "${1:-}" = -l ] && printf '* * * * * %s %s\n' "$DDNS_SCRIPT" "$DDNS_CRON_MARKER"; }
    ddns_cron_service_running() { return 1; }
    [ "$(ddns_status)" = cron_stopped ] || { echo "DDNS status hid a stopped cron daemon" >&2; exit 1; }
)

# DDNS local configuration changes must be fully reversible, including root crontab.
(
    DDNS_TX_TEST="$TMP/ddns-transaction"
    mkdir -p "$DDNS_TX_TEST"
    DDNS_SCRIPT="$DDNS_TX_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TX_TEST/cf-token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TX_TEST/huawei-keys"
    DDNS_ZONE_FILE="$DDNS_TX_TEST/zone"
    CRONTAB_DATA="$DDNS_TX_TEST/crontab"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-keys\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'old-zone\n' > "$DDNS_ZONE_FILE"
    printf '5 * * * * /usr/local/bin/unrelated\n' > "$CRONTAB_DATA"
    crontab() {
        if [ "${1:-}" = -l ]; then
            cat "$CRONTAB_DATA"
        elif [ "${1:-}" = - ]; then
            cat > "$CRONTAB_DATA"
        else
            cp "$1" "$CRONTAB_DATA"
        fi
    }
    ddns_install_tx_begin || { echo "DDNS transaction snapshot failed" >&2; exit 1; }
    printf 'new-script\n' > "$DDNS_SCRIPT"
    printf 'new-token\n' > "$DDNS_TOKEN_FILE"
    rm -f "$DDNS_HUAWEI_KEY_FILE"
    printf 'new-zone\n' > "$DDNS_ZONE_FILE"
    printf 'managed-cron\n' > "$CRONTAB_DATA"
    ddns_install_tx_restore || { echo "DDNS transaction rollback failed" >&2; exit 1; }
    grep -qx old-script "$DDNS_SCRIPT" || { echo "DDNS rollback did not restore the script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "DDNS rollback did not restore the Cloudflare token" >&2; exit 1; }
    grep -qx old-keys "$DDNS_HUAWEI_KEY_FILE" || { echo "DDNS rollback did not restore Huawei credentials" >&2; exit 1; }
    grep -qx old-zone "$DDNS_ZONE_FILE" || { echo "DDNS rollback did not restore provider config" >&2; exit 1; }
    grep -Fq /usr/local/bin/unrelated "$CRONTAB_DATA" || { echo "DDNS rollback did not restore crontab" >&2; exit 1; }
)

# Failed provider test runs must restore the previously working local configuration.
(
    DDNS_TEST="$TMP/ddns-cloudflare-rollback"
    mkdir -p "$DDNS_TEST"
    DDNS_SCRIPT="$DDNS_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TEST/cf-token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TEST/huawei-keys"
    DDNS_ZONE_FILE="$DDNS_TEST/zone"
    # shellcheck disable=SC2034 # consumed by the sourced DDNS installer
    DDNS_LOG="$DDNS_TEST/ddns.log"
    CRONTAB_DATA="$DDNS_TEST/crontab"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-huawei\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'PROVIDER=huawei\n' > "$DDNS_ZONE_FILE"
    printf '*/5 * * * * old-ddns\n' > "$CRONTAB_DATA"
    ddns_ensure_cron() { return 0; }
    ddns_start_cron_service() { return 0; }
    ddns_fetch_public_ip() { echo 198.51.100.10; }
    crontab() {
        if [ "${1:-}" = -l ]; then cat "$CRONTAB_DATA"; elif [ "${1:-}" = - ]; then cat > "$CRONTAB_DATA"; else cp "$1" "$CRONTAB_DATA"; fi
    }
    curl() {
        case "$*" in
            *'/zones?name=example.com'*) printf '%s\n' '{"success":true,"result":[{"id":"zone-id"}]}' ;;
            *'/dns_records?'*) printf '%s\n' '{"success":true,"result":[{"id":"record-id","type":"A","name":"home.example.com","content":"198.51.100.10"}]}' ;;
            *) return 1 ;;
        esac
    }
    bash() { [ "${1:-}" = -n ]; }
    ! ddns_install_cloudflare <<'EOF' >/dev/null 2>&1 || { echo "Cloudflare failed test run returned success" >&2; exit 1; }
example.com

home

token




EOF
    grep -qx old-script "$DDNS_SCRIPT" || { echo "Cloudflare failure did not restore the old script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "Cloudflare failure did not restore the old token" >&2; exit 1; }
    grep -qx old-huawei "$DDNS_HUAWEI_KEY_FILE" || { echo "Cloudflare failure removed Huawei credentials too early" >&2; exit 1; }
    grep -qx 'PROVIDER=huawei' "$DDNS_ZONE_FILE" || { echo "Cloudflare failure did not restore provider config" >&2; exit 1; }
    grep -Fq old-ddns "$CRONTAB_DATA" || { echo "Cloudflare failure did not restore crontab" >&2; exit 1; }
)
(
    DDNS_TEST="$TMP/ddns-huawei-rollback"
    mkdir -p "$DDNS_TEST"
    DDNS_SCRIPT="$DDNS_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TEST/cf-token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TEST/huawei-keys"
    DDNS_ZONE_FILE="$DDNS_TEST/zone"
    # shellcheck disable=SC2034 # consumed by the sourced DDNS installer
    DDNS_LOG="$DDNS_TEST/ddns.log"
    CRONTAB_DATA="$DDNS_TEST/crontab"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-huawei\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'PROVIDER=cloudflare\n' > "$DDNS_ZONE_FILE"
    printf '*/5 * * * * old-ddns\n' > "$CRONTAB_DATA"
    ddns_ensure_cron() { return 0; }
    ddns_start_cron_service() { return 0; }
    crontab() {
        if [ "${1:-}" = -l ]; then cat "$CRONTAB_DATA"; elif [ "${1:-}" = - ]; then cat > "$CRONTAB_DATA"; else cp "$1" "$CRONTAB_DATA"; fi
    }
    bash() { [ "${1:-}" = -n ]; }
    ! ddns_install_huawei <<'EOF' >/dev/null 2>&1 || { echo "Huawei failed test run returned success" >&2; exit 1; }
example.com


home

test-ak
test-sk



EOF
    grep -qx old-script "$DDNS_SCRIPT" || { echo "Huawei failure did not restore the old script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "Huawei failure removed Cloudflare credentials too early" >&2; exit 1; }
    grep -qx old-huawei "$DDNS_HUAWEI_KEY_FILE" || { echo "Huawei failure did not restore AK/SK" >&2; exit 1; }
    grep -qx 'PROVIDER=cloudflare' "$DDNS_ZONE_FILE" || { echo "Huawei failure did not restore provider config" >&2; exit 1; }
    grep -Fq old-ddns "$CRONTAB_DATA" || { echo "Huawei failure did not restore crontab" >&2; exit 1; }
)

# PID-lock fallback must recover stale locks and return 75 for a live owner.
DDNS_LOCK_HELPER="$TMP/ddns-lock-helper.sh"
awk 'p{print} /^acquire_lock\(\) \{/{p=1; print; next} p && /^}$/{exit}' "$ROOT/SSH-Hardening.sh" > "$DDNS_LOCK_HELPER"
(
    # shellcheck source=/dev/null
    source "$DDNS_LOCK_HELPER"
    LOCK_FILE="$TMP/ddns-stale.lockfile"
    LOCK_DIR="$TMP/ddns-stale.lock"
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then return 1; fi
        builtin command "$@"
    }
    mkdir -p "$LOCK_DIR"
    printf '99999999\n' > "$LOCK_DIR/pid"
    acquire_lock || { echo "DDNS did not recover a stale PID lock" >&2; exit 1; }
    grep -qx "$$" "$LOCK_DIR/pid" || { echo "DDNS stale lock owner was not replaced" >&2; exit 1; }
)
(
    # shellcheck source=/dev/null
    source "$DDNS_LOCK_HELPER"
    # shellcheck disable=SC2034 # consumed by the extracted acquire_lock helper
    LOCK_FILE="$TMP/ddns-live.lockfile"
    LOCK_DIR="$TMP/ddns-live.lock"
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then return 1; fi
        builtin command "$@"
    }
    mkdir -p "$LOCK_DIR"
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    if acquire_lock; then
        echo "DDNS accepted a live PID lock" >&2
        exit 1
    else
        RC=$?
    fi
    [ "$RC" -eq 75 ] || { echo "DDNS live lock did not return 75" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-running-script"
    DDNS_ZONE_FILE="$TMP/ddns-running-zone"
    cat > "$DDNS_SCRIPT" <<'EOF'
DOMAIN4="v4.example.com"
DOMAIN6=""
ENABLE_A="true"
ENABLE_AAAA="false"
EOF
    cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=
ENABLE_A=true
ENABLE_AAAA=false
EOF
    bash() { return 75; }
    OUTPUT=$(ddns_run_now)
    grep -Fq '已有一次 DDNS 更新正在运行' <<< "$OUTPUT" || { echo "DDNS manual run hid lock contention" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-dual-run-script"
    DDNS_ZONE_FILE="$TMP/ddns-dual-run-zone"
    DDNS_STATE_DIR="$TMP/ddns-dual-run-state"
    mkdir -p "$DDNS_STATE_DIR"
    cat > "$DDNS_SCRIPT" <<'EOF'
DOMAIN4="v4.example.com"
DOMAIN6="v6.example.com"
ENABLE_A="true"
ENABLE_AAAA="true"
EOF
    cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=v6.example.com
ENABLE_A=true
ENABLE_AAAA=true
EOF
    bash() {
        touch -d '1 second ago' "$RUN_MARK"
        printf '2026-08-02 12:00:00|A|v4.example.com|unchanged|198.51.100.10|198.51.100.10\n' > "$DDNS_STATE_DIR/.cf_last_status_A"
        printf '2026-08-02 12:00:01|AAAA|v6.example.com|updated|2001:4860::1|2001:4860::2\n' > "$DDNS_STATE_DIR/.cf_last_status_AAAA"
    }
    OUTPUT=$(ddns_run_now)
    grep -Fq '本次 IPv4:' <<< "$OUTPUT" || { echo "DDNS manual dual-stack run hid IPv4 status" >&2; exit 1; }
    grep -Fq 'A v4.example.com 未变化 198.51.100.10' <<< "$OUTPUT" || { echo "DDNS manual dual-stack IPv4 result is wrong" >&2; exit 1; }
    grep -Fq '本次 IPv6:' <<< "$OUTPUT" || { echo "DDNS manual dual-stack run hid IPv6 status" >&2; exit 1; }
    grep -Fq 'AAAA v6.example.com 更新成功 2001:4860::1 → 2001:4860::2' <<< "$OUTPUT" || { echo "DDNS manual dual-stack IPv6 result is wrong" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-mismatch-script"
    DDNS_ZONE_FILE="$TMP/ddns-mismatch-zone"
    cat > "$DDNS_SCRIPT" <<'EOF'
DOMAIN4=""
DOMAIN6="v6.example.com"
ENABLE_A="false"
ENABLE_AAAA="true"
EOF
    cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=v6.example.com
ENABLE_A=true
ENABLE_AAAA=true
EOF
    bash() { echo "runtime should not execute" >&2; return 1; }
    ! ddns_run_now >/dev/null 2>&1 || { echo "DDNS manual run accepted stale runtime config" >&2; exit 1; }
)

# Pause and uninstall must preserve DDNS when crontab removal fails.
(
    DDNS_SCRIPT="$TMP/ddns-preserve.sh"
    DDNS_TOKEN_FILE="$TMP/ddns-preserve-token"
    DDNS_HUAWEI_KEY_FILE="$TMP/ddns-preserve-huawei"
    DDNS_ZONE_FILE="$TMP/ddns-preserve-zone"
    : > "$DDNS_SCRIPT"
    : > "$DDNS_TOKEN_FILE"
    : > "$DDNS_HUAWEI_KEY_FILE"
    : > "$DDNS_ZONE_FILE"
    ddns_remove_cron_job() { return 1; }
    ! ddns_pause >/dev/null 2>&1 || { echo "DDNS pause ignored crontab removal failure" >&2; exit 1; }
    ! ddns_uninstall <<< y >/dev/null 2>&1 || { echo "DDNS uninstall ignored crontab removal failure" >&2; exit 1; }
    [ -f "$DDNS_SCRIPT" ] && [ -f "$DDNS_TOKEN_FILE" ] && [ -f "$DDNS_HUAWEI_KEY_FILE" ] && [ -f "$DDNS_ZONE_FILE" ] \
        || { echo "DDNS uninstall deleted files after crontab failure" >&2; exit 1; }
)

# Failed DDNS reconfiguration must restore the previous provider, script and credentials.
(
    DDNS_TEST="$TMP/ddns-transaction"
    mkdir -p "$DDNS_TEST/state"
    DDNS_SCRIPT="$DDNS_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TEST/cf_token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TEST/huawei_key"
    DDNS_ZONE_FILE="$DDNS_TEST/zone"
    DDNS_LOG="$DDNS_TEST/ddns.log"
    DDNS_STATE_DIR="$DDNS_TEST/state"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-huawei-key\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'PROVIDER=cloudflare\n' > "$DDNS_ZONE_FILE"
    ddns_ensure_cron() { return 0; }
    ddns_start_cron_service() { return 0; }
    bash() { return 1; }
    if ddns_install_huawei <<'EOF' >/dev/null 2>&1; then
example.com


home

test-ak
test-sk



EOF
        echo "Broken Huawei DDNS configuration unexpectedly succeeded" >&2
        exit 1
    fi
    grep -qx old-script "$DDNS_SCRIPT" || { echo "DDNS rollback did not restore the old script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "DDNS rollback did not restore the Cloudflare token" >&2; exit 1; }
    grep -qx old-huawei-key "$DDNS_HUAWEI_KEY_FILE" || { echo "DDNS rollback did not restore the Huawei credentials" >&2; exit 1; }
    grep -qx PROVIDER=cloudflare "$DDNS_ZONE_FILE" || { echo "DDNS rollback did not restore the provider config" >&2; exit 1; }
)

# Installation and update paths must not trust or recreate fixed files in the shared /tmp directory.
! grep -Fq '/tmp/ssh_hardening.sh' "$ROOT/src/modules/self-update.sh" \
    || { echo "Installer still trusts the shared /tmp cache" >&2; exit 1; }
! grep -Fq '/tmp/vps_update_$$' "$ROOT/src/modules/self-update.sh" \
    || { echo "Updater still uses predictable temporary files" >&2; exit 1; }
! grep -Fq '/tmp/.vps_new_version' "$ROOT/src/modules/main.sh" "$ROOT/src/modules/self-update.sh" \
    || { echo "Update notice still uses a shared /tmp path" >&2; exit 1; }

# This maintained fork must install and self-update from its own release files.
FORK_REPO='TonyJsonson-8748/SSH-Hardening'
grep -Fq "$FORK_REPO" "$ROOT/README.md" "$ROOT/build.sh" "$ROOT/src/modules/self-update.sh" \
    || { echo "Maintained fork release source is missing" >&2; exit 1; }
! grep -Fq 'chnnic/SSH-Hardening' "$ROOT/build.sh" "$ROOT/src/modules/self-update.sh" \
    || { echo "Installer or updater still points to the upstream repository" >&2; exit 1; }

# Cross-type Cloudflare records must never be deleted without explicit confirmation.
(
    CF_DELETE_LOG="$TMP/cloudflare-delete.log"
    curl() {
        case "$*" in
            *" -X DELETE "*) printf '%s\n' "$*" >> "$CF_DELETE_LOG"; printf '%s\n' '{"success":true}' ;;
            *) printf '%s\n' '{"success":true,"result":[{"id":"stale-aaaa","type":"AAAA","name":"v4.example.com","content":"2001:db8::4"}]}' ;;
        esac
    }
    ddns_cf_cleanup_cross_record zone token AAAA v4.example.com "测试交叉记录" <<< "" >/dev/null
    [ ! -s "$CF_DELETE_LOG" ] || { echo "DDNS deleted a cross-type record without confirmation" >&2; exit 1; }
    ddns_cf_cleanup_cross_record zone token AAAA v4.example.com "测试交叉记录" <<< "y" >/dev/null
    grep -Fq '/dns_records/stale-aaaa' "$CF_DELETE_LOG" || { echo "DDNS confirmed cross-type cleanup did not delete the selected record" >&2; exit 1; }
)

# Swap deletion must stop before touching fstab/files when swapoff fails.
(
    print_header() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    swapon() {
        case "$*" in
            '--show --noheadings') echo '/tmp/vps-tools-test.swap' ;;
            '--show --bytes --noheadings') echo '/tmp/vps-tools-test.swap file 1048576 0 -2' ;;
        esac
    }
    swapoff() { return 1; }
    ! swap_delete <<< $'1\ny' >/dev/null 2>&1 || { echo "Swap delete ignored swapoff failure" >&2; exit 1; }
)

# NTP enablement must report a timedatectl failure.
(
    print_header() { :; }
    info() { :; }
    error() { :; }
    sleep() { :; }
    timedatectl() { [ "${1:-}" = show ] && echo yes && return 0; return 1; }
    systemctl() {
        case "$1" in
            list-unit-files) echo 'systemd-timesyncd.service enabled'; return 0 ;;
            *) return 0 ;;
        esac
    }
    ! ts_enable_ntp >/dev/null 2>&1 || { echo "NTP enablement hid timedatectl failure" >&2; exit 1; }
)

# Multi-IP source switching must arm an exact route rollback and restore on verification failure.
(
    VPS_DATA_DIR="$TMP/ip-source-safety"
    mkdir -p "$VPS_DATA_DIR"
    audit_action() { :; }
    warn() { :; }
    nohup() { return 0; }
    ip_source_safety_arm 4 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' >/dev/null
    grep -Fq 'ip -4 route replace default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' "$SAFETY_SCRIPT" \
        || { echo "Multi-IP safety timer did not preserve the original route" >&2; exit 1; }
    cancel_safety_timer
)
(
    APPLIED=0
    RESTORED=0
    print_header() { :; }
    menu_div() { :; }
    menu_item() { :; }
    ui_prompt() { printf '%s' "$1"; }
    error() { :; }
    warn() { :; }
    confirm_change_preview() { return 0; }
    ip_source_default_iface() { echo eth0; }
    ip_source_default_route() { echo 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100'; }
    ip_source_addresses() { printf '%s\n' 198.51.100.10 198.51.100.11; }
    ip_source_current() { echo 198.51.100.10; }
    ip_source_safety_arm() { return 0; }
    ip_source_route_replace() { APPLIED=1; }
    ip_source_verify() { return 1; }
    ip_source_route_restore() { RESTORED=1; }
    cancel_safety_timer() { :; }
    ! ip_source_switch_family 4 <<< 2 >/dev/null 2>&1 \
        || { echo "Multi-IP switch accepted a failed HTTPS verification" >&2; exit 1; }
    [ "$APPLIED" -eq 1 ] || { echo "Multi-IP switch did not apply the selected route" >&2; exit 1; }
    [ "$RESTORED" -eq 1 ] || { echo "Multi-IP switch did not restore the route after verification failure" >&2; exit 1; }
)

# HTTPS synchronization must not set the clock without enough trusted responses.
(
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by ts_sync_https
    ts_https_fetch_epoch() { return 1; }
    ! ts_sync_https fallback >/dev/null 2>&1 || { echo "HTTPS time sync accepted zero valid sources" >&2; exit 1; }
)

# HTTPS scheduling must render, activate, replace, and remove a systemd timer safely.
(
    SCHEDULE_DIR="$TMP/https-systemd"
    mkdir -p "$SCHEDULE_DIR/data"
    VPS_DATA_DIR="$SCHEDULE_DIR/data"
    LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
    TS_HTTPS_SERVICE_FILE="$SCHEDULE_DIR/vps-tools-https-time.service"
    TS_HTTPS_TIMER_FILE="$SCHEDULE_DIR/vps-tools-https-time.timer"
    TS_HTTPS_INTERVAL_FILE="$SCHEDULE_DIR/data/interval"
    TS_HTTPS_STATE_FILE="$SCHEDULE_DIR/data/state"
    TS_HTTPS_LOCK_FILE="$SCHEDULE_DIR/data/lock"
    SYSTEMCTL_LOG="$SCHEDULE_DIR/systemctl.log"
    systemd_available() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
        [ "${1:-}" = is-active ] && return 0
        return 0
    }
    ts_https_scheduled_run() { return 0; }
    ts_https_schedule_enable 3 >/dev/null || { echo "HTTPS systemd schedule creation failed" >&2; exit 1; }
    grep -q '^OnUnitActiveSec=3h$' "$TS_HTTPS_TIMER_FILE" || { echo "HTTPS systemd interval is wrong" >&2; exit 1; }
    grep -Fq "ExecStart=$LOCAL_SCRIPT --https-time-sync-run" "$TS_HTTPS_SERVICE_FILE" || { echo "HTTPS systemd command is wrong" >&2; exit 1; }
    grep -q '^3$' "$TS_HTTPS_INTERVAL_FILE" || { echo "HTTPS systemd interval state is missing" >&2; exit 1; }
    [ "$(ts_https_schedule_backend)" = systemd ] || { echo "HTTPS systemd schedule status is wrong" >&2; exit 1; }
    ts_https_schedule_disable >/dev/null
    [ ! -e "$TS_HTTPS_TIMER_FILE" ] && [ ! -e "$TS_HTTPS_SERVICE_FILE" ] || { echo "HTTPS systemd schedule was not removed" >&2; exit 1; }
)

# Non-systemd systems must use root crontab without deleting unrelated entries.
(
    SCHEDULE_DIR="$TMP/https-cron"
    mkdir -p "$SCHEDULE_DIR/data"
    VPS_DATA_DIR="$SCHEDULE_DIR/data"
    LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
    TS_HTTPS_SERVICE_FILE="$SCHEDULE_DIR/vps-tools-https-time.service"
    TS_HTTPS_TIMER_FILE="$SCHEDULE_DIR/vps-tools-https-time.timer"
    TS_HTTPS_INTERVAL_FILE="$SCHEDULE_DIR/data/interval"
    TS_HTTPS_STATE_FILE="$SCHEDULE_DIR/data/state"
    TS_HTTPS_LOCK_FILE="$SCHEDULE_DIR/data/lock"
    CRONTAB_DATA="$SCHEDULE_DIR/crontab"
    printf '5 4 * * * /usr/local/bin/unrelated\n' > "$CRONTAB_DATA"
    systemd_available() { return 1; }
    systemctl() { return 1; }
    crontab() {
        if [ "${1:-}" = -l ]; then
            cat "$CRONTAB_DATA"
        else
            cp "$1" "$CRONTAB_DATA"
        fi
    }
    ts_https_cron_daemon_enable() { return 0; }
    ts_https_scheduled_run() { return 0; }
    ts_https_schedule_enable 12 >/dev/null || { echo "HTTPS cron schedule creation failed" >&2; exit 1; }
    grep -Fq '17 */12 * * *' "$CRONTAB_DATA" || { echo "HTTPS cron interval is wrong" >&2; exit 1; }
    grep -Fq "$TS_HTTPS_CRON_MARKER" "$CRONTAB_DATA" || { echo "HTTPS cron marker is missing" >&2; exit 1; }
    grep -Fq '/usr/local/bin/unrelated' "$CRONTAB_DATA" || { echo "HTTPS cron replaced an unrelated entry" >&2; exit 1; }
    [ "$(ts_https_schedule_backend)" = cron ] || { echo "HTTPS cron schedule status is wrong" >&2; exit 1; }
    ts_https_schedule_disable >/dev/null
    ! grep -Fq "$TS_HTTPS_CRON_MARKER" "$CRONTAB_DATA" || { echo "HTTPS cron schedule was not removed" >&2; exit 1; }
    grep -Fq '/usr/local/bin/unrelated' "$CRONTAB_DATA" || { echo "HTTPS cron removal deleted an unrelated entry" >&2; exit 1; }
    ts_https_cron_daemon_enable() { return 1; }
    ! ts_https_schedule_enable_cron 6 >/dev/null 2>&1 || { echo "HTTPS cron accepted a stopped daemon" >&2; exit 1; }
    ! grep -Fq "$TS_HTTPS_CRON_MARKER" "$CRONTAB_DATA" || { echo "HTTPS cron daemon failure left a managed entry" >&2; exit 1; }
)

# Scheduled failures must be persisted for the status screen.
(
    VPS_DATA_DIR="$TMP/https-state"
    TS_HTTPS_STATE_FILE="$VPS_DATA_DIR/state"
    TS_HTTPS_LOCK_FILE="$VPS_DATA_DIR/lock"
    ts_sync_https() { return 1; }
    logger() { :; }
    ! ts_https_scheduled_run >/dev/null 2>&1 || { echo "HTTPS scheduled failure was hidden" >&2; exit 1; }
    grep -Fq $'\t失败\tHTTPS' "$TS_HTTPS_STATE_FILE" || { echo "HTTPS scheduled failure state is missing" >&2; exit 1; }
)

# Interactive scheduled runs must release the flock descriptor before returning.
(
    VPS_DATA_DIR="$TMP/https-flock"
    TS_HTTPS_STATE_FILE="$VPS_DATA_DIR/state"
    TS_HTTPS_LOCK_FILE="$VPS_DATA_DIR/lock"
    FLOCK_RELEASED="$VPS_DATA_DIR/flock.released"
    mkdir -p "$VPS_DATA_DIR"
    ts_sync_https() { return 0; }
    logger() { :; }
    flock() {
        [ "${1:-}" != -u ] || : > "$FLOCK_RELEASED"
        return 0
    }
    ts_https_scheduled_run >/dev/null \
        || { echo "HTTPS scheduled run failed while testing lock release" >&2; exit 1; }
    [ -f "$FLOCK_RELEASED" ] \
        || { echo "HTTPS scheduled run did not release the flock descriptor" >&2; exit 1; }
)

# Offline bundle creation must package a local script and offline install must place it at the target path.
LOCAL_SCRIPT="$TMP/local-script"
cp "$ROOT/SSH-Hardening.sh" "$LOCAL_SCRIPT"
chmod 700 "$LOCAL_SCRIPT"
if ! self_offline_bundle_create >/dev/null; then
    echo "Offline bundle creation failed" >&2
    exit 1
fi
OFFLINE_BUNDLE=$(find "$VPS_DATA_DIR/offline" -type f -name '*.tar.gz' | head -1)
[ -f "$OFFLINE_BUNDLE" ] || { echo "Offline bundle was not created" >&2; exit 1; }
LOCAL_BIN_DIR="$TMP/bin"
LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
self_offline_bundle_install "$OFFLINE_BUNDLE" >/dev/null || { echo "Offline install failed" >&2; exit 1; }
[ -f "$LOCAL_SCRIPT" ] || { echo "Offline install did not place script" >&2; exit 1; }
[ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Offline install did not create an isolated shortcut" >&2; exit 1; }

# Process-substitution descriptors are streams, not complete reusable script files.
if self_resolve_script_source /dev/fd/0 >/dev/null 2>&1; then
    echo "Installer accepted a process-substitution descriptor as a complete script" >&2
    exit 1
fi
BROKEN_LINK_TARGET="$TMP/removed-script.sh"
rm -f "$LOCAL_BIN_DIR/v"
ln -s "$BROKEN_LINK_TARGET" "$LOCAL_BIN_DIR/v"
self_install_shortcut v >/dev/null
[ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Installer did not repair a dangling shortcut" >&2; exit 1; }
FOREIGN_SCRIPT="$TMP/foreign-command"
printf '#!/bin/sh\nexit 0\n' > "$FOREIGN_SCRIPT"
chmod +x "$FOREIGN_SCRIPT"
rm -f "$LOCAL_BIN_DIR/V"
ln -s "$FOREIGN_SCRIPT" "$LOCAL_BIN_DIR/V"
self_install_shortcut V >/dev/null
[ "$(readlink "$LOCAL_BIN_DIR/V")" = "$FOREIGN_SCRIPT" ] || { echo "Installer overwrote a foreign shortcut" >&2; exit 1; }

# The real updater must reject a mismatched checksum without replacing the local script.
LOCAL_SCRIPT="$LOCAL_BIN_DIR/vps-tools"
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

# Post-update tc reconciliation must execute the newly installed script, not a function from the old process.
TC_STATE_FILE="$TMP/update-tc.state"
LOCAL_SCRIPT="$TMP/newly-installed-vps-tools"
UPDATE_TC_MARKER="$TMP/update-tc.marker"
export UPDATE_TC_MARKER
printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$TC_STATE_FILE"
cat > "$LOCAL_SCRIPT" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--bbr-reconcile-tc" ] || exit 1
[ "${VPS_TOOLS_TEST_MODE:-}" = 0 ] || exit 1
[ "${BBR_TUNE_TEST_MODE:-}" = 0 ] || exit 1
: > "$UPDATE_TC_MARKER"
EOF
chmod +x "$LOCAL_SCRIPT"
self_reconcile_tc_after_update >/dev/null \
    || { echo "Updater could not invoke the new tc reconciliation endpoint" >&2; exit 1; }
[ -f "$UPDATE_TC_MARKER" ] \
    || { echo "Updater reconciled tc through the old process" >&2; exit 1; }

echo "Fault injection tests passed."

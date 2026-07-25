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
grep -Fq 'restart fail2ban' "$ROOT/src/modules/toolbox.sh" \
    || { echo "Safety rollback does not reload restored Fail2ban configuration" >&2; exit 1; }

# DDNS cron write errors must propagate.
(
    crontab() { return 1; }
    ! ddns_install_cron_job '* * * * * /root/ddns.sh' >/dev/null 2>&1 \
        || { echo "DDNS cron helper hid a write failure" >&2; exit 1; }
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

# Offline bundle creation must package a local script and offline install must place it at the target path.
LOCAL_SCRIPT="$TMP/local-script"
cat > "$LOCAL_SCRIPT" <<'EOF'
#!/bin/bash
echo offline
EOF
chmod 700 "$LOCAL_SCRIPT"
if ! self_offline_bundle_create >/dev/null; then
    echo "Offline bundle creation failed" >&2
    exit 1
fi
OFFLINE_BUNDLE=$(find "$VPS_DATA_DIR/offline" -type f -name '*.tar.gz' | head -1)
[ -f "$OFFLINE_BUNDLE" ] || { echo "Offline bundle was not created" >&2; exit 1; }
LOCAL_SCRIPT="$TMP/installed-script.sh"
LOCAL_BIN_DIR="$TMP/bin"
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

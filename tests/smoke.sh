#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"

for fn in systemd_available show_cli_help main_menu ssh_tools_menu ssh_key_count show_keys add_key delete_key generate_key set_login_mode ssh_account_record ssh_key_target_allowed ssh_expand_authorized_keys_path ssh_authorized_keys_paths_for_user ssh_authorized_keys_path_for_user ssh_public_key_line_valid ssh_public_key_line_fields ssh_public_key_target_resolve ssh_public_key_install ssh_key_inventory ssh_key_inventory_line_matches ssh_key_file_restore ssh_key_delete_safety_arm ssh_key_delete_confirm_new_session ssh_strict_auth_methods_allow_pubkey ssh_strict_effective_policy_ok ssh_strict_access_policy_allows ssh_strict_find_candidates ssh_strict_candidate_valid ssh_authentication_route ssh_login_route_for_user ssh_login_candidates ssh_login_candidates_have_admin ssh_user_has_full_sudo_access ssh_user_can_admin revoke_user_ssh_login user_management_menu user_require_root user_name_valid user_create_account user_grant_admin user_promote_admin user_revoke_admin user_revoke_admin_rights user_is_admin_account user_has_sudo_access user_change_password user_password_target_allowed user_delete_account user_delete_system_account user_home_safe_to_remove user_home_is_shared fail2ban_menu f2b_effective_ssh_port f2b_sync_ssh_port bbr_menu firewall_menu dns_menu timesync_menu \
    ts_https_date_epoch ts_epoch_utc ts_https_fetch_epoch ts_https_consensus ts_sync_https \
    ts_https_interval_normalize ts_https_interval_current ts_https_cron_expr ts_https_cron_without_managed \
    ts_https_schedule_backend ts_https_schedule_last_result ts_https_schedule_summary ts_https_runner_valid ts_https_runner_path_valid ts_https_ensure_runner ts_https_scheduled_run ts_https_schedule_enable_systemd ts_https_schedule_enable_cron ts_https_cron_daemon_enable ts_https_schedule_remove_cron ts_https_schedule_enable ts_https_schedule_disable ts_https_schedule_menu \
    ip_config_menu caddy_menu caddy_site_records caddy_site_count nft_menu ddns_menu ddns_install ddns_install_cloudflare ddns_install_huawei ddns_run_now ddns_view_logs ddns_status ddns_share_link_tool \
    ddns_provider ddns_provider_label ddns_sed_escape ddns_install_transaction_begin ddns_install_transaction_restore ddns_install_transaction_commit ddns_domain_dot ddns_ipv6_subdomain_default ddns_cf_exact_records ddns_cf_record_ensure ddns_cf_cleanup_cross_record \
    ddns_interval_normalize ddns_interval_min ddns_cron_expr ddns_cron_without_managed ddns_prompt_interval \
    ddns_cfg_enable_a ddns_cfg_enable_aaaa ddns_cfg_domain4 ddns_cfg_domain6 ddns_primary_domain ddns_mode_label ddns_build_domain ddns_replace_link_host \
    ddns_latest_log_line ddns_latest_change_log_line ddns_line_time ddns_line_result_ip ddns_newer_line ddns_change_matches_status ddns_record_status_line ddns_record_change_line ddns_print_record_summary \
    system_toolbox_menu security_password_auth_effective security_password_methods_disabled security_root_password_restricted \
    resource_health_check system_update_manager system_hostname_apply config_backup_create safety_load_pending safety_lock_acquire safety_lock_release self_update docker_menu change_port \
    ssh_socket_activated ssh_socket_override_backup ssh_socket_override_restore ssh_socket_override_write \
    ssh_sudo_list_grants_full_root; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

STRICT_HOME="$TMP/strict-home"
mkdir -p "$STRICT_HOME/.ssh"
ssh_key_target_allowed tony 1000 "$STRICT_HOME" /bin/bash \
    || { echo "Regular SSH key target was rejected" >&2; exit 1; }
! ssh_key_target_allowed root 1000 "$STRICT_HOME" /bin/bash >/dev/null 2>&1 \
    || { echo "Non-root UID using the root name was accepted" >&2; exit 1; }
! ssh_key_target_allowed daemon 1 "$STRICT_HOME" /bin/bash >/dev/null 2>&1 \
    || { echo "System account was accepted as an SSH key target" >&2; exit 1; }
! ssh_key_target_allowed tony 1000 "$STRICT_HOME" /usr/sbin/nologin >/dev/null 2>&1 \
    || { echo "Nologin account was accepted as an SSH key target" >&2; exit 1; }
[[ "$(ssh_expand_authorized_keys_path '.ssh/authorized_keys' tony 1000 "$STRICT_HOME")" \
    = "$STRICT_HOME/.ssh/authorized_keys" ]] \
    || { echo "Relative AuthorizedKeysFile expansion failed" >&2; exit 1; }
[[ "$(ssh_expand_authorized_keys_path '/etc/ssh/keys/%u-%U' tony 1000 "$STRICT_HOME")" \
    = "/etc/ssh/keys/tony-1000" ]] \
    || { echo "AuthorizedKeysFile token expansion failed" >&2; exit 1; }
! ssh_expand_authorized_keys_path '%x/authorized_keys' tony 1000 "$STRICT_HOME" >/dev/null 2>&1 \
    || { echo "Unknown AuthorizedKeysFile token was accepted" >&2; exit 1; }
! ssh_expand_authorized_keys_path $'.ssh/authorized\tkeys' tony 1000 "$STRICT_HOME" >/dev/null 2>&1 \
    || { echo "AuthorizedKeysFile path containing a tab was accepted" >&2; exit 1; }
ssh_strict_auth_methods_allow_pubkey any \
    || { echo "AuthenticationMethods any was rejected for strict mode" >&2; exit 1; }
ssh_strict_auth_methods_allow_pubkey 'publickey publickey,password' \
    || { echo "Publickey alternative was not recognized" >&2; exit 1; }
! ssh_strict_auth_methods_allow_pubkey 'publickey,password' >/dev/null 2>&1 \
    || { echo "Password-dependent AuthenticationMethods was accepted" >&2; exit 1; }

STRICT_POLICY_DUMP=$(cat <<'EOF'
passwordauthentication no
pubkeyauthentication yes
authenticationmethods publickey
permitrootlogin no
kbdinteractiveauthentication no
maxauthtries 3
clientaliveinterval 300
clientalivecountmax 2
x11forwarding no
EOF
)
ssh_strict_effective_policy_ok "$STRICT_POLICY_DUMP" \
    || { echo "Valid strict SSH policy was rejected" >&2; exit 1; }
! ssh_strict_effective_policy_ok "${STRICT_POLICY_DUMP/permitrootlogin no/permitrootlogin prohibit-password}" \
    >/dev/null 2>&1 \
    || { echo "Strict policy accepted root key login" >&2; exit 1; }
ssh_strict_access_policy_allows "${STRICT_POLICY_DUMP}"$'\n''allowusers tony' tony \
    || { echo "Allowed strict SSH user was rejected" >&2; exit 1; }
! ssh_strict_access_policy_allows "${STRICT_POLICY_DUMP}"$'\n''denyusers tony' tony \
    >/dev/null 2>&1 \
    || { echo "Denied strict SSH user was accepted" >&2; exit 1; }
ssh_strict_access_policy_allows "${STRICT_POLICY_DUMP}"$'\n''allowusers t*' tony \
    || { echo "OpenSSH AllowUsers wildcard was not matched literally" >&2; exit 1; }
! ssh_strict_access_policy_allows "${STRICT_POLICY_DUMP}"$'\n''denyusers *' tony \
    >/dev/null 2>&1 \
    || { echo "OpenSSH DenyUsers wildcard was expanded as a filesystem glob" >&2; exit 1; }
[[ "$(ssh_authentication_route "$STRICT_POLICY_DUMP" yes locked)" = "密钥" ]] \
    || { echo "Strict public-key authentication route was not detected" >&2; exit 1; }
PASSWORD_POLICY_DUMP=${STRICT_POLICY_DUMP/passwordauthentication no/passwordauthentication yes}
PASSWORD_POLICY_DUMP=${PASSWORD_POLICY_DUMP/pubkeyauthentication yes/pubkeyauthentication no}
PASSWORD_POLICY_DUMP=${PASSWORD_POLICY_DUMP/authenticationmethods publickey/authenticationmethods any}
PASSWORD_POLICY_DUMP=${PASSWORD_POLICY_DUMP/permitrootlogin no/permitrootlogin yes}
[[ "$(ssh_authentication_route "$PASSWORD_POLICY_DUMP" no set)" = "密码" ]] \
    || { echo "Password authentication route was not detected" >&2; exit 1; }
MFA_POLICY_DUMP=${STRICT_POLICY_DUMP/passwordauthentication no/passwordauthentication yes}
MFA_POLICY_DUMP=${MFA_POLICY_DUMP/authenticationmethods publickey/authenticationmethods publickey,password}
[[ "$(ssh_authentication_route "$MFA_POLICY_DUMP" yes set)" = "密钥 + 密码" ]] \
    || { echo "Multi-factor SSH authentication route was not detected" >&2; exit 1; }
! ssh_authentication_route "$MFA_POLICY_DUMP" no set >/dev/null 2>&1 \
    || { echo "Unavailable MFA route was treated as usable" >&2; exit 1; }
ssh_login_candidates_have_admin $'root|密钥|yes\nguest|密码|no' \
    || { echo "Remaining SSH management entry was not recognized" >&2; exit 1; }
! ssh_login_candidates_have_admin 'guest|密码|no' >/dev/null 2>&1 \
    || { echo "Ordinary login was treated as a management recovery entry" >&2; exit 1; }
(
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (ALL : ALL) ALL'
    }
    ssh_user_has_full_sudo_access tony \
        || { echo "Full sudo recovery access was not recognized" >&2; exit 1; }
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (root) /usr/bin/systemctl restart ssh'
    }
    ! ssh_user_has_full_sudo_access tony >/dev/null 2>&1 \
        || { echo "Limited sudo command was treated as full recovery access" >&2; exit 1; }
)
(
    # 常规管理员的 sudo 需要输入自己的密码，无法通过 `sudo -n` 提权探测；
    # 授权查询必须仍能把它识别为完整 root 入口，否则严格模式、撤销登录和
    # 删除公钥都会误判为"没有可恢复的管理入口"而拒绝执行。
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (ALL : ALL) ALL' \
            '    (ALL) ALL'
    }
    ssh_sudo_list_grants_full_root tony \
        || { echo "Password-required full sudo admin was not recognized" >&2; exit 1; }
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (ALL : ALL) NOPASSWD: ALL'
    }
    ssh_sudo_list_grants_full_root tony \
        || { echo "NOPASSWD full sudo grant was not recognized" >&2; exit 1; }
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (root) SETENV: ALL'
    }
    ssh_sudo_list_grants_full_root tony \
        || { echo "Tagged full sudo grant was not recognized" >&2; exit 1; }
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (www-data) ALL'
    }
    ! ssh_sudo_list_grants_full_root tony >/dev/null 2>&1 \
        || { echo "Non-root RunAs grant was treated as full root access" >&2; exit 1; }
    sudo() {
        printf '%s\n' \
            'User tony may run the following commands on test-host:' \
            '    (ALL) ALL, !/bin/su'
    }
    ! ssh_sudo_list_grants_full_root tony >/dev/null 2>&1 \
        || { echo "Grant with a negated command was treated as unrestricted" >&2; exit 1; }
    sudo() {
        printf '%s\n' 'Sorry, user tony may not run sudo on test-host.'
    }
    ! ssh_sudo_list_grants_full_root tony >/dev/null 2>&1 \
        || { echo "Account without sudo access was treated as an admin" >&2; exit 1; }
    sudo() { return 1; }
    ! ssh_sudo_list_grants_full_root tony >/dev/null 2>&1 \
        || { echo "Failed sudo query was treated as full root access" >&2; exit 1; }
)

(
    ssh-keygen() {
        grep -qx 'ssh-ed25519 VALID_KEY_DATA' "$3"
    }
    ssh_public_key_line_valid 'ssh-ed25519 VALID_KEY_DATA test@example' \
        || { echo "Valid SSH public key line was rejected" >&2; exit 1; }
    ! ssh_public_key_line_valid 'ssh-ed25519 TRUNCATED test@example' >/dev/null 2>&1 \
        || { echo "Malformed SSH public key data was accepted" >&2; exit 1; }
    ! ssh_public_key_line_valid 'not-a-key VALID_KEY_DATA' >/dev/null 2>&1 \
        || { echo "Unsupported SSH public key type was accepted" >&2; exit 1; }
    KEY_FIELDS=$(ssh_public_key_line_fields \
        'command="/usr/bin/id -u",no-pty ssh-ed25519 VALID_KEY_DATA ops@example')
    IFS=$'\t' read -r FIELD_TYPE FIELD_DATA FIELD_COMMENT FIELD_OPTIONS <<< "$KEY_FIELDS"
    [[ "$FIELD_TYPE|$FIELD_DATA|$FIELD_COMMENT" \
        = 'ssh-ed25519|VALID_KEY_DATA|ops@example' ]] \
        || { echo "AuthorizedKeys options prevented public key parsing" >&2; exit 1; }
    [[ "$FIELD_OPTIONS" == *"no-pty"* ]] \
        || { echo "AuthorizedKeys options were not retained in the key inventory" >&2; exit 1; }
)

(
    ssh_effective_config_dump() {
        printf '%s\n' \
            'authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2 .ssh/authorized_keys'
    }
    EXPECTED_PATHS=$(printf '%s\n' \
        "$STRICT_HOME/.ssh/authorized_keys" \
        "$STRICT_HOME/.ssh/authorized_keys2")
    [[ "$(ssh_authorized_keys_paths_for_user /tmp/sshd tony 1000 "$STRICT_HOME")" \
        = "$EXPECTED_PATHS" ]] \
        || { echo "Multiple or duplicate AuthorizedKeysFile paths were not resolved correctly" >&2; exit 1; }
)

(
    SSH_PASSWD_FILE="$TMP/strict-passwd"
    printf '%s\n' \
        "root:x:0:0:root:/root:/bin/bash" \
        "tony:x:1000:1000::${STRICT_HOME}:/bin/bash" \
        "daemon:x:1:1::/usr/sbin:/usr/sbin/nologin" > "$SSH_PASSWD_FILE"
    printf '%s\n' 'ssh-ed25519 VALID_KEY_DATA test@example' > "$STRICT_HOME/.ssh/authorized_keys"
    ssh_effective_config_dump() {
        cat <<'EOF'
passwordauthentication no
pubkeyauthentication yes
authenticationmethods publickey
permitrootlogin no
kbdinteractiveauthentication no
maxauthtries 3
clientaliveinterval 300
clientalivecountmax 2
x11forwarding no
authorizedkeysfile .ssh/authorized_keys
EOF
    }
    ssh_strict_key_path_secure() { return 0; }
    ssh_public_key_line_valid() {
        [[ "$1" == 'ssh-ed25519 VALID_KEY_DATA test@example' ]]
    }
    ssh_user_can_admin() { [ "$1" = tony ]; }
    [[ "$(ssh_strict_find_candidates /tmp/strict-sshd-config)" \
        = "tony|$STRICT_HOME/.ssh/authorized_keys" ]] \
        || { echo "Valid non-root SSH key candidate was not detected" >&2; exit 1; }
    ! SSH_KEY_EXCLUDE_FILE="$STRICT_HOME/.ssh/authorized_keys" SSH_KEY_EXCLUDE_LINE=1 \
        ssh_strict_key_file_has_unrestricted_key "$STRICT_HOME/.ssh/authorized_keys" \
        >/dev/null 2>&1 \
        || { echo "Excluded SSH key line was still treated as a login route" >&2; exit 1; }
    printf '%s\n' 'command="/bin/false" ssh-ed25519 VALID_KEY_DATA test@example' \
        > "$STRICT_HOME/.ssh/authorized_keys"
    [ -z "$(ssh_strict_find_candidates /tmp/strict-sshd-config)" ] \
        || { echo "Restricted SSH key was accepted as a strict-mode rescue login" >&2; exit 1; }
    printf '%s\n' 'ssh-ed25519 VALID_KEY_DATA test@example' > "$STRICT_HOME/.ssh/authorized_keys"
    ssh_user_can_admin() { return 1; }
    [ -z "$(ssh_strict_find_candidates /tmp/strict-sshd-config)" ] \
        || { echo "Non-admin key user was accepted for root-disabled strict mode" >&2; exit 1; }
)

(
    SSH_PASSWD_FILE="$TMP/add-key-cancel-passwd"
    printf '%s\n' "tony:x:1000:1000::${STRICT_HOME}:/bin/bash" > "$SSH_PASSWD_FILE"
    print_header() { :; }
    menu_div() { :; }
    warn() { printf '%s\n' "$*"; }
    ADD_CANCEL_OUTPUT=$(add_key <<< "")
    [[ "$ADD_CANCEL_OUTPUT" == *"已取消，未添加公钥"* ]] \
        || { echo "Blank target did not cancel SSH key addition" >&2; exit 1; }
)

(
    INSTALL_HOME="$TMP/install-generated-key-home"
    mkdir -p "$INSTALL_HOME/.ssh"
    chmod 700 "$INSTALL_HOME" "$INSTALL_HOME/.ssh"
    SSH_KEY_TARGET_USER=tony
    SSH_KEY_TARGET_UID=$(id -u)
    SSH_KEY_TARGET_GID=$(id -g)
    SSH_KEY_TARGET_HOME="$INSTALL_HOME"
    SSH_KEY_TARGET_FILE="$INSTALL_HOME/.ssh/authorized_keys"
    SSH_KEY_TARGET_SCOPE=home
    ssh_public_key_line_valid() {
        case "$1" in
            'ssh-ed25519 EXISTING_KEY_DATA'|'ssh-ed25519 EXISTING_KEY_DATA existing@test'|\
            'ssh-ed25519 GENERATED_KEY_DATA'|'ssh-ed25519 GENERATED_KEY_DATA generated@test')
                return 0
                ;;
            *) return 1 ;;
        esac
    }
    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >&2; }
    INSTALL_AUDIT_LOG="$TMP/install-generated-key-audit"
    audit_action() { printf '%s|%s\n' "$1" "$2" >> "$INSTALL_AUDIT_LOG"; }

    printf '%s' 'ssh-ed25519 EXISTING_KEY_DATA existing@test' > "$SSH_KEY_TARGET_FILE"
    ssh_public_key_install 'ssh-ed25519 GENERATED_KEY_DATA generated@test'
    grep -qx 'ssh-ed25519 EXISTING_KEY_DATA existing@test' "$SSH_KEY_TARGET_FILE" \
        || { echo "Existing authorized_keys line without LF was changed" >&2; exit 1; }
    grep -qx 'ssh-ed25519 GENERATED_KEY_DATA generated@test' "$SSH_KEY_TARGET_FILE" \
        || { echo "Generated key was not installed for the selected user" >&2; exit 1; }
    [ "$(ssh_key_file_count "$SSH_KEY_TARGET_FILE")" = 2 ] \
        || { echo "Missing final LF caused the generated key count to be wrong" >&2; exit 1; }
    sed -i 's/^ssh-ed25519 GENERATED/no-agent-forwarding ssh-ed25519 GENERATED/' "$SSH_KEY_TARGET_FILE"
    ssh_public_key_install 'ssh-ed25519 GENERATED_KEY_DATA generated@test'
    [ "$(wc -l < "$SSH_KEY_TARGET_FILE" | tr -d '[:space:]')" = 2 ] \
        || { echo "Generated key installation did not prevent duplicates" >&2; exit 1; }
    grep -q '为用户 tony 添加 SSH 公钥|SUCCESS' "$INSTALL_AUDIT_LOG" \
        || { echo "Generated public key installation was not written to the audit log" >&2; exit 1; }
)

(
    SYMLINK_HOME="$TMP/install-key-symlink-home"
    SYMLINK_OUTSIDE="$TMP/install-key-symlink-outside"
    mkdir -p "$SYMLINK_HOME" "$SYMLINK_OUTSIDE"
    chmod 700 "$SYMLINK_HOME" "$SYMLINK_OUTSIDE"
    if ln -s "$SYMLINK_OUTSIDE" "$SYMLINK_HOME/.ssh" 2>/dev/null; then
        ! ssh_public_key_path_snapshot \
            "$SYMLINK_HOME/.ssh/authorized_keys" home "$(id -u)" "$SYMLINK_HOME" \
            >/dev/null 2>&1 \
            || { echo "AuthorizedKeysFile parent symlink was accepted" >&2; exit 1; }
    fi
    if [ "$(id -u)" -eq 0 ]; then
        GLOBAL_WRITABLE="$TMP/install-key-global-writable"
        mkdir -p "$GLOBAL_WRITABLE"
        chmod 777 "$GLOBAL_WRITABLE"
        ! ssh_public_key_path_snapshot \
            "$GLOBAL_WRITABLE/tony" global 0 /root >/dev/null 2>&1 \
            || { echo "Writable global AuthorizedKeysFile parent was accepted" >&2; exit 1; }
    fi
)

(
    GENERATED_TARGET_LOG="$TMP/generated-key-targets"
    GENERATED_INSTALL_LOG="$TMP/generated-key-installs"
    GENERATED_AUDIT_LOG="$TMP/generated-key-audit"
    print_header() { :; }
    menu_item() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >&2; }
    ssh_print_key_accounts() { :; }
    audit_action() { printf '%s|%s\n' "$1" "$2" >> "$GENERATED_AUDIT_LOG"; }
    ssh_public_key_target_resolve() {
        SSH_KEY_TARGET_USER="$1"
        SSH_KEY_TARGET_FILE="/tmp/$1-authorized_keys"
        printf '%s\n' "$1" >> "$GENERATED_TARGET_LOG"
    }
    ssh_public_key_install() {
        printf '%s|%s\n' "$SSH_KEY_TARGET_USER" "$1" >> "$GENERATED_INSTALL_LOG"
    }
    ssh-keygen() {
        local KEY_OUTPUT=""
        if [ "${1:-}" = "-t" ]; then
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-f" ]; then
                    KEY_OUTPUT="$2"
                    break
                fi
                shift
            done
            [ -n "$KEY_OUTPUT" ] || return 1
            printf '%s\n' 'TEST PRIVATE KEY' > "$KEY_OUTPUT"
            printf '%s\n' 'ssh-ed25519 GENERATED_KEY_DATA generated@test' > "$KEY_OUTPUT.pub"
            return 0
        fi
        if [ "${1:-}" = "-lf" ]; then
            printf '%s\n' '256 SHA256:generated generated@test (ED25519)'
            return 0
        fi
        return 1
    }

    generate_key <<< $'1\ngenerated@test\n\ntony' >/dev/null
    generate_key <<< $'1\ngenerated@test\n\n' >/dev/null
    generate_key <<< $'1\ngenerated@test\nn' >/dev/null
    [ "$(sed -n '1p' "$GENERATED_TARGET_LOG")" = tony ] \
        || { echo "Generated key did not accept a selected target user" >&2; exit 1; }
    [ "$(sed -n '2p' "$GENERATED_TARGET_LOG")" = root ] \
        || { echo "Blank generated-key target did not default to root" >&2; exit 1; }
    [ "$(wc -l < "$GENERATED_TARGET_LOG" | tr -d '[:space:]')" = 2 ] \
        || { echo "Skipping generated-key installation still selected a target" >&2; exit 1; }
    grep -q '^tony|ssh-ed25519 GENERATED_KEY_DATA generated@test$' "$GENERATED_INSTALL_LOG" \
        || { echo "Generated key was not passed to the selected user installer" >&2; exit 1; }
    grep -q '^root|ssh-ed25519 GENERATED_KEY_DATA generated@test$' "$GENERATED_INSTALL_LOG" \
        || { echo "Generated key was not passed to the default root installer" >&2; exit 1; }
    grep -q '跳过服务器公钥写入|INFO' "$GENERATED_AUDIT_LOG" \
        || { echo "Skipped generated-key installation was not written to the audit log" >&2; exit 1; }
)

(
    VIEW_HOME="$TMP/view-key-home"
    mkdir -p "$VIEW_HOME/.ssh"
    printf '%s\n' 'ssh-ed25519 VALID_KEY_DATA view-key' > "$VIEW_HOME/.ssh/authorized_keys"
    # ssh_public_key_path_snapshot enforces real path ownership even in test
    # mode; the fake passwd entry below claims UID 1000, so the directory
    # tree must actually be owned by that UID or the capture is silently
    # skipped as an ownership mismatch.
    chown -R 1000:1000 "$VIEW_HOME"
    chmod 700 "$VIEW_HOME" "$VIEW_HOME/.ssh"
    SSH_PASSWD_FILE="$TMP/view-key-passwd"
    printf '%s\n' "tony:x:1000:1000::${VIEW_HOME}:/bin/bash" > "$SSH_PASSWD_FILE"
    SSHD_CONFIG="$TMP/view-key-sshd"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    ssh_effective_config_dump() {
        printf '%s\n' 'authorizedkeysfile .ssh/authorized_keys'
    }
    ssh_public_key_line_valid() {
        [[ "$1" == 'ssh-ed25519 VALID_KEY_DATA' ]]
    }
    ssh_public_key_fingerprint() { printf 'SHA256:view\n'; }
    print_header() { :; }
    menu_div() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >&2; }
    VIEW_AUDIT_LOG="$TMP/view-key-audit"
    audit_action() { printf '%s|%s\n' "$1" "$2" >> "$VIEW_AUDIT_LOG"; }
    # tony's UID (1000) must satisfy ssh_key_target_allowed's UID_MIN check,
    # so it cannot be aliased to the test runner's real UID (0 in CI) to take
    # ssh_run_as_target's same-user fast path; run the worker inline instead
    # of dropping privileges, since this test isn't exercising that boundary.
    ssh_run_as_target() {
        local WORKER_SCRIPT="$4"
        shift 4
        bash -c "$WORKER_SCRIPT" vps-tools-key-worker "$@"
    }
    show_keys <<< "tony" >/dev/null
    grep -q '查看用户 tony SSH 公钥（1 个）|SUCCESS' "$VIEW_AUDIT_LOG" \
        || { echo "SSH public key viewing was not written to the audit log" >&2; exit 1; }
)

(
    DELETE_HOME="$TMP/delete-key-no-fallback-home"
    DELETE_KEY_FILE="$DELETE_HOME/.ssh/authorized_keys"
    mkdir -p "$DELETE_HOME/.ssh"
    printf '%s\n' 'ssh-ed25519 VALID_KEY_DATA only-key' > "$DELETE_KEY_FILE"
    chown -R 1000:1000 "$DELETE_HOME"
    chmod 700 "$DELETE_HOME" "$DELETE_HOME/.ssh"
    ssh_run_as_target() {
        local WORKER_SCRIPT="$4"
        shift 4
        bash -c "$WORKER_SCRIPT" vps-tools-key-worker "$@"
    }
    SSH_PASSWD_FILE="$TMP/delete-key-no-fallback-passwd"
    printf '%s\n' "tony:x:1000:1000::${DELETE_HOME}:/bin/bash" > "$SSH_PASSWD_FILE"
    SSHD_CONFIG="$TMP/delete-key-no-fallback-sshd"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    ssh_effective_config_dump() {
        printf '%s\n' \
            'pubkeyauthentication yes' \
            'authorizedkeysfile .ssh/authorized_keys'
    }
    ssh_public_key_line_valid() {
        [[ "$1" == 'ssh-ed25519 VALID_KEY_DATA' ]]
    }
    ssh_public_key_fingerprint() { printf 'SHA256:test\n'; }
    ssh_login_candidates() {
        if [ "${SSH_KEY_EXCLUDE_FILE:-}" = "$DELETE_KEY_FILE" ] \
            && [ "${SSH_KEY_EXCLUDE_LINE:-}" = 1 ]; then
            return 0
        fi
        printf '%s\n' 'tony|密钥|yes'
    }
    print_header() { :; }
    menu_div() { :; }
    error() { printf '%s\n' "$*"; }
    warn() { printf '%s\n' "$*"; }
    DELETE_AUDIT_LOG="$TMP/delete-key-no-fallback-audit"
    audit_action() { printf '%s|%s\n' "$1" "$2" >> "$DELETE_AUDIT_LOG"; }
    DELETE_SAFETY_CALLED="$TMP/delete-key-no-fallback-safety-called"
    ssh_key_delete_safety_arm() { : > "$DELETE_SAFETY_CALLED"; }
    if DELETE_OUTPUT=$(delete_key <<< $'tony\n1'); then
        echo "SSH public key deletion succeeded without any remaining login" >&2
        exit 1
    fi
    [[ "$DELETE_OUTPUT" == *"没有任何账号可以确认登录"* ]] \
        || { echo "Missing post-deletion login route was not reported" >&2; exit 1; }
    grep -qx 'ssh-ed25519 VALID_KEY_DATA only-key' "$DELETE_KEY_FILE" \
        || { echo "Public key file changed before login-route validation" >&2; exit 1; }
    [ ! -e "$DELETE_SAFETY_CALLED" ] \
        || { echo "Public key safety timer started before login-route validation" >&2; exit 1; }
    grep -q '无剩余登录入口|FAILED' "$DELETE_AUDIT_LOG" \
        || { echo "Rejected public key deletion was not written to the audit log" >&2; exit 1; }
)

(
    DELETE_HOME="$TMP/delete-key-success-home"
    DELETE_KEY_FILE="$DELETE_HOME/.ssh/authorized_keys"
    mkdir -p "$DELETE_HOME/.ssh"
    printf '%s\n' \
        'ssh-ed25519 VALID_KEY_DATA delete-me' \
        'ssh-ed25519 SECOND_KEY_DATA keep-me' > "$DELETE_KEY_FILE"
    chown -R 1000:1000 "$DELETE_HOME"
    chmod 700 "$DELETE_HOME" "$DELETE_HOME/.ssh"
    ssh_run_as_target() {
        local WORKER_SCRIPT="$4"
        shift 4
        bash -c "$WORKER_SCRIPT" vps-tools-key-worker "$@"
    }
    DELETE_ORIGINAL=$(cat "$DELETE_KEY_FILE")
    SSH_PASSWD_FILE="$TMP/delete-key-success-passwd"
    printf '%s\n' "tony:x:1000:1000::${DELETE_HOME}:/bin/bash" > "$SSH_PASSWD_FILE"
    SSHD_CONFIG="$TMP/delete-key-success-sshd"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    VPS_DATA_DIR="$TMP/delete-key-success-data"
    VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
    ssh_effective_config_dump() {
        printf '%s\n' \
            'pubkeyauthentication yes' \
            'authorizedkeysfile .ssh/authorized_keys'
    }
    ssh_public_key_line_valid() {
        case "$1" in
            'ssh-ed25519 VALID_KEY_DATA'|'ssh-ed25519 SECOND_KEY_DATA') return 0 ;;
            *) return 1 ;;
        esac
    }
    ssh_public_key_fingerprint() {
        case "$2" in
            VALID_KEY_DATA) printf 'SHA256:delete\n' ;;
            *) printf 'SHA256:keep\n' ;;
        esac
    }
    ssh_login_candidates() { printf '%s\n' 'admin|密钥|yes'; }
    print_header() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*"; }
    DELETE_AUDIT_LOG="$TMP/delete-key-success-audit"
    audit_action() { printf '%s|%s\n' "$1" "$2" >> "$DELETE_AUDIT_LOG"; }
    confirm_file_diff() { return 0; }
    DELETE_SAFETY_CALLED="$TMP/delete-key-success-safety-called"
    ssh_key_delete_safety_arm() {
        printf '%s|%s|%s\n' "$1" "$2" "$3" > "$DELETE_SAFETY_CALLED"
    }
    # ssh_key_delete_apply_transaction cross-checks real safety-arm state
    # (SAFETY_PID/SAFETY_SCRIPT/SAFETY_SNAPSHOT against a live watcher
    # process); that plumbing is already covered end-to-end by the dedicated
    # "delete-key-safety"/"delete-key-executed-safety" tests below, so here
    # delegate straight to the underlying as-target write to verify
    # delete_key()'s own orchestration instead.
    ssh_key_delete_apply_transaction() {
        ssh_key_delete_as_target "$@"
    }
    DELETE_CONFIRM_LOG="$TMP/delete-key-success-confirm"
    ssh_key_delete_confirm_new_session() {
        printf '%s|%s\n' "$1" "$2" > "$DELETE_CONFIRM_LOG"
    }
    delete_key <<< $'tony\n1\nadmin\ntony'
    grep -qx 'ssh-ed25519 SECOND_KEY_DATA keep-me' "$DELETE_KEY_FILE" \
        || { echo "Selected public key line was not deleted precisely" >&2; exit 1; }
    ! grep -q 'VALID_KEY_DATA' "$DELETE_KEY_FILE" \
        || { echo "Deleted public key data remained in the target file" >&2; exit 1; }
    grep -qx 'admin|密钥' "$DELETE_CONFIRM_LOG" \
        || { echo "Post-deletion admin login verification was not requested" >&2; exit 1; }
    DELETE_BACKUP=$(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*_ssh-key_tony_*.bak' | head -1)
    [ -n "$DELETE_BACKUP" ] && [ "$(cat "$DELETE_BACKUP")" = "$DELETE_ORIGINAL" ] \
        || { echo "Original public key file was not preserved in the independent backup" >&2; exit 1; }
    [ -s "$DELETE_SAFETY_CALLED" ] \
        || { echo "Public key deletion did not arm the safety rollback" >&2; exit 1; }
    grep -q '删除用户 tony SSH 公钥|SUCCESS' "$DELETE_AUDIT_LOG" \
        || { echo "Successful public key deletion was not written to the audit log" >&2; exit 1; }
)

(
    VPS_DATA_DIR="$TMP/delete-key-safety-data"
    SAFETY_STATE_FILE="$VPS_DATA_DIR/rollback.active"
    SAFETY_HOME="$TMP/delete key safety home"
    SAFETY_KEY_FILE="$SAFETY_HOME/authorized_keys"
    SAFETY_BACKUP="$VPS_DATA_DIR/authorized_keys.backup"
    mkdir -p "$SAFETY_HOME" "$VPS_DATA_DIR"
    printf '%s\n' 'ssh-ed25519 VALID_KEY_DATA rollback-test' > "$SAFETY_KEY_FILE"
    cp -p "$SAFETY_KEY_FILE" "$SAFETY_BACKUP"
    error() { printf '%s\n' "$*" >&2; }
    warn() { :; }
    audit_action() { :; }
    # `nohup FUNC &` never runs FUNC's arguments as a separate command, so
    # stubbing nohup as a no-op silently prevents the watcher from ever
    # being spawned; the readiness check that follows then has no real
    # process to find. Let the real nohup run (as the sibling
    # "delete-key-executed-safety" test below already does).
    ssh_key_delete_safety_arm "$SAFETY_KEY_FILE" "$SAFETY_BACKUP" tony \
        || { echo "Public key safety rollback could not be armed" >&2; exit 1; }
    IFS='|' read -r SAFETY_TEST_PID SAFETY_TEST_SCRIPT _ _ SAFETY_TEST_BACKUP SAFETY_TEST_STATUS \
        < "$SAFETY_STATE_FILE"
    [[ "$SAFETY_TEST_PID" =~ ^[0-9]+$ ]] && [ -f "$SAFETY_TEST_SCRIPT" ] \
        && [ "$SAFETY_TEST_BACKUP" = "$SAFETY_BACKUP" ] \
        && [ "$SAFETY_TEST_STATUS" = armed ] \
        || { echo "Public key safety rollback state was not persisted" >&2; exit 1; }
    bash -n "$SAFETY_TEST_SCRIPT" \
        || { echo "Generated public key rollback script has invalid syntax" >&2; exit 1; }
    printf -v SAFETY_KEY_QUOTED '%q' "$SAFETY_KEY_FILE"
    grep -Fq "$SAFETY_KEY_QUOTED" "$SAFETY_TEST_SCRIPT" \
        || { echo "Generated public key rollback script lost the target path" >&2; exit 1; }
    grep -Fq "$VPS_AUDIT_LOG" "$SAFETY_TEST_SCRIPT" \
        || { echo "Automatic public key rollback was not connected to the audit log" >&2; exit 1; }
    kill "$SAFETY_TEST_PID" 2>/dev/null || true
    rm -f "$SAFETY_STATE_FILE" "$SAFETY_TEST_SCRIPT"
)

(
    VPS_DATA_DIR="$TMP/delete-key-executed-safety-data"
    SAFETY_STATE_FILE="$VPS_DATA_DIR/rollback.active"
    SSH_KEY_ROLLBACK_DELAY=1
    SAFETY_KEY_FILE="$TMP/delete-key-executed-home/authorized_keys"
    SAFETY_BACKUP="$VPS_DATA_DIR/authorized_keys.backup"
    mkdir -p "$(dirname "$SAFETY_KEY_FILE")" "$VPS_DATA_DIR"
    printf 'before\n' > "$SAFETY_KEY_FILE"
    cp -p "$SAFETY_KEY_FILE" "$SAFETY_BACKUP"
    error() { printf '%s\n' "$*" >&2; }
    warn() { :; }
    audit_action() { :; }
    ssh_key_delete_safety_arm "$SAFETY_KEY_FILE" "$SAFETY_BACKUP" tony \
        || { echo "Executable public key rollback could not be armed" >&2; exit 1; }
    # The watcher only acts once status is "applied" (set by
    # ssh_key_delete_apply_transaction after the real deletion is written);
    # arming alone leaves it "armed" and the watcher waits indefinitely.
    # Flip it here to simulate a completed, unconfirmed deletion so the
    # stale-lock recovery path below actually gets exercised.
    sed -i 's/|armed$/|applied/' "$SAFETY_STATE_FILE"
    printf 'after\n' > "$SAFETY_KEY_FILE"
    mkdir "${SAFETY_STATE_FILE}.lock"
    printf 'stale-owner\n' > "${SAFETY_STATE_FILE}.lock/pid"
    for _ in 1 2 3 4 5 6 7 8; do
        [ ! -e "$SAFETY_STATE_FILE" ] && break
        sleep 1
    done
    grep -qx before "$SAFETY_KEY_FILE" \
        || { echo "Public key rollback abandoned recovery behind a stale lock" >&2; exit 1; }
    [ ! -e "$SAFETY_STATE_FILE" ] && [ ! -e "${SAFETY_STATE_FILE}.lock" ] \
        || { echo "Public key rollback left active state or lock artifacts" >&2; exit 1; }
    [ -f "$SAFETY_BACKUP" ] \
        || { echo "Public key rollback removed the independent operator backup" >&2; exit 1; }
)

(
    SSHD_CONFIG="$TMP/revoke-no-fallback-sshd-config"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    ssh_account_records() {
        printf '%s\n' "tony:x:1000:1000::${STRICT_HOME}:/bin/bash"
    }
    ssh_account_record() {
        ssh_account_records
    }
    ssh_effective_config_dump() {
        if grep -q '^DenyUsers tony$' "$1" 2>/dev/null; then
            printf '%s\n' "${STRICT_POLICY_DUMP}" 'denyusers tony'
        else
            printf '%s\n' "${STRICT_POLICY_DUMP}"
        fi
    }
    sshd() { return 0; }
    ssh_login_candidates() { return 0; }
    print_header() { :; }
    menu_div() { :; }
    error() { printf '%s\n' "$*"; }
    warn() { printf '%s\n' "$*"; }
    REVOKE_BACKUP_CALLED="$TMP/revoke-backup-called"
    backup_config() { : > "$REVOKE_BACKUP_CALLED"; }
    if REVOKE_OUTPUT=$(revoke_user_ssh_login <<< "tony"); then
        echo "SSH login revocation succeeded without any fallback user" >&2
        exit 1
    fi
    [[ "$REVOKE_OUTPUT" == *"没有任何其他账号可确认登录"* ]] \
        || { echo "Missing fallback login was not reported" >&2; exit 1; }
    [ ! -e "$REVOKE_BACKUP_CALLED" ] \
        || { echo "SSH config backup/apply started before fallback validation" >&2; exit 1; }
)

(
    SSHD_CONFIG="$TMP/revoke-success-sshd-config"
    {
        printf '%s\n' "$SSHD_MANAGED_BEGIN"
        printf '%s\n' 'DenyUsers legacy'
        printf '%s\n' "$SSHD_MANAGED_END"
        printf '%s\n' 'Port 22'
        printf '%s\n' 'Match Address 192.0.2.*'
        printf '%s\n' '    DenyUsers conditional-only'
    } > "$SSHD_CONFIG"
    ssh_account_records() {
        printf '%s\n' \
            'root:x:0:0:root:/root:/bin/bash' \
            "tony:x:1000:1000::${STRICT_HOME}:/bin/bash"
    }
    ssh_account_record() {
        ssh_account_records | awk -F: -v username="$1" '$1 == username {print; exit}'
    }
    ssh_effective_config_dump() {
        if [ "$2" = tony ] && grep -Eq '^DenyUsers .*tony([[:space:]]|$)' "$1" 2>/dev/null; then
            printf '%s\n' "${STRICT_POLICY_DUMP}" 'denyusers tony'
        else
            printf '%s\n' "${STRICT_POLICY_DUMP}"
        fi
    }
    sshd() { return 0; }
    ssh_login_candidates() { printf '%s\n' 'root|密钥|yes'; }
    print_header() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    audit_action() { :; }
    backup_config() { :; }
    confirm_file_diff() { return 0; }
    safety_arm() { return 0; }
    apply_and_restart() { return 0; }
    REVOKE_CONFIRM_LOG="$TMP/revoke-confirm-log"
    ssh_revoke_confirm_new_session() {
        printf '%s|%s\n' "$1" "$2" > "$REVOKE_CONFIRM_LOG"
    }
    revoke_user_ssh_login <<< $'tony\nroot\ntony'
    [ "$(ssh_collect_managed_deny_users "$SSHD_CONFIG")" = 'legacy tony' ] \
        || { echo "SSH revocation did not preserve only the historical managed DenyUsers list" >&2; exit 1; }
    grep -q '^[[:space:]]*DenyUsers conditional-only$' "$SSHD_CONFIG" \
        || { echo "Conditional DenyUsers rule outside the managed block was changed" >&2; exit 1; }
    grep -qx 'root|密钥' "$REVOKE_CONFIRM_LOG" \
        || { echo "Successful SSH login revocation did not verify the selected fallback" >&2; exit 1; }
)

(
    SSHD_CONFIG="$TMP/revoke-non-admin-verifier-sshd-config"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    ssh_account_records() {
        printf '%s\n' \
            'root:x:0:0:root:/root:/bin/bash' \
            "tony:x:1000:1000::${STRICT_HOME}:/bin/bash"
    }
    ssh_account_record() {
        ssh_account_records | awk -F: -v username="$1" '$1 == username {print; exit}'
    }
    ssh_effective_config_dump() {
        if [ "$2" = tony ] && grep -Eq '^DenyUsers .*tony([[:space:]]|$)' "$1" 2>/dev/null; then
            printf '%s\n' "${STRICT_POLICY_DUMP}" 'denyusers tony'
        else
            printf '%s\n' "${STRICT_POLICY_DUMP}"
        fi
    }
    sshd() { return 0; }
    ssh_login_candidates() {
        printf '%s\n' 'root|密钥|yes' 'guest|密码|no'
    }
    print_header() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*"; }
    REVOKE_NON_ADMIN_BACKUP="$TMP/revoke-non-admin-backup"
    backup_config() { : > "$REVOKE_NON_ADMIN_BACKUP"; }
    if REVOKE_NON_ADMIN_OUTPUT=$(revoke_user_ssh_login <<< $'tony\nguest'); then
        echo "SSH revocation accepted a non-admin verification account" >&2
        exit 1
    fi
    [[ "$REVOKE_NON_ADMIN_OUTPUT" == *"完整 root 权限的管理员"* ]] \
        || { echo "Non-admin SSH revocation verifier rejection was not reported" >&2; exit 1; }
    [ ! -e "$REVOKE_NON_ADMIN_BACKUP" ] \
        || { echo "SSH revocation backed up/applied before rejecting a non-admin verifier" >&2; exit 1; }
)

user_name_valid alice || { echo "Valid username was rejected" >&2; exit 1; }
user_name_valid ops_admin-2 || { echo "Valid service-style username was rejected" >&2; exit 1; }
! user_name_valid Root >/dev/null 2>&1 || { echo "Uppercase username was accepted" >&2; exit 1; }
! user_name_valid 'bad name' >/dev/null 2>&1 || { echo "Username containing spaces was accepted" >&2; exit 1; }
! user_name_valid root >/dev/null 2>&1 || { echo "Reserved root username was accepted" >&2; exit 1; }
user_password_target_allowed root 0 || { echo "Root password change was rejected" >&2; exit 1; }
user_password_target_allowed alice 1000 || { echo "Regular user password change was rejected" >&2; exit 1; }
! user_password_target_allowed daemon 1 >/dev/null 2>&1 || { echo "System account password change was accepted" >&2; exit 1; }
! user_password_target_allowed nobody 65534 >/dev/null 2>&1 || { echo "Nobody password change was accepted" >&2; exit 1; }
user_admin_target_allowed alice 1000 || { echo "Regular user was rejected as an admin target" >&2; exit 1; }
! user_admin_target_allowed root 0 >/dev/null 2>&1 || { echo "Root was accepted as an admin target" >&2; exit 1; }
security_password_methods_disabled no no || { echo "Disabled SSH password methods were not recognized" >&2; exit 1; }
! security_password_methods_disabled no yes >/dev/null 2>&1 || { echo "Enabled keyboard-interactive authentication was ignored" >&2; exit 1; }
security_password_methods_disabled yes yes publickey || { echo "Publickey-only AuthenticationMethods was treated as password-enabled" >&2; exit 1; }
! security_password_methods_disabled no yes 'publickey,keyboard-interactive' >/dev/null 2>&1 || { echo "AuthenticationMethods keyboard-interactive factor was ignored" >&2; exit 1; }
security_password_auth_effective yes any || { echo "Enabled password authentication was not recognized" >&2; exit 1; }
! security_password_auth_effective yes publickey >/dev/null 2>&1 || { echo "Publickey-only AuthenticationMethods enabled empty-password checks" >&2; exit 1; }
security_root_password_restricted without-password yes yes || { echo "PermitRootLogin without-password was treated as unsafe" >&2; exit 1; }
security_root_password_restricted prohibit-password yes yes || { echo "PermitRootLogin prohibit-password was treated as unsafe" >&2; exit 1; }
security_root_password_restricted forced-commands-only yes yes || { echo "PermitRootLogin forced-commands-only was treated as unsafe" >&2; exit 1; }
security_root_password_restricted yes no no || { echo "Globally disabled password methods did not protect root" >&2; exit 1; }
! security_root_password_restricted yes no yes >/dev/null 2>&1 || { echo "Root keyboard-interactive login was treated as restricted" >&2; exit 1; }
(
    get_config() {
        case "$1" in
            PasswordAuthentication) echo no ;;
            KbdInteractiveAuthentication) echo no ;;
            PermitRootLogin) echo without-password ;;
            PermitEmptyPasswords) echo no ;;
            AuthenticationMethods) echo any ;;
            UsePAM) echo yes ;;
            Port) echo 22 ;;
        esac
    }
    sshd() { [ "$1" = "-t" ]; }
    awk() {
        case "$*" in
            *"/etc/passwd"*) printf 'root\n' ;;
            *) command awk "$@" ;;
        esac
    }
    fw_detect() { echo none; }
    f2b_status() { echo stopped; }
    audit_action() { :; }
    SECURITY_OUTPUT=$(security_audit)
    [[ "$SECURITY_OUTPUT" = *"有效密码及键盘交互登录已关闭"* ]] \
        || { echo "Security audit missed globally disabled password methods" >&2; exit 1; }
    [[ "$SECURITY_OUTPUT" = *"root 密码登录已限制（without-password）"* ]] \
        || { echo "Security audit still misreports PermitRootLogin without-password" >&2; exit 1; }
    [[ "$SECURITY_OUTPUT" != *"root 密码或键盘交互登录可能允许"* ]] \
        || { echo "Security audit emitted a false root password warning" >&2; exit 1; }
)
(
    SUDO_USER=alice
    user_is_elevation_account alice || { echo "Current sudo account was not protected from demotion" >&2; exit 1; }
    ! user_is_elevation_account bob >/dev/null 2>&1 || { echo "Unrelated user was treated as the current elevation account" >&2; exit 1; }
)
(
    sudo() {
        printf 'User tony is not allowed to run sudo on test-host.\n'
        return 0
    }
    ! user_has_sudo_access tony >/dev/null 2>&1 \
        || { echo "Denied sudo listing was treated as administrator access" >&2; exit 1; }
    sudo() {
        printf 'User tony may run the following commands on test-host:\n'
        printf '    (ALL : ALL) ALL\n'
    }
    user_has_sudo_access tony \
        || { echo "Allowed sudo listing was not recognized as administrator access" >&2; exit 1; }
)
REMOVABLE_HOME="$TMP/removable-user-home"
mkdir -p "$REMOVABLE_HOME"
user_home_safe_to_remove "$REMOVABLE_HOME" || { echo "Normal existing user home was rejected for deletion" >&2; exit 1; }
! user_home_safe_to_remove / >/dev/null 2>&1 || { echo "Filesystem root was accepted as user workspace" >&2; exit 1; }
! user_home_safe_to_remove /home >/dev/null 2>&1 || { echo "Shared home root was accepted as user workspace" >&2; exit 1; }
! user_home_safe_to_remove /home/ >/dev/null 2>&1 || { echo "Shared home root with trailing slash was accepted" >&2; exit 1; }
! user_home_safe_to_remove // >/dev/null 2>&1 || { echo "Double-slash filesystem root was accepted" >&2; exit 1; }
! user_home_safe_to_remove /home/alice/../bob >/dev/null 2>&1 || { echo "Traversal path was accepted as user workspace" >&2; exit 1; }
(
    # user_home_canonical_path resolves paths with a real `cd -P`, so the
    # candidate homes must actually exist on disk or resolution fails and
    # user_home_is_shared conservatively reports "shared" either way.
    mkdir -p "$TMP/home/shared" "$TMP/home/alice"
    USER_PASSWD_FILE="$TMP/passwd"
    printf '%s\n' \
        "alice:x:1000:1000::${TMP}/home/shared:/bin/bash" \
        "bob:x:1001:1001::${TMP}/home/shared:/bin/bash" > "$USER_PASSWD_FILE"
    user_home_is_shared alice "$TMP/home/shared" || { echo "Shared user home was not detected" >&2; exit 1; }
    ! user_home_is_shared alice "$TMP/home/alice" >/dev/null 2>&1 || { echo "Unique user home was treated as shared" >&2; exit 1; }
)
(
    VPS_TOOLS_UID_OVERRIDE=1000
    ! user_require_root >/dev/null 2>&1 || { echo "User manager accepted a non-root caller" >&2; exit 1; }
)
(
    SUDO_USER=alice
    user_is_protected_account alice 1000 || { echo "Current sudo account was not protected from deletion" >&2; exit 1; }
    user_is_protected_account root 0 || { echo "Root account was not protected from deletion" >&2; exit 1; }
)
(
    USER_PASSWD_FILE="$TMP/user-list-passwd"
    PAUSE_LOG="$TMP/user-list-paused"
    printf '%s\n' \
        'root:x:0:0:root:/root:/bin/bash' \
        'alice:x:1000:1000::/home/alice:/bin/bash' > "$USER_PASSWD_FILE"
    ui_pause() { : > "$PAUSE_LOG"; }
    USER_LIST_OUTPUT=$(user_list_accounts)
    [[ "$USER_LIST_OUTPUT" = *"root"* && "$USER_LIST_OUTPUT" = *"alice"* ]] \
        || { echo "User list did not render root and regular accounts" >&2; exit 1; }
    [ -e "$PAUSE_LOG" ] || { echo "User list returned without pausing" >&2; exit 1; }
)
(
    USER_PASSWD_FILE="$TMP/revoked-user-list-passwd"
    USER_SUDOERS_DIR="$TMP/revoked-user-list-sudoers"
    mkdir -p "$USER_SUDOERS_DIR"
    printf '%s\n' \
        'root:x:0:0:root:/root:/bin/bash' \
        'tony:x:1000:1000::/home/tony:/bin/bash' > "$USER_PASSWD_FILE"
    id() {
        if [ "$1" = "-nG" ]; then
            printf '%s\n' "$2"
        else
            command id "$@"
        fi
    }
    sudo() {
        printf 'User tony is not allowed to run sudo on test-host.\n'
        return 0
    }
    ui_pause() { :; }
    USER_LIST_OUTPUT=$(user_list_accounts)
    TONY_LINE=$(printf '%s\n' "$USER_LIST_OUTPUT" | grep -E '^[[:space:]]*tony[[:space:]]')
    [[ "$TONY_LINE" = *"普通用户"* ]] \
        || { echo "Revoked user was still displayed as administrator" >&2; exit 1; }
)
(
    USER_SUDOERS_DIR="$TMP/sudoers.d"
    USER_GROUP_FILE="$TMP/group"
    mkdir -p "$USER_SUDOERS_DIR"
    printf 'wheel:x:10:\n' > "$USER_GROUP_FILE"
    USERMOD_LOG="$TMP/usermod.log"
    sudo() {
        printf 'User alice may run the following commands on test-host:\n'
        printf '    (ALL : ALL) ALL\n'
    }
    visudo() { [ "$1" = "-cf" ] && [ -s "$2" ]; }
    usermod() { printf '%s\n' "$*" > "$USERMOD_LOG"; }
    user_grant_admin alice >/dev/null
    grep -qx -- '-aG wheel alice' "$USERMOD_LOG" || { echo "Admin user was not added to the native wheel group" >&2; exit 1; }
    grep -qx 'alice ALL=(ALL) ALL' "$USER_SUDOERS_DIR/vps-tools-alice" || { echo "Validated sudoers rule was not created" >&2; exit 1; }
)

(
    AUTH_KEYS="$TMP/authorized_keys"
    : > "$AUTH_KEYS"
    [[ "$(ssh_key_count)" = 0 ]] || { echo "Empty authorized_keys did not return a single zero" >&2; exit 1; }
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest1 test-one' 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTest2 test-two' > "$AUTH_KEYS"
    [[ "$(ssh_key_count)" = 2 ]] || { echo "SSH key counter did not count valid keys" >&2; exit 1; }
    rm -f "$AUTH_KEYS"
    [[ "$(ssh_key_count)" = 0 ]] || { echo "Missing authorized_keys did not return zero" >&2; exit 1; }
)

[[ "$(ts_https_date_epoch 'Sat, 25 Jul 2026 12:00:00 GMT')" = 1784980800 ]] || { echo "HTTPS Date header parsing failed" >&2; exit 1; }
! ts_https_date_epoch 'invalid date' >/dev/null 2>&1 || { echo "Invalid HTTPS Date header was accepted" >&2; exit 1; }
[[ "$(ts_epoch_utc 1784980800)" = '2026-07-25 12:00:00' ]] || { echo "HTTPS epoch formatting failed" >&2; exit 1; }
[[ "$(ts_https_consensus 1784980800 1784980802 1784980900)" = '1784980801 2 2' ]] || { echo "HTTPS time consensus did not reject an outlier" >&2; exit 1; }
! ts_https_consensus 1784980800 1784980820 >/dev/null 2>&1 || { echo "HTTPS time consensus accepted disagreeing sources" >&2; exit 1; }
for INTERVAL in 1 3 6 12 24; do
    [[ "$(ts_https_interval_normalize "$INTERVAL")" = "$INTERVAL" ]] || { echo "HTTPS interval $INTERVAL was rejected" >&2; exit 1; }
done
! ts_https_interval_normalize 2 >/dev/null 2>&1 || { echo "Unsupported HTTPS interval was accepted" >&2; exit 1; }
[[ "$(ts_https_cron_expr 1)" = '17 * * * *' ]] || { echo "Hourly HTTPS cron expression is wrong" >&2; exit 1; }
[[ "$(ts_https_cron_expr 6)" = '17 */6 * * *' ]] || { echo "Six-hour HTTPS cron expression is wrong" >&2; exit 1; }
[[ "$(ts_https_cron_expr 24)" = '17 3 * * *' ]] || { echo "Daily HTTPS cron expression is wrong" >&2; exit 1; }
(
    # shellcheck disable=SC2329 # test stub used indirectly by ts_https_fetch_epoch
    curl() { printf 'HTTP/2 200\r\nDate: Sat, 25 Jul 2026 12:00:00 GMT\r\n\r\n'; }
    [[ "$(ts_https_fetch_epoch https://example.com/)" = 1784980800 ]] || { echo "HTTPS response Date extraction failed" >&2; exit 1; }
)

CADDYFILE="$TMP/Caddyfile"
cat > "$CADDYFILE" <<'EOF'
{
    email admin@example.com
}

(common_headers) {
    header X-Test enabled
}

cdr.289599.top {
	reverse_proxy 127.0.0.1:8081 {
		header_up Host {host}
		transport http {
			tls
		}
	}
}

dockge.289599.top {
    reverse_proxy 127.0.0.1:5001
}

fwx.289599.top {
    handle {
        reverse_proxy 127.0.0.1:18080
    }
}

example.com, www.example.com {
    redir https://www.example.com{uri}
}
EOF
CADDY_RECORDS=$(caddy_site_records)
EXPECTED_CADDY_SITES=$(printf '%s\n' 'cdr.289599.top' 'dockge.289599.top' 'fwx.289599.top' 'example.com, www.example.com')
ACTUAL_CADDY_SITES=$(printf '%s\n' "$CADDY_RECORDS" | awk -F '\t' '$1 == "site" { print $2 }')
[[ "$ACTUAL_CADDY_SITES" = "$EXPECTED_CADDY_SITES" ]] || { echo "Caddy nested blocks were parsed as sites" >&2; exit 1; }
[[ "$(caddy_site_count)" = 4 ]] || { echo "Caddy site count included nested or option blocks" >&2; exit 1; }
[[ "$CADDY_RECORDS" == *$'directive\treverse_proxy\t127.0.0.1:8081'* ]] || { echo "Caddy nested reverse proxy target was not listed" >&2; exit 1; }
[[ "$CADDY_RECORDS" != *$'site\treverse_proxy'* && "$CADDY_RECORDS" != *$'site\theader_up'* && "$CADDY_RECORDS" != *$'site\ttransport'* ]] || {
    echo "Caddy nested directive was exposed as a site" >&2
    exit 1
}
CADDY_LIST_OUTPUT=$(caddy_list_sites)
[[ "$CADDY_LIST_OUTPUT" == *'[1] cdr.289599.top'* && "$CADDY_LIST_OUTPUT" == *'[2] dockge.289599.top'* && "$CADDY_LIST_OUTPUT" == *'[4] example.com, www.example.com'* ]] || {
    echo "Caddy site list numbering is incomplete" >&2
    exit 1
}
[[ "$CADDY_LIST_OUTPUT" == *'reverse_proxy → 127.0.0.1:8081'* && "$CADDY_LIST_OUTPUT" != *'[2] reverse_proxy'* ]] || {
    echo "Caddy site list did not render a nested proxy correctly" >&2
    exit 1
}
(
    CADDYFILE="$TMP/Caddy-delete"
    cp "$TMP/Caddyfile" "$CADDYFILE"
    # shellcheck disable=SC2329 # test stub used indirectly by caddy_del_site
    caddy() { [ "${1:-}" = validate ]; }
    # shellcheck disable=SC2329 # test stub used indirectly by caddy_del_site
    caddy_reload_config() { return 0; }
    caddy_del_site >/dev/null <<'EOF'
4
y
EOF
    ! grep -qF 'example.com, www.example.com {' "$CADDYFILE" || { echo "Caddy multi-address site was not deleted" >&2; exit 1; }
    grep -qF 'cdr.289599.top {' "$CADDYFILE" || { echo "Caddy deletion removed the wrong top-level block" >&2; exit 1; }
    grep -qF 'header_up Host {host}' "$CADDYFILE" || { echo "Caddy deletion damaged a nested proxy block" >&2; exit 1; }
)

BANNER_WIDE=$(COLUMNS=80 NO_COLOR=1 volcano_art_banner)
[[ "$BANNER_WIDE" = *'██╗███╗'* && "$BANNER_WIDE" = *'███████╗'* ]] || { echo "Wide IMPART OPS banner is missing" >&2; exit 1; }
BANNER_COMPACT=$(COLUMNS=60 NO_COLOR=1 volcano_art_banner)
[[ "$BANNER_COMPACT" = *'██╗███╗'* && "$BANNER_COMPACT" = *'██████╗ ██████╗ ███████╗'* ]] || { echo "Compact IMPART OPS banner is missing" >&2; exit 1; }
[[ "$(COLUMNS=40 NO_COLOR=1 volcano_art_banner)" = *'IMPART OPS'* ]] || { echo "Narrow IMPART OPS banner fallback is missing" >&2; exit 1; }

for fn in bbr_preflight bbr_runtime_snapshot bbr_ensure_baseline bbr_restore_runtime_snapshot bbr_baseline_value bbr_config_has_key \
    bbr_apply_sysctl bbr_generate_config bbr_bdp_mb bbr_buffer_target_mb bbr_recommend_profile \
    bbr_tc_qdisc_safe_to_replace bbr_tc_current_rate bbr_tc_rate_display bbr_tc_topology_matches bbr_tc_managed_artifact bbr_tc_is_legacy_owned \
    bbr_tc_snapshot_foreign bbr_tc_force_confirm bbr_tc_remove_confirm bbr_tc_apply_runtime bbr_default_route_info bbr_route_token \
    bbr_route_strip_cwnd bbr_apply_initcwnd_route volcano_tcp_profile; do
    declare -F "$fn" >/dev/null || { echo "Missing BBR function: $fn" >&2; exit 1; }
done

BBR_BASELINE_FILE="$TMP/bbr-baseline.conf"
cat > "$BBR_BASELINE_FILE" <<'EOF'
netXipv4Xip_forward = 9
net.ipv4.ip_forward = 1
net.core.somaxconn = 4096
EOF
[[ "$(bbr_baseline_value net.ipv4.ip_forward)" = "1" ]] || { echo "BBR baseline key matching was not exact" >&2; exit 1; }
[[ "$(bbr_config_dynamic_scene_keys 'net.ipv6.conf.eth9.accept_ra = 2')" = net.ipv6.conf.eth9.accept_ra ]] || { echo "BBR old IPv6 interface cleanup key was not detected" >&2; exit 1; }
BBR_RESTORE_LOG="$TMP/bbr-restore.log"
# shellcheck disable=SC2329 # test stub used indirectly by bbr_restore_baseline_key
sysctl() {
    [ "${1:-}" = -w ] && printf '%s\n' "$2" >> "$BBR_RESTORE_LOG"
}
bbr_restore_baseline_key net.core.somaxconn
grep -qx 'net.core.somaxconn=4096' "$BBR_RESTORE_LOG" || { echo "BBR baseline restore used the wrong value" >&2; exit 1; }
unset -f sysctl

(
    BBR_BASELINE_FILE="$TMP/bbr-growing-baseline.conf"
    printf 'net.ipv4.ip_forward = 0\n' > "$BBR_BASELINE_FILE"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_ensure_baseline
    bbr_managed_keys() { printf '%s\n' net.ipv4.ip_forward net.ipv6.conf.eth0.accept_ra; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_ensure_baseline
    sysctl() {
        [ "${1:-}" = -n ] && [ "${2:-}" = net.ipv6.conf.eth0.accept_ra ] && echo 1
    }
    bbr_ensure_baseline
    [[ "$(bbr_baseline_value net.ipv4.ip_forward)" = 0 ]] || { echo "BBR baseline overwrote an existing value" >&2; exit 1; }
    [[ "$(bbr_baseline_value net.ipv6.conf.eth0.accept_ra)" = 1 ]] || { echo "BBR baseline did not capture a newly managed interface" >&2; exit 1; }
)

(
    SYSCTL_FILE="$TMP/bbr-sysctl.conf"
    BBR_BASELINE_FILE="$TMP/bbr-transaction-baseline.conf"
    printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FILE"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    ensure_sysctl() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    bbr_ensure_baseline() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    bbr_runtime_snapshot() {
        printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$1"
    }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    sysctl() {
        case "${2:-}" in net.ipv4.tcp_congestion_control=bbr) return 1 ;; *) return 0 ;; esac
    }
    CONFIG=$(printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr')
    if bbr_apply_sysctl "$CONFIG" baseline >/dev/null 2>&1; then
        echo "BBR core sysctl failure returned success" >&2
        exit 1
    fi
    grep -qx 'net.ipv4.tcp_congestion_control = cubic' "$SYSCTL_FILE" || {
        echo "BBR failed apply replaced the previous persistent config" >&2
        exit 1
    }
)

(
    PREFLIGHT_CALLED=0
    BACKUP_CALLED=0
    # shellcheck disable=SC2329 # test stub used indirectly by volcano_tcp_profile
    bbr_preflight() { PREFLIGHT_CALLED=1; return 1; }
    # shellcheck disable=SC2329 # must stay uncalled when preflight fails
    bbr_backup_sysctl() { BACKUP_CALLED=1; }
    if volcano_tcp_profile balanced >/dev/null 2>&1; then
        echo "BBR smart profile ignored a failed preflight" >&2
        exit 1
    fi
    [ "$PREFLIGHT_CALLED" -eq 1 ] || { echo "BBR smart profile skipped preflight" >&2; exit 1; }
    [ "$BACKUP_CALLED" -eq 0 ] || { echo "BBR smart profile changed state after failed preflight" >&2; exit 1; }
)

(
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_generate_config
    bbr_default_ipv6_iface() { echo eth0; }
    CONFIG=$(bbr_generate_config 12582912 12582912 '32768 49152 98304' 131072 2 32768 10 1048576 relay)
    grep -qx 'net.ipv6.conf.eth0.accept_ra = 2' <<< "$CONFIG" || { echo "BBR forwarding profile missing IPv6 accept_ra=2" >&2; exit 1; }
)

bbr_tc_qdisc_safe_to_replace fq || { echo "BBR rejected a safe default qdisc" >&2; exit 1; }
! bbr_tc_qdisc_safe_to_replace cake || { echo "BBR would overwrite a foreign CAKE qdisc" >&2; exit 1; }
(
    TC_STATE_FILE="$TMP/mq-no-state"
    SERVICE_TC="$TMP/mq-tc.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact
    SERVICE_TC_INIT="$TMP/mq-tc.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_tc_restore_owned
    TC_HELPER="$TMP/mq-tc-helper"
    TC_TEST_LOG="$TMP/mq-tc.log"
    export TC_TEST_LOG
    FAKE_TC="$TMP/fake-mq-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    printf '%s\n' \
        'qdisc mq 0: root' \
        'qdisc fq 0: parent :1 limit 10000p flow_limit 100p'
    exit 0
fi
if [ "$1 $2" = "class show" ]; then exit 0; fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
[ "$1 $2" != "qdisc del" ]
EOF
    chmod +x "$FAKE_TC"
    [ "$(bbr_tc_rate_display eth0 "$FAKE_TC")" = "未设置" ] \
        || { echo "BBR reported a rate for the default mq/fq topology" >&2; exit 1; }
    bbr_tc_apply_runtime eth0 2200 2200 "$FAKE_TC" >/dev/null \
        || { echo "BBR could not replace an undeletable mq root qdisc" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: htb default 10' "$TC_TEST_LOG" \
        || { echo "BBR did not use qdisc replace for an mq root" >&2; exit 1; }
    ! grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "BBR tried to delete an undeletable mq root" >&2; exit 1; }
)
(
    TC_STATE_FILE="$TMP/legacy-tc-no-state"
    SERVICE_TC="$TMP/legacy-tc-fq.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact
    SERVICE_TC_INIT="$TMP/legacy-tc-fq.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_tc_restore_owned
    TC_HELPER="$TMP/legacy-tc-helper"
    TC_TEST_LOG="$TMP/legacy-tc.log"
    export TC_TEST_LOG
    cat > "$SERVICE_TC" <<'EOF'
[Unit]
Description=TC egress shaping 1024Mbps (htb shape + fq pacing for BBR)
EOF
    FAKE_TC="$TMP/fake-legacy-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    cat <<'OUT'
qdisc htb 1: root refcnt 3 r2q 10 default 0x10 direct_packets_stat 0 direct_qlen 1000
qdisc fq 100: parent 1:10 limit 10000p flow_limit 100p buckets 1024 maxrate 1024Mbit
OUT
elif [ "$1 $2" = "class show" ]; then
    echo 'class htb 1:10 root rate 1024Mbit ceil 1024Mbit burst 1024Kb cburst 1024Kb'
else
    printf '%s\n' "$*" >> "$TC_TEST_LOG"
fi
EOF
    chmod +x "$FAKE_TC"
    bbr_tc_is_legacy_owned eth0 "$FAKE_TC" || { echo "BBR did not recognize its legacy tc topology" >&2; exit 1; }
    bbr_tc_apply_runtime eth0 780 780 "$FAKE_TC" >/dev/null || { echo "BBR refused to migrate its legacy tc topology" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" || { echo "BBR legacy tc migration did not replace the root qdisc" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 parent 1:10 handle 100: fq maxrate 780mbit' "$TC_TEST_LOG" \
        || { echo "BBR legacy tc migration did not apply the requested rate" >&2; exit 1; }
    rm -f "$SERVICE_TC"
    ! bbr_tc_is_legacy_owned eth0 "$FAKE_TC" || { echo "BBR claimed legacy tc topology without a managed artifact" >&2; exit 1; }
    cat > "$SERVICE_TC" <<'EOF'
[Unit]
Description=TC egress shaping 1024Mbps (htb shape + fq pacing for BBR)
EOF
    TC_BIN_DIR="$TMP/legacy-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cp "$FAKE_TC" "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"
    # shellcheck disable=SC2329 # test stubs consumed indirectly by bbr_remove_tc
    default_iface() { echo eth0; }
    # shellcheck disable=SC2329 # keep the removal test away from the host service manager
    systemd_available() { return 1; }
    # shellcheck disable=SC2329 # test stubs consumed through command -v
    rc-update() { return 0; }
    # shellcheck disable=SC2329 # test stub consumed indirectly by bbr_remove_tc
    rc-service() { return 0; }
    : > "$TC_TEST_LOG"
    bbr_remove_tc >/dev/null || { echo "BBR refused to remove its legacy tc topology" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" || { echo "BBR legacy tc removal left the root qdisc active" >&2; exit 1; }
)
(
    # shellcheck disable=SC2034 # consumed by bbr_tc_is_owned
    TC_STATE_FILE="$TMP/no-tc-state"
    TC_BACKUP_DIR="$TMP/tc-backups"
    SERVICE_TC="$TMP/foreign-tc.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_remove_tc
    SERVICE_TC_INIT="$TMP/foreign-tc.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_remove_tc
    TC_HELPER="$TMP/foreign-tc-helper"
    TC_TEST_LOG="$TMP/tc-test.log"
    export TC_TEST_LOG
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    systemd_available() { return 1; }
    # shellcheck disable=SC2329 # test stubs consumed through command -v by bbr_remove_tc
    rc-update() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    rc-service() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    default_iface() { echo eth0; }
    FAKE_TC="$TMP/fake-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    echo 'qdisc tbf 8001: root refcnt 2 rate 1024Mbit burst 1Mb lat 50ms'
    exit 0
fi
if [ "$1 $2" = "class show" ]; then
    echo 'class tbf 8001:1 root'
    exit 0
fi
if [ "$1 $2" = "filter show" ]; then
    echo 'filter parent 8001: protocol ip pref 1 u32 chain 0'
    exit 0
fi
if [ "$1 $2 $3" = "-j qdisc show" ]; then
    echo '[{"kind":"tbf","root":true}]'
    exit 0
fi
if [ "$1 $2 $3" = "-j class show" ]; then
    echo '[{"kind":"tbf","classid":"8001:1"}]'
    exit 0
fi
if [ "$1 $2 $3" = "-j filter show" ]; then
    echo '[{"kind":"u32","parent":"8001:"}]'
    exit 0
fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
EOF
    chmod +x "$FAKE_TC"
    TC_BIN_DIR="$TMP/foreign-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cp "$FAKE_TC" "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"
    [ "$(bbr_tc_rate_display eth0 "$FAKE_TC")" = "1024Mbit（外部 tbf）" ] \
        || { echo "BBR did not label a foreign tbf rate" >&2; exit 1; }
    APPLY_RC=0
    bbr_tc_apply_runtime eth0 100 100 "$FAKE_TC" >/dev/null 2>&1 || APPLY_RC=$?
    if [ "$APPLY_RC" -ne 2 ]; then
        echo "BBR accepted a foreign root qdisc" >&2
        exit 1
    fi
    [ ! -s "$TC_TEST_LOG" ] || { echo "BBR modified a foreign root qdisc" >&2; exit 1; }

    REMOVE_RC=0
    bbr_remove_tc >/dev/null 2>&1 || REMOVE_RC=$?
    [ "$REMOVE_RC" -eq 2 ] || { echo "BBR cancel did not identify the foreign tbf" >&2; exit 1; }
    [ ! -s "$TC_TEST_LOG" ] || { echo "BBR cancel deleted a foreign tbf without confirmation" >&2; exit 1; }
    if bbr_tc_remove_confirm eth0 "$FAKE_TC" >/dev/null 2>&1 <<'EOF'
DELETE eth1
EOF
    then
        echo "BBR accepted an incorrect foreign qdisc deletion confirmation" >&2
        exit 1
    fi
    bbr_tc_remove_confirm eth0 "$FAKE_TC" >/dev/null <<'EOF'
DELETE eth0
EOF
    bbr_remove_tc 1 >/dev/null \
        || { echo "BBR refused to delete a confirmed foreign tbf" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "BBR did not delete the confirmed foreign tbf" >&2; exit 1; }
    REMOVE_SNAPSHOT=$(find "$TC_BACKUP_DIR" -type f -name 'eth0_*.txt' -print -quit)
    [ -n "$REMOVE_SNAPSHOT" ] && grep -qF 'qdisc tbf 8001: root' "$REMOVE_SNAPSHOT" \
        || { echo "BBR did not snapshot the foreign tbf before deletion" >&2; exit 1; }
    : > "$TC_TEST_LOG"
    rm -rf "$TC_BACKUP_DIR"

    if bbr_tc_force_confirm eth0 100 "$FAKE_TC" >/dev/null 2>&1 <<'EOF'
FORCE eth1
EOF
    then
        echo "BBR accepted an incorrect force confirmation" >&2
        exit 1
    fi
    bbr_tc_force_confirm eth0 100 "$FAKE_TC" >/dev/null <<'EOF'
FORCE eth0
EOF

    bbr_tc_apply_runtime eth0 100 100 "$FAKE_TC" 1 >/dev/null \
        || { echo "BBR refused an explicitly authorized foreign qdisc takeover" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not delete the foreign root qdisc" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 root handle 1: htb default 10' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not install its root qdisc" >&2; exit 1; }
    grep -qx 'class add dev eth0 parent 1: classid 1:10 htb rate 100mbit ceil 100mbit burst 100kb cburst 100kb' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not install its shaping class" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 parent 1:10 handle 100: fq maxrate 100mbit' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not install its fq leaf" >&2; exit 1; }
    SNAPSHOT=$(find "$TC_BACKUP_DIR" -type f -name 'eth0_*.txt' -print -quit)
    [ -n "$SNAPSHOT" ] || { echo "BBR force takeover did not save a tc snapshot" >&2; exit 1; }
    grep -qF 'qdisc tbf 8001: root' "$SNAPSHOT" \
        && grep -qF 'class tbf 8001:1 root' "$SNAPSHOT" \
        && grep -qF 'filter parent 8001:' "$SNAPSHOT" \
        && grep -qF '"kind":"tbf"' "$SNAPSHOT" \
        || { echo "BBR tc snapshot omitted qdisc/class/filter diagnostics" >&2; exit 1; }
)
[[ "$(bbr_route_token 'default dev eth0 proto static metric 100' dev)" = eth0 ]] || { echo "BBR direct default route device parsing failed" >&2; exit 1; }
[[ -z "$(bbr_route_token 'default dev eth0 proto static metric 100' via)" ]] || { echo "BBR direct default route invented a gateway" >&2; exit 1; }
[[ "$(bbr_route_strip_cwnd 'default via 192.0.2.1 dev eth0 metric 100 initcwnd 50 initrwnd 50')" = 'default via 192.0.2.1 dev eth0 metric 100' ]] || { echo "BBR initcwnd route cleanup failed" >&2; exit 1; }
(
    ROUTE_CALL="$TMP/bbr-route-call"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_initcwnd_route
    ip() { printf '%s\n' "$*" > "$ROUTE_CALL"; }
    bbr_apply_initcwnd_route 4 'default dev eth0 proto static metric 100' 50
    grep -qx -- '-4 route replace default dev eth0 proto static metric 100 initcwnd 50 initrwnd 50' "$ROUTE_CALL" || {
        echo "BBR direct route initcwnd application was malformed" >&2
        exit 1
    }
)
[[ "$(bbr_bdp_mb 100 50)" != "0.00" ]] || { echo "BBR BDP estimate was truncated to zero" >&2; exit 1; }
[[ "$(bbr_buffer_target_mb 100 50)" = "1" ]] || { echo "BBR BDP buffer target rounding failed" >&2; exit 1; }
[[ "$(bbr_recommend_profile 4095)" = balanced ]] || { echo "BBR sub-4GB recommendation changed unexpectedly" >&2; exit 1; }
[[ "$(bbr_recommend_profile 4096)" = throughput ]] || { echo "BBR 4GB recommendation does not match documentation" >&2; exit 1; }

BBR_TC_HELPER_TEST="$TMP/tc-helper.sh"
BBR_CWND_HELPER_TEST="$TMP/cwnd-helper.sh"
awk 'p && /^TC_HELPER_EOF$/{exit} /<< '\''TC_HELPER_EOF'\''/{p=1; next} p{print}' "$ROOT/src/modules/bbr.sh" > "$BBR_TC_HELPER_TEST"
awk 'p && /^CWND_HELPER_EOF$/{exit} /<< '\''CWND_HELPER_EOF'\''/{p=1; next} p{print}' "$ROOT/src/modules/bbr.sh" > "$BBR_CWND_HELPER_TEST"
sh -n "$BBR_TC_HELPER_TEST" || { echo "Generated tc helper has syntax errors" >&2; exit 1; }
sh -n "$BBR_CWND_HELPER_TEST" || { echo "Generated initcwnd helper has syntax errors" >&2; exit 1; }

(
    HELPER_STATE="$TMP/tc-helper-mq.state"
    HELPER_RUN="$TMP/tc-helper-mq.sh"
    HELPER_BIN="$TMP/tc-helper-bin"
    HELPER_LOG="$TMP/tc-helper-mq.log"
    export HELPER_LOG
    sed "s|^STATE=.*|STATE=$HELPER_STATE|" "$BBR_TC_HELPER_TEST" > "$HELPER_RUN"
    chmod +x "$HELPER_RUN"
    printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$HELPER_STATE"
    mkdir -p "$HELPER_BIN"
    cat > "$HELPER_BIN/tc" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then echo 'qdisc mq 0: root'; exit 0; fi
if [ "$1 $2" = "class show" ]; then exit 0; fi
printf '%s\n' "$*" >> "$HELPER_LOG"
[ "$1 $2" != "qdisc del" ]
EOF
    chmod +x "$HELPER_BIN/tc"
    PATH="$HELPER_BIN:$PATH" "$HELPER_RUN" apply \
        || { echo "Generated tc helper could not replace mq after reboot" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: htb default 10' "$HELPER_LOG" \
        || { echo "Generated tc helper did not replace mq after reboot" >&2; exit 1; }
    ! grep -qx 'qdisc del dev eth0 root' "$HELPER_LOG" \
        || { echo "Generated tc helper tried to delete mq after reboot" >&2; exit 1; }
)

(
    TC_STATE_FILE="$TMP/tc-persistence.state"
    TC_HELPER="$TMP/tc-persistence-helper"
    SERVICE_TC="$TMP/tc-persistence.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_write_persistence
    SERVICE_TC_INIT="$TMP/tc-persistence.init"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_tc_write_persistence
    systemd_available() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_tc_write_persistence
    systemctl() { return 0; }
    bbr_tc_write_persistence eth0 500 500 1 \
        || { echo "BBR failed to persist an authorized tc takeover" >&2; exit 1; }
    grep -qx 'FORCE=1' "$TC_STATE_FILE" \
        || { echo "BBR tc persistence omitted force authorization" >&2; exit 1; }
    grep -qF '*) [ "$FORCE" -eq 1 ] || exit 1 ;;' "$TC_HELPER" \
        || { echo "Generated tc helper does not gate foreign qdisc takeover" >&2; exit 1; }
)

for fn in docker_install docker_status docker_select_container docker_upgrade_container docker_container_action docker_inspect_label docker_download_file docker_compose_basename docker_compose_fetch_and_deploy; do
    declare -F "$fn" >/dev/null || { echo "Missing Docker function: $fn" >&2; exit 1; }
done

for fn in self_install self_script_valid self_resolve_script_source self_fetch_script self_shortcut_owned self_install_shortcut self_remove_shortcut self_offline_bundle_create self_offline_bundle_install self_update self_manifest_value self_remote_main_sha monitor_alert_check monitor_alert_config_menu monitor_alert_home_menu monitor_alert_daily_report monitor_alert_host_label monitor_alert_host_label_html monitor_alert_html_escape monitor_alert_set_host_label monitor_time_normalize monitor_date_normalize monitor_int_normalize monitor_positive_number_valid monitor_positive_int_valid monitor_percent_valid monitor_renew_notice_days_valid monitor_renew_future_date monitor_traffic_interfaces monitor_traffic_reset_day_valid monitor_traffic_totals monitor_traffic_delta_bytes monitor_traffic_reconcile_counters monitor_traffic_usage_triplet monitor_traffic_usage_text monitor_traffic_set_cycle_usage_split_gb monitor_alert_service_state monitor_alert_any_service_state monitor_alert_ssh_state monitor_alert_test_snapshot monitor_alert_resource_snapshot monitor_alert_traffic_snapshot monitor_alert_renew_snapshot monitor_alert_renew_mark_paid monitor_alert_renew_auto_advance_toggle monitor_alert_renew_auto_advance monitor_alert_renew_reset_state monitor_alert_notify monitor_alert_telegram_send monitor_alert_history_add monitor_alert_history_view monitor_alert_cooldown_seconds monitor_alert_time_to_minutes monitor_alert_in_silence monitor_alert_metrics monitor_alert_metrics_sample monitor_alert_trend_line monitor_alert_trend_summary monitor_alert_level_label monitor_alert_level_icon monitor_alert_level_rank monitor_alert_worst_level monitor_alert_daily_cron_expr monitor_alert_cron_command monitor_alert_cron_without_managed monitor_alert_release_lock monitor_alert_acquire_lock monitor_alert_install_cron monitor_alert_remove_cron monitor_alert_cron_status monitor_alert_next_daily_time monitor_alert_configured_without_cron monitor_alert_service_menu monitor_alert_notify_menu monitor_alert_resource_menu monitor_alert_traffic_menu monitor_alert_daily_menu monitor_alert_renew_menu monitor_alert_advanced_menu monitor_alert_quick_setup_menu config_health_check diagnostic_bundle_create; do
    declare -F "$fn" >/dev/null || { echo "Missing new function: $fn" >&2; exit 1; }
done

for fn in common_software_menu system_reinstall_menu software_reinstall_menu software_group_packages; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in config_export_archive config_import_archive config_transfer_menu rollback_center_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing toolbox function: $fn" >&2; exit 1; }
done

for fn in stun_ports_normalize stun_host_valid stun_udp_explanation stun_nat_explanation stun_mapping_explanation stun_filtering_explanation stun_confidence_explanation stun_recommendation stun_probe_engine stun_render_results stun_probe_execute stun_nat_quick stun_nat_custom stun_nat_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing STUN function: $fn" >&2; exit 1; }
done
[[ "$(stun_ports_normalize '3478, 19302;3478 443')" = "3478,19302,443" ]] || { echo "STUN port normalization failed" >&2; exit 1; }
! stun_ports_normalize '0,3478' >/dev/null 2>&1 || { echo "STUN accepted port zero" >&2; exit 1; }
! stun_ports_normalize '3478,65536' >/dev/null 2>&1 || { echo "STUN accepted an out-of-range port" >&2; exit 1; }
! stun_ports_normalize '1,2,3,4,5,6,7,8,9,10,11,12,13' >/dev/null 2>&1 || { echo "STUN accepted more than 12 ports" >&2; exit 1; }
stun_host_valid stun.nextcloud.com || { echo "STUN rejected a valid hostname" >&2; exit 1; }
! stun_host_valid 'bad host;id' || { echo "STUN accepted an unsafe hostname" >&2; exit 1; }
! stun_host_valid 'bad..example.com' || { echo "STUN accepted an empty hostname label" >&2; exit 1; }
[[ "$(stun_probe_engine selftest - -)" = $'SELFTEST\tok' ]] || { echo "STUN protocol self-test failed" >&2; exit 1; }
! grep -Fq 'stun.sipgate.net' "$ROOT/src/modules/stun.sh" || { echo "STUN still uses the retired Sipgate endpoint" >&2; exit 1; }
grep -Fq '("stun.nextcloud.com", 443)' "$ROOT/src/modules/stun.sh" || { echo "STUN quick endpoints missing Nextcloud UDP/443" >&2; exit 1; }
grep -Fq '("stun.nextcloud.com", 3478)' "$ROOT/src/modules/stun.sh" || { echo "STUN quick endpoints missing Nextcloud UDP/3478" >&2; exit 1; }
[[ "$(stun_udp_explanation 5 5)" = *"全部节点响应"* ]] || { echo "STUN complete UDP explanation failed" >&2; exit 1; }
[[ "$(stun_udp_explanation 3 5)" = *"3/5 节点响应"* ]] || { echo "STUN partial UDP explanation failed" >&2; exit 1; }
[[ "$(stun_udp_explanation 0 5)" = *"无节点响应"* ]] || { echo "STUN unavailable UDP explanation failed" >&2; exit 1; }
for NAT_RESULT in open_internet public_udp_firewall full_cone restricted_cone port_restricted symmetric nat_unknown udp_unavailable unknown; do
    [ -n "$(stun_nat_explanation "$NAT_RESULT")" ] || { echo "STUN NAT explanation missing for $NAT_RESULT" >&2; exit 1; }
    [ -n "$(stun_recommendation "$NAT_RESULT")" ] || { echo "STUN recommendation missing for $NAT_RESULT" >&2; exit 1; }
done
for MAPPING_RESULT in eim adm apdm endpoint_dependent unknown; do
    [ -n "$(stun_mapping_explanation "$MAPPING_RESULT")" ] || { echo "STUN mapping explanation missing for $MAPPING_RESULT" >&2; exit 1; }
done
for FILTERING_RESULT in eif adf apdf unknown; do
    [ -n "$(stun_filtering_explanation "$FILTERING_RESULT")" ] || { echo "STUN filtering explanation missing for $FILTERING_RESULT" >&2; exit 1; }
done
for CONFIDENCE_RESULT in high medium low; do
    [ -n "$(stun_confidence_explanation "$CONFIDENCE_RESULT")" ] || { echo "STUN confidence explanation missing for $CONFIDENCE_RESULT" >&2; exit 1; }
done
STUN_RENDERED=$(stun_render_results $'SUMMARY\t10.0.0.2\t12345\t198.51.100.2:54321\tapdm\tapdf\tsymmetric\thigh\t5\t5')
[[ "$STUN_RENDERED" = *"结果解释"* && "$STUN_RENDERED" = *"UDP 打洞和 P2P 直连较困难"* ]] || { echo "STUN rendered result explanations are missing" >&2; exit 1; }

[[ "$(software_group_packages apt base)" = *curl* ]] || { echo "APT base package mapping is incomplete" >&2; exit 1; }
[[ "$(software_group_packages apk network)" = *mtr* ]] || { echo "APK network package mapping is incomplete" >&2; exit 1; }
CLI_HELP=$(show_cli_help)
[[ "$CLI_HELP" = *"--ssh-menu"* ]] || { echo "CLI help missing SSH entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--user-menu"* ]] || { echo "CLI help missing user management entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--docker-menu"* ]] || { echo "CLI help missing Docker entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--monitor-home"* ]] || { echo "CLI help missing monitor entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--hostname-menu"* ]] || { echo "CLI help missing hostname entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--stun-test"* ]] || { echo "CLI help missing STUN entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--ddns-link"* ]] || { echo "CLI help missing DDNS link replacement entry" >&2; exit 1; }
DDNS_ZONE_FILE="$TMP/cf_zone"
cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=home.example.com
MODE=dual
EOF
ddns_cfg_enable_a || { echo "Legacy DDNS IPv4 enable detection failed" >&2; exit 1; }
ddns_cfg_enable_aaaa || { echo "Legacy DDNS IPv6 enable detection failed" >&2; exit 1; }
[[ "$(ddns_cfg_domain4)" = "home.example.com" ]] || { echo "Legacy DDNS IPv4 domain failed" >&2; exit 1; }
[[ "$(ddns_cfg_domain6)" = "home.example.com" ]] || { echo "Legacy DDNS IPv6 domain failed" >&2; exit 1; }
[[ "$(ddns_mode_label)" = "IPv4 + IPv6（同域名）" ]] || { echo "Legacy DDNS mode label failed" >&2; exit 1; }
[[ "$(ddns_provider)" = "cloudflare" ]] || { echo "Legacy DDNS provider fallback failed" >&2; exit 1; }
[[ "$(ddns_interval_min)" = "5" ]] || { echo "Legacy DDNS interval fallback failed" >&2; exit 1; }
[[ "$(ddns_interval_normalize 1)" = "1" ]] || { echo "DDNS interval 1 should be valid" >&2; exit 1; }
[[ "$(ddns_interval_normalize 2)" = "2" ]] || { echo "DDNS interval 2 should be valid" >&2; exit 1; }
[[ "$(ddns_interval_normalize 5)" = "5" ]] || { echo "DDNS interval 5 should be valid" >&2; exit 1; }
[[ "$(ddns_interval_normalize 0)" = "5" ]] || { echo "DDNS interval 0 should fall back to 5" >&2; exit 1; }
[[ "$(ddns_interval_normalize 60)" = "5" ]] || { echo "DDNS interval 60 should fall back to 5" >&2; exit 1; }
[[ "$(ddns_cron_expr 1)" = "* * * * *" ]] || { echo "DDNS interval 1 cron expression failed" >&2; exit 1; }
[[ "$(ddns_cron_expr 2)" = "*/2 * * * *" ]] || { echo "DDNS interval 2 cron expression failed" >&2; exit 1; }
[[ "$(ddns_cron_expr 5)" = "*/5 * * * *" ]] || { echo "DDNS interval 5 cron expression failed" >&2; exit 1; }
DDNS_CRON_SAMPLE=$(printf '%s\n' \
    '*/5 * * * * /root/ddns.sh >> /var/log/ddns.log 2>&1' \
    '*/5 * * * * /opt/another-ddns.sh >> /var/log/another-ddns.log 2>&1')
DDNS_CRON_FILTERED=$(printf '%s\n' "$DDNS_CRON_SAMPLE" | ddns_cron_without_managed)
[[ "$DDNS_CRON_FILTERED" != *'/root/ddns.sh'* ]] || { echo "Managed DDNS cron entry was not removed" >&2; exit 1; }
[[ "$DDNS_CRON_FILTERED" = *'/opt/another-ddns.sh'* ]] || { echo "Unrelated DDNS cron entry was removed" >&2; exit 1; }
cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=v6.example.com
MODE=dual
ENABLE_A=true
ENABLE_AAAA=true
INTERVAL_MIN=2
EOF
[[ "$(ddns_primary_domain)" = "v4.example.com" ]] || { echo "DDNS primary domain failed" >&2; exit 1; }
[[ "$(ddns_mode_label)" = "IPv4 + IPv6（分别设置）" ]] || { echo "Split DDNS mode label failed" >&2; exit 1; }
[[ "$(ddns_interval_min)" = "2" ]] || { echo "Configured DDNS interval failed" >&2; exit 1; }
[[ "$(ddns_build_domain @ example.com)" = "example.com" ]] || { echo "DDNS root domain build failed" >&2; exit 1; }
[[ "$(ddns_build_domain v6.example.com example.com)" = "v6.example.com" ]] || { echo "DDNS full domain build failed" >&2; exit 1; }
[[ "$(ddns_domain_dot example.com)" = "example.com." ]] || { echo "DDNS trailing-dot helper failed" >&2; exit 1; }
[[ "$(ddns_ipv6_subdomain_default hktv4)" = "hktv6" ]] || { echo "DDNS IPv6 v4-to-v6 default failed" >&2; exit 1; }
[[ "$(ddns_ipv6_subdomain_default home)" = "home-v6" ]] || { echo "DDNS IPv6 independent default failed" >&2; exit 1; }
[[ "$(ddns_ipv6_subdomain_default @)" = "v6" ]] || { echo "DDNS IPv6 root-domain default failed" >&2; exit 1; }
SS_SIP002='ss://dGVzdDpwYXNz@[2001:db8::1]:12928#node'
[[ "$(ddns_replace_link_host "$SS_SIP002" v6.example.com)" = 'ss://dGVzdDpwYXNz@v6.example.com:12928#node' ]] \
    || { echo "DDNS SIP002 Shadowsocks link replacement failed" >&2; exit 1; }
SS_LEGACY='ss://YWVzLTEyOC1nY206dGVzdC1wYXNzQFsyMDAxOmRiODo6MV06ODM4OA#legacy'
[[ "$(ddns_replace_link_host "$SS_LEGACY" v4.example.com)" = 'ss://YWVzLTEyOC1nY206dGVzdC1wYXNzQHY0LmV4YW1wbGUuY29tOjgzODg#legacy' ]] \
    || { echo "DDNS legacy Shadowsocks link replacement failed" >&2; exit 1; }
VLESS_LINK='vless://test-id@[2001:db8::1]:443?security=tls&sni=edge.example.com#node'
[[ "$(ddns_replace_link_host "$VLESS_LINK" v6.example.com)" = 'vless://test-id@v6.example.com:443?security=tls&sni=edge.example.com#node' ]] \
    || { echo "DDNS VLESS link replacement failed" >&2; exit 1; }
VMESS_LINK='vmess://eyJ2IjoiMiIsInBzIjoibm9kZSIsImFkZCI6IjIwMDE6ZGI4OjoxIiwicG9ydCI6IjQ0MyIsImlkIjoidGVzdC1pZCIsIm5ldCI6IndzIn0='
[[ "$(ddns_replace_link_host "$VMESS_LINK" v6.example.com)" = 'vmess://eyJ2IjoiMiIsInBzIjoibm9kZSIsImFkZCI6InY2LmV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIsImlkIjoidGVzdC1pZCIsIm5ldCI6IndzIn0=' ]] \
    || { echo "DDNS VMess link replacement failed" >&2; exit 1; }
! ddns_replace_link_host 'not-a-link' v4.example.com >/dev/null 2>&1 \
    || { echo "DDNS link replacement accepted malformed input" >&2; exit 1; }
CF_MIXED_RECORDS='{"success":true,"result":[{"id":"a-id","type":"A","name":"dual.example.com","content":"192.0.2.10"},{"id":"aaaa-id","type":"AAAA","name":"dual.example.com.","content":"2001:db8::10"},{"id":"other-id","type":"AAAA","name":"other.example.com","content":"2001:db8::20"}]}'
CF_DUPLICATE_RECORDS='{"success":true,"result":[{"id":"a-1","type":"A","name":"dual.example.com","content":"192.0.2.10"},{"id":"a-2","type":"A","name":"dual.example.com","content":"192.0.2.11"}]}'
[[ "$(printf '%s' "$CF_MIXED_RECORDS" | ddns_cf_exact_records AAAA dual.example.com)" = $'aaaa-id\t2001:db8::10' ]] || { echo "Cloudflare exact AAAA record selection failed" >&2; exit 1; }
[[ "$(printf '%s' "$CF_MIXED_RECORDS" | ddns_cf_exact_records A dual.example.com)" = $'a-id\t192.0.2.10' ]] || { echo "Cloudflare exact A record selection failed" >&2; exit 1; }
! printf 'not-json' | ddns_cf_exact_records A dual.example.com >/dev/null 2>&1 || { echo "Cloudflare record parser accepted invalid JSON" >&2; exit 1; }
(
    curl() { printf '%s\n' "$CF_DUPLICATE_RECORDS"; }
    ! ddns_cf_record_ensure zone token A dual.example.com 192.0.2.10 60 false >/dev/null 2>&1 \
        || { echo "Cloudflare installer accepted duplicate A records" >&2; exit 1; }
)
(
    DDNS_TEST="$TMP/ddns-dual-install"
    mkdir -p "$DDNS_TEST/state"
    DDNS_SCRIPT="$DDNS_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TEST/cf_token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TEST/huawei_key"
    DDNS_LOG="$DDNS_TEST/ddns.log"
    DDNS_ZONE_FILE="$DDNS_TEST/cf_zone"
    DDNS_STATE_DIR="$DDNS_TEST/state"
    CF_POST_LOG="$DDNS_TEST/posts"
    ddns_ensure_cron() { return 0; }
    ddns_start_cron_service() { return 0; }
    ddns_install_cron_job() { return 0; }
    ddns_fetch_public_ip() { [ "$1" = 4 ] && echo 198.51.100.10 || echo 2001:db8::10; }
    bash() { return 0; }
    curl() {
        case "$*" in
            *"/zones?name=example.com"*) printf '%s\n' '{"success":true,"result":[{"id":"zone-id"}]}' ;;
            *" -X POST "*) printf '%s\n' "$*" >> "$CF_POST_LOG"; printf '%s\n' '{"success":true,"result":{"id":"new-id"}}' ;;
            *"/dns_records?"*) printf '%s\n' '{"success":true,"result":[]}' ;;
            *) return 1 ;;
        esac
    }
    ddns_install_cloudflare <<'EOF' >/dev/null
example.com

hktv4
y


cf-token




EOF
    grep -qx 'DOMAIN4=hktv4.example.com' "$DDNS_ZONE_FILE" || { echo "DDNS dual install wrote the wrong IPv4 domain" >&2; exit 1; }
    grep -qx 'DOMAIN6=hktv6.example.com' "$DDNS_ZONE_FILE" || { echo "DDNS dual install reused the IPv4 domain for AAAA" >&2; exit 1; }
    [ "$(wc -l < "$CF_POST_LOG")" -eq 2 ] || { echo "DDNS dual install did not create exactly two records" >&2; exit 1; }
    grep -Fq '"type":"A","name":"hktv4.example.com"' "$CF_POST_LOG" || { echo "DDNS dual install missed the IPv4 A record" >&2; exit 1; }
    grep -Fq '"type":"AAAA","name":"hktv6.example.com"' "$CF_POST_LOG" || { echo "DDNS dual install missed the IPv6 AAAA record" >&2; exit 1; }
)
cat > "$DDNS_ZONE_FILE" <<'EOF'
PROVIDER=huawei
DOMAIN=home.example.com
DOMAIN4=home.example.com
ZONE=example.com
MODE=ipv4
ENABLE_A=true
ENABLE_AAAA=false
ENDPOINT=https://dns.myhuaweicloud.com
EOF
[[ "$(ddns_provider)" = "huawei" ]] || { echo "Huawei DDNS provider detection failed" >&2; exit 1; }
[[ "$(ddns_provider_label)" = "华为云 DNS" ]] || { echo "Huawei DDNS provider label failed" >&2; exit 1; }
ddns_cfg_enable_a || { echo "Huawei DDNS IPv4 enable failed" >&2; exit 1; }
! ddns_cfg_enable_aaaa || { echo "Huawei DDNS IPv6 should be disabled" >&2; exit 1; }
grep -Fq 'read -rp "  Cloudflare API Token（输入可见）: " DDNS_TOKEN' "$ROOT/src/modules/ddns.sh" || { echo "Cloudflare API Token input must remain visible" >&2; exit 1; }
grep -q "SDK-HMAC-SHA256" "$ROOT/src/modules/ddns.sh" || { echo "Huawei DDNS signer missing" >&2; exit 1; }
! grep -q "LC_TIME" "$ROOT/src/modules/ddns.sh" || { echo "DDNS menu must not use LC_TIME locale variable" >&2; exit 1; }
CLOUDFLARE_DDNS_TEMPLATE="$TMP/cloudflare-ddns-template.sh"
awk "BEGIN{p=0} /cat > \"\\\$DDNS_SCRIPT\" << 'DDNS_INNER'/{p=1; next} /^DDNS_INNER$/{if(p){exit}} p{print}" "$ROOT/src/modules/ddns.sh" > "$CLOUDFLARE_DDNS_TEMPLATE"
bash -n "$CLOUDFLARE_DDNS_TEMPLATE" || { echo "Cloudflare DDNS generated template has syntax errors" >&2; exit 1; }
grep -Fq 'LOCK_DIR="/run/vps-tools-ddns.lock"' "$CLOUDFLARE_DDNS_TEMPLATE" || { echo "Cloudflare DDNS concurrency lock missing" >&2; exit 1; }
grep -Fq 'record_ip_file()' "$CLOUDFLARE_DDNS_TEMPLATE" || { echo "Cloudflare DDNS successful IP state missing" >&2; exit 1; }
CF_RECORD_INFO_HELPER="$TMP/cloudflare-record-info.sh"
awk 'p && /^ZONE_ID=/{exit} /^cf_record_info\(\)/{p=1} p{print}' "$CLOUDFLARE_DDNS_TEMPLATE" > "$CF_RECORD_INFO_HELPER"
# shellcheck source=/dev/null
source "$CF_RECORD_INFO_HELPER"
[[ "$(printf '%s' "$CF_MIXED_RECORDS" | cf_record_info AAAA dual.example.com)" = 'aaaa-id|2001:db8::10' ]] || { echo "Generated Cloudflare updater selected the wrong record type" >&2; exit 1; }
[[ "$(printf '%s' "$CF_DUPLICATE_RECORDS" | cf_record_info A dual.example.com)" = 'DUPLICATE|2' ]] || { echo "Generated Cloudflare updater did not reject duplicate records" >&2; exit 1; }
CF_SYNC_LINE=$(grep -nF 'if [ "$NEW_IP" = "$VERIFY_IP" ]; then' "$CLOUDFLARE_DDNS_TEMPLATE" | head -1 | cut -d: -f1)
CF_SKIP_LINE=$(grep -nF 'if [ -z "$VERIFY_IP" ] || [ "$VERIFY_IP" != "$OLD_IP" ]; then' "$CLOUDFLARE_DDNS_TEMPLATE" | head -1 | cut -d: -f1)
[[ -n "$CF_SYNC_LINE" && -n "$CF_SKIP_LINE" && "$CF_SYNC_LINE" -lt "$CF_SKIP_LINE" ]] || { echo "Cloudflare DDNS synchronized second-check branch is unreachable" >&2; exit 1; }
CF_STATE_HELPERS="$TMP/cloudflare-state-helpers.sh"
awk 'p && /^write_record_change\(\)/{exit} /^record_status_file\(\)/{p=1} p{print}' "$CLOUDFLARE_DDNS_TEMPLATE" > "$CF_STATE_HELPERS"
# shellcheck source=/dev/null
source "$CF_STATE_HELPERS"
STATE_DIR="$TMP/generated-ddns-state"
mkdir -p "$STATE_DIR"
write_record_status A home.example.com unchanged 1.1.1.1 2.2.2.2
[[ "$(previous_record_ip A home.example.com)" = "2.2.2.2" ]] || { echo "DDNS legacy successful IP migration failed" >&2; exit 1; }
write_record_ip A home.example.com 2.2.2.2
write_record_status A home.example.com fetch_failed "" ""
[[ "$(previous_record_ip A home.example.com)" = "2.2.2.2" ]] || { echo "DDNS failure overwrote the last successful IP" >&2; exit 1; }
HUAWEI_DDNS_TEMPLATE="$TMP/huawei-ddns-template.sh"
awk "BEGIN{p=0} /cat > \"\\\$DDNS_SCRIPT\" << 'DDNS_HUAWEI_INNER'/{p=1; next} /^DDNS_HUAWEI_INNER$/{if(p){exit}} p{print}" "$ROOT/src/modules/ddns.sh" > "$HUAWEI_DDNS_TEMPLATE"
bash -n "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS generated template has syntax errors" >&2; exit 1; }
grep -Fq 'JSON_INPUT=$(cat)' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS JSON parser must preserve piped API responses" >&2; exit 1; }
grep -Fq 'fetch_ip6_local' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS IPv6 local fallback missing" >&2; exit 1; }
grep -Fq 'LOCK_DIR="/run/vps-tools-ddns.lock"' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS concurrency lock missing" >&2; exit 1; }
grep -Fq 'record_ip_file()' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS successful IP state missing" >&2; exit 1; }
awk 'p && /^except Exception:/{exit} /^except urllib\.error\.HTTPError/{p=1} p{print}' "$HUAWEI_DDNS_TEMPLATE" | grep -Fq 'sys.exit(1)' || { echo "Huawei DDNS HTTP errors must fail API calls" >&2; exit 1; }
FETCH_IP6_LOCAL="$TMP/fetch-ip6-local.sh"
awk 'p{print} /^fetch_ip6_local\(\) \{/{p=1; print; next} p && /^}$/{exit}' "$HUAWEI_DDNS_TEMPLATE" > "$FETCH_IP6_LOCAL"
# shellcheck source=/dev/null
source "$FETCH_IP6_LOCAL"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
cat <<'IPADDR'
2: eth0    inet6 2404:c804:2331:ad01:be24:11ff:fe45:5e90/64 scope global dynamic mngtmpaddr \       valid_lft 1041sec preferred_lft 1041sec
2: eth0    inet6 2001:db8::100/64 scope global temporary dynamic \       valid_lft 1041sec preferred_lft 1041sec
IPADDR
EOF
chmod +x "$TMP/bin/ip"
[[ "$(PATH="$TMP/bin:$PATH" fetch_ip6_local)" = "2404:c804:2331:ad01:be24:11ff:fe45:5e90" ]] || { echo "DDNS IPv6 local fallback picked the wrong address" >&2; exit 1; }
DDNS_SAMPLE_LOG="$TMP/ddns.log"
DDNS_STATE_DIR="$TMP/ddns-state"
mkdir -p "$DDNS_STATE_DIR"
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:00:02] OK: AAAA v6jp99.289599.xyz 更新成功 2001:db8::1 → 2001:db8::2
[2026-07-02 23:05:01] OK: A jp99.289599.xyz 未变化 2.2.2.2
[2026-07-02 23:05:02] OK: AAAA v6jp99.289599.xyz 未变化 2001:db8::2
EOF
[[ "$(ddns_latest_log_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 未变化 2.2.2.2"* ]] || { echo "DDNS IPv4 latest log lookup failed" >&2; exit 1; }
[[ "$(ddns_latest_log_line AAAA v6jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"AAAA v6jp99.289599.xyz 未变化 2001:db8::2"* ]] || { echo "DDNS IPv6 latest log lookup failed" >&2; exit 1; }
[[ "$(ddns_latest_change_log_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 1.1.1.1"* ]] || { echo "DDNS IPv4 change log lookup failed" >&2; exit 1; }
[[ "$(ddns_latest_change_log_line AAAA v6jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"AAAA v6jp99.289599.xyz 更新成功 2001:db8::1"* ]] || { echo "DDNS IPv6 change log lookup failed" >&2; exit 1; }
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 1.1.1.1"* ]] || { echo "DDNS current change lookup failed" >&2; exit 1; }
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:06:01] OK: A jp99.289599.xyz IP变化 2.2.2.2 → 3.3.3.3（DNS已同步）
[2026-07-02 23:07:01] OK: A jp99.289599.xyz 未变化 3.3.3.3
EOF
[[ "$(ddns_latest_change_log_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz IP变化 2.2.2.2 → 3.3.3.3"* ]] || { echo "DDNS synced IP change log lookup failed" >&2; exit 1; }
cat > "$DDNS_STATE_DIR/.cf_last_change_A" <<'EOF'
2026-07-02 23:00:01|A|1.1.1.1|2.2.2.2|jp99.289599.xyz
EOF
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:10:01] OK: A jp99.289599.xyz 未变化 3.3.3.3
EOF
! ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG" >/dev/null || { echo "DDNS stale change should be hidden when current IP differs" >&2; exit 1; }
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:10:01] OK: A jp99.289599.xyz 更新成功 2.2.2.2 → 3.3.3.3
[2026-07-02 23:11:01] OK: A jp99.289599.xyz 未变化 3.3.3.3
EOF
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 2.2.2.2 → 3.3.3.3"* ]] || { echo "DDNS newer log change should beat stale state file" >&2; exit 1; }
cat > "$DDNS_STATE_DIR/.cf_last_status_A" <<'EOF'
2026-07-02 23:20:01|A|jp99.289599.xyz|unchanged|4.4.4.4|4.4.4.4
EOF
cat > "$DDNS_STATE_DIR/.cf_last_change_A" <<'EOF'
2026-07-02 23:19:01|A|3.3.3.3|4.4.4.4|jp99.289599.xyz
EOF
[[ "$(ddns_record_status_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 未变化 4.4.4.4"* ]] || { echo "DDNS newer state status should beat old log status" >&2; exit 1; }
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 3.3.3.3 → 4.4.4.4"* ]] || { echo "DDNS current state change should be shown" >&2; exit 1; }
cat > "$DDNS_STATE_DIR/.cf_last_change_A" <<'EOF'
2026-07-02 23:21:01|A|4.4.4.4|5.5.5.5|jp99.289599.xyz|synced
EOF
cat > "$DDNS_STATE_DIR/.cf_last_status_A" <<'EOF'
2026-07-02 23:22:01|A|jp99.289599.xyz|unchanged|5.5.5.5|5.5.5.5
EOF
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz IP变化 4.4.4.4 → 5.5.5.5"* ]] || { echo "DDNS synced state change should be shown" >&2; exit 1; }
grep -q "新端口已测试可登录吗" "$ROOT/src/modules/ssh.sh" || { echo "SSH new port confirmation prompt missing" >&2; exit 1; }
grep -q "自动回滚已取消" "$ROOT/src/modules/ssh.sh" || { echo "SSH rollback cancellation message missing" >&2; exit 1; }
grep -q "关闭旧端口防火墙规则" "$ROOT/src/modules/ssh.sh" || { echo "SSH old firewall rule prompt missing" >&2; exit 1; }
system_hostname_valid GreenCloud.HK6666 || { echo "Hostname validation rejected valid dotted name" >&2; exit 1; }
! system_hostname_valid "-bad-name" || { echo "Hostname validation accepted bad leading hyphen" >&2; exit 1; }
[[ "$(monitor_alert_html_escape 'Ali&HKG<ECS>')" = "Ali&amp;HKG&lt;ECS&gt;" ]] || { echo "HTML escape failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_alert_host_label
MON_HOST_LABEL='Ali&HKG<ECS>'
[[ "$(monitor_alert_host_label)" = "Ali&HKG<ECS>" ]] || { echo "Raw host label changed unexpectedly" >&2; exit 1; }
[[ "$(monitor_alert_host_label_html)" = "Ali&amp;HKG&lt;ECS&gt;" ]] || { echo "Escaped host label failed" >&2; exit 1; }
(
    MONITOR_CFG="$TMP/monitor.cfg"
    PWNED="$TMP/monitor-config-executed"
    monitor_alert_cfg() { echo "$MONITOR_CFG"; }
    # shellcheck disable=SC2034 # consumed by monitor_alert_check
    monitor_alert_load_cfg() { MON_ENABLED=no; }
    {
        echo "ENABLED=no"
        echo "HOST_LABEL=\$(touch '$PWNED')"
    } > "$MONITOR_CFG"
    monitor_alert_check
    [ ! -e "$PWNED" ] || { echo "Monitor config was executed as shell" >&2; exit 1; }
)
SSHD_SAMPLE="$TMP/sshd_config"
cat > "$SSHD_SAMPLE" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes

Match User deploy
    PasswordAuthentication yes
EOF
set_config_file "$SSHD_SAMPLE" "PasswordAuthentication" "no"
FIRST_DIRECTIVE=$(grep -m1 -E '^(Include|PasswordAuthentication|Match)' "$SSHD_SAMPLE")
[[ "$FIRST_DIRECTIVE" = "PasswordAuthentication no" ]] || { echo "Managed SSH settings must precede Include and Match blocks" >&2; exit 1; }
SSHD_PORT_SAMPLE="$TMP/sshd-port-config"
cat > "$SSHD_PORT_SAMPLE" <<'EOF'
Port 22
Include /etc/ssh/sshd_config.d/*.conf
Match User deploy
    Port 2200
EOF
set_config_file "$SSHD_PORT_SAMPLE" "Port" "2222"
grep -q '^Port 2222$' "$SSHD_PORT_SAMPLE" \
    || { echo "Managed SSH port was not written" >&2; exit 1; }
! awk 'tolower($1) == "match" {in_match=1} !in_match && $1 == "Port" && $2 == "22" {found=1} END {exit !found}' \
    "$SSHD_PORT_SAMPLE" \
    || { echo "Unmanaged global SSH Port directive was retained" >&2; exit 1; }
grep -q '^[[:space:]]*Port 2200$' "$SSHD_PORT_SAMPLE" \
    || { echo "Match-scoped SSH Port directive was unexpectedly removed" >&2; exit 1; }
(
    SSHD_WRITE_FAIL="$TMP/sshd-write-fail"
    printf '%s\n' 'PasswordAuthentication yes' > "$SSHD_WRITE_FAIL"
    cp "$SSHD_WRITE_FAIL" "$SSHD_WRITE_FAIL.before"
    mv() { return 1; }
    ! set_config_file "$SSHD_WRITE_FAIL" "PasswordAuthentication" "no" \
        || { echo "set_config_file reported success after replacement failure" >&2; exit 1; }
    cmp -s "$SSHD_WRITE_FAIL.before" "$SSHD_WRITE_FAIL" \
        || { echo "set_config_file changed the target after replacement failure" >&2; exit 1; }
)
(
    SSHD_METADATA="$TMP/sshd-metadata"
    printf '%s\n' 'PasswordAuthentication yes' > "$SSHD_METADATA"
    chmod 640 "$SSHD_METADATA"
    SSHD_METADATA_BEFORE=$(stat -Lc '%u:%g:%a' "$SSHD_METADATA")
    set_config_file "$SSHD_METADATA" "PasswordAuthentication" "no"
    [ "$(stat -Lc '%u:%g:%a' "$SSHD_METADATA")" = "$SSHD_METADATA_BEFORE" ] \
        || { echo "set_config_file changed sshd_config owner or mode" >&2; exit 1; }
)
(
    SSHD_REAL="$TMP/sshd-real"
    SSHD_LINK="$TMP/sshd-link"
    printf '%s\n' 'PasswordAuthentication yes' > "$SSHD_REAL"
    if ln -s "$SSHD_REAL" "$SSHD_LINK" 2>/dev/null; then
        ! set_config_file "$SSHD_LINK" "PasswordAuthentication" "no" \
            || { echo "set_config_file replaced an sshd_config symlink" >&2; exit 1; }
        [ -L "$SSHD_LINK" ] && grep -qx 'PasswordAuthentication yes' "$SSHD_REAL" \
            || { echo "Rejected sshd_config symlink was modified" >&2; exit 1; }
        SSHD_CONFIG="$SSHD_LINK"
        ! ssh_prepare_config_candidate SSHD_LINK_CANDIDATE >/dev/null 2>&1 \
            || { echo "SSH candidate preparation followed an sshd_config symlink" >&2; exit 1; }
    fi
)
(
    sshd() { printf '%s\n' 'port 2222'; }
    ssh_candidate_has_unique_port "$TMP/unused-sshd-candidate" 2222 \
        || { echo "Unique effective SSH port was rejected" >&2; exit 1; }
    sshd() {
        printf '%s\n' \
            'port 2222' \
            'listenaddress 0.0.0.0:2222' \
            'listenaddress [::]:2222'
    }
    ssh_candidate_has_unique_port "$TMP/unused-sshd-candidate" 2222 \
        || { echo "Matching ListenAddress ports were rejected" >&2; exit 1; }
    sshd() {
        printf '%s\n' \
            'port 2222' \
            'listenaddress 0.0.0.0:22'
    }
    ! ssh_candidate_has_unique_port "$TMP/unused-sshd-candidate" 2222 \
        || { echo "Mismatched ListenAddress port was accepted" >&2; exit 1; }
    sshd() { printf '%s\n' 'port 2222' 'port 22'; }
    ! ssh_candidate_has_unique_port "$TMP/unused-sshd-candidate" 2222 \
        || { echo "Multiple effective SSH ports from Include were accepted" >&2; exit 1; }
)
(
    systemd_available() { return 0; }
    systemctl() { [ "$1" = is-active ] && [ "$3" = ssh.socket ]; }
    ssh_socket_activated \
        || { echo "Active ssh.socket was not detected" >&2; exit 1; }
    systemctl() { [ "$1" = is-active ] && return 1; }
    ! ssh_socket_activated \
        || { echo "Inactive ssh.socket was treated as active" >&2; exit 1; }
    systemd_available() { return 1; }
    systemctl() { return 0; }
    ! ssh_socket_activated \
        || { echo "ssh.socket was treated as active without systemd" >&2; exit 1; }
)
(
    SSHD_SOCKET_OVERRIDE_DIR="$TMP/ssh.socket.d"
    SSHD_SOCKET_OVERRIDE_FILE="$SSHD_SOCKET_OVERRIDE_DIR/99-vps-tools-port.conf"
    ssh_socket_override_write 2222 \
        || { echo "ssh_socket_override_write failed on a fresh directory" >&2; exit 1; }
    [ -f "$SSHD_SOCKET_OVERRIDE_FILE" ] \
        || { echo "ssh.socket override file was not created" >&2; exit 1; }
    grep -qx 'ListenStream=' "$SSHD_SOCKET_OVERRIDE_FILE" \
        || { echo "ssh.socket override did not clear inherited ListenStream entries" >&2; exit 1; }
    grep -qx 'ListenStream=0.0.0.0:2222' "$SSHD_SOCKET_OVERRIDE_FILE" \
        || { echo "ssh.socket override is missing the IPv4 listener" >&2; exit 1; }
    grep -qxF 'ListenStream=[::]:2222' "$SSHD_SOCKET_OVERRIDE_FILE" \
        || { echo "ssh.socket override is missing the IPv6 listener" >&2; exit 1; }
)
(
    SSHD_SOCKET_OVERRIDE_DIR="$TMP/ssh.socket.d-roundtrip"
    SSHD_SOCKET_OVERRIDE_FILE="$SSHD_SOCKET_OVERRIDE_DIR/99-vps-tools-port.conf"
    ssh_socket_override_backup \
        || { echo "Backing up a missing ssh.socket override failed" >&2; exit 1; }
    [ "$LAST_SOCKET_OVERRIDE_EXISTED" = no ] \
        || { echo "Missing ssh.socket override was recorded as existing" >&2; exit 1; }
    ssh_socket_override_write 3333 \
        || { echo "ssh_socket_override_write failed before restore round-trip" >&2; exit 1; }
    ssh_socket_override_restore \
        || { echo "ssh_socket_override_restore failed for a previously-absent override" >&2; exit 1; }
    [ ! -e "$SSHD_SOCKET_OVERRIDE_FILE" ] \
        || { echo "ssh_socket_override_restore left behind a file that did not exist before" >&2; exit 1; }
    ssh_socket_override_write 2222 \
        || { echo "ssh_socket_override_write failed to seed an existing override" >&2; exit 1; }
    ssh_socket_override_backup \
        || { echo "Backing up an existing ssh.socket override failed" >&2; exit 1; }
    [ "$LAST_SOCKET_OVERRIDE_EXISTED" = yes ] \
        || { echo "Existing ssh.socket override was not recorded as existing" >&2; exit 1; }
    ssh_socket_override_write 4444 \
        || { echo "ssh_socket_override_write failed to apply a new port" >&2; exit 1; }
    ssh_socket_override_restore \
        || { echo "ssh_socket_override_restore failed for a previously-present override" >&2; exit 1; }
    grep -qx 'ListenStream=0.0.0.0:2222' "$SSHD_SOCKET_OVERRIDE_FILE" \
        || { echo "ssh_socket_override_restore did not roll back to the prior port" >&2; exit 1; }
)
(
    SYSTEMCTL_LOG="$TMP/restart-ssh-systemctl.log"
    systemd_available() { return 0; }
    ssh_socket_activated() { return 0; }
    systemctl() { printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"; return 0; }
    restart_ssh \
        || { echo "restart_ssh failed while ssh.socket is active" >&2; exit 1; }
    grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" \
        || { echo "restart_ssh did not reload systemd before restarting ssh.socket" >&2; exit 1; }
    grep -qx 'restart ssh.socket' "$SYSTEMCTL_LOG" \
        || { echo "restart_ssh did not restart ssh.socket" >&2; exit 1; }
    RELOAD_LINE=$(grep -nx 'daemon-reload' "$SYSTEMCTL_LOG" | cut -d: -f1)
    SOCKET_LINE=$(grep -nx 'restart ssh.socket' "$SYSTEMCTL_LOG" | cut -d: -f1)
    [ "$RELOAD_LINE" -lt "$SOCKET_LINE" ] \
        || { echo "restart_ssh reloaded systemd after restarting ssh.socket" >&2; exit 1; }
    systemctl() {
        [ "$1" = restart ] && [ "$2" = ssh.socket ] && return 1
        return 0
    }
    ! restart_ssh >/dev/null 2>&1 \
        || { echo "restart_ssh reported success despite ssh.socket restart failure" >&2; exit 1; }
)
(
    IPTABLES_RULE_PRESENT=yes
    IPTABLES_DELETE_LOG="$TMP/iptables-delete.log"
    IPTABLES_RULES_FILE="$TMP/rules.v4"
    : > "$IPTABLES_RULES_FILE"
    iptables() {
        case "$1" in
            -S) printf '%s\n' '-P INPUT DROP' '-A INPUT -p tcp --dport 22 -j ACCEPT' ;;
            -C) [ "$IPTABLES_RULE_PRESENT" = yes ] ;;
            -D)
                printf '%s\n' "$*" > "$IPTABLES_DELETE_LOG"
                IPTABLES_RULE_PRESENT=no
                ;;
            *) return 1 ;;
        esac
    }
    iptables-save() { printf '%s\n' '*filter' 'COMMIT'; }
    firewall_remove_port 22 \
        || { echo "Exact iptables old-port cleanup failed" >&2; exit 1; }
    [ "${FIREWALL_REMOVE_CHANGED:-no}" = yes ] \
        || { echo "Successful iptables cleanup was not marked as changed" >&2; exit 1; }
    grep -qx -- '-D INPUT -p tcp --dport 22 -j ACCEPT' "$IPTABLES_DELETE_LOG" \
        || { echo "iptables cleanup did not delete the exact SSH allow rule" >&2; exit 1; }
    grep -q '^COMMIT$' "$IPTABLES_RULES_FILE" \
        || { echo "iptables cleanup was not persisted safely" >&2; exit 1; }
)
(
    iptables() {
        case "$1" in
            -S) printf '%s\n' '-P INPUT DROP' '-A INPUT -p tcp --dport 22 -j ACCEPT' ;;
            -C) return 0 ;;
            -D) return 1 ;;
            *) return 1 ;;
        esac
    }
    ! firewall_remove_port 22 >/dev/null 2>&1 \
        || { echo "Failed iptables cleanup reported success" >&2; exit 1; }
    [ "${FIREWALL_REMOVE_CHANGED:-no}" = no ] \
        || { echo "Failed iptables cleanup falsely reported a removed rule" >&2; exit 1; }
)
(
    [ "$(firewall_ufw_port_state $'Status: active\n2222/tcp DENY IN Anywhere' 2222)" = deny ] \
        || { echo "UFW deny rule was mistaken for an allowance" >&2; exit 1; }
    [ "$(firewall_ufw_port_state $'Status: active\n2222/tcp LIMIT IN Anywhere' 2222)" = limit ] \
        || { echo "Unconditional UFW limit rule was not classified as reachable" >&2; exit 1; }
    [ "$(firewall_ufw_port_state $'Status: active\n2222/tcp on eth0 LIMIT IN Anywhere' 2222)" = policy ] \
        || { echo "Interface-scoped UFW limit policy was treated as unconditional" >&2; exit 1; }
    [ "$(firewall_ufw_port_state $'Status: active\n2222/tcp ALLOW IN 192.0.2.1' 2222)" = policy ] \
        || { echo "Source-scoped UFW allow rule was not preserved as policy" >&2; exit 1; }
    # A destination-address-qualified rule only opens the port on that one
    # local address; on a multi-homed host it would not cover the others,
    # so firewall_allow_port deliberately treats "policy" as a hard refusal
    # (src/lib/core.sh:1586-1588) rather than assuming it's fully open.
    [ "$(firewall_ufw_port_state $'Status: active\n10.0.0.5 2222/tcp ALLOW IN Anywhere' 2222)" = policy ] \
        || { echo "UFW rule with a destination address was not treated as scoped" >&2; exit 1; }
)
(
    UFW_RULE_PRESENT=no
    UFW_ROLLBACK_LOG="$TMP/ufw-new-port-rollback"
    ufw() {
        case "$1" in
            status)
                printf '%s\n' 'Status: active'
                ;;
            insert)
                UFW_RULE_PRESENT=yes
                ;;
            delete)
                UFW_RULE_PRESENT=no
                : > "$UFW_ROLLBACK_LOG"
                ;;
            *) return 1 ;;
        esac
    }
    ! firewall_allow_port 2222 <<< "y" >/dev/null 2>&1 \
        || { echo "Failed new-port firewall allowance reported success" >&2; exit 1; }
    [ "$UFW_RULE_PRESENT" = no ] && [ -e "$UFW_ROLLBACK_LOG" ] \
        || { echo "Partial firewall allowance did not roll back its new ufw rule" >&2; exit 1; }
)
(
    IPTABLES_RULES_FILE="$TMP/iptables-drop-first.rules"
    printf '%s\n' '*filter' 'COMMIT' > "$IPTABLES_RULES_FILE"
    IPTABLES_INSERT_LOG="$TMP/iptables-insert.log"
    svc_is_active() { return 1; }
    iptables() {
        case "$1" in
            -S)
                printf '%s\n' \
                    '-P INPUT DROP' \
                    '-A INPUT -p tcp --dport 2222 -j ACCEPT'
                ;;
            -I) printf '%s\n' "$*" > "$IPTABLES_INSERT_LOG" ;;
            -D) return 0 ;;
            *) return 1 ;;
        esac
    }
    iptables-save() { printf '%s\n' '*filter' 'COMMIT'; }
    firewall_allow_port 2222 <<< "y" >/dev/null \
        || { echo "Default-DROP iptables policy was not handled" >&2; exit 1; }
    grep -qx -- '-I INPUT 1 -p tcp --dport 2222 -j ACCEPT' "$IPTABLES_INSERT_LOG" \
        || { echo "iptables allowance was not inserted before an earlier drop" >&2; exit 1; }
)
(
    SSHD_CONFIG="$TMP/change-port-firewall-failure"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    get_config() { printf '%s\n' 22; }
    sshd() {
        if [ "$1" = -T ]; then
            awk 'tolower($1) == "port" {print "port " $2}' "$3"
        else
            return 0
        fi
    }
    print_header() { :; }
    menu_div() { :; }
    confirm_file_diff() { return 0; }
    backup_config() {
        LAST_SSHD_BACKUP="$SSHD_CONFIG.before"
        cp -p -- "$SSHD_CONFIG" "$LAST_SSHD_BACKUP"
    }
    safety_arm() { return 0; }
    firewall_allow_port() { return 1; }
    PORT_RESTORE_MARK="$TMP/change-port-restored"
    PORT_CANCEL_MARK="$TMP/change-port-cancelled"
    restore_ssh_config_backup() {
        cp -p -- "$LAST_SSHD_BACKUP" "$SSHD_CONFIG"
        : > "$PORT_RESTORE_MARK"
    }
    ssh_cancel_safety_timer_checked() { : > "$PORT_CANCEL_MARK"; }
    info() { :; }
    warn() { :; }
    error() { :; }
    ! change_port <<< "2222" \
        || { echo "SSH port change continued after firewall allowance failure" >&2; exit 1; }
    grep -qx 'Port 22' "$SSHD_CONFIG" \
        || { echo "SSH config was not restored after firewall allowance failure" >&2; exit 1; }
    [ -e "$PORT_RESTORE_MARK" ] && [ -e "$PORT_CANCEL_MARK" ] \
        || { echo "Firewall failure did not restore config and cancel safety timer" >&2; exit 1; }
)
(
    SSHD_CONFIG="$TMP/change-port-apply-failure"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    get_config() { printf '%s\n' 22; }
    sshd() {
        if [ "$1" = -T ]; then
            awk 'tolower($1) == "port" {print "port " $2}' "$3"
        else
            return 0
        fi
    }
    print_header() { :; }
    menu_div() { :; }
    confirm_file_diff() { return 0; }
    backup_config() {
        LAST_SSHD_BACKUP="$SSHD_CONFIG.before"
        cp -p -- "$SSHD_CONFIG" "$LAST_SSHD_BACKUP"
    }
    safety_arm() { return 0; }
    firewall_allow_port() { return 0; }
    PORT_FIREWALL_ROLLBACK="$TMP/change-port-firewall-rolled-back"
    PORT_TIMER_CANCEL="$TMP/change-port-apply-timer-cancelled"
    firewall_rollback_allowed_port() { : > "$PORT_FIREWALL_ROLLBACK"; }
    apply_and_restart() {
        cp -p -- "$LAST_SSHD_BACKUP" "$SSHD_CONFIG"
        return 1
    }
    ssh_cancel_safety_timer_checked() { : > "$PORT_TIMER_CANCEL"; }
    info() { :; }
    warn() { :; }
    error() { :; }
    ! change_port <<< "2222" \
        || { echo "SSH port change reported success after apply failure" >&2; exit 1; }
    grep -qx 'Port 22' "$SSHD_CONFIG" \
        || { echo "SSH config was not restored after apply failure" >&2; exit 1; }
    [ -e "$PORT_FIREWALL_ROLLBACK" ] && [ -e "$PORT_TIMER_CANCEL" ] \
        || { echo "SSH apply failure did not roll back firewall and cancel safety timer" >&2; exit 1; }
)
(
    SSHD_CONFIG="$TMP/change-port-socket-active"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    get_config() { printf '%s\n' 22; }
    sshd() {
        if [ "$1" = -T ]; then
            awk 'tolower($1) == "port" {print "port " $2}' "$3"
        else
            return 0
        fi
    }
    print_header() { :; }
    menu_div() { :; }
    confirm_file_diff() { return 0; }
    backup_config() {
        LAST_SSHD_BACKUP="$SSHD_CONFIG.before"
        cp -p -- "$SSHD_CONFIG" "$LAST_SSHD_BACKUP"
    }
    safety_arm() { return 0; }
    ssh_socket_activated() { return 0; }
    SOCKET_WRITE_LOG="$TMP/change-port-socket-write.log"
    ssh_socket_override_write() { printf '%s\n' "$1" > "$SOCKET_WRITE_LOG"; }
    firewall_allow_port() { return 1; }
    ssh_restore_and_cancel_safety() { : > "$TMP/change-port-socket-active-restored"; }
    info() { :; }
    warn() { :; }
    error() { :; }
    ! change_port <<< "2222" \
        || { echo "SSH port change continued after firewall allowance failure" >&2; exit 1; }
    [ "$(cat "$SOCKET_WRITE_LOG" 2>/dev/null)" = 2222 ] \
        || { echo "ssh.socket override was not written with the new port before applying" >&2; exit 1; }
)
(
    SSHD_CONFIG="$TMP/change-port-socket-write-failure"
    printf '%s\n' 'Port 22' > "$SSHD_CONFIG"
    get_config() { printf '%s\n' 22; }
    sshd() {
        if [ "$1" = -T ]; then
            awk 'tolower($1) == "port" {print "port " $2}' "$3"
        else
            return 0
        fi
    }
    print_header() { :; }
    menu_div() { :; }
    confirm_file_diff() { return 0; }
    backup_config() {
        LAST_SSHD_BACKUP="$SSHD_CONFIG.before"
        cp -p -- "$SSHD_CONFIG" "$LAST_SSHD_BACKUP"
    }
    safety_arm() { return 0; }
    ssh_socket_activated() { return 0; }
    ssh_socket_override_write() { return 1; }
    PORT_SOCKET_RESTORE="$TMP/change-port-socket-write-failure-restored"
    PORT_FIREWALL_CALLED="$TMP/change-port-socket-write-failure-firewall-called"
    ssh_restore_and_cancel_safety() { : > "$PORT_SOCKET_RESTORE"; }
    firewall_allow_port() { : > "$PORT_FIREWALL_CALLED"; return 0; }
    info() { :; }
    warn() { :; }
    error() { :; }
    ! change_port <<< "2222" \
        || { echo "SSH port change reported success despite ssh.socket override failure" >&2; exit 1; }
    [ -e "$PORT_SOCKET_RESTORE" ] \
        || { echo "ssh.socket override failure did not trigger rollback" >&2; exit 1; }
    [ ! -e "$PORT_FIREWALL_CALLED" ] \
        || { echo "SSH port change opened the firewall despite ssh.socket override failure" >&2; exit 1; }
)
(
    NFT_RULES_FILE="$TMP/nft-rules.db"
    NFT_ACCESS_FILE="$TMP/nft-access.conf"
    : > "$NFT_RULES_FILE"
    echo "mode=off" > "$NFT_ACCESS_FILE"
    NFT_CONFIG=$(nft_generate_config)
    [[ "$NFT_CONFIG" != *"flush ruleset"* ]] || { echo "NFT config must not flush the host ruleset" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *"table ip nftpf_nat"* ]] || { echo "NFT IPv4 table name should be script-scoped" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *"table ip6 nftpf_nat"* ]] || { echo "NFT IPv6 table name should be script-scoped" >&2; exit 1; }

(
    NFT_TEST="$TMP/nft-transaction"
    mkdir -p "$NFT_TEST/state"
    NFT_CONFIG_FILE="$NFT_TEST/nftables.conf"
    NFT_MANAGED_FILE="$NFT_TEST/vps-tools.nft"
    NFT_STATE_DIR="$NFT_TEST/state"
    NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
    NFT_ACCESS_FILE="$NFT_STATE_DIR/access.conf"
    : > "$NFT_RULES_FILE"
    printf 'mode=off\n' > "$NFT_ACCESS_FILE"
    printf '#!/usr/sbin/nft -f\ntable inet user_firewall {}\n' > "$NFT_CONFIG_FILE"
    systemd_available() { return 1; }
    nft() {
        [ "${1:-}" = list ] && return 1
        return 0
    }
    nft_write_and_apply >/dev/null
    grep -q 'table inet user_firewall' "$NFT_CONFIG_FILE" || { echo "NFT update replaced user config" >&2; exit 1; }
    grep -Fq "$NFT_INCLUDE_MARKER" "$NFT_CONFIG_FILE" || { echo "NFT managed include missing" >&2; exit 1; }
    [ -s "$NFT_MANAGED_FILE" ] || { echo "NFT managed rules file missing" >&2; exit 1; }
)
(
    NFT_TEST="$TMP/nft-rollback"
    mkdir -p "$NFT_TEST/state"
    NFT_CONFIG_FILE="$NFT_TEST/nftables.conf"
    NFT_MANAGED_FILE="$NFT_TEST/vps-tools.nft"
    NFT_STATE_DIR="$NFT_TEST/state"
    NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
    NFT_ACCESS_FILE="$NFT_STATE_DIR/access.conf"
    : > "$NFT_RULES_FILE"
    printf 'mode=off\n' > "$NFT_ACCESS_FILE"
    printf '#!/usr/sbin/nft -f\ntable inet user_firewall {}\n' > "$NFT_CONFIG_FILE"
    printf '# old managed rules\n' > "$NFT_MANAGED_FILE"
    cp "$NFT_CONFIG_FILE" "$NFT_TEST/main.expected"
    cp "$NFT_MANAGED_FILE" "$NFT_TEST/managed.expected"
    systemd_available() { return 1; }
    nft() {
        [ "${1:-}" = list ] && return 1
        [ "${1:-}" = -c ] && return 0
        return 1
    }
    ! nft_write_and_apply >/dev/null 2>&1 || { echo "NFT apply failure returned success" >&2; exit 1; }
    [ "$(cat "$NFT_CONFIG_FILE")" = "$(cat "$NFT_TEST/main.expected")" ] \
        || { echo "NFT apply failure did not restore main config" >&2; exit 1; }
    [ "$(cat "$NFT_MANAGED_FILE")" = "$(cat "$NFT_TEST/managed.expected")" ] \
        || { echo "NFT apply failure did not restore managed config" >&2; exit 1; }
)
)
monitor_alert_service_state() { case "$1" in ssh) echo stopped ;; sshd) echo running ;; *) echo unknown ;; esac; }
[[ "$(monitor_alert_ssh_state)" = "running" ]] || { echo "SSH service alias check failed" >&2; exit 1; }
[[ "$(monitor_int_normalize 1.24682e+11)" = "124682000000" ]] || { echo "Scientific notation normalization failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_alert_cooldown_seconds
MON_ALERT_COOLDOWN_MIN=7
[[ "$(monitor_alert_cooldown_seconds)" = "420" ]] || { echo "Alert cooldown conversion failed" >&2; exit 1; }
[[ "$(monitor_alert_time_to_minutes 23:59)" = "1439" ]] || { echo "Alert silence time parsing failed" >&2; exit 1; }
[[ "$(monitor_alert_daily_cron_expr 23:59)" = "59 23 * * *" ]] || { echo "Daily cron 23:59 expression failed" >&2; exit 1; }
[[ "$(monitor_alert_daily_cron_expr 2359)" = "59 23 * * *" ]] || { echo "Daily cron 2359 expression failed" >&2; exit 1; }
[[ "$(monitor_alert_level_label critical)" = "严重" ]] || { echo "Alert level label failed" >&2; exit 1; }
[[ "$(monitor_alert_worst_level warning critical)" = "critical" ]] || { echo "Alert level ranking failed" >&2; exit 1; }
monitor_percent_valid 85 || { echo "Valid monitor percentage rejected" >&2; exit 1; }
! monitor_percent_valid 101 || { echo "Invalid monitor percentage accepted" >&2; exit 1; }
monitor_positive_number_valid 0.5 || { echo "Valid positive monitor number rejected" >&2; exit 1; }
! monitor_positive_number_valid '50GB' || { echo "Invalid monitor number accepted" >&2; exit 1; }
monitor_positive_int_valid 30 || { echo "Valid positive monitor integer rejected" >&2; exit 1; }
! monitor_positive_int_valid 0 || { echo "Zero monitor integer accepted" >&2; exit 1; }
monitor_renew_notice_days_valid '30,7,3,1,0' || { echo "Valid renewal notice list rejected" >&2; exit 1; }
! monitor_renew_notice_days_valid '30,bad,1' || { echo "Invalid renewal notice list accepted" >&2; exit 1; }
[[ "$(monitor_renew_future_date interval 2026-01-10 30 1 2026-01-11)" = "2026-02-09" ]] || { echo "Interval renewal future date failed" >&2; exit 1; }
[[ "$(monitor_renew_future_date interval 2026-01-10 30 1 2026-03-20)" = "2026-04-10" ]] || { echo "Missed interval renewal catch-up failed" >&2; exit 1; }
[[ "$(monitor_renew_future_date monthly 2026-01-10 365 10 2026-01-11)" = "2026-02-10" ]] || { echo "Monthly renewal future date failed" >&2; exit 1; }
[[ "$(monitor_renew_future_date monthly 2026-01-31 365 31 2026-02-01)" = "2026-02-28" ]] || { echo "Short-month renewal future date failed" >&2; exit 1; }
(
    MONITOR_CFG_FILE="$TMP/monitor-auto-renew.cfg"
    monitor_alert_cfg() { echo "$MONITOR_CFG_FILE"; }
    MON_RENEW_MODE=monthly
    MON_RENEW_AUTO_ADVANCE=yes
    monitor_alert_save_cfg
    MON_RENEW_MODE=
    MON_RENEW_AUTO_ADVANCE=
    monitor_alert_load_cfg
    [[ "$MON_RENEW_AUTO_ADVANCE" = yes ]] || { echo "Renewal auto-advance config was not persisted" >&2; exit 1; }
)
(
    MON_TRAFFIC_INTERFACES=
    ip() {
        case "$1" in
            -4) echo 'default via 192.0.2.1 dev eth0' ;;
            -6) echo 'default via 2001:db8::1 dev eth0'; echo 'default via 2001:db8::2 dev eth1' ;;
        esac
    }
    [[ "$(monitor_traffic_interfaces)" = "eth0 eth1" ]] || { echo "Default-route traffic interface detection failed" >&2; exit 1; }
    export MON_TRAFFIC_INTERFACES='ens3,docker0'
    [[ "$(monitor_traffic_interfaces)" = "ens3 docker0" ]] || { echo "Configured traffic interface parsing failed" >&2; exit 1; }
)
MONITOR_CRON_SAMPLE=$(printf '%s\n' \
    '*/10 * * * * /usr/local/bin/vps-tools --monitor-alert # vps-monitor-alert' \
    '5 * * * * /opt/vps-monitor-alert-helper' \
    '0 8 * * * * /usr/local/bin/vps-tools --monitor-alert # VPS_TOOLS_DAILY_JOB')
MONITOR_CRON_FILTERED=$(printf '%s\n' "$MONITOR_CRON_SAMPLE" | monitor_alert_cron_without_managed)
[[ "$MONITOR_CRON_FILTERED" = '5 * * * * /opt/vps-monitor-alert-helper' ]] || { echo "Monitor cron cleanup removed an unrelated job" >&2; exit 1; }
(
    export MONITOR_ALERT_LOCK_FILE="$TMP/monitor.lock"
    monitor_alert_acquire_lock || { echo "Monitor lock acquisition failed" >&2; exit 1; }
    ! (monitor_alert_acquire_lock) || { echo "Concurrent monitor lock acquisition succeeded" >&2; exit 1; }
)
(
    export MONITOR_ALERT_FORCE_MKDIR_LOCK=1
    export MONITOR_ALERT_LOCK_FILE="$TMP/monitor-stale.lock"
    mkdir -p "${MONITOR_ALERT_LOCK_FILE}.d"
    printf '99999999\n' > "${MONITOR_ALERT_LOCK_FILE}.d/pid"
    monitor_alert_acquire_lock || { echo "Stale monitor fallback lock was not recovered" >&2; exit 1; }
)
monitor_traffic_reset_day_valid 31 || { echo "Reset day 31 should be valid" >&2; exit 1; }
! monitor_traffic_reset_day_valid 32 || { echo "Reset day 32 should be invalid" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-02-15)" = "2026-01-31" ]] || { echo "Previous short-month reset calculation failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-02-28)" = "2026-01-31" ]] || { echo "Short-month reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-03-01)" = "2026-03-01" ]] || { echo "Short-month rollover reset failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2028-02-29)" = "2028-01-31" ]] || { echo "Leap-year short-month reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2028-03-01)" = "2028-03-01" ]] || { echo "Leap-year rollover reset failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-04-30)" = "2026-03-31" ]] || { echo "April reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-05-01)" = "2026-05-01" ]] || { echo "April rollover reset failed" >&2; exit 1; }
# shellcheck disable=SC2329 # invoked indirectly by traffic helper functions under test
monitor_traffic_totals() { echo "107374182400 214748364800 322122547200"; }
monitor_alert_save_cfg() { :; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_set_cycle_usage_split_gb
MON_TRAFFIC_RESET_DAY=1
monitor_traffic_set_cycle_usage_split_gb 10 20
MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:?}
MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:?}
[[ "$(monitor_traffic_usage_triplet cycle)" = "10737418240 21474836480 32212254720" ]] || { echo "Split traffic calibration failed" >&2; exit 1; }
monitor_traffic_set_cycle_usage_split_gb 1000 1000
[[ "$(monitor_traffic_usage_triplet cycle)" = "1073741824000 1073741824000 2147483648000" ]] || { echo "Large split traffic calibration failed" >&2; exit 1; }
# shellcheck disable=SC2329 # invoked indirectly by traffic helper functions under test
monitor_traffic_totals() { echo "100 200 300"; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_BASELINE_RX_BYTES=1000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_BASELINE_TX_BYTES=2000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_BASELINE_BYTES=3000
[[ "$(monitor_traffic_usage_triplet daily)" = "100 200 300" ]] || { echo "Daily traffic counter reset handling failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=1000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=2000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_BASELINE_BYTES=3000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=10
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=20
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_OFFSET_BYTES=30
[[ "$(monitor_traffic_usage_triplet cycle)" = "110 220 330" ]] || { echo "Cycle traffic counter reset handling failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_ENABLED=yes
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_DATE=2026-07-06
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_RX_BYTES=1000
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_TX_BYTES=2000
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_BYTES=3000
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_RX_BYTES=5
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_TX_BYTES=6
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_BYTES=11
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_DATE=2026-07-01
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=500
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=800
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_BYTES=1300
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=10
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=20
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_OFFSET_BYTES=30
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_RX_BYTES=1200
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_TX_BYTES=2400
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_BYTES=3600
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_DAILY_BASELINE_RESET=no
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_RESET=no
[[ "$(monitor_traffic_usage_triplet daily)" = "205 406 611" ]] || { echo "Daily traffic reset ledger failed" >&2; exit 1; }
[[ "$(monitor_traffic_usage_triplet cycle)" = "710 1620 2330" ]] || { echo "Cycle traffic reset ledger failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_RX_BYTES=100
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_TX_BYTES=200
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_BYTES=300
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_RX_BYTES=0
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_TX_BYTES=0
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_BYTES=0
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_RX_BYTES=1200
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_TX_BYTES=2400
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_BYTES=3600
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_DAILY_BASELINE_RESET=yes
[[ "$(monitor_traffic_usage_triplet daily)" = "0 0 0" ]] || { echo "Daily rollover should not inherit old traffic" >&2; exit 1; }
(
    METRICS_FILE="$TMP/monitor.metrics"
    NOW=$(date +%s)
    printf '%s 10 20 0.10 1073741824\n%s 11 21 0.20 536870912\n' "$((NOW - 120))" "$((NOW - 60))" > "$METRICS_FILE"
    monitor_alert_metrics() { echo "$METRICS_FILE"; }
    [[ "$(monitor_alert_trend_line '测试趋势' 3600)" = *'流量 +0.50G'* ]] || { echo "Monitor trend did not preserve traffic across a counter reset" >&2; exit 1; }
)
MANIFEST="$TMP/manifest.json"
cat > "$MANIFEST" <<'EOF'
{"name":"SSH-Hardening","version":"V3.9.45","sha256":"abc123"}
EOF
[[ "$(self_manifest_value "$MANIFEST" version)" = "V3.9.45" ]] || { echo "Manifest parsing failed" >&2; exit 1; }

DAILY_REPORT_CALLS=0
monitor_alert_daily_report() { DAILY_REPORT_CALLS=$((DAILY_REPORT_CALLS + 1)); }
monitor_alert_state_get() {
    case "$1" in
        DAILY_REPORT_DATE) date +%F ;;
        DAILY_REPORT_TS|RENEW_TS) echo 0 ;;
        *) return 1 ;;
    esac
}
monitor_alert_state_set() { :; }
# shellcheck disable=SC2034 # consumed by monitor_alert_daily_report_check
MON_DAILY_REPORT_ENABLED=yes
# shellcheck disable=SC2034 # consumed by monitor_alert_daily_report_check
MON_DAILY_REPORT_TIME=00:00
monitor_alert_daily_report_check
[[ "$DAILY_REPORT_CALLS" -eq 0 ]] || { echo "Daily report repeated on the same day" >&2; exit 1; }

(
    STATE_SET_CALLS=0
    monitor_alert_daily_report() { return 1; }
    monitor_daily_report_due() { return 0; }
    monitor_alert_state_get() { return 1; }
    monitor_alert_state_set() { STATE_SET_CALLS=$((STATE_SET_CALLS + 1)); }
    monitor_alert_history_add() { :; }
    audit_action() { :; }
    export MON_DAILY_REPORT_ENABLED=yes
    export MON_DAILY_REPORT_TIME=00:00
    ! monitor_alert_daily_report_check || { echo "Failed daily report returned success" >&2; exit 1; }
    [[ "$STATE_SET_CALLS" -eq 0 ]] || { echo "Failed daily report was marked as sent" >&2; exit 1; }
)

(
    monitor_alert_cfg_get() { case "$1" in BOT_TOKEN) echo token ;; CHAT_ID) echo chat ;; esac; }
    monitor_alert_telegram_send() { return 1; }
    ! monitor_alert_notify title body || { echo "Failed Telegram request returned success" >&2; exit 1; }
)

RENEW_NOTIFY_CALLS=0
monitor_alert_notify() { RENEW_NOTIFY_CALLS=$((RENEW_NOTIFY_CALLS + 1)); }
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_ENABLED=yes
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_NEXT_DATE=$(date +%F)
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_NOTICE_DAYS=0
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_LAST_ALERT=$(date +%F)
monitor_alert_renew_check
[[ "$RENEW_NOTIFY_CALLS" -eq 0 ]] || { echo "Renew reminder repeated on the same day" >&2; exit 1; }

(
    monitor_alert_notify() { return 0; }
    monitor_alert_history_add() { :; }
    monitor_alert_state_get() { return 1; }
    monitor_alert_state_set() { :; }
    monitor_alert_save_cfg() { :; }
    audit_action() { :; }
    export MON_RENEW_ENABLED=yes
    export MON_RENEW_MODE=interval
    MON_RENEW_NEXT_DATE=$(date +%F)
    ORIGINAL_RENEW_DATE="$MON_RENEW_NEXT_DATE"
    export MON_RENEW_INTERVAL_DAYS=365
    export MON_RENEW_MONTH_DAY=1
    export MON_RENEW_NOTICE_DAYS=0
    export MON_RENEW_AUTO_ADVANCE=no
    export MON_RENEW_LAST_ALERT=
    monitor_alert_renew_check
    [[ "$MON_RENEW_NEXT_DATE" = "$ORIGINAL_RENEW_DATE" ]] || { echo "Due renewal date advanced without payment confirmation" >&2; exit 1; }
)

(
    monitor_alert_notify() { return 0; }
    monitor_alert_history_add() { :; }
    monitor_alert_state_set() { :; }
    monitor_alert_save_cfg() { SAVE_CALLS=$((SAVE_CALLS + 1)); }
    audit_action() { :; }
    export MON_RENEW_ENABLED=yes
    export MON_RENEW_MODE=interval
    MON_RENEW_NEXT_DATE=$(python3 -c 'from datetime import date,timedelta; print(date.today()-timedelta(days=1))')
    ORIGINAL_RENEW_DATE="$MON_RENEW_NEXT_DATE"
    export MON_RENEW_INTERVAL_DAYS=30
    export MON_RENEW_MONTH_DAY=1
    export MON_RENEW_NOTICE_DAYS=0
    export MON_RENEW_AUTO_ADVANCE=yes
    export MON_RENEW_LAST_ALERT=
    MON_BOT_TOKEN=
    MON_CHAT_ID=
    SAVE_CALLS=0
    EXPECTED_RENEW_DATE=$(monitor_renew_future_date interval "$ORIGINAL_RENEW_DATE" 30 1 "$(date +%F)")
    monitor_alert_renew_check
    [[ "$MON_RENEW_NEXT_DATE" = "$EXPECTED_RENEW_DATE" ]] || { echo "Enabled renewal auto-advance did not move to the next cycle" >&2; exit 1; }
    [[ "$SAVE_CALLS" -eq 1 ]] || { echo "Renewal auto-advance did not persist exactly once" >&2; exit 1; }
)

(
    monitor_alert_save_cfg() { return 1; }
    monitor_alert_history_add() { :; }
    audit_action() { :; }
    export MON_RENEW_MODE=monthly
    export MON_RENEW_NEXT_DATE=2026-01-10
    export MON_RENEW_MONTH_DAY=10
    export MON_RENEW_AUTO_ADVANCE=yes
    ! monitor_alert_renew_auto_advance 2026-01-11 || { echo "Renewal auto-advance ignored a config save failure" >&2; exit 1; }
    [[ "$MON_RENEW_NEXT_DATE" = 2026-01-10 ]] || { echo "Failed renewal auto-advance did not roll back the date" >&2; exit 1; }
)

OS=$(detect_os)
[ -n "$OS" ] || { echo "OS detection returned empty" >&2; exit 1; }

COLUMNS=44; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 1 ] || { echo "Narrow terminal did not enable compact layout" >&2; exit 1; }
COLUMNS=72; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 0 ] || { echo "Wide terminal did not enable two-column layout" >&2; exit 1; }

echo "Smoke test passed on $OS."

# ══════════════════════════════════════════════════════════
#  功能模块
# ══════════════════════════════════════════════════════════

show_keys() {
    print_header "查看指定用户 SSH 公钥"

    local USERNAME RECORD ACCOUNT_UID HOME_DIR LOGIN_SHELL INVENTORY KEY_COUNT
    ssh_print_key_accounts
    read -rp "  输入要查看公钥的用户名（直接回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消。"; return; }
    RECORD=$(ssh_account_record "$USERNAME")
    [ -n "$RECORD" ] || { error "用户 $USERNAME 不存在"; return 1; }
    IFS=: read -r _ _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || {
        error "用户 $USERNAME 不是可用的交互式登录账号"
        return 1
    }

    INVENTORY=$(mktemp) || { error "无法创建公钥清单"; return 1; }
    ssh_key_inventory "$SSHD_CONFIG" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" > "$INVENTORY"
    if [ ! -s "$INVENTORY" ]; then
        rm -f "$INVENTORY"
        audit_action "查看用户 $USERNAME SSH 公钥（0 个）" SUCCESS
        warn "用户 $USERNAME 当前没有可识别的 SSH 公钥"
        return 0
    fi
    KEY_COUNT=$(wc -l < "$INVENTORY" | tr -d '[:space:]')
    ssh_key_inventory_print "$INVENTORY"
    rm -f "$INVENTORY"
    audit_action "查看用户 $USERNAME SSH 公钥（${KEY_COUNT:-0} 个）" SUCCESS
}

ssh_account_records() {
    local PASSWD_FILE="${SSH_PASSWD_FILE:-${USER_PASSWD_FILE:-/etc/passwd}}"
    if [ "$PASSWD_FILE" = "/etc/passwd" ] && command -v getent >/dev/null 2>&1; then
        getent passwd 2>/dev/null || cat "$PASSWD_FILE" 2>/dev/null
    else
        cat "$PASSWD_FILE" 2>/dev/null
    fi
}

ssh_account_record() {
    local USERNAME="$1"
    ssh_account_records | awk -F: -v username="$USERNAME" '$1 == username {print; exit}'
}

ssh_account_uid_min() {
    local LOGIN_DEFS="${SSH_LOGIN_DEFS_FILE:-/etc/login.defs}" UID_MIN=1000
    [ -r "$LOGIN_DEFS" ] \
        && UID_MIN=$(awk '$1=="UID_MIN"{print $2; exit}' "$LOGIN_DEFS" 2>/dev/null)
    [[ "$UID_MIN" =~ ^[0-9]+$ ]] || UID_MIN=1000
    printf '%s\n' "$UID_MIN"
}

ssh_login_shell_allowed() {
    local LOGIN_SHELL="${1:-}"
    case "$LOGIN_SHELL" in
        ""|*/nologin|*/false|*/sync) return 1 ;;
        *) return 0 ;;
    esac
}

ssh_key_target_allowed() {
    local USERNAME="$1" ACCOUNT_UID="$2" HOME_DIR="$3" LOGIN_SHELL="$4" UID_MIN
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || return 1
    [[ "$ACCOUNT_UID" =~ ^[0-9]+$ ]] || return 1
    case "$HOME_DIR" in /*) ;; *) return 1 ;; esac
    [ -d "$HOME_DIR" ] || return 1
    ssh_login_shell_allowed "$LOGIN_SHELL" || return 1
    if [ "$USERNAME" = root ] && [ "$ACCOUNT_UID" = 0 ]; then
        return 0
    fi
    case "$USERNAME:$ACCOUNT_UID" in
        root:*|nobody:*|nfsnobody:*|*:0|*:65534) return 1 ;;
    esac
    UID_MIN=$(ssh_account_uid_min)
    [ "$ACCOUNT_UID" -ge "$UID_MIN" ] 2>/dev/null
}

ssh_effective_config_dump() {
    local CONFIG_FILE="$1" USERNAME="$2"
    local CLIENT_ADDR=127.0.0.1 SERVER_ADDR=127.0.0.1 SERVER_PORT=22 CONNECTION=""
    CONNECTION=$(vps_tools_ssh_connection 2>/dev/null || true)
    if [ -n "$CONNECTION" ]; then
        read -r CLIENT_ADDR _ SERVER_ADDR SERVER_PORT <<< "$CONNECTION"
    fi
    [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || SERVER_PORT=22
    LC_ALL=C sshd -T -f "$CONFIG_FILE" \
        -C "user=${USERNAME},host=${CLIENT_ADDR},addr=${CLIENT_ADDR},laddr=${SERVER_ADDR},lport=${SERVER_PORT}" \
        2>/dev/null
}

ssh_config_dump_value() {
    local DUMP="$1" KEY="$2"
    printf '%s\n' "$DUMP" | awk -v key="$KEY" \
        'tolower($1) == tolower(key) {$1=""; sub(/^[[:space:]]+/, ""); print; exit}'
}

ssh_expand_authorized_keys_path() {
    local TEMPLATE="$1" USERNAME="$2" ACCOUNT_UID="$3" HOME_DIR="$4"
    local SENTINEL="__VPS_TOOLS_LITERAL_PERCENT__" RESULT
    [ "$TEMPLATE" != none ] || return 1
    RESULT=${TEMPLATE//%%/$SENTINEL}
    RESULT=${RESULT//%h/$HOME_DIR}
    RESULT=${RESULT//%u/$USERNAME}
    RESULT=${RESULT//%U/$ACCOUNT_UID}
    RESULT=${RESULT//$SENTINEL/%}
    case "$RESULT" in
        *%*|*'|'*|*$'\t'*|*$'\n'*|*$'\r'*|*/../*|*/..|*/./*) return 1 ;;
        /*) ;;
        *) RESULT="${HOME_DIR%/}/$RESULT" ;;
    esac
    printf '%s\n' "$RESULT"
}

ssh_authorized_keys_paths_for_user() {
    local CONFIG_FILE="$1" USERNAME="$2" ACCOUNT_UID="$3" HOME_DIR="$4"
    local DUMP KEY_PATHS TEMPLATE RESOLVED EXISTING DUPLICATE
    local RESOLVED_PATHS=()
    DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || return 1
    KEY_PATHS=$(ssh_config_dump_value "$DUMP" authorizedkeysfile)
    [ -n "$KEY_PATHS" ] || return 1
    while IFS= read -r TEMPLATE; do
        [ -n "$TEMPLATE" ] || continue
        RESOLVED=$(ssh_expand_authorized_keys_path "$TEMPLATE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR") \
            || continue
        DUPLICATE=no
        for EXISTING in "${RESOLVED_PATHS[@]}"; do
            [ "$EXISTING" != "$RESOLVED" ] || { DUPLICATE=yes; break; }
        done
        [ "$DUPLICATE" = no ] || continue
        RESOLVED_PATHS+=("$RESOLVED")
        printf '%s\n' "$RESOLVED"
    done < <(printf '%s\n' "$KEY_PATHS" | tr '[:space:]' '\n')
    [ "${#RESOLVED_PATHS[@]}" -gt 0 ]
}

ssh_authorized_keys_path_for_user() {
    local CONFIG_FILE="$1" USERNAME="$2" ACCOUNT_UID="$3" HOME_DIR="$4" KEY_FILE
    while IFS= read -r KEY_FILE; do
        [ -n "$KEY_FILE" ] || continue
        printf '%s\n' "$KEY_FILE"
        return 0
    done < <(ssh_authorized_keys_paths_for_user \
        "$CONFIG_FILE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR")
    return 1
}

ssh_public_key_type_supported() {
    case "$1" in
        ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|\
        sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            return 0
            ;;
        *) return 1 ;;
    esac
}

ssh_public_key_line_valid() {
    local KEY_LINE="$1" KEY_TYPE KEY_DATA TMP_KEY
    read -r KEY_TYPE KEY_DATA _ <<< "$KEY_LINE"
    ssh_public_key_type_supported "$KEY_TYPE" || return 1
    [ -n "$KEY_DATA" ] || return 1
    command -v ssh-keygen >/dev/null 2>&1 || return 1
    TMP_KEY=$(mktemp) || return 1
    if ! printf '%s %s\n' "$KEY_TYPE" "$KEY_DATA" > "$TMP_KEY"; then
        rm -f -- "$TMP_KEY"
        return 1
    fi
    if ssh-keygen -l -f "$TMP_KEY" >/dev/null 2>&1; then
        rm -f "$TMP_KEY"
        return 0
    fi
    rm -f "$TMP_KEY"
    return 1
}

ssh_public_key_line_fields() {
    local KEY_LINE="$1" INDEX KEY_TYPE KEY_DATA COMMENT OPTIONS FIELD
    local FIELDS=()
    KEY_LINE="${KEY_LINE%$'\r'}"
    KEY_LINE="${KEY_LINE#"${KEY_LINE%%[![:space:]]*}"}"
    case "$KEY_LINE" in ""|\#*) return 1 ;; esac
    read -r -a FIELDS <<< "$KEY_LINE"
    [ "${#FIELDS[@]}" -ge 2 ] || return 1
    for ((INDEX=0; INDEX<${#FIELDS[@]}-1; INDEX++)); do
        KEY_TYPE=${FIELDS[$INDEX]}
        ssh_public_key_type_supported "$KEY_TYPE" || continue
        KEY_DATA=${FIELDS[$((INDEX+1))]}
        ssh_public_key_line_valid "$KEY_TYPE $KEY_DATA" || continue
        OPTIONS="none"
        if [ "$INDEX" -gt 0 ]; then
            OPTIONS=""
            for ((FIELD=0; FIELD<INDEX; FIELD++)); do
                OPTIONS="${OPTIONS}${OPTIONS:+ }${FIELDS[$FIELD]}"
            done
        fi
        COMMENT=""
        for ((FIELD=INDEX+2; FIELD<${#FIELDS[@]}; FIELD++)); do
            COMMENT="${COMMENT}${COMMENT:+ }${FIELDS[$FIELD]}"
        done
        COMMENT=${COMMENT//$'\t'/ }
        OPTIONS=${OPTIONS//$'\t'/ }
        printf '%s\t%s\t%s\t%s\n' \
            "$KEY_TYPE" "$KEY_DATA" "${COMMENT:-（无备注）}" "$OPTIONS"
        return 0
    done
    return 1
}

ssh_public_key_fingerprint() {
    local KEY_TYPE="$1" KEY_DATA="$2" TMP_KEY FINGERPRINT
    command -v ssh-keygen >/dev/null 2>&1 || { printf 'N/A\n'; return; }
    TMP_KEY=$(mktemp) || { printf 'N/A\n'; return; }
    if ! printf '%s %s\n' "$KEY_TYPE" "$KEY_DATA" > "$TMP_KEY"; then
        rm -f -- "$TMP_KEY"
        printf 'N/A\n'
        return
    fi
    FINGERPRINT=$(ssh-keygen -lf "$TMP_KEY" 2>/dev/null | awk 'NR == 1 {print $2}')
    rm -f "$TMP_KEY"
    printf '%s\n' "${FINGERPRINT:-N/A}"
}

ssh_print_key_accounts() {
    local USERNAME ACCOUNT_UID HOME_DIR LOGIN_SHELL
    echo -e "  ${DIM}可管理公钥的登录账号：${NC}"
    printf "  %-18s %-8s %-24s %s\n" "用户名" "UID" "主目录" "Shell"
    menu_div
    while IFS=: read -r USERNAME _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL; do
        ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || continue
        printf "  %-18s %-8s %-24s %s\n" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL"
    done < <(ssh_account_records)
    menu_div
    echo ""
}

ssh_key_inventory() {
    local CONFIG_FILE="$1" USERNAME="$2" ACCOUNT_UID="$3" HOME_DIR="$4"
    local KEY_FILE KEY_LINE LINE_NO FIELDS KEY_TYPE KEY_DATA COMMENT OPTIONS FINGERPRINT
    local RECORD ACCOUNT_GID SCOPE CAPTURE
    RECORD=$(ssh_account_record "$USERNAME")
    IFS=: read -r _ _ _ ACCOUNT_GID _ _ _ <<< "$RECORD"
    [[ "$ACCOUNT_GID" =~ ^[0-9]+$ ]] || return 1
    while IFS= read -r KEY_FILE; do
        if [ "$HOME_DIR" = / ] || [[ "$KEY_FILE" == "${HOME_DIR%/}/"* ]]; then
            SCOPE=home
        else
            SCOPE=global
        fi
        CAPTURE=$(mktemp) || return 1
        if ! ssh_key_file_capture_as_target \
            "$KEY_FILE" "$SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
            "$HOME_DIR" > "$CAPTURE"; then
            rm -f "$CAPTURE"
            continue
        fi
        LINE_NO=0
        while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
            LINE_NO=$((LINE_NO+1))
            FIELDS=$(ssh_public_key_line_fields "$KEY_LINE") || continue
            IFS=$'\t' read -r KEY_TYPE KEY_DATA COMMENT OPTIONS <<< "$FIELDS"
            FINGERPRINT=$(ssh_public_key_fingerprint "$KEY_TYPE" "$KEY_DATA")
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$KEY_FILE" "$LINE_NO" "$KEY_TYPE" "$KEY_DATA" \
                "$FINGERPRINT" "$COMMENT" "$OPTIONS"
        done < "$CAPTURE"
        rm -f "$CAPTURE"
    done < <(ssh_authorized_keys_paths_for_user \
        "$CONFIG_FILE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR")
}

ssh_key_inventory_print() {
    local INVENTORY="$1" INDEX=1 KEY_FILE LINE_NO KEY_TYPE KEY_DATA FINGERPRINT COMMENT OPTIONS
    while IFS=$'\t' read -r KEY_FILE LINE_NO KEY_TYPE KEY_DATA FINGERPRINT COMMENT OPTIONS; do
        echo -e "  ${GREEN}[$INDEX]${NC} ${BOLD}${KEY_TYPE}${NC}"
        echo -e "      ${DIM}指纹：${NC}${BLUE}${FINGERPRINT}${NC}"
        echo -e "      ${DIM}备注：${NC}${YELLOW}${COMMENT}${NC}"
        echo -e "      ${DIM}位置：${NC}${KEY_FILE}:${LINE_NO}"
        if [ "$OPTIONS" = none ]; then
            echo -e "      ${DIM}授权选项：${NC}无（普通登录密钥）"
        else
            echo -e "      ${DIM}授权选项：${NC}${OPTIONS}"
        fi
        echo ""
        INDEX=$((INDEX+1))
    done < "$INVENTORY"
}

ssh_key_inventory_line_matches() {
    local KEY_FILE="$1" LINE_NO="$2" EXPECTED_TYPE="$3" EXPECTED_DATA="$4"
    local KEY_LINE FIELDS KEY_TYPE KEY_DATA COMMENT OPTIONS
    KEY_LINE=$(awk -v target="$LINE_NO" 'NR == target {print; exit}' "$KEY_FILE") || return 1
    [ -n "$KEY_LINE" ] || return 1
    FIELDS=$(ssh_public_key_line_fields "$KEY_LINE") || return 1
    IFS=$'\t' read -r KEY_TYPE KEY_DATA COMMENT OPTIONS <<< "$FIELDS"
    [ "$KEY_TYPE" = "$EXPECTED_TYPE" ] && [ "$KEY_DATA" = "$EXPECTED_DATA" ]
}

ssh_key_file_restore() {
    local BACKUP="$1" KEY_FILE="$2" RESTORE_TMP
    if [ "$#" -ge 7 ]; then
        ssh_key_file_restore_as_target "$@"
        return
    fi
    [ "${VPS_TOOLS_TEST_MODE:-0}" = 1 ] || return 1
    RESTORE_TMP=$(mktemp "${KEY_FILE}.vps-tools-restore.XXXXXX") || return 1
    if cp -p -- "$BACKUP" "$RESTORE_TMP" \
        && mv -f -- "$RESTORE_TMP" "$KEY_FILE"; then
        return 0
    fi
    rm -f "$RESTORE_TMP"
    return 1
}

ssh_key_file_restore_worker() {
    local KEY_FILE="$1" SCOPE="$2" EXPECTED_UID="$3" HOME_DIR="$4"
    local EXPECTED_DIGEST="${5:-}" BEFORE AFTER RESTORE_TMP KEY_MODE KEY_GID CURRENT_DIGEST
    BEFORE=$(ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || return 21
    CURRENT_DIGEST=$(cksum < "$KEY_FILE" 2>/dev/null) || return 21
    [ -z "$EXPECTED_DIGEST" ] || [ "$CURRENT_DIGEST" = "$EXPECTED_DIGEST" ] || return 26
    read -r KEY_GID KEY_MODE < <(stat -Lc '%g %a' -- "$KEY_FILE" 2>/dev/null) \
        || return 21
    [[ "$KEY_GID" =~ ^[0-9]+$ && "$KEY_MODE" =~ ^[0-7]+$ ]] || return 21
    RESTORE_TMP=$(mktemp "${KEY_FILE}.vps-tools-restore.XXXXXX") || return 22
    if ! cp -a -- "$KEY_FILE" "$RESTORE_TMP" \
        || ! cat > "$RESTORE_TMP" \
        || ! chmod "$KEY_MODE" "$RESTORE_TMP" \
        || [ "$(stat -Lc '%g' -- "$RESTORE_TMP" 2>/dev/null)" != "$KEY_GID" ]; then
        rm -f -- "$RESTORE_TMP"
        return 23
    fi
    AFTER=$(ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || {
        rm -f -- "$RESTORE_TMP"
        return 24
    }
    CURRENT_DIGEST=$(cksum < "$KEY_FILE" 2>/dev/null) || {
        rm -f -- "$RESTORE_TMP"
        return 24
    }
    if [ "$AFTER" != "$BEFORE" ] \
        || { [ -n "$EXPECTED_DIGEST" ] && [ "$CURRENT_DIGEST" != "$EXPECTED_DIGEST" ]; }; then
        rm -f -- "$RESTORE_TMP"
        return 24
    fi
    if ! mv -f -- "$RESTORE_TMP" "$KEY_FILE"; then
        rm -f -- "$RESTORE_TMP"
        return 25
    fi
    ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR" >/dev/null || return 27
}

ssh_key_file_restore_as_target() {
    local BACKUP="$1" KEY_FILE="$2" SCOPE="$3" USERNAME="$4"
    local ACCOUNT_UID="$5" ACCOUNT_GID="$6" HOME_DIR="$7"
    local EXPECTED_DIGEST="${8:-}" WORKER_SCRIPT
    [ -f "$BACKUP" ] && [ ! -L "$BACKUP" ] || return 1
    WORKER_SCRIPT="$(declare -f ssh_public_key_path_snapshot)
$(declare -f ssh_key_file_restore_worker)
ssh_key_file_restore_worker \"\$@\""
    if [ "$SCOPE" = global ]; then
        ssh_key_file_restore_worker \
            "$KEY_FILE" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" \
            "$EXPECTED_DIGEST" < "$BACKUP"
        return
    fi
    ssh_run_as_target "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$WORKER_SCRIPT" \
        "$KEY_FILE" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" \
        "$EXPECTED_DIGEST" < "$BACKUP"
}

ssh_key_delete_worker() {
    local KEY_FILE="$1" SCOPE="$2" EXPECTED_UID="$3" HOME_DIR="$4"
    local LINE_NO="$5" EXPECTED_DIGEST="$6" BEFORE AFTER CURRENT_DIGEST
    local KEY_MODE KEY_GID APPLY_TMP
    [[ "$LINE_NO" =~ ^[1-9][0-9]*$ ]] || return 21
    BEFORE=$(ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || return 21
    CURRENT_DIGEST=$(cksum < "$KEY_FILE" 2>/dev/null) || return 22
    [ "$CURRENT_DIGEST" = "$EXPECTED_DIGEST" ] || return 23
    read -r KEY_GID KEY_MODE < <(stat -Lc '%g %a' -- "$KEY_FILE" 2>/dev/null) \
        || return 21
    [[ "$KEY_GID" =~ ^[0-9]+$ && "$KEY_MODE" =~ ^[0-7]+$ ]] || return 21
    APPLY_TMP=$(mktemp "${KEY_FILE}.vps-tools.XXXXXX") || return 24
    if ! cp -a -- "$KEY_FILE" "$APPLY_TMP" \
        || ! awk -v target="$LINE_NO" 'NR != target {print}' "$KEY_FILE" > "$APPLY_TMP" \
        || ! chmod "$KEY_MODE" "$APPLY_TMP" \
        || [ "$(stat -Lc '%g' -- "$APPLY_TMP" 2>/dev/null)" != "$KEY_GID" ]; then
        rm -f -- "$APPLY_TMP"
        return 25
    fi
    AFTER=$(ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || {
        rm -f -- "$APPLY_TMP"
        return 26
    }
    CURRENT_DIGEST=$(cksum < "$KEY_FILE" 2>/dev/null) || {
        rm -f -- "$APPLY_TMP"
        return 26
    }
    if [ "$AFTER" != "$BEFORE" ] || [ "$CURRENT_DIGEST" != "$EXPECTED_DIGEST" ]; then
        rm -f -- "$APPLY_TMP"
        return 26
    fi
    if ! mv -f -- "$APPLY_TMP" "$KEY_FILE"; then
        rm -f -- "$APPLY_TMP"
        return 27
    fi
    ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR" >/dev/null || return 40
}

ssh_key_delete_as_target() {
    local KEY_FILE="$1" SCOPE="$2" USERNAME="$3" ACCOUNT_UID="$4"
    local ACCOUNT_GID="$5" HOME_DIR="$6" LINE_NO="$7" EXPECTED_DIGEST="$8"
    local WORKER_SCRIPT
    WORKER_SCRIPT="$(declare -f ssh_public_key_path_snapshot)
$(declare -f ssh_key_delete_worker)
ssh_key_delete_worker \"\$@\""
    if [ "$SCOPE" = global ]; then
        ssh_key_delete_worker \
            "$KEY_FILE" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" \
            "$LINE_NO" "$EXPECTED_DIGEST"
        return
    fi
    ssh_run_as_target "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$WORKER_SCRIPT" \
        "$KEY_FILE" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" \
        "$LINE_NO" "$EXPECTED_DIGEST"
}

ssh_safety_worker_identity_valid() {
    local WORKER_PID="$1" WORKER_SCRIPT="$2" CMDLINE=""
    [[ "$WORKER_PID" =~ ^[1-9][0-9]*$ ]] && [ -f "$WORKER_SCRIPT" ] \
        && kill -0 "$WORKER_PID" 2>/dev/null || return 1
    if [ -r "/proc/${WORKER_PID}/cmdline" ]; then
        CMDLINE=$(tr '\0' ' ' < "/proc/${WORKER_PID}/cmdline" 2>/dev/null) \
            || return 1
    elif command -v ps >/dev/null 2>&1; then
        CMDLINE=$(ps -p "$WORKER_PID" -o args= 2>/dev/null) || return 1
    else
        return 1
    fi
    case "$CMDLINE" in
        *"$WORKER_SCRIPT"*) return 0 ;;
        *) return 1 ;;
    esac
}

ssh_key_delete_apply_transaction() {
    local KEY_FILE="$1" SCOPE="$2" USERNAME="$3" ACCOUNT_UID="$4"
    local ACCOUNT_GID="$5" HOME_DIR="$6" LINE_NO="$7" EXPECTED_DIGEST="$8"
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL STATE_SNAPSHOT STATE_STATUS
    local STATE_TMP="" RC
    safety_lock_acquire || return 31
    if ! IFS='|' read -r STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL \
        STATE_SNAPSHOT STATE_STATUS < "$STATE_FILE" 2>/dev/null \
        || [ "$STATE_PID" != "${SAFETY_PID:-}" ] \
        || [ "$STATE_SCRIPT" != "${SAFETY_SCRIPT:-}" ] \
        || [ "$STATE_SNAPSHOT" != "${SAFETY_SNAPSHOT:-}" ] \
        || [ "$STATE_STATUS" != armed ] \
        || ! ssh_safety_worker_identity_valid "$STATE_PID" "$STATE_SCRIPT"; then
        safety_lock_release
        return 32
    fi
    if ssh_key_delete_as_target \
        "$KEY_FILE" "$SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" "$LINE_NO" "$EXPECTED_DIGEST"; then
        STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || STATE_TMP=""
        if [ -n "$STATE_TMP" ] \
            && printf '%s|%s|%s|%s|%s|applied\n' \
            "$STATE_PID" "$STATE_SCRIPT" "$STATE_ROOTS" "$STATE_SYSCTL" \
            "$STATE_SNAPSHOT" > "$STATE_TMP" \
            && chmod 600 "$STATE_TMP" 2>/dev/null \
            && mv -f -- "$STATE_TMP" "$STATE_FILE"; then
            SAFETY_STATUS=applied
            RC=0
        else
            [ -z "$STATE_TMP" ] || rm -f -- "$STATE_TMP"
            RC=40
        fi
    else
        RC=$?
    fi
    safety_lock_release
    return "$RC"
}

ssh_key_delete_safety_arm() {
    local KEY_FILE="$1" BACKUP="$2" USERNAME="$3"
    local SCOPE="${4:-}" ACCOUNT_UID="${5:-}" ACCOUNT_GID="${6:-}" HOME_DIR="${7:-}"
    local EXPECTED_CURRENT_DIGEST="${8:-}"
    local SECURE_TARGET=yes
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}" SCRIPT LOCK_DIR SOURCE_IP=local
    local STATE_TMP="" READY=no
    local BACKUP_DIGEST=""
    local ROLLBACK_DELAY="${SSH_KEY_ROLLBACK_DELAY:-180}"
    case "$ROLLBACK_DELAY" in ''|*[!0-9]*) ROLLBACK_DELAY=180 ;; esac
    [ "$ROLLBACK_DELAY" -ge 1 ] 2>/dev/null || ROLLBACK_DELAY=180
    if [ -z "$SCOPE" ] || [ -z "$ACCOUNT_UID" ] \
        || [ -z "$ACCOUNT_GID" ] || [ -z "$HOME_DIR" ] \
        || [ -z "$EXPECTED_CURRENT_DIGEST" ]; then
        [ "${VPS_TOOLS_TEST_MODE:-0}" = 1 ] || return 1
        SECURE_TARGET=no
    fi
    if [ "$SECURE_TARGET" = yes ]; then
        [ -f "$BACKUP" ] && [ ! -L "$BACKUP" ] || return 1
        BACKUP_DIGEST=$(cksum < "$BACKUP" 2>/dev/null) || return 1
    fi
    SOURCE_IP=$(vps_tools_ssh_client_ip 2>/dev/null || printf 'local')
    mkdir -p "$VPS_DATA_DIR" 2>/dev/null || {
        error "无法创建防断联任务目录"
        return 1
    }
    chmod 700 "$VPS_DATA_DIR" 2>/dev/null || true
    if ! safety_lock_acquire; then
        error "另一个防断联保护操作正在进行，请稍后重试"
        return 1
    fi
    if safety_load_pending; then
        safety_lock_release
        error "已有防断联回滚任务正在计时，请先确认上一项变更或等待其完成"
        return 1
    fi
    SCRIPT="$VPS_DATA_DIR/rollback_key_$$_$(date +%s)_${RANDOM}.sh"
    LOCK_DIR="${STATE_FILE}.lock"
    if ! {
        printf '#!/usr/bin/env bash\n'
        printf 'set -o pipefail\n'
        printf 'sleep %s\n' "$ROLLBACK_DELAY"
        printf 'state_file=%q\n' "$STATE_FILE"
        printf 'script_file=%q\n' "$SCRIPT"
        printf 'backup_file=%q\n' "$BACKUP"
        printf 'lock_dir=%q\n' "$LOCK_DIR"
        printf 'lock_owner=""\n'
        if [ "$SECURE_TARGET" = yes ]; then
            printf 'key_file=%q\n' "$KEY_FILE"
            printf 'key_scope=%q\n' "$SCOPE"
            printf 'key_user=%q\n' "$USERNAME"
            printf 'key_uid=%q\n' "$ACCOUNT_UID"
            printf 'key_gid=%q\n' "$ACCOUNT_GID"
            printf 'key_home=%q\n' "$HOME_DIR"
            printf 'key_expected_digest=%q\n' "$EXPECTED_CURRENT_DIGEST"
            printf 'backup_expected_digest=%q\n' "$BACKUP_DIGEST"
            declare -f ssh_public_key_path_snapshot
            declare -f ssh_setpriv_target_supported
            declare -f ssh_run_as_target
            declare -f ssh_key_file_capture_worker
            declare -f ssh_key_file_capture_as_target
            declare -f ssh_key_file_restore_worker
            declare -f ssh_key_file_restore_as_target
        fi
        printf 'process_start_token() {\n'
        printf '    local process_pid="$1" process_stat="" process_rest="" token=""\n'
        printf '    [[ "$process_pid" =~ ^[1-9][0-9]*$ ]] || return 1\n'
        printf '    if [ -r "/proc/${process_pid}/stat" ]; then\n'
        printf '        IFS= read -r process_stat < "/proc/${process_pid}/stat" || return 1\n'
        printf '        process_rest=${process_stat##*) }\n'
        printf '        token=$(printf "%%s\\n" "$process_rest" | awk '"'"'{print $20}'"'"') || return 1\n'
        printf '    elif command -v ps >/dev/null 2>&1; then\n'
        printf '        token=$(LC_ALL=C ps -p "$process_pid" -o lstart= 2>/dev/null) || return 1\n'
        printf '        token=$(printf "%%s\\n" "$token" | awk '"'"'{$1=$1; print}'"'"')\n'
        printf '    fi\n'
        printf '    [ -n "$token" ] || return 1\n'
        printf '    printf "%%s\\n" "$token"\n'
        printf '}\n'
        printf 'lock_owner_valid() {\n'
        printf '    local owner="$1" owner_pid owner_token current_token\n'
        printf '    case "$owner" in *"|"*) ;; *) return 1 ;; esac\n'
        printf '    owner_pid=${owner%%|*}; owner_token=${owner#*|}\n'
        printf '    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$owner_token" ] \\\n'
        printf '        && kill -0 "$owner_pid" 2>/dev/null || return 1\n'
        printf '    current_token=$(process_start_token "$owner_pid") || return 1\n'
        printf '    [ "$current_token" = "$owner_token" ]\n'
        printf '}\n'
        printf 'release_lock() {\n'
        printf '    if [ -f "$lock_dir/pid" ] && [ "$(cat "$lock_dir/pid" 2>/dev/null)" = "$lock_owner" ]; then\n'
        printf '        rm -f "$lock_dir/pid" >/dev/null 2>&1 || true\n'
        printf '        rmdir "$lock_dir" >/dev/null 2>&1 || true\n'
        printf '    fi\n'
        printf '}\n'
        printf 'acquire_lock() {\n'
        printf '    local current_owner="" current_owner_after="" self_token=""\n'
        printf '    while true; do\n'
        printf '        if mkdir "$lock_dir" 2>/dev/null; then\n'
        printf '            self_token=$(process_start_token "$$") || self_token=""\n'
        printf '            lock_owner="$$|$self_token"\n'
        printf '            if [ -n "$self_token" ] && printf "%%s\\n" "$lock_owner" > "$lock_dir/pid" 2>/dev/null; then return 0; fi\n'
        printf '            rm -f "$lock_dir/pid" >/dev/null 2>&1 || true\n'
        printf '            rmdir "$lock_dir" >/dev/null 2>&1 || true\n'
        printf '            sleep 1\n'
        printf '            continue\n'
        printf '        fi\n'
        printf '        current_owner=$(cat "$lock_dir/pid" 2>/dev/null || true)\n'
        printf '        if lock_owner_valid "$current_owner"; then sleep 1; continue; fi\n'
        printf '        sleep 1\n'
        printf '        current_owner_after=$(cat "$lock_dir/pid" 2>/dev/null || true)\n'
        printf '        if lock_owner_valid "$current_owner_after"; then continue; fi\n'
        printf '        if [ "$current_owner" = "$current_owner_after" ]; then\n'
        printf '            rm -f "$lock_dir/pid" >/dev/null 2>&1 || true\n'
        printf '            rmdir "$lock_dir" >/dev/null 2>&1 || true\n'
        printf '        fi\n'
        printf '    done\n'
        printf '}\n'
        printf 'write_state() {\n'
        printf '    local next_status="$1" state_tmp current_pid current_script current_backup current_status\n'
        printf '    IFS="|" read -r current_pid current_script _ _ current_backup current_status < "$state_file" 2>/dev/null || return 1\n'
        printf '    [ "$current_pid" = "$$" ] && [ "$current_script" = "$script_file" ] \\\n'
        printf '        && [ "$current_backup" = "$backup_file" ] || return 1\n'
        printf '    case "$current_status" in armed|applied|restoring) ;; *) return 1 ;; esac\n'
        printf '    state_tmp=$(mktemp "${state_file}.tmp.XXXXXX") || return 1\n'
        printf '    if printf "%%s|%%s|||%%s|%%s\\n" "$$" "$script_file" "$backup_file" "$next_status" > "$state_tmp" \\\n'
        printf '        && chmod 600 "$state_tmp" 2>/dev/null \\\n'
        printf '        && mv -f -- "$state_tmp" "$state_file"; then return 0; fi\n'
        printf '    rm -f -- "$state_tmp"\n'
        printf '    return 1\n'
        printf '}\n'
        printf 'mark_failed() {\n'
        printf '    write_state failed || true\n'
        printf '}\n'
        printf 'acquire_lock\n'
        printf 'trap release_lock EXIT\n'
        printf 'trap '"'"'mark_failed; release_lock; exit 1'"'"' TERM INT HUP\n'
        printf 'wait_count=0\n'
        printf 'while true; do\n'
        printf '    IFS="|" read -r state_pid state_script _ _ state_backup state_status < "$state_file" 2>/dev/null || exit 1\n'
        printf '    [ "$state_pid" = "$$" ] && [ "$state_script" = "$script_file" ] \\\n'
        printf '        && [ "$state_backup" = "$backup_file" ] || exit 1\n'
        printf '    case "$state_status" in\n'
        printf '        applied) break ;;\n'
        printf '        cancelled) rm -f -- "$script_file" "$state_file"; exit 0 ;;\n'
        printf '        armed)\n'
        if [ "$SECURE_TARGET" = yes ]; then
            printf '            current_digest=$(ssh_key_file_capture_as_target "$key_file" "$key_scope" "$key_user" "$key_uid" "$key_gid" "$key_home" | cksum) \\\n'
            printf '                || { mark_failed; exit 1; }\n'
            printf '            if [ "$current_digest" = "$key_expected_digest" ]; then break; fi\n'
            printf '            [ "$current_digest" = "$backup_expected_digest" ] || { mark_failed; exit 1; }\n'
        fi
        printf '            wait_count=$((wait_count + 1))\n'
        if [ "$SECURE_TARGET" = yes ]; then
            printf '            if [ "$wait_count" -ge 60 ]; then\n'
            printf '                rm -f -- "$script_file" "$state_file"\n'
            printf '                exit 0\n'
            printf '            fi\n'
        else
            printf '            [ "$wait_count" -lt 60 ] || { mark_failed; exit 1; }\n'
        fi
        printf '            release_lock\n'
        printf '            sleep 1\n'
        printf '            acquire_lock\n'
        printf '            ;;\n'
        printf '        *) mark_failed; exit 1 ;;\n'
        printf '    esac\n'
        printf 'done\n'
        printf 'write_state restoring || { mark_failed; exit 1; }\n'
        if [ "$SECURE_TARGET" = yes ]; then
            printf 'if ssh_key_file_restore_as_target "$backup_file" "$key_file" "$key_scope" "$key_user" "$key_uid" "$key_gid" "$key_home" "$key_expected_digest"; then\n'
        else
            printf 'rollback_tmp=$(mktemp %q) || { mark_failed; exit 1; }\n' \
                "${KEY_FILE}.vps-tools-rollback.XXXXXX"
            printf 'if cp -p -- %q "$rollback_tmp" >/dev/null 2>&1 \\\n' "$BACKUP"
            printf '    && mv -f -- "$rollback_tmp" %q >/dev/null 2>&1; then\n' "$KEY_FILE"
        fi
        printf '    logger -t vps-tools %q >/dev/null 2>&1 || true\n' \
            "未确认新登录，已自动恢复用户 $USERNAME 的 SSH 公钥文件"
        printf '    printf "%%s\\tFAILED\\t%%s\\t%%s\\n" "$(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"')" %q %q >> %q 2>/dev/null || true\n' \
            "$SOURCE_IP" "删除用户 $USERNAME SSH 公钥未确认，自动回滚成功" "$VPS_AUDIT_LOG"
        printf '    rm -f -- "$script_file" "$state_file"\n'
        printf 'else\n'
        [ "$SECURE_TARGET" = yes ] || printf '    rm -f -- "$rollback_tmp"\n'
        printf '    logger -t vps-tools %q >/dev/null 2>&1 || true\n' \
            "未确认新登录，但自动恢复用户 $USERNAME 的 SSH 公钥文件失败"
        printf '    printf "%%s\\tFAILED\\t%%s\\t%%s\\n" "$(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"')" %q %q >> %q 2>/dev/null || true\n' \
            "$SOURCE_IP" "删除用户 $USERNAME SSH 公钥未确认，自动回滚失败" "$VPS_AUDIT_LOG"
        printf '    write_state failed || true\n'
        printf 'fi\n'
        printf 'chmod 600 %q 2>/dev/null || true\n' "$VPS_AUDIT_LOG"
    } > "$SCRIPT"; then
        rm -f "$SCRIPT"
        safety_lock_release
        error "无法创建公钥自动回滚任务"
        return 1
    fi
    if ! chmod 700 "$SCRIPT"; then
        rm -f "$SCRIPT"
        safety_lock_release
        error "无法设置公钥自动回滚任务权限"
        return 1
    fi
    nohup bash "$SCRIPT" >/dev/null 2>&1 &
    SAFETY_PID=$!
    SAFETY_SCRIPT="$SCRIPT"
    SAFETY_ROOTS_FILE=""
    SAFETY_SYSCTL_FILE=""
    SAFETY_SNAPSHOT="$BACKUP"
    SAFETY_STATUS=armed
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if ssh_safety_worker_identity_valid "$SAFETY_PID" "$SAFETY_SCRIPT"; then
            READY=yes
            break
        fi
        kill -0 "$SAFETY_PID" 2>/dev/null || break
        sleep 0.05
    done
    if [ "$READY" != yes ]; then
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        rm -f -- "$SAFETY_SCRIPT"
        SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_SNAPSHOT="" SAFETY_STATUS=""
        safety_lock_release
        error "公钥自动回滚进程未能可靠启动"
        return 1
    fi
    STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || STATE_TMP=""
    if [ -z "$STATE_TMP" ] \
        || ! printf '%s|%s|||%s|armed\n' \
            "$SAFETY_PID" "$SAFETY_SCRIPT" "$SAFETY_SNAPSHOT" > "$STATE_TMP" \
        || ! chmod 600 "$STATE_TMP" 2>/dev/null \
        || ! mv -f -- "$STATE_TMP" "$STATE_FILE"; then
        [ -z "$STATE_TMP" ] || rm -f -- "$STATE_TMP"
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        rm -f "$SAFETY_SCRIPT"
        SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_SNAPSHOT="" SAFETY_STATUS=""
        safety_lock_release
        error "无法保存公钥自动回滚任务状态"
        return 1
    fi
    safety_lock_release
    audit_action "启动删除用户 $USERNAME SSH 公钥的防断联保护" SUCCESS
    warn "防断联保护已启动：${ROLLBACK_DELAY} 秒内未确认新登录，将自动恢复该公钥文件。"
}

ssh_key_delete_confirm_new_session() {
    local EXPECTED_USER="$1" ROUTE="$2" CONFIRMED_USER
    local KEY_FILE="${3:-}" KEY_SCOPE="${4:-}" KEY_USER="${5:-}"
    local ACCOUNT_UID="${6:-}" ACCOUNT_GID="${7:-}" HOME_DIR="${8:-}"
    local CANDIDATE_DIGEST="${9:-}"
    echo ""
    warn "请保持当前窗口，并立即用新终端验证剩余管理员入口。"
    echo -e "  验证用户：${BOLD}${EXPECTED_USER}${NC}  预计方式：${BOLD}${ROUTE}${NC}"
    read -rp "  新会话成功并确认具备 root 管理能力后，输入用户名 ${EXPECTED_USER}: " CONFIRMED_USER
    if [ "$CONFIRMED_USER" = "$EXPECTED_USER" ]; then
        ssh_key_delete_cancel_live_timer \
            "$KEY_FILE" "$KEY_SCOPE" "$KEY_USER" "$ACCOUNT_UID" "$ACCOUNT_GID" \
            "$HOME_DIR" "$CANDIDATE_DIGEST" || return 1
        audit_action "确认删除公钥后的管理员入口 $EXPECTED_USER" SUCCESS
        info "验证确认完成，已取消自动回滚"
    else
        warn "未完成确认，180 秒自动回滚仍在计时；请勿关闭当前连接。"
    fi
}

ssh_key_file_count() {
    local KEY_FILE="$1" KEY_LINE COUNT=0
    [ -f "$KEY_FILE" ] || { printf '0\n'; return; }
    while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
        ssh_public_key_line_fields "$KEY_LINE" >/dev/null || continue
        COUNT=$((COUNT+1))
    done < "$KEY_FILE"
    printf '%s\n' "$COUNT"
}

ssh_public_key_path_snapshot() {
    local TARGET="$1" SCOPE="$2" EXPECTED_UID="$3" HOME_DIR="$4"
    local CURRENT="/" PART META _ OWNER MODE
    local IS_FINAL=no ROOT_UID=0
    local PARTS=()

    case "$TARGET" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$TARGET" in
        *$'\n'*|*$'\r'*|*$'\t'*|*'//'*) return 1 ;;
    esac
    HOME_DIR=${HOME_DIR%/}
    [ -n "$HOME_DIR" ] || HOME_DIR=/
    if [ "${VPS_TOOLS_TEST_MODE:-0}" = 1 ]; then
        ROOT_UID=$(id -u 2>/dev/null) || return 1
    fi
    IFS=/ read -r -a PARTS <<< "${TARGET#/}"

    META=$(stat -Lc '%d:%i:%u:%g:%a:%F:%s:%Y:%Z' -- / 2>/dev/null) || return 1
    IFS=: read -r _ _ OWNER _ MODE _ _ _ _ <<< "$META"
    [ "$OWNER" = "$ROOT_UID" ] || return 1
    [[ "$MODE" =~ ^[0-7]+$ ]] || return 1
    [ $((8#$MODE & 0022)) -eq 0 ] || return 1
    printf '/|%s\n' "$META"

    for PART in "${PARTS[@]}"; do
        [ -n "$PART" ] || continue
        case "$PART" in .|..) return 1 ;; esac
        if [ "$CURRENT" = / ]; then
            CURRENT="/$PART"
        else
            CURRENT="$CURRENT/$PART"
        fi
        [ "$CURRENT" != "$TARGET" ] || IS_FINAL=yes

        if [ ! -e "$CURRENT" ] && [ ! -L "$CURRENT" ]; then
            printf '%s|missing\n' "$CURRENT"
            continue
        fi
        [ ! -L "$CURRENT" ] || return 1
        if [ "$IS_FINAL" = yes ]; then
            [ -f "$CURRENT" ] || return 1
        else
            [ -d "$CURRENT" ] || return 1
        fi
        META=$(stat -Lc '%d:%i:%u:%g:%a:%F:%s:%Y:%Z' -- "$CURRENT" 2>/dev/null) \
            || return 1
        IFS=: read -r _ _ OWNER _ MODE _ _ _ _ <<< "$META"
        [[ "$MODE" =~ ^[0-7]+$ ]] || return 1

        if [ "$SCOPE" = global ]; then
            [ "$OWNER" = "$ROOT_UID" ] || return 1
            [ $((8#$MODE & 0022)) -eq 0 ] || return 1
        elif [ "$HOME_DIR" = / ] \
            || [ "$CURRENT" = "$HOME_DIR" ] \
            || [[ "$CURRENT" == "$HOME_DIR/"* ]]; then
            [ "$OWNER" = "$EXPECTED_UID" ] || return 1
            [ $((8#$MODE & 0022)) -eq 0 ] || return 1
        else
            [ "$OWNER" = "$ROOT_UID" ] || return 1
            if [ $((8#$MODE & 0022)) -ne 0 ]; then
                [ $((8#$MODE & 1000)) -ne 0 ] || return 1
            fi
        fi
        printf '%s|%s\n' "$CURRENT" "$META"
    done
}

ssh_public_key_install_worker() {
    local TARGET="$1" PUBKEY_INPUT="$2" SCOPE="$3" EXPECTED_UID="$4" HOME_DIR="$5"
    local KEY_TYPE KEY_DATA KEY_DIR BEFORE TEMP LAST_BYTE AFTER
    local ORIGINAL_PRESENT=no BEFORE_DIGEST="" CURRENT_DIGEST=""

    read -r KEY_TYPE KEY_DATA _ <<< "$PUBKEY_INPUT"
    [ -n "$KEY_TYPE" ] && [ -n "$KEY_DATA" ] || return 20
    ssh_public_key_path_snapshot \
        "$TARGET" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR" >/dev/null || return 21
    KEY_DIR=$(dirname -- "$TARGET") || return 21
    if ! (umask 077; mkdir -p -- "$KEY_DIR"); then
        return 22
    fi
    BEFORE=$(ssh_public_key_path_snapshot \
        "$TARGET" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || return 21
    if [ -f "$TARGET" ]; then
        ORIGINAL_PRESENT=yes
        BEFORE_DIGEST=$(cksum < "$TARGET" 2>/dev/null) || return 21
    fi

    if [ -f "$TARGET" ] && awk -v wanted_type="$KEY_TYPE" -v wanted_data="$KEY_DATA" '
        function supported(value) {
            return value == "ssh-rsa" || value == "ssh-ed25519" || value == "ssh-dss" \
                || value == "ecdsa-sha2-nistp256" || value == "ecdsa-sha2-nistp384" \
                || value == "ecdsa-sha2-nistp521" \
                || value == "sk-ssh-ed25519@openssh.com" \
                || value == "sk-ecdsa-sha2-nistp256@openssh.com"
        }
        {
            for (field=1; field<NF; field++) {
                if (!supported($field)) continue
                if ($field == wanted_type && $(field+1) == wanted_data) found=1
                break
            }
        }
        END {exit !found}
    ' "$TARGET"; then
        return 10
    fi

    TEMP=$(mktemp "${TARGET}.vps-tools.XXXXXX") || return 23
    if [ -f "$TARGET" ] && ! cp -a -- "$TARGET" "$TEMP"; then
        rm -f -- "$TEMP"
        return 24
    fi
    if [ -s "$TEMP" ]; then
        LAST_BYTE=$(tail -c 1 -- "$TEMP" 2>/dev/null | od -An -tu1 | tr -d '[:space:]')
        if [ "$LAST_BYTE" != 10 ] && ! printf '\n' >> "$TEMP"; then
            rm -f -- "$TEMP"
            return 25
        fi
    fi
    if ! printf '%s\n' "$PUBKEY_INPUT" >> "$TEMP" \
        || ! chmod 600 "$TEMP"; then
        rm -f -- "$TEMP"
        return 25
    fi

    AFTER=$(ssh_public_key_path_snapshot \
        "$TARGET" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || {
        rm -f -- "$TEMP"
        return 26
    }
    if [ "$ORIGINAL_PRESENT" = yes ]; then
        CURRENT_DIGEST=$(cksum < "$TARGET" 2>/dev/null) || {
            rm -f -- "$TEMP"
            return 26
        }
    elif [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        rm -f -- "$TEMP"
        return 26
    fi
    if [ "$AFTER" != "$BEFORE" ] \
        || { [ "$ORIGINAL_PRESENT" = yes ] && [ "$CURRENT_DIGEST" != "$BEFORE_DIGEST" ]; }; then
        rm -f -- "$TEMP"
        return 26
    fi
    if ! mv -f -- "$TEMP" "$TARGET"; then
        rm -f -- "$TEMP"
        return 27
    fi
    ssh_public_key_path_snapshot \
        "$TARGET" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR" >/dev/null || return 28
    return 0
}

ssh_setpriv_target_supported() {
    local HELP
    command -v setpriv >/dev/null 2>&1 || return 1
    HELP=$(LC_ALL=C setpriv --help 2>&1 || true)
    printf '%s\n' "$HELP" | grep -q -- '--reuid' \
        && printf '%s\n' "$HELP" | grep -q -- '--regid' \
        && printf '%s\n' "$HELP" | grep -q -- '--init-groups'
}

ssh_run_as_target() {
    local USERNAME="$1" ACCOUNT_UID="$2" ACCOUNT_GID="$3" WORKER_SCRIPT="$4"
    local CURRENT_UID BASH_BIN
    shift 4
    CURRENT_UID=$(id -u 2>/dev/null) || return 30
    BASH_BIN=$(command -v bash 2>/dev/null) || return 30
    if [ "$CURRENT_UID" = "$ACCOUNT_UID" ]; then
        "$BASH_BIN" -c "$WORKER_SCRIPT" vps-tools-key-worker "$@"
        return
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USERNAME" -- "$BASH_BIN" -c "$WORKER_SCRIPT" \
            vps-tools-key-worker "$@"
        return
    fi
    if ssh_setpriv_target_supported; then
        setpriv --reuid="$ACCOUNT_UID" --regid="$ACCOUNT_GID" --init-groups \
            "$BASH_BIN" -c "$WORKER_SCRIPT" vps-tools-key-worker "$@"
        return
    fi
    if command -v su >/dev/null 2>&1; then
        su -s "$BASH_BIN" -c "$WORKER_SCRIPT" "$USERNAME" \
            vps-tools-key-worker "$@"
        return
    fi
    return 30
}

ssh_key_file_capture_worker() {
    local TARGET="$1" SCOPE="$2" EXPECTED_UID="$3" HOME_DIR="$4"
    local MAX_BYTES="$5" BEFORE AFTER SIZE BEFORE_DIGEST AFTER_DIGEST
    case "$MAX_BYTES" in
        ''|*[!0-9]*) return 21 ;;
    esac
    [ "$MAX_BYTES" -ge 1 ] 2>/dev/null || return 21
    BEFORE=$(ssh_public_key_path_snapshot \
        "$TARGET" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || return 21
    SIZE=$(stat -Lc '%s' -- "$TARGET" 2>/dev/null) || return 21
    [[ "$SIZE" =~ ^[0-9]+$ ]] && [ "$SIZE" -le "$MAX_BYTES" ] || return 21
    BEFORE_DIGEST=$(cksum < "$TARGET" 2>/dev/null) || return 22
    head -c "$((MAX_BYTES + 1))" -- "$TARGET" || return 22
    SIZE=$(stat -Lc '%s' -- "$TARGET" 2>/dev/null) || return 21
    [ "$SIZE" -le "$MAX_BYTES" ] || return 21
    AFTER_DIGEST=$(cksum < "$TARGET" 2>/dev/null) || return 22
    [ "$AFTER_DIGEST" = "$BEFORE_DIGEST" ] || return 23
    AFTER=$(ssh_public_key_path_snapshot \
        "$TARGET" "$SCOPE" "$EXPECTED_UID" "$HOME_DIR") || return 21
    [ "$AFTER" = "$BEFORE" ] || return 23
}

ssh_key_file_capture_as_target() {
    local TARGET="$1" SCOPE="$2" USERNAME="$3" ACCOUNT_UID="$4"
    local ACCOUNT_GID="$5" HOME_DIR="$6" WORKER_SCRIPT
    local MAX_BYTES="${SSH_AUTHORIZED_KEYS_MAX_BYTES:-4194304}"
    case "$MAX_BYTES" in
        ''|*[!0-9]*) MAX_BYTES=4194304 ;;
    esac
    [ "$MAX_BYTES" -ge 1 ] 2>/dev/null || MAX_BYTES=4194304
    WORKER_SCRIPT="$(declare -f ssh_public_key_path_snapshot)
$(declare -f ssh_key_file_capture_worker)
ssh_key_file_capture_worker \"\$@\""
    if [ "$SCOPE" = global ]; then
        ssh_key_file_capture_worker \
            "$TARGET" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" "$MAX_BYTES"
        return
    fi
    ssh_run_as_target "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$WORKER_SCRIPT" \
        "$TARGET" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" "$MAX_BYTES"
}

ssh_public_key_install_as_target() {
    local TARGET="$1" PUBKEY_INPUT="$2" SCOPE="$3" USERNAME="$4"
    local ACCOUNT_UID="$5" ACCOUNT_GID="$6" HOME_DIR="$7" WORKER_SCRIPT

    if [ "$SCOPE" = global ]; then
        ssh_public_key_install_worker \
            "$TARGET" "$PUBKEY_INPUT" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR"
        return
    fi
    WORKER_SCRIPT="$(declare -f ssh_public_key_path_snapshot)
$(declare -f ssh_public_key_install_worker)
ssh_public_key_install_worker \"\$@\""
    ssh_run_as_target "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$WORKER_SCRIPT" \
        "$TARGET" "$PUBKEY_INPUT" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR"
}

ssh_cancel_safety_timer_checked() {
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local OLD_PID="${SAFETY_PID:-}" OLD_SCRIPT="${SAFETY_SCRIPT:-}"
    local OLD_ROOTS="${SAFETY_ROOTS_FILE:-}" OLD_SYSCTL="${SAFETY_SYSCTL_FILE:-}"
    local OLD_IPTABLES="${SAFETY_IPTABLES_FILE:-}" OLD_SNAPSHOT="${SAFETY_SNAPSHOT:-}"
    local OLD_IP6TABLES="${SAFETY_IP6TABLES_FILE:-}"
    local OLD_APPLIED="${SAFETY_APPLIED_SNAPSHOT:-}"
    local OLD_APPLIED_ROOTS="${SAFETY_APPLIED_ROOTS:-}"
    local ARTIFACT FAILED=no

    [[ "$OLD_PID" =~ ^[1-9][0-9]*$ ]] && [ -n "$OLD_SCRIPT" ] || {
        error "缺少待取消防断联事务的身份信息，拒绝取消未知任务"
        return 1
    }
    if ! cancel_safety_timer \
        "$OLD_PID" "$OLD_SCRIPT" "$OLD_ROOTS" "$OLD_SYSCTL" "$OLD_SNAPSHOT"; then
        FAILED=yes
    fi
    { [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; } || FAILED=yes
    for ARTIFACT in \
        "$OLD_SCRIPT" "$OLD_ROOTS" "$OLD_SYSCTL" "$OLD_IPTABLES" "$OLD_IP6TABLES"; do
        [ -z "$ARTIFACT" ] \
            || { [ ! -e "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ]; } \
            || FAILED=yes
    done
    for ARTIFACT in "$OLD_APPLIED" "$OLD_APPLIED_ROOTS"; do
        [ -z "$ARTIFACT" ] \
            || { [ ! -e "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ]; } \
            || FAILED=yes
    done
    # Generic safety snapshots are private timer artifacts and must disappear.
    # A key-deletion timer stores its independent user backup in the same state
    # field so abnormal termination is recoverable; that backup is intentionally
    # retained after confirmation.
    case "$OLD_SNAPSHOT" in
        "${VPS_DATA_DIR}"/rollback_*.tar.gz)
            [ ! -e "$OLD_SNAPSHOT" ] && [ ! -L "$OLD_SNAPSHOT" ] \
                || FAILED=yes
            ;;
    esac
    if [[ "$OLD_PID" =~ ^[1-9][0-9]*$ ]]; then
        for _ in 1 2 3; do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.05
        done
        kill -0 "$OLD_PID" 2>/dev/null && FAILED=yes
    fi
    if [ "$FAILED" = yes ]; then
        error "自动回滚任务未能完整取消；请保持当前连接并检查：$STATE_FILE"
        return 1
    fi
    return 0
}

ssh_cancel_loaded_timer_locked() {
    local STATE_FILE="$1" STATE_PID="$2" STATE_SCRIPT="$3" STATE_ROOTS="$4"
    local STATE_SYSCTL="$5" STATE_SNAPSHOT="$6"
    local STATE_IPTABLES STATE_IP6TABLES STATE_APPLIED STATE_APPLIED_ROOTS
    local ARTIFACT FAILED=no
    STATE_IPTABLES="${STATE_SCRIPT%.sh}.iptables"
    STATE_IP6TABLES="${STATE_SCRIPT%.sh}.ip6tables"
    STATE_APPLIED="${STATE_SCRIPT%.sh}.applied.tar"
    STATE_APPLIED_ROOTS="${STATE_SCRIPT%.sh}.applied.roots"
    if [[ "$STATE_PID" =~ ^[1-9][0-9]*$ ]]; then
        ssh_safety_worker_identity_valid "$STATE_PID" "$STATE_SCRIPT" || return 1
        kill "$STATE_PID" 2>/dev/null || true
        wait "$STATE_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$STATE_PID" 2>/dev/null || break
            sleep 0.05
        done
        kill -0 "$STATE_PID" 2>/dev/null && return 1
    fi
    safety_artifact_remove "$STATE_SCRIPT"
    safety_artifact_remove "$STATE_ROOTS"
    safety_artifact_remove "$STATE_SYSCTL"
    safety_artifact_remove "$STATE_IPTABLES"
    safety_artifact_remove "$STATE_IP6TABLES"
    safety_artifact_remove "$STATE_APPLIED"
    safety_artifact_remove "$STATE_APPLIED_ROOTS"
    # A key-deletion transaction stores its independent user backup in the
    # snapshot field.  Keep that backup after confirmation; generic timers
    # always have a roots file and own their snapshot.
    [ -z "$STATE_ROOTS" ] || safety_artifact_remove "$STATE_SNAPSHOT"
    for ARTIFACT in \
        "$STATE_SCRIPT" "$STATE_ROOTS" "$STATE_SYSCTL" "$STATE_IPTABLES" \
        "$STATE_IP6TABLES" "$STATE_APPLIED" "$STATE_APPLIED_ROOTS"; do
        [ -z "$ARTIFACT" ] \
            || { [ ! -e "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ]; } \
            || FAILED=yes
    done
    if [ -n "$STATE_ROOTS" ]; then
        [ ! -e "$STATE_SNAPSHOT" ] && [ ! -L "$STATE_SNAPSHOT" ] \
            || FAILED=yes
    fi
    [ "$FAILED" = no ] || return 1
    rm -f -- "$STATE_FILE" 2>/dev/null || return 1
    [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 1
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_ROOTS_FILE="" SAFETY_SYSCTL_FILE=""
    SAFETY_IPTABLES_FILE="" SAFETY_IP6TABLES_FILE=""
    SAFETY_APPLIED_SNAPSHOT="" SAFETY_APPLIED_ROOTS=""
    SAFETY_SNAPSHOT="" SAFETY_STATUS=""
}

ssh_safety_cancel_transition() {
    local REQUIRED_STATUS="$1"
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local EXPECTED_PID="${SAFETY_PID:-}" EXPECTED_SCRIPT="${SAFETY_SCRIPT:-}"
    local EXPECTED_ROOTS="${SAFETY_ROOTS_FILE:-}" EXPECTED_SYSCTL="${SAFETY_SYSCTL_FILE:-}"
    local EXPECTED_SNAPSHOT="${SAFETY_SNAPSHOT:-}"
    local STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL STATE_SNAPSHOT STATE_STATUS
    local STATE_TMP=""
    [[ "$EXPECTED_PID" =~ ^[1-9][0-9]*$ ]] && [ -n "$EXPECTED_SCRIPT" ] || return 1
    safety_lock_acquire || return 1
    if ! IFS='|' read -r STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL \
        STATE_SNAPSHOT STATE_STATUS < "$STATE_FILE" 2>/dev/null \
        || [ "$STATE_PID" != "$EXPECTED_PID" ] \
        || [ "$STATE_SCRIPT" != "$EXPECTED_SCRIPT" ] \
        || [ "$STATE_ROOTS" != "$EXPECTED_ROOTS" ] \
        || [ "$STATE_SYSCTL" != "$EXPECTED_SYSCTL" ] \
        || [ "$STATE_SNAPSHOT" != "$EXPECTED_SNAPSHOT" ] \
        || [ "$STATE_STATUS" != "$REQUIRED_STATUS" ] \
        || ! ssh_safety_worker_identity_valid "$STATE_PID" "$STATE_SCRIPT"; then
        safety_lock_release
        return 1
    fi
    STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || STATE_TMP=""
    if [ -z "$STATE_TMP" ] \
        || ! printf '%s|%s|%s|%s|%s|cancelled\n' \
            "$STATE_PID" "$STATE_SCRIPT" "$STATE_ROOTS" "$STATE_SYSCTL" \
            "$STATE_SNAPSHOT" > "$STATE_TMP" \
        || ! chmod 600 "$STATE_TMP" 2>/dev/null \
        || ! mv -f -- "$STATE_TMP" "$STATE_FILE"; then
        [ -z "$STATE_TMP" ] || rm -f -- "$STATE_TMP"
        safety_lock_release
        return 1
    fi
    SAFETY_STATUS=cancelled
    if ! ssh_cancel_loaded_timer_locked \
        "$STATE_FILE" "$STATE_PID" "$STATE_SCRIPT" "$STATE_ROOTS" \
        "$STATE_SYSCTL" "$STATE_SNAPSHOT"; then
        safety_lock_release
        error "自动回滚进程未能按事务身份停止，已保留 cancelled 状态供人工核对"
        return 1
    fi
    safety_lock_release
    return 0
}

ssh_cancel_live_safety_timer_checked() {
    if ! ssh_safety_cancel_transition applied; then
        error "待确认的防断联任务已不存在、已开始回滚或身份不匹配，不能报告确认成功"
        return 1
    fi
}

ssh_key_delete_cancel_live_timer() {
    local KEY_FILE="$1" KEY_SCOPE="$2" KEY_USER="$3" ACCOUNT_UID="$4"
    local ACCOUNT_GID="$5" HOME_DIR="$6" CANDIDATE_DIGEST="$7"
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}"
    local EXPECTED_PID="${SAFETY_PID:-}" EXPECTED_SCRIPT="${SAFETY_SCRIPT:-}"
    local EXPECTED_SNAPSHOT="${SAFETY_SNAPSHOT:-}" CURRENT_DIGEST
    local STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL STATE_SNAPSHOT STATE_STATUS
    local STATE_TMP="" CURRENT_CAPTURE=""
    [ -n "$KEY_FILE" ] && [ -n "$CANDIDATE_DIGEST" ] || return 1
    safety_lock_acquire || {
        error "公钥自动恢复已经开始或正由其他进程处理，不能确认删除"
        return 1
    }
    if ! IFS='|' read -r STATE_PID STATE_SCRIPT STATE_ROOTS STATE_SYSCTL \
        STATE_SNAPSHOT STATE_STATUS < "$STATE_FILE" 2>/dev/null \
        || [ "$STATE_PID" != "$EXPECTED_PID" ] \
        || [ "$STATE_SCRIPT" != "$EXPECTED_SCRIPT" ] \
        || [ "$STATE_SNAPSHOT" != "$EXPECTED_SNAPSHOT" ] \
        || [ "$STATE_STATUS" != applied ] \
        || ! ssh_safety_worker_identity_valid "$STATE_PID" "$STATE_SCRIPT"; then
        safety_lock_release
        error "公钥删除任务已回滚、状态不完整或身份不匹配，不能报告确认成功"
        return 1
    fi
    CURRENT_CAPTURE=$(mktemp) || CURRENT_CAPTURE=""
    if [ -z "$CURRENT_CAPTURE" ] \
        || ! ssh_key_file_capture_as_target \
            "$KEY_FILE" "$KEY_SCOPE" "$KEY_USER" "$ACCOUNT_UID" "$ACCOUNT_GID" \
            "$HOME_DIR" > "$CURRENT_CAPTURE"; then
        [ -z "$CURRENT_CAPTURE" ] || rm -f -- "$CURRENT_CAPTURE"
        safety_lock_release
        error "无法确认公钥文件仍是本次删除后的候选内容，保留自动恢复"
        return 1
    fi
    CURRENT_DIGEST=$(cksum < "$CURRENT_CAPTURE" 2>/dev/null) || CURRENT_DIGEST=""
    rm -f -- "$CURRENT_CAPTURE"
    if [ "$CURRENT_DIGEST" != "$CANDIDATE_DIGEST" ]; then
        safety_lock_release
        error "公钥文件在确认前已变化或已被自动恢复，不能报告删除确认成功"
        return 1
    fi
    STATE_TMP=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || STATE_TMP=""
    if [ -z "$STATE_TMP" ] \
        || ! printf '%s|%s|%s|%s|%s|cancelled\n' \
            "$STATE_PID" "$STATE_SCRIPT" "$STATE_ROOTS" "$STATE_SYSCTL" \
            "$STATE_SNAPSHOT" > "$STATE_TMP" \
        || ! chmod 600 "$STATE_TMP" 2>/dev/null \
        || ! mv -f -- "$STATE_TMP" "$STATE_FILE"; then
        [ -z "$STATE_TMP" ] || rm -f -- "$STATE_TMP"
        safety_lock_release
        error "无法原子确认公钥删除状态，保留自动恢复"
        return 1
    fi
    SAFETY_STATUS=cancelled
    if ! ssh_cancel_loaded_timer_locked \
        "$STATE_FILE" "$STATE_PID" "$STATE_SCRIPT" "$STATE_ROOTS" \
        "$STATE_SYSCTL" "$STATE_SNAPSHOT"; then
        safety_lock_release
        error "公钥自动恢复进程未能按事务身份停止，已保留 cancelled 状态供人工核对"
        return 1
    fi
    safety_lock_release
    return 0
}

ssh_safety_confirm_checked() {
    local OK
    safety_mark_applied || {
        error "无法记录本次 SSH 变更状态；保留自动回滚且不允许确认"
        return 1
    }
    echo ""
    warn "请保持当前连接，并用新终端确认 SSH 和网络正常。"
    read -rp "  确认连接正常，取消自动回滚？(y/N): " OK
    if ! echo "$OK" | grep -qiE '^y(es)?$'; then
        warn "自动回滚仍在计时，请勿关闭旧连接。"
        return 0
    fi
    if ! ssh_cancel_live_safety_timer_checked; then
        return 1
    fi
    audit_action "确认连接正常，取消自动回滚" SUCCESS
    info "已取消自动回滚"
}

ssh_config_file_state() {
    local FILE="$1" BEFORE_META AFTER_META DIGEST
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || return 1
    BEFORE_META=$(stat -Lc '%d:%i:%u:%g:%a:%s:%Y:%Z:%F' -- "$FILE" 2>/dev/null) \
        || return 1
    DIGEST=$(cksum < "$FILE" 2>/dev/null) || return 1
    AFTER_META=$(stat -Lc '%d:%i:%u:%g:%a:%s:%Y:%Z:%F' -- "$FILE" 2>/dev/null) \
        || return 1
    [ "$AFTER_META" = "$BEFORE_META" ] || return 1
    printf '%s|%s\n' "$BEFORE_META" "$DIGEST"
}

ssh_prepare_config_candidate() {
    local RESULT_VAR="$1" PREPARED_CONFIG BEFORE_STATE AFTER_STATE
    [ -f "$SSHD_CONFIG" ] && [ ! -L "$SSHD_CONFIG" ] || {
        error "SSH 配置必须是普通文件，拒绝修改符号链接或特殊文件：$SSHD_CONFIG"
        return 1
    }
    BEFORE_STATE=$(ssh_config_file_state "$SSHD_CONFIG") || {
        error "无法稳定读取当前 SSH 配置，文件可能正在被其他进程修改"
        return 1
    }
    PREPARED_CONFIG=$(mktemp) || {
        error "无法创建 SSH 候选配置"
        return 1
    }
    if ! cp -a -- "$SSHD_CONFIG" "$PREPARED_CONFIG"; then
        rm -f -- "$PREPARED_CONFIG"
        error "无法读取当前 SSH 配置"
        return 1
    fi
    AFTER_STATE=$(ssh_config_file_state "$SSHD_CONFIG") || AFTER_STATE=""
    if [ "$AFTER_STATE" != "$BEFORE_STATE" ] \
        || ! cmp -s "$SSHD_CONFIG" "$PREPARED_CONFIG"; then
        rm -f -- "$PREPARED_CONFIG"
        error "读取候选配置期间 SSH 配置发生变化，请重新操作"
        return 1
    fi
    SSH_CONFIG_PREPARED_STATE="$BEFORE_STATE"
    SSH_CONFIG_APPLIED_STATE=""
    SSH_CONFIG_APPLIED_DIGEST=""
    printf -v "$RESULT_VAR" '%s' "$PREPARED_CONFIG"
}

ssh_candidate_set_options() {
    local CANDIDATE="$1" KEY VALUE
    shift
    while [ "$#" -ge 2 ]; do
        KEY="$1"
        VALUE="$2"
        shift 2
        if ! set_config_file "$CANDIDATE" "$KEY" "$VALUE"; then
            error "无法在 SSH 候选配置中设置 $KEY"
            return 1
        fi
    done
    [ "$#" -eq 0 ]
}

ssh_install_candidate_config() {
    local CANDIDATE="$1" APPLY_TMP CURRENT_STATE CANDIDATE_DIGEST
    SSH_CONFIG_INSTALL_UNCHANGED=no
    [ -f "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ] || {
        error "SSH 候选配置不是安全的普通文件"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    }
    [ -f "$SSHD_CONFIG" ] && [ ! -L "$SSHD_CONFIG" ] || {
        error "SSH 配置目标必须是普通文件，拒绝替换符号链接或特殊文件：$SSHD_CONFIG"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    }
    CURRENT_STATE=$(ssh_config_file_state "$SSHD_CONFIG") || {
        error "无法稳定读取 SSH 配置目标"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    }
    if [ -z "${SSH_CONFIG_PREPARED_STATE:-}" ] \
        || [ "$CURRENT_STATE" != "$SSH_CONFIG_PREPARED_STATE" ]; then
        error "准备候选配置后 sshd_config 已被其他进程修改，拒绝覆盖并发变更"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    fi
    CANDIDATE_DIGEST=$(cksum < "$CANDIDATE" 2>/dev/null) || {
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    }
    APPLY_TMP=$(mktemp "${SSHD_CONFIG}.vps-tools-apply.XXXXXX") || {
        error "无法在 sshd_config 目录创建临时文件"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    }
    if ! cp -a -- "$CANDIDATE" "$APPLY_TMP" \
        || ! cmp -s "$CANDIDATE" "$APPLY_TMP"; then
        rm -f -- "$APPLY_TMP"
        error "无法准备待应用的 SSH 配置"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    fi
    CURRENT_STATE=$(ssh_config_file_state "$SSHD_CONFIG") || CURRENT_STATE=""
    if [ "$CURRENT_STATE" != "$SSH_CONFIG_PREPARED_STATE" ]; then
        rm -f -- "$APPLY_TMP"
        error "安装候选配置前 sshd_config 发生并发变化，已取消写入"
        SSH_CONFIG_INSTALL_UNCHANGED=yes
        return 1
    fi
    if ! mv -f -- "$APPLY_TMP" "$SSHD_CONFIG"; then
        rm -f -- "$APPLY_TMP"
        error "无法原子替换 SSH 配置"
        return 1
    fi
    SSH_CONFIG_APPLIED_DIGEST="$CANDIDATE_DIGEST"
    SSH_CONFIG_APPLIED_STATE=$(ssh_config_file_state "$SSHD_CONFIG") || {
        error "无法验证写入后的 SSH 配置状态"
        return 1
    }
    if ! cmp -s "$CANDIDATE" "$SSHD_CONFIG"; then
        error "写入后的 SSH 配置与候选配置不一致"
        return 1
    fi
    return 0
}

ssh_restore_and_cancel_safety() {
    if [ "${SSH_CONFIG_INSTALL_UNCHANGED:-no}" = yes ]; then
        ssh_cancel_safety_timer_checked || return 1
        return 0
    fi
    if restore_ssh_config_backup; then
        ssh_cancel_safety_timer_checked || return 1
        return 0
    fi
    error "即时恢复失败，自动回滚仍应保持运行；请勿关闭当前连接"
    return 1
}

ssh_handle_apply_failure() {
    local APPLY_STATUS="$1"
    if [ "$APPLY_STATUS" -eq 1 ]; then
        ssh_cancel_safety_timer_checked || return 1
    else
        error "SSH 配置即时回滚失败，自动回滚仍在计时；请勿关闭当前连接"
    fi
    return 1
}

ssh_public_key_target_resolve() {
    local USERNAME="$1" RECORD LOGIN_SHELL
    SSH_KEY_TARGET_USER=""
    SSH_KEY_TARGET_UID=""
    SSH_KEY_TARGET_GID=""
    SSH_KEY_TARGET_HOME=""
    SSH_KEY_TARGET_FILE=""
    SSH_KEY_TARGET_SCOPE=""

    RECORD=$(ssh_account_record "$USERNAME")
    [ -n "$RECORD" ] || { error "用户 $USERNAME 不存在"; return 1; }
    IFS=: read -r SSH_KEY_TARGET_USER _ SSH_KEY_TARGET_UID SSH_KEY_TARGET_GID _ \
        SSH_KEY_TARGET_HOME LOGIN_SHELL <<< "$RECORD"
    if ! ssh_key_target_allowed \
        "$SSH_KEY_TARGET_USER" "$SSH_KEY_TARGET_UID" "$SSH_KEY_TARGET_HOME" "$LOGIN_SHELL"; then
        error "用户 $USERNAME 不是可用的交互式登录账号"
        return 1
    fi
    SSH_KEY_TARGET_FILE=$(ssh_authorized_keys_path_for_user \
        "$SSHD_CONFIG" "$SSH_KEY_TARGET_USER" "$SSH_KEY_TARGET_UID" "$SSH_KEY_TARGET_HOME") || {
        error "无法确定用户 $USERNAME 实际生效的 AuthorizedKeysFile，已拒绝写入"
        return 1
    }
    if [ "$SSH_KEY_TARGET_HOME" = / ] \
        || [[ "$SSH_KEY_TARGET_FILE" == "${SSH_KEY_TARGET_HOME%/}/"* ]]; then
        SSH_KEY_TARGET_SCOPE=home
    else
        SSH_KEY_TARGET_SCOPE=global
    fi
    if ! ssh_public_key_path_snapshot \
        "$SSH_KEY_TARGET_FILE" "$SSH_KEY_TARGET_SCOPE" \
        "$SSH_KEY_TARGET_UID" "$SSH_KEY_TARGET_HOME" >/dev/null; then
        error "公钥目标路径包含符号链接、非普通文件或不安全的可写组件：$SSH_KEY_TARGET_FILE"
        return 1
    fi
}

ssh_public_key_install() {
    local PUBKEY_INPUT="$1" TOTAL INSTALL_STATUS CAPTURE
    [ -n "${SSH_KEY_TARGET_USER:-}" ] && [ -n "${SSH_KEY_TARGET_FILE:-}" ] || {
        error "尚未选择有效的公钥目标用户"
        return 1
    }
    case "$PUBKEY_INPUT" in
        *$'\n'*|*$'\r'*)
            error "公钥必须是单行内容"
            return 1
            ;;
    esac
    if ! ssh_public_key_line_valid "$PUBKEY_INPUT"; then
        error "公钥格式或内容无效，应使用以 ssh-ed25519、ssh-rsa 等开头的完整单行公钥"
        return 1
    fi

    if ssh_public_key_install_as_target \
        "$SSH_KEY_TARGET_FILE" "$PUBKEY_INPUT" "$SSH_KEY_TARGET_SCOPE" \
        "$SSH_KEY_TARGET_USER" "$SSH_KEY_TARGET_UID" "$SSH_KEY_TARGET_GID" \
        "$SSH_KEY_TARGET_HOME"; then
        :
    else
        INSTALL_STATUS=$?
        if [ "$INSTALL_STATUS" -eq 10 ]; then
            warn "该公钥已存在于用户 $SSH_KEY_TARGET_USER，跳过添加"
            audit_action "为用户 $SSH_KEY_TARGET_USER 添加 SSH 公钥（已存在）" INFO
            return 0
        fi
        if [ "$INSTALL_STATUS" -eq 30 ]; then
            error "系统缺少可用的 runuser/setpriv/su，无法以目标用户身份安全写入公钥"
        else
            error "安全写入公钥失败（路径可能在操作期间变化），原文件未被直接追加"
        fi
        return 1
    fi

    CAPTURE=$(mktemp) || {
        error "公钥已写入，但无法创建写后校验文件"
        return 1
    }
    if ! ssh_key_file_capture_as_target \
        "$SSH_KEY_TARGET_FILE" "$SSH_KEY_TARGET_SCOPE" "$SSH_KEY_TARGET_USER" \
        "$SSH_KEY_TARGET_UID" "$SSH_KEY_TARGET_GID" "$SSH_KEY_TARGET_HOME" \
        > "$CAPTURE"; then
        rm -f "$CAPTURE"
        error "公钥已写入，但无法安全完成写后校验"
        return 1
    fi
    TOTAL=$(ssh_key_file_count "$CAPTURE")
    rm -f "$CAPTURE"
    info "公钥已添加到用户 $SSH_KEY_TARGET_USER！该文件当前共 $TOTAL 个公钥 ✓"
    audit_action "为用户 $SSH_KEY_TARGET_USER 添加 SSH 公钥" SUCCESS
}

add_key() {
    print_header "添加 SSH 公钥"

    local USERNAME PUBKEY_INPUT
    ssh_print_key_accounts

    read -rp "  输入目标用户名（直接回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消，未添加公钥。"; return; }
    ssh_public_key_target_resolve "$USERNAME" || return 1

    echo ""
    echo -e "  目标用户：${BOLD}${SSH_KEY_TARGET_USER}${NC}"
    echo -e "  公钥文件：${BOLD}${SSH_KEY_TARGET_FILE}${NC}"
    read -r -p "  粘贴一整行 SSH 公钥（直接回车取消）: " PUBKEY_INPUT
    PUBKEY_INPUT=${PUBKEY_INPUT%$'\r'}
    PUBKEY_INPUT="${PUBKEY_INPUT#"${PUBKEY_INPUT%%[![:space:]]*}"}"
    if [ -z "$PUBKEY_INPUT" ]; then
        warn "已取消，未添加公钥。"
        return
    fi
    ssh_public_key_install "$PUBKEY_INPUT"
}

delete_key() {
    print_header "删除指定用户 SSH 公钥"

    local USERNAME RECORD ACCOUNT_UID ACCOUNT_GID HOME_DIR LOGIN_SHELL INVENTORY DEL_NUM SELECTED
    local KEY_FILE LINE_NO KEY_TYPE KEY_DATA FINGERPRINT COMMENT OPTIONS ORIGINAL CANDIDATE
    local REMAINING VERIFY_USER VERIFY_LINE VERIFY_ROUTE VERIFY_ADMIN CONFIRM_NAME
    local LIST_USER LIST_ROUTE LIST_ADMIN BACKUP POST_REMAINING KEY_SCOPE CURRENT_CAPTURE
    local EXPECTED_DIGEST CANDIDATE_DIGEST APPLY_STATUS CAPTURE_OK
    ssh_print_key_accounts
    read -rp "  输入要删除公钥的用户名（直接回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消，公钥未修改。"; return; }
    RECORD=$(ssh_account_record "$USERNAME")
    [ -n "$RECORD" ] || { error "用户 $USERNAME 不存在"; return 1; }
    IFS=: read -r _ _ ACCOUNT_UID ACCOUNT_GID _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || {
        error "用户 $USERNAME 不是可用的交互式登录账号"
        return 1
    }

    INVENTORY=$(mktemp) || { error "无法创建公钥清单"; return 1; }
    ssh_key_inventory "$SSHD_CONFIG" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" > "$INVENTORY"
    if [ ! -s "$INVENTORY" ]; then
        rm -f "$INVENTORY"
        audit_action "查看待删除的用户 $USERNAME SSH 公钥（0 个）" SUCCESS
        warn "用户 $USERNAME 当前没有可删除的 SSH 公钥"
        return 0
    fi
    ssh_key_inventory_print "$INVENTORY"
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -n "$DEL_NUM" ] || { rm -f "$INVENTORY"; warn "已取消，公钥未修改。"; return; }
    [[ "$DEL_NUM" =~ ^[0-9]+$ ]] || {
        rm -f "$INVENTORY"
        error "无效编号"
        return 1
    }
    SELECTED=$(sed -n "${DEL_NUM}p" "$INVENTORY")
    rm -f "$INVENTORY"
    [ -n "$SELECTED" ] || { error "编号 $DEL_NUM 不存在"; return 1; }
    IFS=$'\t' read -r KEY_FILE LINE_NO KEY_TYPE KEY_DATA FINGERPRINT COMMENT OPTIONS <<< "$SELECTED"
    [[ "$LINE_NO" =~ ^[1-9][0-9]*$ ]] || { error "公钥行号无效"; return 1; }
    if [ "$HOME_DIR" = / ] || [[ "$KEY_FILE" == "${HOME_DIR%/}/"* ]]; then
        KEY_SCOPE=home
    else
        KEY_SCOPE=global
    fi
    ORIGINAL=$(mktemp) || { error "无法创建公钥文件快照"; return 1; }
    if ! ssh_key_file_capture_as_target \
        "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" > "$ORIGINAL"; then
        rm -f "$ORIGINAL"
        error "目标公钥文件路径不安全、不可读或在读取期间发生变化：$KEY_FILE"
        return 1
    fi
    ssh_key_inventory_line_matches "$ORIGINAL" "$LINE_NO" "$KEY_TYPE" "$KEY_DATA" || {
        rm -f "$ORIGINAL"
        error "公钥文件已发生变化，请重新进入菜单后再操作"
        return 1
    }

    CANDIDATE=$(mktemp) || { rm -f "$ORIGINAL"; error "无法创建候选公钥文件"; return 1; }
    awk -v target="$LINE_NO" 'NR != target {print}' "$ORIGINAL" > "$CANDIDATE" || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        error "无法生成删除后的候选公钥文件"
        return 1
    }
    REMAINING=$(SSH_KEY_EXCLUDE_FILE="$KEY_FILE" SSH_KEY_EXCLUDE_LINE="$LINE_NO" \
        ssh_login_candidates "$SSHD_CONFIG")
    if [ -z "$REMAINING" ]; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "拒绝删除用户 $USERNAME SSH 公钥：无剩余登录入口" FAILED
        error "删除后没有任何账号可以确认登录，禁止执行以避免锁死"
        return 1
    fi
    if ! ssh_login_candidates_have_admin "$REMAINING"; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "拒绝删除用户 $USERNAME SSH 公钥：无剩余管理入口" FAILED
        error "删除后虽有账号可登录，但没有 root 或具备完整 sudo/doas root 权限的管理入口，禁止执行"
        return 1
    fi

    echo -e "  ${BOLD}删除后仍可用的登录入口：${NC}"
    while IFS='|' read -r LIST_USER LIST_ROUTE LIST_ADMIN; do
        if [ "$LIST_ADMIN" = yes ]; then LIST_ADMIN="可管理"; else LIST_ADMIN="普通用户"; fi
        echo -e "  ${GREEN}•${NC} ${BOLD}${LIST_USER}${NC}  ${LIST_ROUTE}  ${DIM}${LIST_ADMIN}${NC}"
    done <<< "$REMAINING"
    echo ""
    read -rp "  选择一个将在新终端验证的管理员用户名（直接回车取消）: " VERIFY_USER
    [ -n "$VERIFY_USER" ] || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        warn "已取消，公钥未修改。"
        return
    }
    VERIFY_LINE=$(printf '%s\n' "$REMAINING" \
        | awk -F'|' -v username="$VERIFY_USER" '$1 == username && $3 == "yes" {print; exit}')
    if [ -z "$VERIFY_LINE" ]; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "拒绝删除用户 $USERNAME SSH 公钥：验证用户 $VERIFY_USER 不是可用管理员" FAILED
        error "用户 $VERIFY_USER 不是删除后可登录且可取得完整 root 权限的管理员"
        return 1
    fi
    IFS='|' read -r _ VERIFY_ROUTE VERIFY_ADMIN <<< "$VERIFY_LINE"

    warn "即将删除用户 $USERNAME 的以下公钥："
    echo -e "  ${RED}${KEY_TYPE}${NC}  ${FINGERPRINT}  ${COMMENT}"
    echo -e "  ${DIM}${KEY_FILE}:${LINE_NO}${NC}"
    read -rp "  输入目标用户名 $USERNAME 确认删除（其他输入取消）: " CONFIRM_NAME
    if [ "$CONFIRM_NAME" != "$USERNAME" ]; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        warn "用户名不匹配，已取消删除"
        return
    fi
    if ! confirm_file_diff "$ORIGINAL" "$CANDIDATE" "删除用户 $USERNAME 的 SSH 公钥"; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        warn "已取消，公钥未修改。"
        return
    fi

    CURRENT_CAPTURE=$(mktemp) || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        return 1
    }
    if ! ssh_key_file_capture_as_target \
        "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" > "$CURRENT_CAPTURE" \
        || ! cmp -s "$ORIGINAL" "$CURRENT_CAPTURE"; then
        rm -f "$CURRENT_CAPTURE"
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "取消删除用户 $USERNAME SSH 公钥：目标文件并发变更" FAILED
        error "确认期间公钥文件已发生变化，删除已取消"
        return 1
    fi
    rm -f "$CURRENT_CAPTURE"
    mkdir -p "$VPS_BACKUP_DIR" || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        error "无法创建备份目录"
        return 1
    }
    chmod 700 "$VPS_DATA_DIR" "$VPS_BACKUP_DIR" 2>/dev/null || true
    BACKUP="$VPS_BACKUP_DIR/$(date +%Y%m%d_%H%M%S)_ssh-key_${USERNAME}_$$_${RANDOM}.bak"
    cp -p -- "$ORIGINAL" "$BACKUP" || {
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        audit_action "删除用户 $USERNAME SSH 公钥：备份失败" FAILED
        error "无法备份目标公钥文件，删除已取消"
        return 1
    }
    CURRENT_CAPTURE=$(mktemp) || {
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        return 1
    }
    if ! ssh_key_file_capture_as_target \
        "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" > "$CURRENT_CAPTURE" \
        || ! cmp -s "$ORIGINAL" "$CURRENT_CAPTURE"; then
        rm -f "$CURRENT_CAPTURE"
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        audit_action "取消删除用户 $USERNAME SSH 公钥：备份期间目标文件并发变更" FAILED
        error "确认期间公钥文件已发生变化，删除已取消"
        return 1
    fi
    rm -f "$CURRENT_CAPTURE"
    EXPECTED_DIGEST=$(cksum < "$ORIGINAL" 2>/dev/null) || {
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        return 1
    }
    CANDIDATE_DIGEST=$(cksum < "$CANDIDATE" 2>/dev/null) || {
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        return 1
    }
    ssh_key_delete_safety_arm \
        "$KEY_FILE" "$BACKUP" "$USERNAME" "$KEY_SCOPE" \
        "$ACCOUNT_UID" "$ACCOUNT_GID" "$HOME_DIR" "$CANDIDATE_DIGEST" || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "删除用户 $USERNAME SSH 公钥：启动自动回滚失败" FAILED
        return 1
    }

    if ssh_key_delete_apply_transaction \
        "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" "$LINE_NO" "$EXPECTED_DIGEST"; then
        :
    else
        APPLY_STATUS=$?
        CURRENT_CAPTURE=$(mktemp) || CURRENT_CAPTURE=""
        CAPTURE_OK=no
        if [ -n "$CURRENT_CAPTURE" ] && ssh_key_file_capture_as_target \
            "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
            "$HOME_DIR" > "$CURRENT_CAPTURE"; then
            CAPTURE_OK=yes
        fi
        if [ "$CAPTURE_OK" = yes ] && cmp -s "$ORIGINAL" "$CURRENT_CAPTURE"; then
            ssh_cancel_safety_timer_checked || true
            audit_action "删除用户 $USERNAME SSH 公钥：写入前检测到并发变化" FAILED
            error "公钥文件未被本次操作修改，删除已取消（状态 $APPLY_STATUS）"
        elif [ "$CAPTURE_OK" = yes ] && cmp -s "$CANDIDATE" "$CURRENT_CAPTURE" \
            && ssh_key_file_restore_as_target \
                "$BACKUP" "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" \
                "$ACCOUNT_UID" "$ACCOUNT_GID" "$HOME_DIR" "$CANDIDATE_DIGEST"; then
            ssh_cancel_safety_timer_checked || true
            audit_action "删除用户 $USERNAME SSH 公钥：写入异常并条件回滚" FAILED
            error "写入过程异常，已在确认文件未被并发修改后恢复原文件"
        else
            audit_action "删除用户 $USERNAME SSH 公钥：并发状态不明，拒绝覆盖" FAILED
            error "公钥文件可能被并发修改，已拒绝用旧备份覆盖；自动恢复任务和备份均已保留，请人工核对：$KEY_FILE（备份：$BACKUP）"
        fi
        [ -z "$CURRENT_CAPTURE" ] || rm -f "$CURRENT_CAPTURE"
        rm -f "$ORIGINAL" "$CANDIDATE"
        return 1
    fi
    CURRENT_CAPTURE=$(mktemp) || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        return 1
    }
    CAPTURE_OK=yes
    if ! ssh_key_file_capture_as_target \
        "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" > "$CURRENT_CAPTURE"; then
        CAPTURE_OK=no
    fi
    if [ "$CAPTURE_OK" != yes ] || ! cmp -s "$CANDIDATE" "$CURRENT_CAPTURE"; then
        rm -f "$CURRENT_CAPTURE"
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "删除用户 $USERNAME SSH 公钥：写后出现并发变化，拒绝覆盖" FAILED
        error "写入后的公钥文件与候选结果不一致，已拒绝用旧备份覆盖；自动恢复任务和备份均已保留，请人工核对：$KEY_FILE（备份：$BACKUP）"
        return 1
    fi
    rm -f "$CURRENT_CAPTURE"

    POST_REMAINING=$(ssh_login_candidates "$SSHD_CONFIG")
    if [ -z "$POST_REMAINING" ] || ! ssh_login_candidates_have_admin "$POST_REMAINING"; then
        if ssh_key_file_restore_as_target \
            "$BACKUP" "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" \
            "$ACCOUNT_UID" "$ACCOUNT_GID" "$HOME_DIR" "$CANDIDATE_DIGEST"; then
            ssh_cancel_safety_timer_checked || true
            audit_action "删除用户 $USERNAME SSH 公钥后校验失败并回滚" FAILED
            error "删除后的实际校验未找到可用管理入口，已立即恢复原公钥文件"
        else
            audit_action "删除用户 $USERNAME SSH 公钥后校验失败且即时恢复失败" FAILED
            error "删除后校验失败，且文件已并发变化或即时恢复失败；已拒绝覆盖并保留自动恢复任务，请人工核对（备份：$BACKUP）"
        fi
        rm -f "$ORIGINAL" "$CANDIDATE"
        return 1
    fi
    rm -f "$ORIGINAL" "$CANDIDATE"

    info "公钥已删除；原文件备份：$BACKUP"
    audit_action "删除用户 $USERNAME SSH 公钥" SUCCESS
    ssh_key_delete_confirm_new_session \
        "$VERIFY_USER" "$VERIFY_ROUTE" "$KEY_FILE" "$KEY_SCOPE" "$USERNAME" \
        "$ACCOUNT_UID" "$ACCOUNT_GID" "$HOME_DIR" "$CANDIDATE_DIGEST"
}

generate_key() {
    print_header "生成 SSH 密钥对"

    echo -e "  选择密钥类型："
    menu_item "1" "Ed25519  ${DIM}推荐，更安全更短${NC}"
    menu_item "2" "RSA 4096"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择密钥类型 [0-2]: ')" KEY_TYPE_CHOICE

    case "$KEY_TYPE_CHOICE" in
        0) return ;;
        1) KEY_TYPE="ed25519"; KEY_BITS="" ;;
        2) KEY_TYPE="rsa";     KEY_BITS="-b 4096" ;;
        *) warn "无效选项，已取消。"; return ;;
    esac

    echo ""
    read -rp "  输入密钥备注（如 mypc@home，直接回车跳过）: " KEY_COMMENT
    KEY_COMMENT="${KEY_COMMENT:-ssh-key-$(date +%Y%m%d)}"

    local TMP_DIR KEY_FILE
    TMP_DIR=$(mktemp -d 2>/dev/null) || {
        error "无法创建安全的密钥临时目录"
        return 1
    }
    KEY_FILE="$TMP_DIR/id_${KEY_TYPE}"

    echo ""
    info "正在生成 $KEY_TYPE 密钥对..."

    # shellcheck disable=SC2086 # KEY_BITS intentionally expands to "-b 4096" for RSA only.
    if ! ssh-keygen -t "$KEY_TYPE" $KEY_BITS -C "$KEY_COMMENT" -f "$KEY_FILE" -N "" -q 2>/dev/null; then
        error "密钥生成失败。"; rm -rf "$TMP_DIR"; return
    fi

    local PUBKEY PRIVKEY FINGER
    PUBKEY=$(cat "${KEY_FILE}.pub")
    PRIVKEY=$(cat "$KEY_FILE")
    FINGER=$(ssh-keygen -lf "${KEY_FILE}.pub" 2>/dev/null | awk '{print $2}')
    audit_action "生成 SSH $KEY_TYPE 密钥对（指纹 ${FINGER:-N/A}）" SUCCESS

    print_header "密钥生成完成 — 请复制保存"

    echo -e "  ${DIM}类型：${NC}${BOLD}$KEY_TYPE${NC}   ${DIM}备注：${NC}${YELLOW}$KEY_COMMENT${NC}"
    echo -e "  ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
    echo ""
    echo -e "  ${BOLD}${RED}┌─── 私钥（仅显示一次，请立即复制！）───┐${NC}"
    echo ""
    echo "$PRIVKEY"
    echo ""
    echo -e "  ${BOLD}${RED}└────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}┌─── 公钥（可添加到服务器）─────────────┐${NC}"
    echo ""
    echo "$PUBKEY"
    echo ""
    echo -e "  ${BOLD}${GREEN}└────────────────────────────────────────┘${NC}"
    echo ""
    menu_div
    warn "私钥请立即复制到本地保存，关闭后无法找回！"
    menu_div
    echo ""

    read -rp "  是否将公钥添加到本服务器用户？(Y/n，默认Y): " ADD_CONFIRM
    [ -z "${ADD_CONFIRM}" ] && ADD_CONFIRM="y"
    if echo "${ADD_CONFIRM}" | grep -qiE '^y(es)?$'; then
        ssh_print_key_accounts
        local TARGET_USERNAME RETRY_TARGET
        while true; do
            read -rp "  输入目标用户名（默认 root，输入 0 则不添加）: " TARGET_USERNAME
            TARGET_USERNAME="${TARGET_USERNAME:-root}"
            if [ "$TARGET_USERNAME" = "0" ]; then
                warn "已跳过，生成的公钥未添加到任何用户。"
                audit_action "生成 SSH $KEY_TYPE 密钥对后跳过服务器公钥写入" INFO
                break
            fi
            if ssh_public_key_target_resolve "$TARGET_USERNAME"; then
                echo ""
                echo -e "  目标用户：${BOLD}${SSH_KEY_TARGET_USER}${NC}"
                echo -e "  公钥文件：${BOLD}${SSH_KEY_TARGET_FILE}${NC}"
                if ssh_public_key_install "$PUBKEY"; then
                    break
                fi
                audit_action "生成 SSH $KEY_TYPE 密钥对后为用户 $TARGET_USERNAME 写入公钥失败" FAILED
            fi
            read -rp "  目标不可用或写入失败，是否重新选择？(y/N，默认N): " RETRY_TARGET
            if ! echo "${RETRY_TARGET:-n}" | grep -qiE '^y(es)?$'; then
                warn "已停止添加，生成的公钥未写入任何用户。"
                audit_action "生成 SSH $KEY_TYPE 密钥对后未完成服务器公钥写入" FAILED
                break
            fi
        done
    else
        warn "已跳过，生成的公钥未添加到任何用户。"
        audit_action "生成 SSH $KEY_TYPE 密钥对后跳过服务器公钥写入" INFO
    fi

    rm -rf "$TMP_DIR"
}

ssh_strict_auth_methods_allow_pubkey() {
    local AUTH_METHODS="${1:-any}" METHOD
    case "$AUTH_METHODS" in
        ""|any) return 0 ;;
    esac
    while IFS= read -r METHOD; do
        [ -n "$METHOD" ] || continue
        [ "$METHOD" = publickey ] && return 0
    done < <(printf '%s\n' "$AUTH_METHODS" | tr '[:space:]' '\n')
    return 1
}

ssh_strict_effective_policy_ok() {
    local DUMP="$1"
    [ "$(ssh_config_dump_value "$DUMP" passwordauthentication)" = no ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" pubkeyauthentication)" = yes ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" permitrootlogin)" = no ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" kbdinteractiveauthentication)" = no ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" maxauthtries)" = 3 ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" clientaliveinterval)" = 300 ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" clientalivecountmax)" = 2 ] || return 1
    [ "$(ssh_config_dump_value "$DUMP" x11forwarding)" = no ] || return 1
    ssh_strict_auth_methods_allow_pubkey \
        "$(ssh_config_dump_value "$DUMP" authenticationmethods)"
}

ssh_strict_path_owner_mode_secure() {
    local TARGET="$1" ACCOUNT_UID="$2" STAT_INFO OWNER MODE PERMS GROUP_DIGIT OTHER_DIGIT
    STAT_INFO=$(stat -Lc '%u %a' "$TARGET" 2>/dev/null) || return 1
    read -r OWNER MODE <<< "$STAT_INFO"
    [ "$OWNER" = 0 ] || [ "$OWNER" = "$ACCOUNT_UID" ] || return 1
    [[ "$MODE" =~ ^[0-7]+$ ]] || return 1
    PERMS=${MODE: -3}
    [ "${#PERMS}" -eq 3 ] || return 1
    GROUP_DIGIT=${PERMS:1:1}
    OTHER_DIGIT=${PERMS:2:1}
    case "$GROUP_DIGIT$OTHER_DIGIT" in
        *2*|*3*|*6*|*7*) return 1 ;;
    esac
    return 0
}

ssh_strict_key_path_secure() {
    local KEY_FILE="$1" ACCOUNT_UID="$2" USERNAME="${3:-}" ACCOUNT_GID="${4:-}"
    local HOME_DIR="${5:-}" SCOPE
    if [ -z "$USERNAME" ] || [ -z "$ACCOUNT_GID" ] || [ -z "$HOME_DIR" ]; then
        [ "${VPS_TOOLS_TEST_MODE:-0}" = 1 ] || return 1
        [ -f "$KEY_FILE" ] && [ -r "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ]
        return
    fi
    if [ "$HOME_DIR" = / ] || [[ "$KEY_FILE" == "${HOME_DIR%/}/"* ]]; then
        SCOPE=home
    else
        SCOPE=global
    fi
    ssh_public_key_path_snapshot \
        "$KEY_FILE" "$SCOPE" "$ACCOUNT_UID" "$HOME_DIR" >/dev/null || return 1
    ssh_key_file_capture_as_target \
        "$KEY_FILE" "$SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
        "$HOME_DIR" >/dev/null
}

ssh_strict_key_file_has_unrestricted_key() {
    local KEY_FILE="$1" USERNAME="${2:-}" ACCOUNT_UID="${3:-}" ACCOUNT_GID="${4:-}"
    local HOME_DIR="${5:-}" KEY_LINE KEY_TYPE LINE_NO=0 INPUT_FILE="$KEY_FILE" SCOPE CAPTURE=""
    if [ -n "$USERNAME" ] && [ -n "$ACCOUNT_UID" ] \
        && [ -n "$ACCOUNT_GID" ] && [ -n "$HOME_DIR" ] \
        && [ "${VPS_TOOLS_TEST_MODE:-0}" != 1 ]; then
        if [ "$HOME_DIR" = / ] || [[ "$KEY_FILE" == "${HOME_DIR%/}/"* ]]; then
            SCOPE=home
        else
            SCOPE=global
        fi
        CAPTURE=$(mktemp) || return 1
        if ! ssh_key_file_capture_as_target \
            "$KEY_FILE" "$SCOPE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" \
            "$HOME_DIR" > "$CAPTURE"; then
            rm -f "$CAPTURE"
            return 1
        fi
        INPUT_FILE="$CAPTURE"
    fi
    while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
        LINE_NO=$((LINE_NO+1))
        if [ -n "${SSH_KEY_EXCLUDE_FILE:-}" ] \
            && [ "$KEY_FILE" = "$SSH_KEY_EXCLUDE_FILE" ] \
            && [ "$LINE_NO" = "${SSH_KEY_EXCLUDE_LINE:-}" ]; then
            continue
        fi
        KEY_LINE="${KEY_LINE#"${KEY_LINE%%[![:space:]]*}"}"
        case "$KEY_LINE" in ""|\#*) continue ;; esac
        read -r KEY_TYPE _ <<< "$KEY_LINE"
        [ "$KEY_TYPE" != ssh-dss ] || continue
        if ssh_public_key_line_valid "$KEY_LINE"; then
            [ -z "$CAPTURE" ] || rm -f "$CAPTURE"
            return 0
        fi
    done < "$INPUT_FILE"
    [ -z "$CAPTURE" ] || rm -f "$CAPTURE"
    return 1
}

ssh_strict_pattern_matches() {
    local VALUE="$1" PATTERN="$2"
    # shellcheck disable=SC2053  # PATTERN is an intentional glob, not a literal to quote
    [[ "$VALUE" == $PATTERN ]]
}

ssh_strict_access_policy_allows() {
    local DUMP="$1" USERNAME="$2" CLIENT_ADDR=127.0.0.1
    local ALLOW_USERS DENY_USERS ALLOW_GROUPS DENY_GROUPS PATTERN USER_PATTERN HOST_PATTERN
    local GROUP MATCHED=0
    CLIENT_ADDR=$(vps_tools_ssh_client_ip 2>/dev/null || printf '127.0.0.1')
    ALLOW_USERS=$(ssh_config_dump_value "$DUMP" allowusers)
    DENY_USERS=$(ssh_config_dump_value "$DUMP" denyusers)
    ALLOW_GROUPS=$(ssh_config_dump_value "$DUMP" allowgroups)
    DENY_GROUPS=$(ssh_config_dump_value "$DUMP" denygroups)

    while IFS= read -r PATTERN; do
        [ -n "$PATTERN" ] || continue
        if [[ "$PATTERN" == *@* ]]; then
            USER_PATTERN=${PATTERN%%@*}
            HOST_PATTERN=${PATTERN#*@}
            if ssh_strict_pattern_matches "$USERNAME" "$USER_PATTERN"; then
                case "$HOST_PATTERN" in
                    */*) return 1 ;;
                    *) ssh_strict_pattern_matches "$CLIENT_ADDR" "$HOST_PATTERN" && return 1 ;;
                esac
            fi
        else
            ssh_strict_pattern_matches "$USERNAME" "$PATTERN" && return 1
        fi
    done < <(printf '%s\n' "$DENY_USERS" | tr '[:space:]' '\n')
    if [ -n "$ALLOW_USERS" ]; then
        MATCHED=0
        while IFS= read -r PATTERN; do
            [ -n "$PATTERN" ] || continue
            if [[ "$PATTERN" == *@* ]]; then
                USER_PATTERN=${PATTERN%%@*}
                HOST_PATTERN=${PATTERN#*@}
                case "$HOST_PATTERN" in
                    */*) ;;
                    *)
                        ssh_strict_pattern_matches "$USERNAME" "$USER_PATTERN" \
                            && ssh_strict_pattern_matches "$CLIENT_ADDR" "$HOST_PATTERN" \
                            && MATCHED=1
                        ;;
                esac
            else
                ssh_strict_pattern_matches "$USERNAME" "$PATTERN" && MATCHED=1
            fi
        done < <(printf '%s\n' "$ALLOW_USERS" | tr '[:space:]' '\n')
        [ "$MATCHED" -eq 1 ] || return 1
    fi

    if [ -n "$DENY_GROUPS" ] || [ -n "$ALLOW_GROUPS" ]; then
        command -v id >/dev/null 2>&1 || return 1
        MATCHED=0
        while IFS= read -r GROUP; do
            [ -n "$GROUP" ] || continue
            while IFS= read -r PATTERN; do
                [ -n "$PATTERN" ] || continue
                ssh_strict_pattern_matches "$GROUP" "$PATTERN" && return 1
            done < <(printf '%s\n' "$DENY_GROUPS" | tr '[:space:]' '\n')
            while IFS= read -r PATTERN; do
                [ -n "$PATTERN" ] || continue
                ssh_strict_pattern_matches "$GROUP" "$PATTERN" && MATCHED=1
            done < <(printf '%s\n' "$ALLOW_GROUPS" | tr '[:space:]' '\n')
        done < <(id -Gn "$USERNAME" 2>/dev/null | tr '[:space:]' '\n')
        [ -z "$ALLOW_GROUPS" ] || [ "$MATCHED" -eq 1 ] || return 1
    fi
    return 0
}

ssh_strict_find_candidates() {
    local CONFIG_FILE="$1" USERNAME ACCOUNT_UID ACCOUNT_GID HOME_DIR LOGIN_SHELL
    local DUMP KEY_PATHS TEMPLATE KEY_FILE
    while IFS=: read -r USERNAME _ ACCOUNT_UID ACCOUNT_GID _ HOME_DIR LOGIN_SHELL; do
        [ "$USERNAME" != root ] || continue
        ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || continue
        ssh_user_can_admin "$USERNAME" || continue
        DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || continue
        ssh_strict_effective_policy_ok "$DUMP" || continue
        ssh_strict_access_policy_allows "$DUMP" "$USERNAME" || continue
        KEY_PATHS=$(ssh_config_dump_value "$DUMP" authorizedkeysfile)
        [ -n "$KEY_PATHS" ] || continue
        while IFS= read -r TEMPLATE; do
            [ -n "$TEMPLATE" ] || continue
            KEY_FILE=$(ssh_expand_authorized_keys_path \
                "$TEMPLATE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR") || continue
            ssh_strict_key_path_secure \
                "$KEY_FILE" "$ACCOUNT_UID" "$USERNAME" "$ACCOUNT_GID" "$HOME_DIR" \
                || continue
            ssh_strict_key_file_has_unrestricted_key \
                "$KEY_FILE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$HOME_DIR" \
                || continue
            printf '%s|%s\n' "$USERNAME" "$KEY_FILE"
            break
        done < <(printf '%s\n' "$KEY_PATHS" | tr '[:space:]' '\n')
    done < <(ssh_account_records)
}

ssh_strict_candidate_valid() {
    local CONFIG_FILE="$1" ROOT_DUMP
    sshd -t -f "$CONFIG_FILE" 2>/dev/null || return 1
    ROOT_DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" root) || return 1
    ssh_strict_effective_policy_ok "$ROOT_DUMP"
}

ssh_strict_confirm_new_session() {
    local EXPECTED_USER="$1" CONFIRMED_USER
    safety_mark_applied || {
        error "无法记录严格模式提交状态；保留自动回滚且不允许确认"
        return 1
    }
    echo ""
    warn "root 的新 SSH 登录已禁止，请保持当前窗口不要断开。"
    info "请立即新开终端，强制使用密钥登录："
    echo -e "  ${BOLD}ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no ${EXPECTED_USER}@服务器IP${NC}"
    echo -e "  登录后执行 ${BOLD}whoami${NC}，必须显示 ${BOLD}${EXPECTED_USER}${NC}。"
    read -rp "  确认新会话成功后，输入用户名 ${EXPECTED_USER} 取消自动回滚: " CONFIRMED_USER
    if [ "$CONFIRMED_USER" = "$EXPECTED_USER" ]; then
        ssh_cancel_live_safety_timer_checked || return 1
        audit_action "确认严格模式非 root 密钥登录用户 $EXPECTED_USER" SUCCESS
        info "验证确认完成，已取消自动回滚"
    else
        warn "未完成确认，180 秒自动回滚仍在计时；请勿关闭当前连接。"
    fi
}

ssh_shadow_record() {
    local USERNAME="$1" SHADOW_FILE="${SSH_SHADOW_FILE:-/etc/shadow}"
    if [ -n "${SSH_SHADOW_FILE:-}" ]; then
        awk -F: -v username="$USERNAME" '$1 == username {print; exit}' \
            "$SHADOW_FILE" 2>/dev/null || true
    elif command -v getent >/dev/null 2>&1; then
        getent shadow "$USERNAME" 2>/dev/null \
            | awk -F: -v username="$USERNAME" '$1 == username {print; exit}' || true
    elif [ -r "$SHADOW_FILE" ]; then
        awk -F: -v username="$USERNAME" '$1 == username {print; exit}' \
            "$SHADOW_FILE" 2>/dev/null || true
    fi
    return 0
}

ssh_account_not_expired() {
    local USERNAME="$1" SHADOW_RECORD EXPIRE_DAY NOW_DAY
    SHADOW_RECORD=$(ssh_shadow_record "$USERNAME")
    [ -n "$SHADOW_RECORD" ] || return 0
    IFS=: read -r _ _ _ _ _ _ _ EXPIRE_DAY _ <<< "$SHADOW_RECORD"
    case "$EXPIRE_DAY" in ""|*[!0-9]*) return 0 ;; esac
    [ "$EXPIRE_DAY" -gt 0 ] || return 0
    NOW_DAY=$(( $(date +%s) / 86400 ))
    [ "$NOW_DAY" -lt "$EXPIRE_DAY" ]
}

ssh_password_state() {
    local USERNAME="$1" SHADOW_RECORD PASSWORD_HASH
    SHADOW_RECORD=$(ssh_shadow_record "$USERNAME")
    [ -n "$SHADOW_RECORD" ] || { printf 'unknown\n'; return; }
    IFS=: read -r _ PASSWORD_HASH _ <<< "$SHADOW_RECORD"
    case "$PASSWORD_HASH" in
        "") printf 'empty\n' ;;
        '!'*|'*'*) printf 'locked\n' ;;
        *) printf 'set\n' ;;
    esac
}

ssh_user_has_unrestricted_key() {
    local CONFIG_FILE="$1" USERNAME="$2" ACCOUNT_UID="$3" HOME_DIR="$4"
    local DUMP KEY_PATHS TEMPLATE KEY_FILE RECORD ACCOUNT_GID
    RECORD=$(ssh_account_record "$USERNAME")
    IFS=: read -r _ _ _ ACCOUNT_GID _ _ _ <<< "$RECORD"
    [[ "$ACCOUNT_GID" =~ ^[0-9]+$ ]] || return 1
    DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || return 1
    [ "$(ssh_config_dump_value "$DUMP" pubkeyauthentication)" = yes ] || return 1
    KEY_PATHS=$(ssh_config_dump_value "$DUMP" authorizedkeysfile)
    [ -n "$KEY_PATHS" ] || return 1
    while IFS= read -r TEMPLATE; do
        [ -n "$TEMPLATE" ] || continue
        KEY_FILE=$(ssh_expand_authorized_keys_path \
            "$TEMPLATE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR") || continue
        ssh_strict_key_path_secure \
            "$KEY_FILE" "$ACCOUNT_UID" "$USERNAME" "$ACCOUNT_GID" "$HOME_DIR" \
            || continue
        ssh_strict_key_file_has_unrestricted_key \
            "$KEY_FILE" "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$HOME_DIR" \
            && return 0
    done < <(printf '%s\n' "$KEY_PATHS" | tr '[:space:]' '\n')
    return 1
}

ssh_authentication_route() {
    local DUMP="$1" HAS_KEY="$2" HAS_PASSWORD="$3"
    local METHODS ALTERNATIVE FACTOR ROUTE SEEN_KEY
    local PUBKEY_AUTH PASSWORD_AUTH KBD_AUTH EMPTY_PASSWORDS USE_PAM
    METHODS=$(ssh_config_dump_value "$DUMP" authenticationmethods)
    PUBKEY_AUTH=$(ssh_config_dump_value "$DUMP" pubkeyauthentication)
    PASSWORD_AUTH=$(ssh_config_dump_value "$DUMP" passwordauthentication)
    KBD_AUTH=$(ssh_config_dump_value "$DUMP" kbdinteractiveauthentication)
    EMPTY_PASSWORDS=$(ssh_config_dump_value "$DUMP" permitemptypasswords)
    USE_PAM=$(ssh_config_dump_value "$DUMP" usepam)
    if [ "$HAS_PASSWORD" = empty ]; then
        # shellcheck disable=SC2209  # "set"/"locked" are literal state values, not the `set` builtin
        if [ "$EMPTY_PASSWORDS" = yes ]; then HAS_PASSWORD=set; else HAS_PASSWORD=locked; fi
    fi

    if [ -z "$METHODS" ] || [ "$METHODS" = any ]; then
        if [ "$PUBKEY_AUTH" = yes ] && [ "$HAS_KEY" = yes ]; then
            printf '密钥\n'
            return 0
        fi
        if [ "$PASSWORD_AUTH" = yes ] && [ "$HAS_PASSWORD" = set ]; then
            printf '密码\n'
            return 0
        fi
        if [ "$KBD_AUTH" = yes ] && [ "$USE_PAM" = yes ] && [ "$HAS_PASSWORD" = set ]; then
            printf '键盘交互\n'
            return 0
        fi
        return 1
    fi

    while IFS= read -r ALTERNATIVE; do
        [ -n "$ALTERNATIVE" ] || continue
        ROUTE="" SEEN_KEY=0
        while IFS= read -r FACTOR; do
            FACTOR=${FACTOR%%:*}
            case "$FACTOR" in
                publickey)
                    [ "$PUBKEY_AUTH" = yes ] && [ "$HAS_KEY" = yes ] && [ "$SEEN_KEY" -eq 0 ] \
                        || { ROUTE=""; break; }
                    SEEN_KEY=1
                    ROUTE="${ROUTE}${ROUTE:+ + }密钥"
                    ;;
                password)
                    [ "$PASSWORD_AUTH" = yes ] && [ "$HAS_PASSWORD" = set ] \
                        || { ROUTE=""; break; }
                    ROUTE="${ROUTE}${ROUTE:+ + }密码"
                    ;;
                keyboard-interactive)
                    [ "$KBD_AUTH" = yes ] && [ "$USE_PAM" = yes ] && [ "$HAS_PASSWORD" = set ] \
                        || { ROUTE=""; break; }
                    ROUTE="${ROUTE}${ROUTE:+ + }键盘交互"
                    ;;
                *) ROUTE=""; break ;;
            esac
        done < <(printf '%s\n' "$ALTERNATIVE" | tr ',' '\n')
        if [ -n "$ROUTE" ]; then
            printf '%s\n' "$ROUTE"
            return 0
        fi
    done < <(printf '%s\n' "$METHODS" | tr '[:space:]' '\n')
    return 1
}

ssh_login_route_for_user() {
    local CONFIG_FILE="$1" USERNAME="$2" RECORD ACCOUNT_UID HOME_DIR LOGIN_SHELL
    local DUMP ROOT_POLICY HAS_KEY=no PASSWORD_STATE ROUTE
    RECORD=$(ssh_account_record "$USERNAME")
    [ -n "$RECORD" ] || return 1
    IFS=: read -r _ _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || return 1
    ssh_account_not_expired "$USERNAME" || return 1
    DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || return 1
    ssh_strict_access_policy_allows "$DUMP" "$USERNAME" || return 1
    if [ "$USERNAME" = root ]; then
        ROOT_POLICY=$(ssh_config_dump_value "$DUMP" permitrootlogin)
        case "$ROOT_POLICY" in
            no|forced-commands-only) return 1 ;;
        esac
    else
        ROOT_POLICY=yes
    fi

    ssh_user_has_unrestricted_key "$CONFIG_FILE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" \
        && HAS_KEY=yes
    PASSWORD_STATE=$(ssh_password_state "$USERNAME")
    case "$ROOT_POLICY" in
        prohibit-password|without-password) PASSWORD_STATE=locked ;;
    esac
    ROUTE=$(ssh_authentication_route "$DUMP" "$HAS_KEY" "$PASSWORD_STATE") || return 1
    printf '%s\n' "$ROUTE"
}

ssh_admin_capability_probe_worker() {
    local ELEVATOR="$1" ID_BIN="$2" RESULT
    case "${ELEVATOR##*/}" in
        sudo)
            RESULT=$("$ELEVATOR" -n -u root -- "$ID_BIN" -u 2>/dev/null) || return 1
            ;;
        doas)
            RESULT=$("$ELEVATOR" -n -u root "$ID_BIN" -u 2>/dev/null) || return 1
            ;;
        *)
            return 1
            ;;
    esac
    [ "$RESULT" = 0 ]
}

ssh_user_has_root_capability() {
    local USERNAME="$1" ELEVATOR_NAME="$2"
    local RECORD ACCOUNT_UID ACCOUNT_GID HOME_DIR LOGIN_SHELL ELEVATOR ID_BIN WORKER_SCRIPT
    ELEVATOR=$(command -v "$ELEVATOR_NAME" 2>/dev/null) || return 1
    ID_BIN=$(command -v id 2>/dev/null) || return 1
    RECORD=$(ssh_account_record "$USERNAME") || return 1
    IFS=: read -r _ _ ACCOUNT_UID ACCOUNT_GID _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || return 1
    WORKER_SCRIPT="$(declare -f ssh_admin_capability_probe_worker)
ssh_admin_capability_probe_worker \"\$@\""
    ssh_run_as_target "$USERNAME" "$ACCOUNT_UID" "$ACCOUNT_GID" "$WORKER_SCRIPT" \
        "$ELEVATOR" "$ID_BIN"
}

ssh_user_has_full_sudo_access() {
    ssh_user_has_root_capability "$1" sudo
}

ssh_user_can_admin() {
    local USERNAME="$1"
    [ "$USERNAME" = root ] && return 0
    ssh_user_has_full_sudo_access "$USERNAME" \
        || ssh_user_has_root_capability "$USERNAME" doas
}

ssh_login_candidates() {
    local CONFIG_FILE="$1" USERNAME ACCOUNT_UID HOME_DIR LOGIN_SHELL ROUTE ADMIN=no
    while IFS=: read -r USERNAME _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL; do
        ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || continue
        ROUTE=$(ssh_login_route_for_user "$CONFIG_FILE" "$USERNAME") || continue
        ADMIN=no
        ssh_user_can_admin "$USERNAME" && ADMIN=yes
        printf '%s|%s|%s\n' "$USERNAME" "$ROUTE" "$ADMIN"
    done < <(ssh_account_records)
}

ssh_login_candidates_have_admin() {
    local CANDIDATES="$1"
    printf '%s\n' "$CANDIDATES" \
        | awk -F'|' '$3 == "yes" {found=1} END {exit !found}'
}

ssh_collect_managed_deny_users() {
    local CONFIG_FILE="$1"
    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
        $0 == begin {in_block=1; next}
        $0 == end {in_block=0; next}
        in_block {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            count=split(line, fields, /[[:space:]]+/)
            if (tolower(fields[1]) != "denyusers") next
            for (i=2; i<=count; i++) {
                if (substr(fields[i], 1, 1) == "#") break
                if (fields[i] != "" && !seen[fields[i]]++) {
                    values=values (values == "" ? "" : " ") fields[i]
                }
            }
        }
        END {print values}
    ' "$CONFIG_FILE"
}

ssh_user_explicitly_denied() {
    local DUMP="$1" USERNAME="$2" CLIENT_ADDR=127.0.0.1
    local PATTERN USER_PATTERN HOST_PATTERN
    CLIENT_ADDR=$(vps_tools_ssh_client_ip 2>/dev/null || printf '127.0.0.1')
    while IFS= read -r PATTERN; do
        [ -n "$PATTERN" ] || continue
        if [[ "$PATTERN" == *@* ]]; then
            USER_PATTERN=${PATTERN%%@*}
            HOST_PATTERN=${PATTERN#*@}
            if ssh_strict_pattern_matches "$USERNAME" "$USER_PATTERN"; then
                case "$HOST_PATTERN" in
                    */*) continue ;;
                    *) ssh_strict_pattern_matches "$CLIENT_ADDR" "$HOST_PATTERN" && return 0 ;;
                esac
            fi
        else
            ssh_strict_pattern_matches "$USERNAME" "$PATTERN" && return 0
        fi
    done < <(ssh_config_dump_value "$DUMP" denyusers | tr '[:space:]' '\n')
    return 1
}

ssh_current_login_user() {
    local CURRENT_USER=""
    for CURRENT_USER in "${SUDO_USER:-}" "${DOAS_USER:-}"; do
        [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != root ] && {
            printf '%s\n' "$CURRENT_USER"
            return
        }
    done
    if [ -n "${SSH_TTY:-}" ] && command -v who >/dev/null 2>&1; then
        CURRENT_USER=$(who 2>/dev/null \
            | awk -v tty="${SSH_TTY#/dev/}" '$2 == tty {print $1; exit}')
    fi
    [ -n "$CURRENT_USER" ] || CURRENT_USER=$(id -un 2>/dev/null || printf 'root')
    printf '%s\n' "$CURRENT_USER"
}

ssh_revoke_confirm_new_session() {
    local EXPECTED_USER="$1" ROUTE="$2" CONFIRMED_USER
    safety_mark_applied || {
        error "无法记录撤权后的提交状态；保留自动回滚且不允许确认"
        return 1
    }
    echo ""
    warn "请保持当前窗口，并用新终端验证剩余登录入口。"
    echo -e "  验证用户：${BOLD}${EXPECTED_USER}${NC}  预计方式：${BOLD}${ROUTE}${NC}"
    read -rp "  新会话成功后，输入用户名 ${EXPECTED_USER} 取消自动回滚: " CONFIRMED_USER
    if [ "$CONFIRMED_USER" = "$EXPECTED_USER" ]; then
        ssh_cancel_live_safety_timer_checked || return 1
        audit_action "确认撤销登录权限后的备用用户 $EXPECTED_USER" SUCCESS
        info "验证确认完成，已取消自动回滚"
    else
        warn "未完成确认，180 秒自动回滚仍在计时；请勿关闭当前连接。"
    fi
}

revoke_user_ssh_login() {
    print_header "撤销指定用户 SSH 登录权限"

    local USERNAME RECORD ACCOUNT_UID HOME_DIR LOGIN_SHELL CURRENT_USER
    local DENY_USERS CANDIDATE TARGET_DUMP REMAINING VERIFY_USER VERIFY_LINE
    local VERIFY_ROUTE VERIFY_ADMIN HAS_ADMIN=no CONFIRM_NAME LIST_USER LIST_ROUTE LIST_ADMIN
    local APPLY_STATUS
    printf "  %-18s %-8s %-24s %s\n" "用户名" "UID" "主目录" "Shell"
    menu_div
    while IFS=: read -r USERNAME _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL; do
        ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || continue
        printf "  %-18s %-8s %-24s %s\n" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL"
    done < <(ssh_account_records)
    menu_div
    echo ""

    read -rp "  输入要撤销 SSH 登录权限的用户名（直接回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消，配置未修改"; return; }
    RECORD=$(ssh_account_record "$USERNAME")
    [ -n "$RECORD" ] || { error "用户 $USERNAME 不存在"; return 1; }
    IFS=: read -r _ _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || {
        error "拒绝操作系统服务账号或不可登录账号：$USERNAME"
        return 1
    }

    DENY_USERS=$(ssh_collect_managed_deny_users "$SSHD_CONFIG") || {
        error "无法读取脚本维护的 DenyUsers 历史列表"
        return 1
    }
    if [[ " $DENY_USERS " == *" $USERNAME "* ]]; then
        warn "用户 $USERNAME 已在脚本维护的全局 DenyUsers 列表中，无需重复设置"
        return 0
    fi
    DENY_USERS="${DENY_USERS}${DENY_USERS:+ }$USERNAME"
    ssh_prepare_config_candidate CANDIDATE || return 1
    if ! ssh_candidate_set_options "$CANDIDATE" "DenyUsers" "$DENY_USERS"; then
        rm -f -- "$CANDIDATE"
        return 1
    fi
    if ! sshd -t -f "$CANDIDATE" 2>/dev/null; then
        rm -f "$CANDIDATE"
        error "候选 SSH 配置语法校验失败，未作任何修改"
        return 1
    fi
    TARGET_DUMP=$(ssh_effective_config_dump "$CANDIDATE" "$USERNAME") || {
        rm -f "$CANDIDATE"
        error "无法验证撤权后的用户配置"
        return 1
    }
    if ! ssh_user_explicitly_denied "$TARGET_DUMP" "$USERNAME"; then
        rm -f "$CANDIDATE"
        error "候选配置未能确认禁止 $USERNAME 登录，已拒绝应用"
        return 1
    fi

    REMAINING=$(ssh_login_candidates "$CANDIDATE")
    if [ -z "$REMAINING" ]; then
        rm -f "$CANDIDATE"
        error "撤权后没有任何其他账号可确认登录，禁止执行以避免锁死"
        return 1
    fi
    ssh_login_candidates_have_admin "$REMAINING" && HAS_ADMIN=yes
    if [ "$HAS_ADMIN" != yes ]; then
        rm -f "$CANDIDATE"
        error "撤权后虽有账号可登录，但没有 root 或具备完整 sudo/doas root 权限的管理入口，禁止执行"
        return 1
    fi

    CURRENT_USER=$(ssh_current_login_user)
    echo -e "  ${BOLD}撤权后可用的备用登录入口：${NC}"
    while IFS='|' read -r LIST_USER LIST_ROUTE LIST_ADMIN; do
        if [ "$LIST_ADMIN" = yes ]; then LIST_ADMIN="可管理"; else LIST_ADMIN="普通用户"; fi
        echo -e "  ${GREEN}•${NC} ${BOLD}${LIST_USER}${NC}  ${LIST_ROUTE}  ${DIM}${LIST_ADMIN}${NC}"
    done <<< "$REMAINING"
    [ "$USERNAME" != "$CURRENT_USER" ] \
        || warn "目标是当前登录/提权用户；现有会话不会立刻断开，但退出后将无法重新登录。"
    echo ""
    read -rp "  选择一个将在新终端验证的备用用户名（直接回车取消）: " VERIFY_USER
    [ -n "$VERIFY_USER" ] || {
        rm -f "$CANDIDATE"
        warn "已取消，配置未修改"
        return
    }
    VERIFY_LINE=$(printf '%s\n' "$REMAINING" \
        | awk -F'|' -v username="$VERIFY_USER" \
            '$1 == username && $3 == "yes" {print; exit}')
    if [ -z "$VERIFY_LINE" ]; then
        rm -f "$CANDIDATE"
        error "用户 $VERIFY_USER 不是撤权后可登录且可取得完整 root 权限的管理员"
        return 1
    fi
    IFS='|' read -r _ VERIFY_ROUTE VERIFY_ADMIN <<< "$VERIFY_LINE"
    [ "$VERIFY_ADMIN" = yes ] || {
        rm -f -- "$CANDIDATE"
        error "验证用户必须具备完整 root 管理能力"
        return 1
    }

    read -rp "  输入目标用户名 $USERNAME 确认撤销（其他输入取消）: " CONFIRM_NAME
    if [ "$CONFIRM_NAME" != "$USERNAME" ]; then
        rm -f "$CANDIDATE"
        warn "用户名不匹配，已取消撤销"
        return
    fi
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "撤销用户 $USERNAME 的 SSH 登录权限"; then
        rm -f "$CANDIDATE"
        warn "已取消，配置未修改"
        return
    fi
    if ! backup_config; then
        rm -f -- "$CANDIDATE"
        return 1
    fi
    safety_arm ssh_revoke_login || { rm -f "$CANDIDATE"; return 1; }
    if ssh_install_candidate_config "$CANDIDATE"; then
        :
    else
        rm -f -- "$CANDIDATE"
        ssh_restore_and_cancel_safety || true
        error "无法写入 SSH 配置，撤权未应用"
        return 1
    fi
    rm -f -- "$CANDIDATE"
    if apply_and_restart; then
        info "用户 $USERNAME 的新 SSH 登录已禁止 ✓"
        audit_action "撤销用户 $USERNAME 的 SSH 登录权限" SUCCESS
        ssh_revoke_confirm_new_session "$VERIFY_USER" "$VERIFY_ROUTE"
    else
        APPLY_STATUS=$?
        ssh_handle_apply_failure "$APPLY_STATUS"
    fi
}

ssh_apply_login_mode_change() {
    local DIFF_TITLE="$1" SUCCESS_TEXT="$2" AUDIT_TEXT="$3"
    local CANDIDATE APPLY_STATUS
    shift 3

    ssh_prepare_config_candidate CANDIDATE || return 1
    if ! ssh_candidate_set_options "$CANDIDATE" "$@"; then
        rm -f -- "$CANDIDATE"
        return 1
    fi
    if ! sshd -t -f "$CANDIDATE" 2>/dev/null; then
        rm -f -- "$CANDIDATE"
        error "SSH 候选配置语法校验失败，未作任何修改"
        return 1
    fi
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "$DIFF_TITLE"; then
        rm -f -- "$CANDIDATE"
        warn "已取消，配置未修改"
        return 0
    fi
    if ! backup_config; then
        rm -f -- "$CANDIDATE"
        return 1
    fi
    safety_arm ssh_login || { rm -f -- "$CANDIDATE"; return 1; }
    if ! ssh_install_candidate_config "$CANDIDATE"; then
        rm -f -- "$CANDIDATE"
        ssh_restore_and_cancel_safety || true
        error "无法写入 SSH 配置，登录方式未切换"
        return 1
    fi
    rm -f -- "$CANDIDATE"
    if apply_and_restart; then
        info "$SUCCESS_TEXT"
        audit_action "$AUDIT_TEXT" SUCCESS
        ssh_safety_confirm_checked
    else
        APPLY_STATUS=$?
        ssh_handle_apply_failure "$APPLY_STATUS"
    fi
}

set_login_mode() {
    print_header "登录方式设置"

    local CURRENT_PWD CURRENT_PUBKEY CURRENT_ROOT
    CURRENT_PWD=$(get_config "PasswordAuthentication")
    CURRENT_PUBKEY=$(get_config "PubkeyAuthentication")
    CURRENT_ROOT=$(get_config "PermitRootLogin")

    echo -e "  ${DIM}当前配置：${NC}"
    echo -e "  PasswordAuthentication : ${BOLD}${CURRENT_PWD:-未设置}${NC}"
    echo -e "  PubkeyAuthentication   : ${BOLD}${CURRENT_PUBKEY:-未设置}${NC}"
    echo -e "  PermitRootLogin        : ${BOLD}${CURRENT_ROOT:-未设置}${NC}"
    echo ""
    menu_div
    menu_item "1" "仅密钥登录  ${DIM}推荐${NC}"
    menu_item "2" "密码 + 密钥登录"
    menu_item "3" "仅密码登录  ${RED}不推荐${NC}" "$YELLOW"
    menu_item "4" "严格模式（禁用 root 登录，仅非 root 密钥）" "$CYAN"
    menu_item "0" "返回上级" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择登录方式 [0-4]: ')" MODE
    echo ""

    case "$MODE" in
        1)
            local KEYCOUNT
            KEYCOUNT=$(ssh_key_count)
            if [ "$KEYCOUNT" -eq 0 ]; then
                warn "当前没有公钥！启用仅密钥登录后将无法通过密码登录！"
                read -rp "  仍要继续？(Y/n，默认Y): " FORCE
                [ -z "${FORCE}" ] && FORCE="y"
    if ! echo "${FORCE}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            fi
            ssh_apply_login_mode_change \
                "SSH 仅密钥登录" "已切换：仅密钥登录 ✓" "SSH切换为仅密钥登录" \
                "PasswordAuthentication" "no" \
                "PubkeyAuthentication" "yes" \
                "PermitRootLogin" "prohibit-password"
            ;;
        2)
            ssh_apply_login_mode_change \
                "SSH 密码和密钥登录" "已切换：密码 + 密钥均可登录 ✓" \
                "SSH启用密码和密钥登录" \
                "PasswordAuthentication" "yes" \
                "PubkeyAuthentication" "yes" \
                "PermitRootLogin" "yes"
            ;;
        3)
            warn "仅密码登录安全性较低，建议配合强密码使用！"
            read -rp "  确认切换？(Y/n，默认Y): " CONFIRM
            [ -z "${CONFIRM}" ] && CONFIRM="y"
            if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            ssh_apply_login_mode_change \
                "SSH 仅密码登录" "已切换：仅密码登录 ✓" "SSH切换为仅密码登录" \
                "PasswordAuthentication" "yes" \
                "PubkeyAuthentication" "no" \
                "PermitRootLogin" "yes"
            ;;
        4)
            local STRICT_CANDIDATE STRICT_CANDIDATES STRICT_USER STRICT_LINE STRICT_KEY_FILE
            local STRICT_APPLY_STATUS
            ssh_prepare_config_candidate STRICT_CANDIDATE || return 1
            if ! ssh_candidate_set_options "$STRICT_CANDIDATE" \
                "PasswordAuthentication" "no" \
                "PubkeyAuthentication" "yes" \
                "AuthenticationMethods" "publickey" \
                "PermitRootLogin" "no" \
                "KbdInteractiveAuthentication" "no" \
                "MaxAuthTries" "3" \
                "ClientAliveInterval" "300" \
                "ClientAliveCountMax" "2" \
                "X11Forwarding" "no"; then
                rm -f -- "$STRICT_CANDIDATE"
                return 1
            fi

            if ! ssh_strict_candidate_valid "$STRICT_CANDIDATE"; then
                rm -f "$STRICT_CANDIDATE"
                error "严格模式候选配置未通过 sshd 语法或有效配置校验，未作任何修改"
                return 1
            fi
            STRICT_CANDIDATES=$(ssh_strict_find_candidates "$STRICT_CANDIDATE")
            if [ -z "$STRICT_CANDIDATES" ]; then
                rm -f "$STRICT_CANDIDATE"
                error "未找到可确认安全登录的非 root 密钥账号，禁止开启严格模式"
                warn "账号必须可交互登录、拥有完整 sudo/doas root 权限、未被 Allow/Deny 规则阻止，并有格式及权限安全的无前置选项公钥"
                info "请先为管理员用户添加公钥，并实际测试该用户的密钥登录"
                return 1
            fi

            echo -e "  ${BOLD}检测到以下非 root 密钥登录候选：${NC}"
            printf '%s\n' "$STRICT_CANDIDATES" | while IFS='|' read -r STRICT_USER STRICT_KEY_FILE; do
                echo -e "  ${GREEN}•${NC} ${BOLD}${STRICT_USER}${NC}  ${DIM}${STRICT_KEY_FILE}${NC}"
            done
            echo ""
            read -rp "  输入将用于防锁死验证的非 root 用户名（直接回车取消）: " STRICT_USER
            [ -n "$STRICT_USER" ] || {
                rm -f "$STRICT_CANDIDATE"
                warn "已取消，配置未修改"
                return
            }
            STRICT_LINE=$(printf '%s\n' "$STRICT_CANDIDATES" \
                | awk -F'|' -v username="$STRICT_USER" '$1 == username {print; exit}')
            if [ -z "$STRICT_LINE" ]; then
                rm -f "$STRICT_CANDIDATE"
                error "用户 $STRICT_USER 不在已验证的候选列表中，禁止开启严格模式"
                return 1
            fi
            STRICT_KEY_FILE=${STRICT_LINE#*|}

            if ! confirm_file_diff "$SSHD_CONFIG" "$STRICT_CANDIDATE" "SSH 严格模式"; then
                rm -f "$STRICT_CANDIDATE"
                warn "已取消，配置未修改"
                return
            fi
            if ! backup_config; then
                rm -f -- "$STRICT_CANDIDATE"
                return 1
            fi
            safety_arm ssh_strict_login || { rm -f "$STRICT_CANDIDATE"; return 1; }
            if ! ssh_install_candidate_config "$STRICT_CANDIDATE"; then
                rm -f -- "$STRICT_CANDIDATE"
                ssh_restore_and_cancel_safety || true
                error "无法写入 SSH 配置，已取消严格模式"
                return 1
            fi
            rm -f -- "$STRICT_CANDIDATE"
            if apply_and_restart; then
                info "严格模式已临时应用：root 登录已禁用，仅允许非 root 密钥认证 ✓"
                info "验证账号：$STRICT_USER  公钥文件：$STRICT_KEY_FILE"
                audit_action "SSH启用严格模式，验证用户 $STRICT_USER" SUCCESS
                ssh_strict_confirm_new_session "$STRICT_USER"
            else
                STRICT_APPLY_STATUS=$?
                ssh_handle_apply_failure "$STRICT_APPLY_STATUS"
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) return ;;
    esac
}

ssh_candidate_has_unique_port() {
    local CONFIG_FILE="$1" EXPECTED_PORT="$2" DUMP PORTS UNIQUE_PORTS COUNT
    SSH_CANDIDATE_PORTS=""
    DUMP=$(LC_ALL=C sshd -T -f "$CONFIG_FILE" 2>/dev/null) || return 1
    PORTS=$(printf '%s\n' "$DUMP" | awk '
        tolower($1) == "port" && $2 ~ /^[0-9]+$/ {
            print $2
            next
        }
        tolower($1) == "listenaddress" {
            endpoint=$2
            if (endpoint ~ /^\[[^]]+\]:[0-9]+$/) {
                sub(/^.*\]:/, "", endpoint)
                print endpoint
            } else if (endpoint ~ /:[0-9]+$/) {
                sub(/^.*:/, "", endpoint)
                print endpoint
            }
        }
    ') || return 1
    [ -n "$PORTS" ] || return 1
    UNIQUE_PORTS=$(printf '%s\n' "$PORTS" | sort -nu) || return 1
    COUNT=$(printf '%s\n' "$UNIQUE_PORTS" | awk 'NF {count++} END {print count+0}')
    SSH_CANDIDATE_PORTS=$(printf '%s\n' "$UNIQUE_PORTS" | paste -sd, -)
    [ "$COUNT" -eq 1 ] && [ "$UNIQUE_PORTS" = "$EXPECTED_PORT" ]
}

# 备份当前 ssh.socket 端口覆盖文件（若不存在则记录为"不存在"，
# 以便 ssh_socket_override_restore 精确恢复到变更前状态而不是留下残留文件）
ssh_socket_override_backup() {
    LAST_SOCKET_OVERRIDE_BACKUP=""
    LAST_SOCKET_OVERRIDE_EXISTED=no
    [ -f "$SSHD_SOCKET_OVERRIDE_FILE" ] && [ ! -L "$SSHD_SOCKET_OVERRIDE_FILE" ] || return 0
    LAST_SOCKET_OVERRIDE_BACKUP=$(mktemp "${SSHD_SOCKET_OVERRIDE_FILE}.bak.XXXXXX") || return 1
    if ! cp -a -- "$SSHD_SOCKET_OVERRIDE_FILE" "$LAST_SOCKET_OVERRIDE_BACKUP"; then
        rm -f -- "$LAST_SOCKET_OVERRIDE_BACKUP"
        LAST_SOCKET_OVERRIDE_BACKUP=""
        return 1
    fi
    LAST_SOCKET_OVERRIDE_EXISTED=yes
}

ssh_socket_override_restore() {
    if [ "${LAST_SOCKET_OVERRIDE_EXISTED:-no}" = yes ]; then
        [ -n "${LAST_SOCKET_OVERRIDE_BACKUP:-}" ] && [ -f "$LAST_SOCKET_OVERRIDE_BACKUP" ] \
            || return 1
        mv -f -- "$LAST_SOCKET_OVERRIDE_BACKUP" "$SSHD_SOCKET_OVERRIDE_FILE" 2>/dev/null \
            || return 1
    else
        rm -f -- "$SSHD_SOCKET_OVERRIDE_FILE" 2>/dev/null || true
    fi
    return 0
}

# 显式覆盖 ssh.socket 的监听端口。经验证：部分 openssh-server 版本会用
# systemd generator 动态把 sshd_config 的 Port 同步进 socket 单元并在合并时
# 优先于本文件生效，但两者写入的是同一个端口号，结果始终一致；
# 没有该 generator（或未被采用）的系统则完全依赖本文件生效。
ssh_socket_override_write() {
    local PORT="$1" TMP
    mkdir -p "$SSHD_SOCKET_OVERRIDE_DIR" 2>/dev/null || return 1
    chmod 755 "$SSHD_SOCKET_OVERRIDE_DIR" 2>/dev/null || true
    TMP=$(mktemp "${SSHD_SOCKET_OVERRIDE_FILE}.XXXXXX") || return 1
    if ! {
        printf '[Socket]\n'
        printf 'ListenStream=\n'
        printf 'ListenStream=0.0.0.0:%s\n' "$PORT"
        printf 'ListenStream=[::]:%s\n' "$PORT"
    } > "$TMP"; then
        rm -f -- "$TMP"
        return 1
    fi
    chmod 644 "$TMP" 2>/dev/null || true
    mv -f -- "$TMP" "$SSHD_SOCKET_OVERRIDE_FILE"
}

change_port() {
    print_header "修改 SSH 端口"

    local CURRENT_PORT INPUT_PORT CANDIDATE OLD_PORT APPLY_STATUS NEW_OK CLOSE_OLD
    local FIREWALL_ROLLBACK_OK=yes
    CURRENT_PORT=$(get_config "Port")
    echo -e "  当前端口：${BOLD}${CURRENT_PORT:-22}${NC}"
    echo ""
    menu_div
    read -rp "  请输入新端口号（直接回车取消）: " INPUT_PORT
    menu_div
    echo ""

    [ -z "$INPUT_PORT" ] && { warn "已取消。"; return; }

    if ! echo "$INPUT_PORT" | grep -qE '^[0-9]+$' \
        || [ "${#INPUT_PORT}" -gt 10 ]; then
        error "无效端口号（请输入 1-65535）。"; return 1
    fi
    INPUT_PORT=$(printf '%s\n' "$INPUT_PORT" | sed 's/^0*//')
    [ -n "$INPUT_PORT" ] || INPUT_PORT=0
    if [ "${#INPUT_PORT}" -gt 5 ] \
        || [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        error "无效端口号（请输入 1-65535）。"; return 1
    fi
    INPUT_PORT=$((10#$INPUT_PORT))

    if [ "$INPUT_PORT" = "${CURRENT_PORT:-22}" ]; then
        warn "端口未变化，无需修改。"; return
    fi

    ssh_prepare_config_candidate CANDIDATE || return 1
    if ! ssh_candidate_set_options "$CANDIDATE" "Port" "$INPUT_PORT"; then
        rm -f -- "$CANDIDATE"
        return 1
    fi
    if ! ssh_candidate_has_unique_port "$CANDIDATE" "$INPUT_PORT"; then
        rm -f -- "$CANDIDATE"
        error "候选配置未能确认仅监听新端口 $INPUT_PORT（检测到：${SSH_CANDIDATE_PORTS:-未知}）"
        warn "请检查 Include 文件中的 Port 指令；为避免旧端口继续监听，本次修改已拒绝应用"
        return 1
    fi

    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 端口 ${CURRENT_PORT:-22} → $INPUT_PORT"; then
        rm -f -- "$CANDIDATE"
        warn "已取消，配置未修改"
        return
    fi
    if ! backup_config; then
        rm -f -- "$CANDIDATE"
        return 1
    fi
    safety_arm ssh_port || { rm -f -- "$CANDIDATE"; return 1; }
    if ! ssh_install_candidate_config "$CANDIDATE"; then
        rm -f -- "$CANDIDATE"
        ssh_restore_and_cancel_safety || true
        error "无法写入 SSH 端口候选配置，修改未应用"
        return 1
    fi
    rm -f -- "$CANDIDATE"

    if ssh_socket_activated && ! ssh_socket_override_write "$INPUT_PORT"; then
        ssh_restore_and_cancel_safety || true
        error "检测到 systemd socket 激活的 sshd，但无法写入 ssh.socket 端口覆盖，修改未应用"
        return 1
    fi

    OLD_PORT="${CURRENT_PORT:-22}"
    # 先放行新端口（旧端口暂不删，避免 restart 失败/连不上时被锁外面）
    if ! firewall_allow_port "$INPUT_PORT"; then
        if [ "${FIREWALL_ALLOW_DIRTY:-no}" = yes ]; then
            restore_ssh_config_backup || true
            warn "防火墙规则未能完整恢复，已保留自动回滚快照；请保持当前连接"
        else
            ssh_restore_and_cancel_safety || true
        fi
        error "新端口防火墙放行失败，SSH 端口切换已中止"
        return 1
    fi

    # 应用并重启（失败会自动回滚到旧配置）
    if apply_and_restart; then
        :
    else
        APPLY_STATUS=$?
        if ! firewall_rollback_allowed_port "$INPUT_PORT"; then
            FIREWALL_ROLLBACK_OK=no
            warn "SSH 应用失败后，本次新增的新端口防火墙规则未能完整回滚"
        fi
        if [ "$FIREWALL_ROLLBACK_OK" = yes ] \
            && [ "${FIREWALL_ALLOW_DIRTY:-no}" = no ]; then
            ssh_handle_apply_failure "$APPLY_STATUS"
        else
            if [ "$APPLY_STATUS" -eq 1 ]; then
                warn "SSH 配置已恢复，但因防火墙回滚不完整，自动回滚快照继续保留"
            else
                error "SSH 与防火墙均未能完整即时恢复，自动回滚仍在计时；请勿关闭当前连接"
            fi
        fi
        error "SSH 端口切换失败；请保持当前连接并确认旧端口 $OLD_PORT"
        return 1
    fi
    if ! f2b_sync_ssh_port "$INPUT_PORT"; then
        warn "SSH 已切换到 $INPUT_PORT，但 Fail2ban 端口同步失败，请进入 Fail2ban 菜单检查"
    fi
    audit_action "SSH端口 ${CURRENT_PORT:-22} 修改为 $INPUT_PORT" SUCCESS
    if ! safety_mark_applied; then
        error "无法记录 SSH 端口切换后的提交状态；保留自动回滚且不允许确认"
        return 1
    fi

    echo ""
    menu_div
    warn "新端口已生效，自动回滚保护仍在。"
    echo ""
    echo -e "  请【保持当前连接不要断开】，新开一个终端测试新端口："
    echo ""
    echo -e "     ${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    echo ""
    echo -e "  ${DIM}注意：如果 VPS 有云厂商安全组，也必须在安全组放行 ${INPUT_PORT}/tcp。${NC}"
    echo ""
    warn "只有确认新端口可登录后，脚本才会取消自动回滚。"
    menu_div
    echo ""
    read -rp "  新端口已测试可登录吗？(y/N，默认N): " NEW_OK
    [ -z "$NEW_OK" ] && NEW_OK="n"
    if ! echo "$NEW_OK" | grep -qiE '^y(es)?$'; then
        warn "未确认新端口可用，自动回滚保护仍在。180 秒内未确认将恢复旧配置。"
        return
    fi

    if ! ssh_candidate_has_unique_port "$SSHD_CONFIG" "$INPUT_PORT"; then
        error "确认时 SSH 已不再仅监听新端口 $INPUT_PORT，拒绝取消回滚和清理旧端口规则"
        return 1
    fi
    if ! ssh_cancel_live_safety_timer_checked; then
        return 1
    fi
    audit_action "确认 SSH 新端口 ${INPUT_PORT} 可登录，取消自动回滚" SUCCESS
    info "已确认新端口可登录，自动回滚已取消。"

    echo ""
    warn "下面只清理旧端口 ${OLD_PORT}/tcp 的防火墙放行规则，不会再修改 SSH 监听端口。"
    read -rp "  现在关闭旧端口防火墙规则 ${OLD_PORT}/tcp？(y/N，默认N): " CLOSE_OLD
    [ -z "$CLOSE_OLD" ] && CLOSE_OLD="n"
    if echo "$CLOSE_OLD" | grep -qiE '^y(es)?$'; then
        if [ "$OLD_PORT" != "$INPUT_PORT" ]; then
            if firewall_remove_port "$OLD_PORT"; then
                if [ "${FIREWALL_REMOVE_CHANGED:-no}" = yes ]; then
                    info "已删除检测到的旧端口本机防火墙放行规则"
                else
                    warn "未发现可删除的旧端口本机防火墙放行规则；未报告为已关闭"
                fi
            else
                warn "旧端口防火墙规则仅完成部分清理，请手动核对 ${OLD_PORT}/tcp"
            fi
        fi
    else
        warn "旧端口 ${OLD_PORT} 保留开放。确认无误后可手动关闭，或重新进入本菜单。"
    fi
}

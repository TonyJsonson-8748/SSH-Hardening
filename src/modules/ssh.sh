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
    local CLIENT_ADDR=127.0.0.1 SERVER_ADDR=127.0.0.1 SERVER_PORT=22
    if [ -n "${SSH_CONNECTION:-}" ]; then
        read -r CLIENT_ADDR _ SERVER_ADDR SERVER_PORT <<< "$SSH_CONNECTION"
    fi
    [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || SERVER_PORT=22
    LC_ALL=C sshd -T -f "$CONFIG_FILE" \
        -C "user=${USERNAME},host=${CLIENT_ADDR},addr=${CLIENT_ADDR},laddr=${SERVER_ADDR},lport=${SERVER_PORT}" \
        2>/dev/null
}

ssh_config_dump_value() {
    local DUMP="$1" KEY="$2"
    printf '%s\n' "$DUMP" | awk -v key="$KEY" '$1 == key {$1=""; sub(/^[[:space:]]+/, ""); print; exit}'
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
    printf '%s %s\n' "$KEY_TYPE" "$KEY_DATA" > "$TMP_KEY"
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
    printf '%s %s\n' "$KEY_TYPE" "$KEY_DATA" > "$TMP_KEY"
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
    while IFS= read -r KEY_FILE; do
        [ -f "$KEY_FILE" ] && [ -r "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] || continue
        LINE_NO=0
        while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
            LINE_NO=$((LINE_NO+1))
            FIELDS=$(ssh_public_key_line_fields "$KEY_LINE") || continue
            IFS=$'\t' read -r KEY_TYPE KEY_DATA COMMENT OPTIONS <<< "$FIELDS"
            FINGERPRINT=$(ssh_public_key_fingerprint "$KEY_TYPE" "$KEY_DATA")
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$KEY_FILE" "$LINE_NO" "$KEY_TYPE" "$KEY_DATA" \
                "$FINGERPRINT" "$COMMENT" "$OPTIONS"
        done < "$KEY_FILE"
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
    RESTORE_TMP=$(mktemp "${KEY_FILE}.vps-tools-restore.XXXXXX") || return 1
    if cp -p -- "$BACKUP" "$RESTORE_TMP" \
        && mv -f -- "$RESTORE_TMP" "$KEY_FILE"; then
        return 0
    fi
    rm -f "$RESTORE_TMP"
    return 1
}

ssh_key_delete_safety_arm() {
    local KEY_FILE="$1" BACKUP="$2" USERNAME="$3"
    local STATE_FILE="${SAFETY_STATE_FILE:-${VPS_DATA_DIR}/rollback.active}" SCRIPT SOURCE_IP=local
    [ -z "${SSH_CONNECTION:-}" ] || SOURCE_IP=${SSH_CONNECTION%% *}
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
    if ! {
        printf '#!/usr/bin/env bash\n'
        printf 'sleep 180\n'
        printf 'rollback_tmp=$(mktemp %q) || exit 1\n' \
            "${KEY_FILE}.vps-tools-rollback.XXXXXX"
        printf 'if cp -p -- %q "$rollback_tmp" >/dev/null 2>&1 \\\n' "$BACKUP"
        printf '    && mv -f -- "$rollback_tmp" %q >/dev/null 2>&1; then\n' "$KEY_FILE"
        printf '    logger -t vps-tools %q >/dev/null 2>&1 || true\n' \
            "未确认新登录，已自动恢复用户 $USERNAME 的 SSH 公钥文件"
        printf '    printf "%%s\\tFAILED\\t%%s\\t%%s\\n" "$(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"')" %q %q >> %q 2>/dev/null || true\n' \
            "$SOURCE_IP" "删除用户 $USERNAME SSH 公钥未确认，自动回滚成功" "$VPS_AUDIT_LOG"
        printf 'else\n'
        printf '    rm -f -- "$rollback_tmp"\n'
        printf '    logger -t vps-tools %q >/dev/null 2>&1 || true\n' \
            "未确认新登录，但自动恢复用户 $USERNAME 的 SSH 公钥文件失败"
        printf '    printf "%%s\\tFAILED\\t%%s\\t%%s\\n" "$(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"')" %q %q >> %q 2>/dev/null || true\n' \
            "$SOURCE_IP" "删除用户 $USERNAME SSH 公钥未确认，自动回滚失败" "$VPS_AUDIT_LOG"
        printf 'fi\n'
        printf 'chmod 600 %q 2>/dev/null || true\n' "$VPS_AUDIT_LOG"
        printf 'rm -f -- %q %q\n' "$SCRIPT" "$STATE_FILE"
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
    if ! printf '%s|%s\n' "$SAFETY_PID" "$SAFETY_SCRIPT" > "$STATE_FILE"; then
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        rm -f "$SAFETY_SCRIPT"
        SAFETY_PID="" SAFETY_SCRIPT=""
        safety_lock_release
        error "无法保存公钥自动回滚任务状态"
        return 1
    fi
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    safety_lock_release
    audit_action "启动删除用户 $USERNAME SSH 公钥的防断联保护" SUCCESS
    warn "防断联保护已启动：180 秒内未确认新登录，将自动恢复该公钥文件。"
}

ssh_key_delete_confirm_new_session() {
    local EXPECTED_USER="$1" ROUTE="$2" CONFIRMED_USER
    echo ""
    warn "请保持当前窗口，并立即用新终端验证剩余管理员入口。"
    echo -e "  验证用户：${BOLD}${EXPECTED_USER}${NC}  预计方式：${BOLD}${ROUTE}${NC}"
    read -rp "  新会话成功并确认具备 root 管理能力后，输入用户名 ${EXPECTED_USER}: " CONFIRMED_USER
    if [ "$CONFIRMED_USER" = "$EXPECTED_USER" ]; then
        cancel_safety_timer
        audit_action "确认删除公钥后的管理员入口 $EXPECTED_USER" SUCCESS
        info "验证确认完成，已取消自动回滚"
    else
        warn "未完成确认，180 秒自动回滚仍在计时；请勿关闭当前连接。"
    fi
}

ssh_key_file_count() {
    local KEY_FILE="$1" KEY_LINE COUNT=0
    [ -f "$KEY_FILE" ] || { printf '0\n'; return; }
    while IFS= read -r KEY_LINE; do
        ssh_public_key_line_fields "$KEY_LINE" >/dev/null || continue
        COUNT=$((COUNT+1))
    done < "$KEY_FILE"
    printf '%s\n' "$COUNT"
}

ssh_public_key_target_resolve() {
    local USERNAME="$1" RECORD LOGIN_SHELL
    SSH_KEY_TARGET_USER=""
    SSH_KEY_TARGET_UID=""
    SSH_KEY_TARGET_GID=""
    SSH_KEY_TARGET_HOME=""
    SSH_KEY_TARGET_FILE=""

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
    if [ -L "$SSH_KEY_TARGET_FILE" ] \
        || { [ -e "$SSH_KEY_TARGET_FILE" ] && [ ! -f "$SSH_KEY_TARGET_FILE" ]; }; then
        error "公钥目标不是安全的普通文件：$SSH_KEY_TARGET_FILE"
        return 1
    fi
}

ssh_public_key_install() {
    local PUBKEY_INPUT="$1" KEY_TYPE KEY_DATA KEY_DIR TOTAL EXISTING_LINE EXISTING_FIELDS
    local EXISTING_TYPE EXISTING_DATA
    [ -n "${SSH_KEY_TARGET_USER:-}" ] && [ -n "${SSH_KEY_TARGET_FILE:-}" ] || {
        error "尚未选择有效的公钥目标用户"
        return 1
    }
    if ! ssh_public_key_line_valid "$PUBKEY_INPUT"; then
        error "公钥格式或内容无效，应使用以 ssh-ed25519、ssh-rsa 等开头的完整单行公钥"
        return 1
    fi

    # 取类型+主体比较，忽略备注差异，避免重复加入同一把公钥。
    read -r KEY_TYPE KEY_DATA _ <<< "$PUBKEY_INPUT"
    if [ -f "$SSH_KEY_TARGET_FILE" ]; then
        while IFS= read -r EXISTING_LINE; do
            EXISTING_FIELDS=$(ssh_public_key_line_fields "$EXISTING_LINE") || continue
            IFS=$'\t' read -r EXISTING_TYPE EXISTING_DATA _ <<< "$EXISTING_FIELDS"
            if [ "$EXISTING_TYPE" = "$KEY_TYPE" ] && [ "$EXISTING_DATA" = "$KEY_DATA" ]; then
                warn "该公钥已存在于用户 $SSH_KEY_TARGET_USER，跳过添加"
                audit_action "为用户 $SSH_KEY_TARGET_USER 添加 SSH 公钥（已存在）" INFO
                return 0
            fi
        done < "$SSH_KEY_TARGET_FILE"
    fi

    KEY_DIR=$(dirname "$SSH_KEY_TARGET_FILE")
    mkdir -p "$KEY_DIR" || { error "无法创建目录 $KEY_DIR"; return 1; }
    if [[ "$SSH_KEY_TARGET_FILE" == "${SSH_KEY_TARGET_HOME%/}/"* ]]; then
        chown "$SSH_KEY_TARGET_UID:$SSH_KEY_TARGET_GID" "$KEY_DIR" 2>/dev/null || {
            error "无法设置目录属主：$KEY_DIR"
            return 1
        }
        chmod 700 "$KEY_DIR" || { error "无法设置目录权限：$KEY_DIR"; return 1; }
    fi
    touch "$SSH_KEY_TARGET_FILE" \
        || { error "无法创建公钥文件：$SSH_KEY_TARGET_FILE"; return 1; }
    chmod 600 "$SSH_KEY_TARGET_FILE" || { error "无法设置公钥文件权限"; return 1; }
    if [[ "$SSH_KEY_TARGET_FILE" == "${SSH_KEY_TARGET_HOME%/}/"* ]]; then
        chown "$SSH_KEY_TARGET_UID:$SSH_KEY_TARGET_GID" "$SSH_KEY_TARGET_FILE" || {
            error "无法设置公钥文件属主"
            return 1
        }
    else
        chown 0:0 "$SSH_KEY_TARGET_FILE" 2>/dev/null || true
    fi
    if ! printf '%s\n' "$PUBKEY_INPUT" >> "$SSH_KEY_TARGET_FILE"; then
        error "写入公钥失败"
        return 1
    fi

    TOTAL=$(ssh_key_file_count "$SSH_KEY_TARGET_FILE")
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

    local USERNAME RECORD ACCOUNT_UID HOME_DIR LOGIN_SHELL INVENTORY DEL_NUM SELECTED
    local KEY_FILE LINE_NO KEY_TYPE KEY_DATA FINGERPRINT COMMENT OPTIONS ORIGINAL CANDIDATE
    local REMAINING VERIFY_USER VERIFY_LINE VERIFY_ROUTE VERIFY_ADMIN CONFIRM_NAME
    local LIST_USER LIST_ROUTE LIST_ADMIN BACKUP APPLY_TMP POST_REMAINING KEY_META KEY_OWNER KEY_MODE
    ssh_print_key_accounts
    read -rp "  输入要删除公钥的用户名（直接回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消，公钥未修改。"; return; }
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
    [ -f "$KEY_FILE" ] && [ -r "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] || {
        error "目标公钥文件不是安全、可读的普通文件：$KEY_FILE"
        return 1
    }
    [[ "$LINE_NO" =~ ^[1-9][0-9]*$ ]] || { error "公钥行号无效"; return 1; }
    ssh_key_inventory_line_matches "$KEY_FILE" "$LINE_NO" "$KEY_TYPE" "$KEY_DATA" || {
        error "公钥文件已发生变化，请重新进入菜单后再操作"
        return 1
    }

    ORIGINAL=$(mktemp) || { error "无法创建公钥文件快照"; return 1; }
    cp -- "$KEY_FILE" "$ORIGINAL" || {
        rm -f "$ORIGINAL"
        error "无法读取目标公钥文件"
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
    if ! confirm_file_diff "$KEY_FILE" "$CANDIDATE" "删除用户 $USERNAME 的 SSH 公钥"; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        warn "已取消，公钥未修改。"
        return
    fi

    if ! cmp -s "$ORIGINAL" "$KEY_FILE"; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "取消删除用户 $USERNAME SSH 公钥：目标文件并发变更" FAILED
        error "确认期间公钥文件已发生变化，删除已取消"
        return 1
    fi
    mkdir -p "$VPS_BACKUP_DIR" || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        error "无法创建备份目录"
        return 1
    }
    chmod 700 "$VPS_DATA_DIR" "$VPS_BACKUP_DIR" 2>/dev/null || true
    BACKUP="$VPS_BACKUP_DIR/$(date +%Y%m%d_%H%M%S)_ssh-key_${USERNAME}_$$_${RANDOM}.bak"
    cp -p -- "$KEY_FILE" "$BACKUP" || {
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        audit_action "删除用户 $USERNAME SSH 公钥：备份失败" FAILED
        error "无法备份目标公钥文件，删除已取消"
        return 1
    }
    if ! cmp -s "$ORIGINAL" "$KEY_FILE"; then
        rm -f "$ORIGINAL" "$CANDIDATE" "$BACKUP"
        audit_action "取消删除用户 $USERNAME SSH 公钥：备份期间目标文件并发变更" FAILED
        error "确认期间公钥文件已发生变化，删除已取消"
        return 1
    fi
    ssh_key_delete_safety_arm "$KEY_FILE" "$BACKUP" "$USERNAME" || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        audit_action "删除用户 $USERNAME SSH 公钥：启动自动回滚失败" FAILED
        return 1
    }

    KEY_META=$(stat -Lc '%u:%g %a' "$KEY_FILE" 2>/dev/null) || KEY_META=""
    read -r KEY_OWNER KEY_MODE <<< "$KEY_META"
    if ! [[ "$KEY_OWNER" =~ ^[0-9]+:[0-9]+$ && "$KEY_MODE" =~ ^[0-7]+$ ]]; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        cancel_safety_timer
        audit_action "删除用户 $USERNAME SSH 公钥：无法读取原文件属主或权限" FAILED
        error "无法读取公钥文件的属主或权限，删除已取消"
        return 1
    fi
    APPLY_TMP=$(mktemp "${KEY_FILE}.vps-tools.XXXXXX") || {
        rm -f "$ORIGINAL" "$CANDIDATE"
        cancel_safety_timer
        audit_action "删除用户 $USERNAME SSH 公钥：无法创建安全临时文件" FAILED
        error "无法在公钥目录中创建安全临时文件，删除已取消"
        return 1
    }
    if ! awk -v target="$LINE_NO" 'NR != target {print}' "$ORIGINAL" > "$APPLY_TMP" \
        || ! chown "$KEY_OWNER" "$APPLY_TMP" \
        || ! chmod "$KEY_MODE" "$APPLY_TMP" \
        || ! mv -f -- "$APPLY_TMP" "$KEY_FILE"; then
        rm -f "$ORIGINAL" "$CANDIDATE" "$APPLY_TMP"
        if ssh_key_file_restore "$BACKUP" "$KEY_FILE"; then
            cancel_safety_timer
            audit_action "删除用户 $USERNAME SSH 公钥：写入失败并回滚" FAILED
            error "写入公钥文件失败，已恢复原文件"
        else
            audit_action "删除用户 $USERNAME SSH 公钥：写入失败且即时恢复失败" FAILED
            error "写入失败且即时恢复失败；180 秒自动回滚仍在运行，请保持当前连接"
        fi
        return 1
    fi
    if ! cmp -s "$CANDIDATE" "$KEY_FILE"; then
        rm -f "$ORIGINAL" "$CANDIDATE"
        if ssh_key_file_restore "$BACKUP" "$KEY_FILE"; then
            cancel_safety_timer
            audit_action "删除用户 $USERNAME SSH 公钥：写入结果不一致并回滚" FAILED
            error "写入后的公钥文件与候选结果不一致，已恢复原文件"
        else
            audit_action "删除用户 $USERNAME SSH 公钥：写入结果不一致且即时恢复失败" FAILED
            error "写入结果异常且即时恢复失败；180 秒自动回滚仍在运行，请保持当前连接"
        fi
        return 1
    fi
    rm -f "$ORIGINAL" "$CANDIDATE"

    POST_REMAINING=$(ssh_login_candidates "$SSHD_CONFIG")
    if [ -z "$POST_REMAINING" ] || ! ssh_login_candidates_have_admin "$POST_REMAINING"; then
        if ssh_key_file_restore "$BACKUP" "$KEY_FILE"; then
            cancel_safety_timer
            audit_action "删除用户 $USERNAME SSH 公钥后校验失败并回滚" FAILED
            error "删除后的实际校验未找到可用管理入口，已立即恢复原公钥文件"
        else
            audit_action "删除用户 $USERNAME SSH 公钥后校验失败且即时恢复失败" FAILED
            error "删除后校验失败且即时恢复失败！180 秒自动回滚仍在运行，请保持当前连接；备份：$BACKUP"
        fi
        return 1
    fi

    info "公钥已删除；原文件备份：$BACKUP"
    audit_action "删除用户 $USERNAME SSH 公钥" SUCCESS
    ssh_key_delete_confirm_new_session "$VERIFY_USER" "$VERIFY_ROUTE"
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
    TMP_DIR=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/vps_tmp_$$" && echo "/tmp/vps_tmp_$$"; })
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
    local KEY_FILE="$1" ACCOUNT_UID="$2" CURRENT
    [ -f "$KEY_FILE" ] && [ -r "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] || return 1
    ssh_strict_path_owner_mode_secure "$KEY_FILE" "$ACCOUNT_UID" || return 1
    CURRENT=$(dirname "$KEY_FILE")
    while [ "$CURRENT" != / ]; do
        [ -d "$CURRENT" ] || return 1
        ssh_strict_path_owner_mode_secure "$CURRENT" "$ACCOUNT_UID" || return 1
        CURRENT=$(dirname "$CURRENT")
    done
    return 0
}

ssh_strict_key_file_has_unrestricted_key() {
    local KEY_FILE="$1" KEY_LINE KEY_TYPE LINE_NO=0
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
        ssh_public_key_line_valid "$KEY_LINE" && return 0
    done < "$KEY_FILE"
    return 1
}

ssh_strict_pattern_matches() {
    local VALUE="$1" PATTERN="$2"
    [[ "$VALUE" == $PATTERN ]]
}

ssh_strict_access_policy_allows() {
    local DUMP="$1" USERNAME="$2" CLIENT_ADDR=127.0.0.1
    local ALLOW_USERS DENY_USERS ALLOW_GROUPS DENY_GROUPS PATTERN USER_PATTERN HOST_PATTERN
    local GROUP MATCHED=0
    [ -z "${SSH_CONNECTION:-}" ] || read -r CLIENT_ADDR _ <<< "$SSH_CONNECTION"
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
    local CONFIG_FILE="$1" USERNAME ACCOUNT_UID HOME_DIR LOGIN_SHELL
    local DUMP KEY_PATHS TEMPLATE KEY_FILE
    while IFS=: read -r USERNAME _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL; do
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
            ssh_strict_key_path_secure "$KEY_FILE" "$ACCOUNT_UID" || continue
            ssh_strict_key_file_has_unrestricted_key "$KEY_FILE" || continue
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
    echo ""
    warn "root 的新 SSH 登录已禁止，请保持当前窗口不要断开。"
    info "请立即新开终端，强制使用密钥登录："
    echo -e "  ${BOLD}ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no ${EXPECTED_USER}@服务器IP${NC}"
    echo -e "  登录后执行 ${BOLD}whoami${NC}，必须显示 ${BOLD}${EXPECTED_USER}${NC}。"
    read -rp "  确认新会话成功后，输入用户名 ${EXPECTED_USER} 取消自动回滚: " CONFIRMED_USER
    if [ "$CONFIRMED_USER" = "$EXPECTED_USER" ]; then
        cancel_safety_timer
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
    local DUMP KEY_PATHS TEMPLATE KEY_FILE
    DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || return 1
    [ "$(ssh_config_dump_value "$DUMP" pubkeyauthentication)" = yes ] || return 1
    KEY_PATHS=$(ssh_config_dump_value "$DUMP" authorizedkeysfile)
    [ -n "$KEY_PATHS" ] || return 1
    while IFS= read -r TEMPLATE; do
        [ -n "$TEMPLATE" ] || continue
        KEY_FILE=$(ssh_expand_authorized_keys_path \
            "$TEMPLATE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR") || continue
        ssh_strict_key_path_secure "$KEY_FILE" "$ACCOUNT_UID" || continue
        ssh_strict_key_file_has_unrestricted_key "$KEY_FILE" && return 0
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

ssh_user_has_full_sudo_access() {
    local USERNAME="$1" SUDO_OUTPUT
    command -v sudo >/dev/null 2>&1 || return 1
    SUDO_OUTPUT=$(LC_ALL=C sudo -n -l -U "$USERNAME" 2>&1) || return 1
    printf '%s\n' "$SUDO_OUTPUT" | grep -Eq \
        '^[[:space:]]*\((ALL|root)([[:space:]]*:[^)]*)?\)[[:space:]]+((NO)?PASSWD:[[:space:]]*)?ALL([[:space:]]*$|,)'
}

ssh_user_can_admin() {
    local USERNAME="$1"
    [ "$USERNAME" = root ] && return 0
    [ -n "${DOAS_USER:-}" ] && [ "$USERNAME" = "$DOAS_USER" ] && return 0
    ssh_user_has_full_sudo_access "$USERNAME"
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

ssh_collect_effective_deny_users() {
    local CONFIG_FILE="$1" USERNAME ACCOUNT_UID HOME_DIR LOGIN_SHELL DUMP PATTERN SEEN=""
    while IFS=: read -r USERNAME _ ACCOUNT_UID _ _ HOME_DIR LOGIN_SHELL; do
        ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || continue
        DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || continue
        while IFS= read -r PATTERN; do
            [ -n "$PATTERN" ] || continue
            case " $SEEN " in *" $PATTERN "*) continue ;; esac
            SEEN="${SEEN}${SEEN:+ }$PATTERN"
        done < <(ssh_config_dump_value "$DUMP" denyusers | tr '[:space:]' '\n')
    done < <(ssh_account_records)
    printf '%s\n' "$SEEN"
}

ssh_user_explicitly_denied() {
    local DUMP="$1" USERNAME="$2" CLIENT_ADDR=127.0.0.1
    local PATTERN USER_PATTERN HOST_PATTERN
    [ -z "${SSH_CONNECTION:-}" ] || read -r CLIENT_ADDR _ <<< "$SSH_CONNECTION"
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
    echo ""
    warn "请保持当前窗口，并用新终端验证剩余登录入口。"
    echo -e "  验证用户：${BOLD}${EXPECTED_USER}${NC}  预计方式：${BOLD}${ROUTE}${NC}"
    read -rp "  新会话成功后，输入用户名 ${EXPECTED_USER} 取消自动回滚: " CONFIRMED_USER
    if [ "$CONFIRMED_USER" = "$EXPECTED_USER" ]; then
        cancel_safety_timer
        audit_action "确认撤销登录权限后的备用用户 $EXPECTED_USER" SUCCESS
        info "验证确认完成，已取消自动回滚"
    else
        warn "未完成确认，180 秒自动回滚仍在计时；请勿关闭当前连接。"
    fi
}

revoke_user_ssh_login() {
    print_header "撤销指定用户 SSH 登录权限"

    local USERNAME RECORD ACCOUNT_UID HOME_DIR LOGIN_SHELL CURRENT_USER
    local CURRENT_DUMP DENY_USERS CANDIDATE TARGET_DUMP REMAINING VERIFY_USER VERIFY_LINE
    local VERIFY_ROUTE HAS_ADMIN=no CONFIRM_NAME LIST_USER LIST_ROUTE LIST_ADMIN
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

    CURRENT_DUMP=$(ssh_effective_config_dump "$SSHD_CONFIG" "$USERNAME") || {
        error "无法读取用户 $USERNAME 的 SSH 有效配置"
        return 1
    }
    if ssh_user_explicitly_denied "$CURRENT_DUMP" "$USERNAME"; then
        warn "用户 $USERNAME 已被当前 DenyUsers 规则禁止登录，无需重复设置"
        return 0
    fi

    DENY_USERS=$(ssh_collect_effective_deny_users "$SSHD_CONFIG")
    case " $DENY_USERS " in
        *" $USERNAME "*) ;;
        *) DENY_USERS="${DENY_USERS}${DENY_USERS:+ }$USERNAME" ;;
    esac
    CANDIDATE=$(mktemp) || { error "无法创建临时配置"; return 1; }
    cp "$SSHD_CONFIG" "$CANDIDATE" || {
        rm -f "$CANDIDATE"
        error "无法读取当前 SSH 配置"
        return 1
    }
    set_config_file "$CANDIDATE" "DenyUsers" "$DENY_USERS"
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
        | awk -F'|' -v username="$VERIFY_USER" '$1 == username {print; exit}')
    if [ -z "$VERIFY_LINE" ]; then
        rm -f "$CANDIDATE"
        error "用户 $VERIFY_USER 不在撤权后的可登录列表中"
        return 1
    fi
    IFS='|' read -r _ VERIFY_ROUTE _ <<< "$VERIFY_LINE"

    read -rp "  输入目标用户名 $USERNAME 确认撤销（其他输入取消）: " CONFIRM_NAME
    if [ "$CONFIRM_NAME" != "$USERNAME" ]; then
        rm -f "$CANDIDATE"
        warn "用户名不匹配，已取消撤销"
        return
    fi
    backup_config
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "撤销用户 $USERNAME 的 SSH 登录权限"; then
        rm -f "$CANDIDATE"
        warn "已取消，配置未修改"
        return
    fi
    safety_arm ssh_revoke_login || { rm -f "$CANDIDATE"; return 1; }
    if ! cp "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"
        cancel_safety_timer
        error "无法写入 SSH 配置，撤权未应用"
        return 1
    fi
    rm -f "$CANDIDATE"
    if apply_and_restart; then
        info "用户 $USERNAME 的新 SSH 登录已禁止 ✓"
        audit_action "撤销用户 $USERNAME 的 SSH 登录权限" SUCCESS
        ssh_revoke_confirm_new_session "$VERIFY_USER" "$VERIFY_ROUTE"
    else
        cancel_safety_timer
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
            backup_config
            local CANDIDATE; CANDIDATE=$(mktemp)
            cp "$SSHD_CONFIG" "$CANDIDATE"
            set_config_file "$CANDIDATE" "PasswordAuthentication" "no"
            set_config_file "$CANDIDATE" "PubkeyAuthentication"   "yes"
            set_config_file "$CANDIDATE" "PermitRootLogin"        "prohibit-password"
            if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 仅密钥登录"; then
                rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return
            fi
            safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
            cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"
            if apply_and_restart; then
                info "已切换：仅密钥登录 ✓"
                audit_action "SSH切换为仅密钥登录" SUCCESS
                safety_confirm
            else
                cancel_safety_timer
            fi
            ;;
        2)
            backup_config
            local CANDIDATE; CANDIDATE=$(mktemp)
            cp "$SSHD_CONFIG" "$CANDIDATE"
            set_config_file "$CANDIDATE" "PasswordAuthentication" "yes"
            set_config_file "$CANDIDATE" "PubkeyAuthentication"   "yes"
            set_config_file "$CANDIDATE" "PermitRootLogin"        "yes"
            if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 密码和密钥登录"; then
                rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return
            fi
            safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
            cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"
            if apply_and_restart; then
                info "已切换：密码 + 密钥均可登录 ✓"
                audit_action "SSH启用密码和密钥登录" SUCCESS
                safety_confirm
            else
                cancel_safety_timer
            fi
            ;;
        3)
            warn "仅密码登录安全性较低，建议配合强密码使用！"
            read -rp "  确认切换？(Y/n，默认Y): " CONFIRM
            [ -z "${CONFIRM}" ] && CONFIRM="y"
            if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            backup_config
            local CANDIDATE; CANDIDATE=$(mktemp)
            cp "$SSHD_CONFIG" "$CANDIDATE"
            set_config_file "$CANDIDATE" "PasswordAuthentication" "yes"
            set_config_file "$CANDIDATE" "PubkeyAuthentication"   "no"
            set_config_file "$CANDIDATE" "PermitRootLogin"        "yes"
            if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 仅密码登录"; then
                rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return
            fi
            safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
            cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"
            if apply_and_restart; then
                info "已切换：仅密码登录 ✓"
                audit_action "SSH切换为仅密码登录" SUCCESS
                safety_confirm
            else
                cancel_safety_timer
            fi
            ;;
        4)
            local STRICT_CANDIDATE STRICT_CANDIDATES STRICT_USER STRICT_LINE STRICT_KEY_FILE
            STRICT_CANDIDATE=$(mktemp) || { error "无法创建临时配置"; return 1; }
            cp "$SSHD_CONFIG" "$STRICT_CANDIDATE" || {
                rm -f "$STRICT_CANDIDATE"
                error "无法读取当前 SSH 配置"
                return 1
            }
            set_config_file "$STRICT_CANDIDATE" "PasswordAuthentication" "no"
            set_config_file "$STRICT_CANDIDATE" "PubkeyAuthentication" "yes"
            set_config_file "$STRICT_CANDIDATE" "AuthenticationMethods" "publickey"
            set_config_file "$STRICT_CANDIDATE" "PermitRootLogin" "no"
            set_config_file "$STRICT_CANDIDATE" "KbdInteractiveAuthentication" "no"
            set_config_file "$STRICT_CANDIDATE" "MaxAuthTries" "3"
            set_config_file "$STRICT_CANDIDATE" "ClientAliveInterval" "300"
            set_config_file "$STRICT_CANDIDATE" "ClientAliveCountMax" "2"
            set_config_file "$STRICT_CANDIDATE" "X11Forwarding" "no"

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

            backup_config
            if ! confirm_file_diff "$SSHD_CONFIG" "$STRICT_CANDIDATE" "SSH 严格模式"; then
                rm -f "$STRICT_CANDIDATE"
                warn "已取消，配置未修改"
                return
            fi
            safety_arm ssh_strict_login || { rm -f "$STRICT_CANDIDATE"; return 1; }
            if ! cp "$STRICT_CANDIDATE" "$SSHD_CONFIG"; then
                rm -f "$STRICT_CANDIDATE"
                cancel_safety_timer
                error "无法写入 SSH 配置，已取消严格模式"
                return 1
            fi
            rm -f "$STRICT_CANDIDATE"
            if apply_and_restart; then
                info "严格模式已临时应用：root 登录已禁用，仅允许非 root 密钥认证 ✓"
                info "验证账号：$STRICT_USER  公钥文件：$STRICT_KEY_FILE"
                audit_action "SSH启用严格模式，验证用户 $STRICT_USER" SUCCESS
                ssh_strict_confirm_new_session "$STRICT_USER"
            else
                cancel_safety_timer
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) return ;;
    esac
}

change_port() {
    print_header "修改 SSH 端口"

    local CURRENT_PORT
    CURRENT_PORT=$(get_config "Port")
    echo -e "  当前端口：${BOLD}${CURRENT_PORT:-22}${NC}"
    echo ""
    menu_div
    read -rp "  请输入新端口号（直接回车取消）: " INPUT_PORT
    menu_div
    echo ""

    [ -z "$INPUT_PORT" ] && { warn "已取消。"; return; }

    if ! echo "$INPUT_PORT" | grep -qE '^[0-9]+$' || [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        error "无效端口号（请输入 1-65535）。"; return
    fi

    if [ "$INPUT_PORT" = "${CURRENT_PORT:-22}" ]; then
        warn "端口未变化，无需修改。"; return
    fi

    backup_config
    local CANDIDATE; CANDIDATE=$(mktemp)
    cp "$SSHD_CONFIG" "$CANDIDATE"
    set_config_file "$CANDIDATE" "Port" "$INPUT_PORT"

    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 端口 ${CURRENT_PORT:-22} → $INPUT_PORT"; then
        rm -f "$CANDIDATE"
        warn "已取消，配置未修改"
        return
    fi
    safety_arm ssh_port || { rm -f "$CANDIDATE"; return 1; }
    cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"

    if ! sshd -t 2>/dev/null; then
        error "配置语法错误，自动回滚中..."
        [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ] && cp "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" 2>/dev/null && warn "已回滚配置"
        return
    fi

    local OLD_PORT="${CURRENT_PORT:-22}"
    # 先放行新端口（旧端口暂不删，避免 restart 失败/连不上时被锁外面）
    firewall_allow_port "$INPUT_PORT"

    # 应用并重启（失败会自动回滚到旧配置）
    apply_and_restart || {
        cancel_safety_timer
        error "SSH 重启失败，已回滚。旧端口 ${OLD_PORT} 未改动，当前连接安全。"
        return
    }
    if ! f2b_sync_ssh_port "$INPUT_PORT"; then
        warn "SSH 已切换到 $INPUT_PORT，但 Fail2ban 端口同步失败，请进入 Fail2ban 菜单检查"
    fi
    audit_action "SSH端口 ${CURRENT_PORT:-22} 修改为 $INPUT_PORT" SUCCESS

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

    cancel_safety_timer
    audit_action "确认 SSH 新端口 ${INPUT_PORT} 可登录，取消自动回滚" SUCCESS
    info "已确认新端口可登录，自动回滚已取消。"

    echo ""
    warn "下面只清理旧端口 ${OLD_PORT}/tcp 的防火墙放行规则，不会再修改 SSH 监听端口。"
    read -rp "  现在关闭旧端口防火墙规则 ${OLD_PORT}/tcp？(y/N，默认N): " CLOSE_OLD
    [ -z "$CLOSE_OLD" ] && CLOSE_OLD="n"
    if echo "$CLOSE_OLD" | grep -qiE '^y(es)?$'; then
        if [ "$OLD_PORT" != "$INPUT_PORT" ]; then
            command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && \
                ufw delete allow "${OLD_PORT}"/tcp 2>/dev/null && info "ufw 已关闭旧端口 ${OLD_PORT}/tcp ✓"
            if command -v firewall-cmd &>/dev/null && svc_is_active firewalld; then
                firewall-cmd --permanent --remove-port="${OLD_PORT}/tcp" 2>/dev/null
                firewall-cmd --reload 2>/dev/null && info "firewalld 已关闭旧端口 ${OLD_PORT}/tcp ✓"
            fi
        fi
        info "旧端口已关闭。"
    else
        warn "旧端口 ${OLD_PORT} 保留开放。确认无误后可手动关闭，或重新进入本菜单。"
    fi
}

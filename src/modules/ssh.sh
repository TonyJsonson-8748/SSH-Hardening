# ══════════════════════════════════════════════════════════
#  功能模块
# ══════════════════════════════════════════════════════════

show_keys() {
    print_header "查看 root 已有公钥"
    list_keys
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
        *%*|*'|'*|*$'\n'*|*$'\r'*|*/../*|*/..|*/./*) return 1 ;;
        /*) ;;
        *) RESULT="${HOME_DIR%/}/$RESULT" ;;
    esac
    printf '%s\n' "$RESULT"
}

ssh_authorized_keys_path_for_user() {
    local CONFIG_FILE="$1" USERNAME="$2" ACCOUNT_UID="$3" HOME_DIR="$4"
    local DUMP KEY_PATHS TEMPLATE RESOLVED
    DUMP=$(ssh_effective_config_dump "$CONFIG_FILE" "$USERNAME") || return 1
    KEY_PATHS=$(ssh_config_dump_value "$DUMP" authorizedkeysfile)
    [ -n "$KEY_PATHS" ] || return 1
    while IFS= read -r TEMPLATE; do
        [ -n "$TEMPLATE" ] || continue
        RESOLVED=$(ssh_expand_authorized_keys_path "$TEMPLATE" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR") \
            || continue
        printf '%s\n' "$RESOLVED"
        return 0
    done < <(printf '%s\n' "$KEY_PATHS" | tr '[:space:]' '\n')
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

ssh_key_file_count() {
    local KEY_FILE="$1" COUNT
    COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' \
        "$KEY_FILE" 2>/dev/null || true)
    case "$COUNT" in
        ''|*[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$COUNT" ;;
    esac
}

add_key() {
    print_header "添加 SSH 公钥"

    local USERNAME RECORD ACCOUNT_UID ACCOUNT_GID HOME_DIR LOGIN_SHELL
    local TARGET_KEYS KEY_DIR PUBKEY_INPUT KEY_TYPE KEY_DATA TOTAL
    echo -e "  ${DIM}可添加公钥的登录账号：${NC}"
    printf "  %-18s %-8s %-24s %s\n" "用户名" "UID" "主目录" "Shell"
    menu_div
    while IFS=: read -r USERNAME _ ACCOUNT_UID ACCOUNT_GID _ HOME_DIR LOGIN_SHELL; do
        ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL" || continue
        printf "  %-18s %-8s %-24s %s\n" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL"
    done < <(ssh_account_records)
    menu_div
    echo ""

    read -rp "  输入目标用户名（直接回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消，未添加公钥。"; return; }
    RECORD=$(ssh_account_record "$USERNAME")
    [ -n "$RECORD" ] || { error "用户 $USERNAME 不存在"; return 1; }
    IFS=: read -r _ _ ACCOUNT_UID ACCOUNT_GID _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    if ! ssh_key_target_allowed "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR" "$LOGIN_SHELL"; then
        error "用户 $USERNAME 不是可用的交互式登录账号"
        return 1
    fi
    TARGET_KEYS=$(ssh_authorized_keys_path_for_user \
        "$SSHD_CONFIG" "$USERNAME" "$ACCOUNT_UID" "$HOME_DIR") || {
        error "无法确定用户 $USERNAME 实际生效的 AuthorizedKeysFile，已拒绝写入"
        return 1
    }
    if [ -L "$TARGET_KEYS" ] || { [ -e "$TARGET_KEYS" ] && [ ! -f "$TARGET_KEYS" ]; }; then
        error "公钥目标不是安全的普通文件：$TARGET_KEYS"
        return 1
    fi

    echo ""
    echo -e "  目标用户：${BOLD}${USERNAME}${NC}"
    echo -e "  公钥文件：${BOLD}${TARGET_KEYS}${NC}"
    read -r -p "  粘贴一整行 SSH 公钥（直接回车取消）: " PUBKEY_INPUT
    PUBKEY_INPUT=${PUBKEY_INPUT%$'\r'}
    PUBKEY_INPUT="${PUBKEY_INPUT#"${PUBKEY_INPUT%%[![:space:]]*}"}"
    if [ -z "$PUBKEY_INPUT" ]; then
        warn "已取消，未添加公钥。"
        return
    fi
    if ! ssh_public_key_line_valid "$PUBKEY_INPUT"; then
        error "公钥格式或内容无效，应粘贴以 ssh-ed25519、ssh-rsa 等开头的完整单行公钥"
        return
    fi

    # 检查是否已存在相同公钥（取类型+主体比较，忽略备注差异）
    read -r KEY_TYPE KEY_DATA _ <<< "$PUBKEY_INPUT"
    if awk -v key_type="$KEY_TYPE" -v key_data="$KEY_DATA" \
        '$1 == key_type && $2 == key_data {found=1} END {exit !found}' \
        "$TARGET_KEYS" 2>/dev/null; then
        warn "该公钥已存在，跳过添加（避免重复）"
        return
    fi

    KEY_DIR=$(dirname "$TARGET_KEYS")
    mkdir -p "$KEY_DIR" || { error "无法创建目录 $KEY_DIR"; return 1; }
    if [[ "$TARGET_KEYS" == "${HOME_DIR%/}/"* ]]; then
        chown "$ACCOUNT_UID:$ACCOUNT_GID" "$KEY_DIR" 2>/dev/null || {
            error "无法设置目录属主：$KEY_DIR"
            return 1
        }
        chmod 700 "$KEY_DIR" || { error "无法设置目录权限：$KEY_DIR"; return 1; }
    fi
    touch "$TARGET_KEYS" || { error "无法创建公钥文件：$TARGET_KEYS"; return 1; }
    chmod 600 "$TARGET_KEYS" || { error "无法设置公钥文件权限"; return 1; }
    if [[ "$TARGET_KEYS" == "${HOME_DIR%/}/"* ]]; then
        chown "$ACCOUNT_UID:$ACCOUNT_GID" "$TARGET_KEYS" || {
            error "无法设置公钥文件属主"
            return 1
        }
    else
        chown 0:0 "$TARGET_KEYS" 2>/dev/null || true
    fi
    if ! printf '%s\n' "$PUBKEY_INPUT" >> "$TARGET_KEYS"; then
        error "写入公钥失败"
        return 1
    fi

    TOTAL=$(ssh_key_file_count "$TARGET_KEYS")
    info "公钥已添加到用户 $USERNAME！该文件当前共 $TOTAL 个公钥 ✓"
    audit_action "为用户 $USERNAME 添加 SSH 公钥" SUCCESS
}

delete_key() {
    print_header "删除 root SSH 公钥"

    if ! list_keys; then
        return
    fi

    menu_div
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"; return
    fi

    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then TARGET_LINE="$line"; break; fi
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"

    if [ -z "$TARGET_LINE" ]; then
        error "编号 $DEL_NUM 不存在。"; return
    fi

    echo ""
    warn "即将删除以下公钥："
    echo -e "  ${RED}$(echo "$TARGET_LINE" | awk '{print $1, $3}')${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 取公钥主体（类型+base64）作为匹配依据，避免尾部空格/备注差异导致删除失败
    local KEY_BODY
    KEY_BODY=$(echo "$TARGET_LINE" | awk '{print $1, $2}')
    grep -vF "$KEY_BODY" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" || true
    mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    info "公钥已删除 ✓"
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

    read -rp "  是否将公钥添加到本服务器的 root 用户？(Y/n，默认Y): " ADD_CONFIRM
    [ -z "${ADD_CONFIRM}" ] && ADD_CONFIRM="y"
    if echo "${ADD_CONFIRM}" | grep -qiE '^y(es)?$'; then
        mkdir -p "$(dirname "$AUTH_KEYS")"; chmod 700 "$(dirname "$AUTH_KEYS")"
        local KEY_BODY
        KEY_BODY=$(echo "$PUBKEY" | awk '{print $1, $2}')
        if grep -qF "$KEY_BODY" "$AUTH_KEYS" 2>/dev/null; then
            warn "该公钥已存在于 root，跳过添加"
        else
            echo "$PUBKEY" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
            local TOTAL
            TOTAL=$(ssh_key_count)
            echo ""
            info "公钥已添加到 root！当前共 $TOTAL 个公钥 ✓"
        fi
    else
        warn "已跳过，公钥未添加到 root。"
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
    local KEY_FILE="$1" KEY_LINE KEY_TYPE
    while IFS= read -r KEY_LINE || [ -n "$KEY_LINE" ]; do
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

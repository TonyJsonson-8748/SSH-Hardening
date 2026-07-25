# ============================================================
#  用户管理模块
# ============================================================

USER_SUDOERS_DIR="${USER_SUDOERS_DIR:-/etc/sudoers.d}"
USER_GROUP_FILE="${USER_GROUP_FILE:-/etc/group}"
USER_PASSWD_FILE="${USER_PASSWD_FILE:-/etc/passwd}"

user_effective_uid() {
    if [ -n "${VPS_TOOLS_UID_OVERRIDE:-}" ]; then
        printf '%s\n' "$VPS_TOOLS_UID_OVERRIDE"
    else
        id -u
    fi
}

user_require_root() {
    if [ "$(user_effective_uid)" = "0" ]; then
        return 0
    fi
    error "用户管理需要 root 权限"
    warn "请退出后使用 sudo v、sudo V，或切换到 root 再运行脚本"
    return 1
}

user_name_valid() {
    local USERNAME="$1"
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    [ "$USERNAME" != "root" ]
}

user_login_shell() {
    if [ -x /bin/bash ]; then
        echo /bin/bash
    elif [ -x /bin/ash ]; then
        echo /bin/ash
    else
        echo /bin/sh
    fi
}

user_account_exists() {
    id "$1" >/dev/null 2>&1
}

user_uid_min() {
    local UID_MIN=1000
    [ -r /etc/login.defs ] && UID_MIN=$(awk '$1=="UID_MIN"{print $2; exit}' /etc/login.defs 2>/dev/null)
    [[ "$UID_MIN" =~ ^[0-9]+$ ]] || UID_MIN=1000
    printf '%s\n' "$UID_MIN"
}

user_account_record() {
    local USERNAME="$1"
    if [ "$USER_PASSWD_FILE" = "/etc/passwd" ] && command -v getent >/dev/null 2>&1; then
        getent passwd "$USERNAME" 2>/dev/null \
            | awk -F: -v username="$USERNAME" '$1 == username {print; exit}'
    else
        awk -F: -v username="$USERNAME" '$1 == username {print; exit}' "$USER_PASSWD_FILE" 2>/dev/null
    fi
}

user_has_active_session() {
    local USERNAME="$1"
    command -v who >/dev/null 2>&1 || return 1
    who 2>/dev/null | awk -v username="$USERNAME" '$1 == username {found=1} END {exit !found}'
}

user_has_processes() {
    local USERNAME="$1"
    command -v pgrep >/dev/null 2>&1 || return 1
    pgrep -u "$USERNAME" >/dev/null 2>&1
}

user_is_protected_account() {
    local USERNAME="$1" USER_ID="$2" UID_MIN PROTECTED_USER
    UID_MIN=$(user_uid_min)
    [ "$USERNAME" != "root" ] && [ "$USER_ID" != "0" ] || return 0
    case "$USERNAME:$USER_ID" in
        nobody:*|nfsnobody:*|*:65534) return 0 ;;
    esac
    [ "$USER_ID" -ge "$UID_MIN" ] 2>/dev/null || return 0
    for PROTECTED_USER in "${SUDO_USER:-}" "${DOAS_USER:-}"; do
        [ -z "$PROTECTED_USER" ] || [ "$USERNAME" != "$PROTECTED_USER" ] || return 0
    done
    return 1
}

user_password_target_allowed() {
    local USERNAME="$1" USER_ID="$2" UID_MIN
    [[ "$USER_ID" =~ ^[0-9]+$ ]] || return 1
    if [ "$USERNAME" = "root" ] && [ "$USER_ID" = "0" ]; then
        return 0
    fi
    case "$USERNAME:$USER_ID" in
        nobody:*|nfsnobody:*|*:65534) return 1 ;;
    esac
    UID_MIN=$(user_uid_min)
    [ "$USER_ID" -ge "$UID_MIN" ] 2>/dev/null
}

user_home_safe_to_remove() {
    local HOME_DIR="$1"
    case "$HOME_DIR" in
        ""|/|/root|/home|/usr|/var|/etc|/opt|/srv|/tmp|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/run|/mnt|/media)
            return 1
            ;;
        /*/../*|*/..|/*/./*|*/.)
            return 1
            ;;
        /*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

user_home_is_shared() {
    local USERNAME="$1" HOME_DIR="$2"
    if [ "$USER_PASSWD_FILE" = "/etc/passwd" ] && command -v getent >/dev/null 2>&1; then
        { getent passwd 2>/dev/null || cat "$USER_PASSWD_FILE" 2>/dev/null; }
    else
        cat "$USER_PASSWD_FILE" 2>/dev/null
    fi | awk -F: -v username="$USERNAME" -v home="$HOME_DIR" \
        '$1 != username && $6 == home {found=1} END {exit !found}'
}

user_create_system_account() {
    local USERNAME="$1" LOGIN_SHELL="$2" ADDUSER_HELP
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "$LOGIN_SHELL" "$USERNAME"
        return $?
    fi
    if ! command -v adduser >/dev/null 2>&1; then
        error "系统缺少 useradd/adduser，无法创建用户"
        return 1
    fi
    ADDUSER_HELP=$(adduser --help 2>&1 || true)
    if echo "$ADDUSER_HELP" | grep -qE 'BusyBox|[[:space:]]-D([,[:space:]]|$)'; then
        adduser -D -s "$LOGIN_SHELL" "$USERNAME"
    else
        adduser --disabled-password --gecos "" --shell "$LOGIN_SHELL" "$USERNAME"
    fi
}

user_remove_created_account() {
    local USERNAME="$1"
    if command -v userdel >/dev/null 2>&1; then
        userdel -r "$USERNAME" >/dev/null 2>&1 || userdel "$USERNAME" >/dev/null 2>&1 || true
    elif command -v deluser >/dev/null 2>&1; then
        deluser --remove-home "$USERNAME" >/dev/null 2>&1 || deluser "$USERNAME" >/dev/null 2>&1 || true
    fi
}

user_delete_system_account() {
    local USERNAME="$1" REMOVE_HOME="$2"
    if command -v userdel >/dev/null 2>&1; then
        if [ "$REMOVE_HOME" = "yes" ]; then
            userdel -r "$USERNAME"
        else
            userdel "$USERNAME"
        fi
        return $?
    fi
    if command -v deluser >/dev/null 2>&1; then
        if [ "$REMOVE_HOME" = "yes" ]; then
            deluser --remove-home "$USERNAME"
        else
            deluser "$USERNAME"
        fi
        return $?
    fi
    error "系统缺少 userdel/deluser，无法删除用户"
    return 1
}

user_apply_password() {
    local USERNAME="$1" PASSWORD="$2"
    if command -v chpasswd >/dev/null 2>&1; then
        printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
        return $?
    fi
    warn "系统缺少 chpasswd，将调用 passwd 交互设置密码"
    passwd "$USERNAME"
}

user_prompt_password() {
    local USERNAME="$1" PASSWORD="" CONFIRM="" TRY
    for TRY in 1 2 3; do
        read -rsp "  输入登录密码（至少 8 位，输入不显示）: " PASSWORD
        echo ""
        if [ "${#PASSWORD}" -lt 8 ]; then
            warn "密码至少需要 8 位"
            continue
        fi
        case "$PASSWORD" in
            *:*) warn "密码不能包含冒号"; continue ;;
        esac
        read -rsp "  再次输入密码: " CONFIRM
        echo ""
        if [ "$PASSWORD" != "$CONFIRM" ]; then
            warn "两次密码不一致"
            continue
        fi
        if user_apply_password "$USERNAME" "$PASSWORD"; then
            PASSWORD="" CONFIRM=""
            return 0
        fi
        error "密码设置失败"
        PASSWORD="" CONFIRM=""
        return 1
    done
    error "密码输入连续失败"
    PASSWORD="" CONFIRM=""
    return 1
}

user_group_exists() {
    local GROUP_NAME="$1"
    if [ -n "${USER_GROUP_FILE:-}" ] && [ "$USER_GROUP_FILE" != "/etc/group" ]; then
        grep -q "^${GROUP_NAME}:" "$USER_GROUP_FILE" 2>/dev/null
    elif command -v getent >/dev/null 2>&1; then
        getent group "$GROUP_NAME" >/dev/null 2>&1
    else
        grep -q "^${GROUP_NAME}:" /etc/group 2>/dev/null
    fi
}

user_add_to_group() {
    local USERNAME="$1" GROUP_NAME="$2"
    if command -v usermod >/dev/null 2>&1; then
        usermod -aG "$GROUP_NAME" "$USERNAME"
    elif command -v gpasswd >/dev/null 2>&1; then
        gpasswd -a "$USERNAME" "$GROUP_NAME"
    elif command -v addgroup >/dev/null 2>&1; then
        addgroup "$USERNAME" "$GROUP_NAME"
    else
        return 1
    fi
}

user_ensure_sudo() {
    if command -v sudo >/dev/null 2>&1 && command -v visudo >/dev/null 2>&1; then
        return 0
    fi
    info "正在安装 sudo..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install sudo >/dev/null 2>&1
    else
        pkg_install sudo
    fi
    command -v sudo >/dev/null 2>&1 && command -v visudo >/dev/null 2>&1
}

user_write_sudoers() {
    local USERNAME="$1" TARGET TMP
    TARGET="$USER_SUDOERS_DIR/vps-tools-$USERNAME"
    [ ! -e "$TARGET" ] || {
        error "sudoers 文件已存在：$TARGET"
        return 1
    }
    if [ ! -d "$USER_SUDOERS_DIR" ]; then
        install -d -m 750 "$USER_SUDOERS_DIR" || return 1
    fi
    TMP=$(mktemp "$USER_SUDOERS_DIR/.vps-tools-${USERNAME}.XXXXXX") || return 1
    if ! printf '%s ALL=(ALL) ALL\n' "$USERNAME" > "$TMP" \
        || ! chmod 440 "$TMP" \
        || ! visudo -cf "$TMP" >/dev/null 2>&1; then
        rm -f "$TMP"
        error "sudoers 配置校验失败"
        return 1
    fi
    mv "$TMP" "$TARGET" || { rm -f "$TMP"; return 1; }
    chmod 440 "$TARGET"
}

user_grant_admin() {
    local USERNAME="$1" ADMIN_GROUP="" SUDOERS_TARGET
    user_ensure_sudo || {
        error "sudo 安装或检测失败"
        return 1
    }
    if user_group_exists sudo; then
        ADMIN_GROUP=sudo
    elif user_group_exists wheel; then
        ADMIN_GROUP=wheel
    fi
    if [ -n "$ADMIN_GROUP" ]; then
        user_add_to_group "$USERNAME" "$ADMIN_GROUP" || {
            error "无法将 $USERNAME 加入 $ADMIN_GROUP 组"
            return 1
        }
    fi
    user_write_sudoers "$USERNAME" || return 1
    SUDOERS_TARGET="$USER_SUDOERS_DIR/vps-tools-$USERNAME"
    if ! sudo -l -U "$USERNAME" >/dev/null 2>&1; then
        rm -f "$SUDOERS_TARGET"
        error "sudo 未识别新管理员规则，已撤销授权"
        return 1
    fi
    info "已授予 $USERNAME sudo 管理权限 ✓"
}

user_create_account() {
    local ROLE="$1" ROLE_LABEL="普通" USERNAME="" LOGIN_SHELL SUDOERS_TARGET
    [ "$ROLE" = admin ] && ROLE_LABEL="管理员"
    user_require_root || return 1
    print_header "创建${ROLE_LABEL}用户"
    read -rp "  输入用户名（小写字母开头，可含数字、_、-）: " USERNAME
    if ! user_name_valid "$USERNAME"; then
        error "用户名无效：需以小写字母或下划线开头，最长 32 位，且不能是 root"
        return 1
    fi
    if user_account_exists "$USERNAME"; then
        error "用户 $USERNAME 已存在"
        return 1
    fi
    SUDOERS_TARGET="$USER_SUDOERS_DIR/vps-tools-$USERNAME"
    if [ "$ROLE" = admin ] && [ -e "$SUDOERS_TARGET" ]; then
        error "检测到残留 sudoers 文件：$SUDOERS_TARGET，请人工确认后再创建"
        return 1
    fi
    LOGIN_SHELL=$(user_login_shell)
    if [ "$ROLE" = admin ]; then
        confirm_change_preview "创建管理员用户" \
            "用户名：$USERNAME" "主目录：/home/$USERNAME" \
            "登录 Shell：$LOGIN_SHELL" "权限：可使用 sudo 执行管理命令" || return 0
    else
        confirm_change_preview "创建普通用户" \
            "用户名：$USERNAME" "主目录：/home/$USERNAME" \
            "登录 Shell：$LOGIN_SHELL" "权限：普通用户，不授予 sudo" || return 0
    fi
    info "正在创建用户 $USERNAME..."
    if ! user_create_system_account "$USERNAME" "$LOGIN_SHELL"; then
        error "用户创建失败"
        audit_action "创建${ROLE_LABEL}用户 $USERNAME" FAILED
        return 1
    fi
    if ! user_prompt_password "$USERNAME"; then
        warn "密码设置失败，正在删除未完成的用户"
        user_remove_created_account "$USERNAME"
        audit_action "创建${ROLE_LABEL}用户 $USERNAME" FAILED
        return 1
    fi
    if [ "$ROLE" = admin ] && ! user_grant_admin "$USERNAME"; then
        rm -f "$SUDOERS_TARGET" 2>/dev/null || true
        warn "管理员授权失败，正在删除未完成的用户"
        user_remove_created_account "$USERNAME"
        audit_action "创建管理员用户 $USERNAME" FAILED
        return 1
    fi
    audit_action "创建${ROLE_LABEL}用户 $USERNAME" SUCCESS
    info "用户 $USERNAME 创建完成 ✓"
    [ "$ROLE" = admin ] && ui_hint "验证方式：su - $USERNAME，然后执行 sudo -v"
}

user_change_password() {
    local USERNAME="" RECORD USER_ID HOME_DIR LOGIN_SHELL
    user_require_root || return 1
    print_header "修改用户密码"
    read -rp "  输入要修改密码的用户名（输入 0 返回）: " USERNAME
    [ "$USERNAME" != "0" ] || return 0
    RECORD=$(user_account_record "$USERNAME")
    if [ -z "$RECORD" ]; then
        error "用户 $USERNAME 不存在"
        return 1
    fi
    IFS=: read -r _ _ USER_ID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    if ! user_password_target_allowed "$USERNAME" "$USER_ID"; then
        error "拒绝修改系统服务账号密码：$USERNAME"
        warn "该功能只允许 root、普通用户和 sudo 管理员账号"
        return 1
    fi
    [ "$USERNAME" != "root" ] || warn "正在修改 root 密码，请确保你仍保留可用的 SSH 登录方式"
    confirm_change_preview "修改用户密码" \
        "用户名：$USERNAME" "UID：$USER_ID" \
        "主目录：$HOME_DIR" "登录 Shell：$LOGIN_SHELL" \
        "影响：现有密码将立即失效" || return 0
    if ! user_prompt_password "$USERNAME"; then
        audit_action "修改用户密码 $USERNAME" FAILED
        return 1
    fi
    audit_action "修改用户密码 $USERNAME" SUCCESS
    info "用户 $USERNAME 的密码已更新 ✓"
}

user_delete_account() {
    local USERNAME="" RECORD USER_ID HOME_DIR LOGIN_SHELL REMOVE_HOME MODE_LABEL CONFIRM_NAME CHOICE DELETE_RC=0
    user_require_root || return 1
    print_header "删除用户"
    read -rp "  输入要删除的用户名（输入 0 返回）: " USERNAME
    [ "$USERNAME" != "0" ] || return 0
    RECORD=$(user_account_record "$USERNAME")
    if [ -z "$RECORD" ]; then
        error "用户 $USERNAME 不存在"
        return 1
    fi
    IFS=: read -r _ _ USER_ID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    if user_is_protected_account "$USERNAME" "$USER_ID"; then
        error "拒绝删除受保护账号：$USERNAME"
        warn "root、系统账号以及当前 sudo/doas 提权账号不能通过本脚本删除"
        return 1
    fi
    if user_has_active_session "$USERNAME"; then
        error "用户 $USERNAME 当前仍有登录会话"
        warn "请让该用户退出登录后再删除，避免中断正在进行的工作"
        return 1
    fi
    if user_has_processes "$USERNAME"; then
        error "用户 $USERNAME 当前仍有运行中的进程"
        warn "请先确认并停止这些进程，然后再删除用户"
        return 1
    fi

    while true; do
        print_header "删除用户 · $USERNAME"
        menu_item "1" "仅删除账号，保留工作空间  ${DIM}$HOME_DIR${NC}"
        menu_item "2" "删除账号及全部工作空间  ${DIM}不可恢复${NC}" "$RED"
        menu_item "0" "取消并返回" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择删除方式 [0-2]: ')" CHOICE
        case "$CHOICE" in
            1)
                REMOVE_HOME=no
                MODE_LABEL="保留工作空间"
                break
                ;;
            2)
                if ! user_home_safe_to_remove "$HOME_DIR"; then
                    error "主目录路径不安全，拒绝自动删除：$HOME_DIR"
                    warn "账号尚未删除，请人工核对 /etc/passwd 中的主目录设置"
                    return 1
                fi
                if user_home_is_shared "$USERNAME" "$HOME_DIR"; then
                    error "主目录被其他账号共用，拒绝删除：$HOME_DIR"
                    warn "请选择“保留工作空间”，或先解除共享关系"
                    return 1
                fi
                REMOVE_HOME=yes
                MODE_LABEL="删除账号及工作空间"
                break
                ;;
            0) return 0 ;;
            *) warn "无效选项" ;;
        esac
    done

    echo ""
    warn "即将执行不可逆的用户删除操作"
    echo "  用户名：$USERNAME"
    echo "  UID：$USER_ID"
    echo "  主目录：$HOME_DIR"
    echo "  登录 Shell：$LOGIN_SHELL"
    echo "  删除方式：$MODE_LABEL"
    [ "$REMOVE_HOME" = "no" ] && ui_hint "账号删除后，保留文件仍属于原 UID，需要管理员后续重新分配所有权"
    echo ""
    read -rp "  输入用户名 $USERNAME 确认删除（其他输入取消）: " CONFIRM_NAME
    if [ "$CONFIRM_NAME" != "$USERNAME" ]; then
        warn "用户名不匹配，已取消删除"
        return 0
    fi

    info "正在删除用户 $USERNAME..."
    user_delete_system_account "$USERNAME" "$REMOVE_HOME" || DELETE_RC=$?
    if user_account_exists "$USERNAME"; then
        error "用户删除失败，账号可能仍有进程或被系统策略保护"
        audit_action "删除用户 $USERNAME（$MODE_LABEL）" FAILED
        return 1
    fi
    rm -f "$USER_SUDOERS_DIR/vps-tools-$USERNAME" 2>/dev/null || true
    if [ "$DELETE_RC" -ne 0 ]; then
        warn "账号已删除，但系统报告工作空间清理不完整"
        [ "$REMOVE_HOME" = "yes" ] && [ -e "$HOME_DIR" ] \
            && warn "请人工检查残留目录：$HOME_DIR"
        audit_action "删除用户 $USERNAME（$MODE_LABEL，工作空间可能残留）" PARTIAL
        return 1
    fi
    audit_action "删除用户 $USERNAME（$MODE_LABEL）" SUCCESS
    info "用户 $USERNAME 已删除 ✓"
    if [ "$REMOVE_HOME" = "no" ]; then
        info "工作空间已保留：$HOME_DIR"
    else
        info "工作空间已随账号删除：$HOME_DIR"
    fi
}

user_list_accounts() {
    local UID_MIN LINE USERNAME USER_ID HOME_DIR LOGIN_SHELL GROUP_LIST ROLE
    UID_MIN=$(user_uid_min)
    print_header "用户列表"
    printf "  %-18s %-8s %-10s %-24s %s\n" "用户名" "UID" "类型" "主目录" "Shell"
    menu_div
    while IFS=: read -r USERNAME _ USER_ID _ _ HOME_DIR LOGIN_SHELL; do
        [ "$USER_ID" = "0" ] || [ "$USER_ID" -ge "$UID_MIN" ] 2>/dev/null || continue
        [ "$USERNAME" != "nobody" ] || continue
        GROUP_LIST=$(id -nG "$USERNAME" 2>/dev/null || true)
        ROLE=普通用户
        [ "$USER_ID" = "0" ] && ROLE=超级用户
        case " $GROUP_LIST " in
            *" sudo "*|*" wheel "*) ROLE=管理员 ;;
        esac
        [ -f "$USER_SUDOERS_DIR/vps-tools-$USERNAME" ] && ROLE=管理员
        printf "  %-18s %-8s %-10s %-24s %s\n" "$USERNAME" "$USER_ID" "$ROLE" "$HOME_DIR" "$LOGIN_SHELL"
    done < "$USER_PASSWD_FILE"
    ui_pause
}

user_management_menu() {
    user_require_root || return 1
    while true; do
        print_header "用户管理"
        menu_item "1" "创建普通用户"
        menu_item "2" "创建管理员用户  ${DIM}可使用 sudo${NC}" "$YELLOW"
        menu_item "3" "查看用户列表"
        menu_item "4" "修改用户密码"
        menu_item "5" "删除用户  ${DIM}可选择保留或删除工作空间${NC}" "$RED"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CHOICE
        case "$CHOICE" in
            1) user_create_account regular ;;
            2) user_create_account admin ;;
            3) user_list_accounts ;;
            4) user_change_password ;;
            5) user_delete_account ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

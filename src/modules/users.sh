# ============================================================
#  用户管理模块
# ============================================================

USER_SUDOERS_DIR="${USER_SUDOERS_DIR:-/etc/sudoers.d}"
USER_GROUP_FILE="${USER_GROUP_FILE:-/etc/group}"

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

user_list_accounts() {
    local UID_MIN=1000 LINE USERNAME USER_ID HOME_DIR LOGIN_SHELL GROUP_LIST ROLE
    [ -r /etc/login.defs ] && UID_MIN=$(awk '$1=="UID_MIN"{print $2; exit}' /etc/login.defs 2>/dev/null)
    [[ "$UID_MIN" =~ ^[0-9]+$ ]] || UID_MIN=1000
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
    done < /etc/passwd
    echo ""
    press_enter
}

user_management_menu() {
    user_require_root || return 1
    while true; do
        print_header "用户管理"
        menu_item "1" "创建普通用户"
        menu_item "2" "创建管理员用户  ${DIM}可使用 sudo${NC}" "$YELLOW"
        menu_item "3" "查看用户列表"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" CHOICE
        case "$CHOICE" in
            1) user_create_account regular ;;
            2) user_create_account admin ;;
            3) user_list_accounts ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

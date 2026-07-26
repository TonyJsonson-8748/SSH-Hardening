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
    local USERNAME="$1" WHO_OUTPUT
    command -v who >/dev/null 2>&1 || return 2
    WHO_OUTPUT=$(who 2>/dev/null) || return 2
    printf '%s\n' "$WHO_OUTPUT" \
        | awk -v username="$USERNAME" '$1 == username {found=1} END {exit !found}'
}

user_has_processes() {
    local USERNAME="$1" RC
    command -v pgrep >/dev/null 2>&1 || return 2
    pgrep -u "$USERNAME" >/dev/null 2>&1
    RC=$?
    [ "$RC" -le 1 ] || return 2
    return "$RC"
}

user_runtime_quiescent() {
    local USERNAME="$1" PHASE="${2:-当前}" RC
    if user_has_active_session "$USERNAME"; then
        error "${PHASE}用户 $USERNAME 仍有登录会话"
        return 1
    else
        RC=$?
        if [ "$RC" -ne 1 ]; then
            error "无法可靠检查${PHASE}用户 $USERNAME 的登录会话，拒绝删除"
            return 1
        fi
    fi
    if user_has_processes "$USERNAME"; then
        error "${PHASE}用户 $USERNAME 仍有运行中的进程"
        return 1
    else
        RC=$?
        if [ "$RC" -ne 1 ]; then
            error "无法可靠检查${PHASE}用户 $USERNAME 的运行进程，拒绝删除"
            return 1
        fi
    fi
    return 0
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

user_home_canonical_path() {
    local HOME_DIR="$1" RESOLVED
    case "$HOME_DIR" in
        ""|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
        /*) ;;
        *) return 1 ;;
    esac
    [ -d "$HOME_DIR" ] || return 1
    RESOLVED=$(CDPATH= cd -P -- "$HOME_DIR" 2>/dev/null && pwd -P) || return 1
    case "$RESOLVED" in /*) ;; *) return 1 ;; esac
    # POSIX permits an implementation to preserve exactly two leading slashes.
    # Linux treats them as "/", so normalize them before safety comparisons.
    while [ "${RESOLVED#//}" != "$RESOLVED" ]; do
        RESOLVED="/${RESOLVED#//}"
    done
    while [ "$RESOLVED" != "/" ] && [ "${RESOLVED%/}" != "$RESOLVED" ]; do
        RESOLVED=${RESOLVED%/}
    done
    printf '%s\n' "$RESOLVED"
}

user_home_normalize_text() {
    local HOME_DIR="$1" REL COMPONENT NORMALIZED=""
    local COMPONENTS=()
    case "$HOME_DIR" in
        ""|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
        /*) ;;
        *) return 1 ;;
    esac
    REL=${HOME_DIR#/}
    IFS='/' read -r -a COMPONENTS <<< "$REL"
    for COMPONENT in "${COMPONENTS[@]}"; do
        [ -n "$COMPONENT" ] || continue
        case "$COMPONENT" in .|..) return 1 ;; esac
        NORMALIZED="${NORMALIZED}/${COMPONENT}"
    done
    printf '%s\n' "${NORMALIZED:-/}"
}

user_home_resolve_path() {
    local HOME_DIR="$1" REL COMPONENT CURRENT=""
    local COMPONENTS=()
    case "$HOME_DIR" in
        ""|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
        /*) ;;
        *) return 1 ;;
    esac
    [ -d "$HOME_DIR" ] || return 1

    # Reject every symlink component. Resolving only the final component is not
    # enough: /home/user may traverse a user-controlled parent symlink.
    REL=${HOME_DIR#/}
    IFS='/' read -r -a COMPONENTS <<< "$REL"
    for COMPONENT in "${COMPONENTS[@]}"; do
        [ -n "$COMPONENT" ] || continue
        case "$COMPONENT" in .|..) return 1 ;; esac
        CURRENT="${CURRENT}/${COMPONENT}"
        [ ! -L "$CURRENT" ] || return 1
    done
    user_home_canonical_path "$HOME_DIR"
}

user_home_path_protected() {
    local HOME_DIR="$1"
    case "$HOME_DIR" in
        /|/root|/root/*|/home|/usr|/usr/*|/var|/var/*|/etc|/etc/*|\
        /bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|\
        /boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|\
        /opt|/srv|/tmp|/mnt|/media)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

user_home_mounts_safe() {
    local HOME_DIR="$1" RESOLVED LIST MOUNT_DEV MOUNT_ROOT MOUNT_TARGET
    local HOME_MOUNT_DEV="" HOME_MOUNT_ROOT="" HOME_MOUNT_TARGET=""
    local HOME_FS_PATH="" RELATIVE="" BEST_LEN=-1 TARGET_LEN RAW_LIST=""
    RESOLVED=$(user_home_resolve_path "$HOME_DIR") || return 1
    LIST=$(mktemp) || return 1
    if [ -n "${USER_MOUNTINFO_FILE:-}" ]; then
        [ -r "$USER_MOUNTINFO_FILE" ] \
            && awk 'NF >= 5 {print $3 "\t" $4 "\t" $5}' \
                "$USER_MOUNTINFO_FILE" > "$LIST" 2>/dev/null || {
            rm -f "$LIST"
            return 1
        }
    elif [ -r /proc/self/mountinfo ]; then
        if ! awk 'NF >= 5 {print $3 "\t" $4 "\t" $5}' \
            /proc/self/mountinfo > "$LIST" 2>/dev/null; then
            rm -f "$LIST"
            return 1
        fi
    elif command -v findmnt >/dev/null 2>&1; then
        RAW_LIST=$(mktemp) || {
            rm -f "$LIST"
            return 1
        }
        if ! LC_ALL=C findmnt -rn -o MAJ:MIN,FSROOT,TARGET \
            > "$RAW_LIST" 2>/dev/null \
            || ! awk 'NF >= 3 {print $1 "\t" $2 "\t" $3}' \
                "$RAW_LIST" > "$LIST" 2>/dev/null; then
            rm -f "$RAW_LIST"
            rm -f "$LIST"
            return 1
        fi
        rm -f "$RAW_LIST"
    else
        rm -f "$LIST"
        [ "${VPS_TOOLS_TEST_MODE:-0}" = 1 ] && return 0
        return 1
    fi
    [ -s "$LIST" ] || {
        rm -f "$LIST"
        return 1
    }
    while IFS=$'\t' read -r MOUNT_DEV MOUNT_ROOT MOUNT_TARGET; do
        [ -n "$MOUNT_DEV" ] && [ -n "$MOUNT_ROOT" ] && [ -n "$MOUNT_TARGET" ] \
            || continue
        MOUNT_ROOT=$(printf '%b' "$MOUNT_ROOT") || {
            rm -f "$LIST"
            return 1
        }
        MOUNT_TARGET=$(printf '%b' "$MOUNT_TARGET") || {
            rm -f "$LIST"
            return 1
        }
        if [ "$MOUNT_TARGET" = / ]; then
            case "$RESOLVED" in /*)
                TARGET_LEN=1
                if [ "$TARGET_LEN" -gt "$BEST_LEN" ]; then
                    BEST_LEN=$TARGET_LEN
                    HOME_MOUNT_DEV="$MOUNT_DEV"
                    HOME_MOUNT_ROOT="$MOUNT_ROOT"
                    HOME_MOUNT_TARGET="$MOUNT_TARGET"
                fi
                ;;
            esac
        else
            case "$RESOLVED" in
                "$MOUNT_TARGET"|"$MOUNT_TARGET"/*)
                    TARGET_LEN=${#MOUNT_TARGET}
                    if [ "$TARGET_LEN" -gt "$BEST_LEN" ]; then
                        BEST_LEN=$TARGET_LEN
                        HOME_MOUNT_DEV="$MOUNT_DEV"
                        HOME_MOUNT_ROOT="$MOUNT_ROOT"
                        HOME_MOUNT_TARGET="$MOUNT_TARGET"
                    fi
                    ;;
            esac
        fi
        case "$MOUNT_TARGET" in
            "$RESOLVED"|"$RESOLVED"/*)
                rm -f "$LIST"
                return 1
                ;;
        esac
    done < "$LIST"
    [ -n "$HOME_MOUNT_DEV" ] && [ -n "$HOME_MOUNT_TARGET" ] || {
        rm -f "$LIST"
        return 1
    }
    if [ "$HOME_MOUNT_TARGET" = "$RESOLVED" ]; then
        HOME_FS_PATH="$HOME_MOUNT_ROOT"
    else
        RELATIVE=${RESOLVED#"$HOME_MOUNT_TARGET"}
        HOME_FS_PATH="${HOME_MOUNT_ROOT%/}/${RELATIVE#/}"
        [ -n "$HOME_FS_PATH" ] || HOME_FS_PATH=/
    fi
    while IFS=$'\t' read -r MOUNT_DEV MOUNT_ROOT MOUNT_TARGET; do
        [ "$MOUNT_DEV" = "$HOME_MOUNT_DEV" ] || continue
        MOUNT_ROOT=$(printf '%b' "$MOUNT_ROOT") || {
            rm -f "$LIST"
            return 1
        }
        MOUNT_TARGET=$(printf '%b' "$MOUNT_TARGET") || {
            rm -f "$LIST"
            return 1
        }
        if [ "$MOUNT_ROOT" = "$HOME_MOUNT_ROOT" ] \
            && [ "$MOUNT_TARGET" = "$HOME_MOUNT_TARGET" ]; then
            continue
        fi
        case "$MOUNT_TARGET" in "$RESOLVED"|"$RESOLVED"/*) continue ;; esac
        if [ "$MOUNT_ROOT" = / ]; then
            rm -f "$LIST"
            return 1
        fi
        case "$MOUNT_ROOT" in
            "$HOME_FS_PATH"|"$HOME_FS_PATH"/*)
                rm -f "$LIST"
                return 1
                ;;
        esac
        case "$HOME_FS_PATH" in
            "$MOUNT_ROOT"|"$MOUNT_ROOT"/*)
                rm -f "$LIST"
                return 1
                ;;
        esac
    done < "$LIST"
    rm -f "$LIST"
    return 0
}

user_home_safe_to_remove() {
    local HOME_DIR="$1" RESOLVED
    RESOLVED=$(user_home_resolve_path "$HOME_DIR") || return 1
    ! user_home_path_protected "$RESOLVED" \
        && user_home_mounts_safe "$RESOLVED"
}

user_home_owned_by_uid() {
    local HOME_DIR="$1" EXPECTED_UID="$2" RESOLVED OWNER_UID
    [[ "$EXPECTED_UID" =~ ^[0-9]+$ ]] || return 1
    RESOLVED=$(user_home_resolve_path "$HOME_DIR") || return 1
    OWNER_UID=$(stat -c '%u' -- "$RESOLVED" 2>/dev/null) || return 1
    [[ "$OWNER_UID" =~ ^[0-9]+$ ]] && [ "$OWNER_UID" = "$EXPECTED_UID" ]
}

user_home_stat_owner_mode() {
    stat -c '%u:%a' -- "$1" 2>/dev/null
}

user_home_ancestor_acl_safe() {
    local ANCESTOR="$1" ACL MODE_TEXT
    if ! command -v getfacl >/dev/null 2>&1; then
        MODE_TEXT=$(LC_ALL=C ls -ld -- "$ANCESTOR" 2>/dev/null \
            | awk 'NR == 1 {print $1}') || return 1
        [ -n "$MODE_TEXT" ] || return 1
        case "$MODE_TEXT" in
            *+) return 1 ;;
        esac
        return 0
    fi
    ACL=$(getfacl -cp -- "$ANCESTOR" 2>/dev/null) || return 1
    if printf '%s\n' "$ACL" | awk -F: '
        /^user:[^:]+:/ && $3 ~ /w/ {bad=1}
        /^group:/ && $3 ~ /w/ {bad=1}
        /^other::/ && $3 ~ /w/ {bad=1}
        END {exit !bad}
    '; then
        return 1
    fi
    return 0
}

user_home_ancestors_root_safe() {
    local HOME_DIR="$1" RESOLVED ANCESTOR META OWNER MODE MODE_VALUE
    RESOLVED=$(user_home_resolve_path "$HOME_DIR") || return 1
    ANCESTOR=$(dirname -- "$RESOLVED") || return 1
    while :; do
        META=$(user_home_stat_owner_mode "$ANCESTOR") || return 1
        OWNER=${META%%:*}
        MODE=${META#*:}
        [[ "$OWNER" =~ ^[0-9]+$ ]] && [ "$OWNER" = 0 ] || return 1
        [[ "$MODE" =~ ^[0-7]{3,4}$ ]] || return 1
        MODE_VALUE=$((8#$MODE))
        (( (MODE_VALUE & 0022) == 0 )) || return 1

        # Mode bits do not expose named POSIX ACL grants. Be conservative when
        # getfacl is available: any non-owner write grant makes the ancestor
        # replaceable by a non-root principal.
        user_home_ancestor_acl_safe "$ANCESTOR" || return 1
        [ "$ANCESTOR" != "/" ] || break
        ANCESTOR=$(dirname -- "$ANCESTOR") || return 1
    done
}

user_home_path_snapshot() {
    local HOME_DIR="$1" RESOLVED REL COMPONENT CURRENT="/" IDENTITY
    local COMPONENTS=()
    RESOLVED=$(user_home_resolve_path "$HOME_DIR") || return 1
    IDENTITY=$(stat -c '%d:%i' -- / 2>/dev/null) || return 1
    printf '%s\n' "$IDENTITY"
    REL=${RESOLVED#/}
    IFS='/' read -r -a COMPONENTS <<< "$REL"
    for COMPONENT in "${COMPONENTS[@]}"; do
        [ -n "$COMPONENT" ] || continue
        if [ "$CURRENT" = "/" ]; then
            CURRENT="/$COMPONENT"
        else
            CURRENT="$CURRENT/$COMPONENT"
        fi
        IDENTITY=$(stat -c '%d:%i' -- "$CURRENT" 2>/dev/null) || return 1
        printf '%s\n' "$IDENTITY"
    done
}

user_home_paths_overlap() {
    local TARGET_HOME="$1" OTHER_HOME="$2"
    [ "$TARGET_HOME" != "$OTHER_HOME" ] || return 0
    case "$OTHER_HOME/" in
        "$TARGET_HOME/"*) return 0 ;;
    esac
    case "$TARGET_HOME/" in
        "$OTHER_HOME/"*)
            user_home_path_protected "$OTHER_HOME" && return 1
            return 0
            ;;
    esac
    return 1
}

user_home_path_identity() {
    stat -Lc '%d:%i' -- "$1" 2>/dev/null
}

user_home_component_identities() {
    local HOME_DIR="$1" RESOLVED REL COMPONENT CURRENT="/" IDENTITY
    local COMPONENTS=()
    RESOLVED=$(user_home_canonical_path "$HOME_DIR") || return 1
    REL=${RESOLVED#/}
    IFS='/' read -r -a COMPONENTS <<< "$REL"
    for COMPONENT in "${COMPONENTS[@]}"; do
        [ -n "$COMPONENT" ] || continue
        if [ "$CURRENT" = "/" ]; then
            CURRENT="/$COMPONENT"
        else
            CURRENT="$CURRENT/$COMPONENT"
        fi
        IDENTITY=$(user_home_path_identity "$CURRENT") || return 1
        printf '%s\n' "$IDENTITY"
    done
}

user_home_is_shared() {
    local USERNAME="$1" HOME_DIR="$2" TARGET_HOME TARGET_ID TARGET_COMPONENTS ACCOUNT_RECORDS
    local OTHER_USER OTHER_HOME OTHER_RESOLVED OTHER_ID OTHER_COMPONENTS TARGET_TEXT OTHER_TEXT
    TARGET_HOME=$(user_home_resolve_path "$HOME_DIR") || return 0
    TARGET_TEXT=$(user_home_normalize_text "$HOME_DIR") || return 0
    TARGET_ID=$(user_home_path_identity "$TARGET_HOME") || return 0
    TARGET_COMPONENTS=$(user_home_component_identities "$TARGET_HOME") || return 0

    if [ "$USER_PASSWD_FILE" = "/etc/passwd" ] && command -v getent >/dev/null 2>&1; then
        ACCOUNT_RECORDS=$(getent passwd 2>/dev/null) \
            || ACCOUNT_RECORDS=$(cat "$USER_PASSWD_FILE" 2>/dev/null) \
            || return 0
    else
        ACCOUNT_RECORDS=$(cat "$USER_PASSWD_FILE" 2>/dev/null) || return 0
    fi
    [ -n "$ACCOUNT_RECORDS" ] || return 0

    while IFS=: read -r OTHER_USER _ _ _ _ OTHER_HOME _; do
        [ -n "$OTHER_USER" ] || continue
        [ "$OTHER_USER" != "$USERNAME" ] || continue
        if OTHER_TEXT=$(user_home_normalize_text "$OTHER_HOME"); then
            ! user_home_paths_overlap "$TARGET_TEXT" "$OTHER_TEXT" || return 0
        fi
        OTHER_RESOLVED=$(user_home_canonical_path "$OTHER_HOME") || continue
        ! user_home_paths_overlap "$TARGET_HOME" "$OTHER_RESOLVED" || return 0
        OTHER_ID=$(user_home_path_identity "$OTHER_RESOLVED") || continue
        [ "$OTHER_ID" != "$TARGET_ID" ] || return 0
        OTHER_COMPONENTS=$(user_home_component_identities "$OTHER_RESOLVED") || return 0
        printf '%s\n' "$OTHER_COMPONENTS" \
            | awk -v identity="$TARGET_ID" '$0 == identity {found=1} END {exit !found}' \
            && return 0
        if ! user_home_path_protected "$OTHER_RESOLVED"; then
            printf '%s\n' "$TARGET_COMPONENTS" \
                | awk -v identity="$OTHER_ID" '$0 == identity {found=1} END {exit !found}' \
                && return 0
        fi
    done <<< "$ACCOUNT_RECORDS"
    return 1
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
    local USERNAME="$1" REMOVE_RC=1 SUDOERS_TARGET
    SUDOERS_TARGET="$USER_SUDOERS_DIR/vps-tools-$USERNAME"
    if command -v userdel >/dev/null 2>&1; then
        if userdel -r "$USERNAME" >/dev/null 2>&1; then
            REMOVE_RC=0
        elif userdel "$USERNAME" >/dev/null 2>&1; then
            REMOVE_RC=2
        fi
    elif command -v deluser >/dev/null 2>&1; then
        if deluser --remove-home "$USERNAME" >/dev/null 2>&1; then
            REMOVE_RC=0
        elif deluser "$USERNAME" >/dev/null 2>&1; then
            REMOVE_RC=2
        fi
    fi
    if user_account_exists "$USERNAME"; then
        error "创建回滚失败：账号 $USERNAME 仍然存在，必须立即人工处理"
        return 1
    fi
    if ! rm -f -- "$SUDOERS_TARGET" 2>/dev/null \
        || [ -e "$SUDOERS_TARGET" ] || [ -L "$SUDOERS_TARGET" ]; then
        error "创建回滚后仍有 sudoers 残留：$SUDOERS_TARGET"
        return 1
    fi
    [ "$REMOVE_RC" -eq 0 ] || {
        warn "账号已回滚，但主目录可能未完整清理，请人工核对 /home/$USERNAME"
        return 2
    }
    return 0
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

user_in_group() {
    local USERNAME="$1" GROUP_NAME="$2"
    id -nG "$USERNAME" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$GROUP_NAME"
}

user_remove_from_group() {
    local USERNAME="$1" GROUP_NAME="$2"
    if command -v gpasswd >/dev/null 2>&1; then
        gpasswd -d "$USERNAME" "$GROUP_NAME"
    elif command -v deluser >/dev/null 2>&1; then
        deluser "$USERNAME" "$GROUP_NAME"
    elif command -v delgroup >/dev/null 2>&1; then
        delgroup "$USERNAME" "$GROUP_NAME"
    else
        error "系统缺少 gpasswd/deluser/delgroup，无法撤销用户组权限"
        return 1
    fi
}

user_has_sudo_access() {
    local USERNAME="$1" SUDO_OUTPUT
    command -v sudo >/dev/null 2>&1 || return 1
    SUDO_OUTPUT=$(LC_ALL=C sudo -n -l -U "$USERNAME" 2>&1) || return 1
    printf '%s\n' "$SUDO_OUTPUT" \
        | grep -Eq '^User .+ may run the following commands( on .+)?:[[:space:]]*$'
}

user_print_sudo_access_report() {
    local USERNAME="$1"
    command -v sudo >/dev/null 2>&1 || return 1
    echo ""
    warn "检测到其他 sudo 授权来源，以下为 sudo 的实际权限报告："
    LC_ALL=C sudo -n -l -U "$USERNAME" 2>&1 | sed 's/^/    /'
}

user_is_admin_account() {
    local USERNAME="$1"
    [ "$USERNAME" = "root" ] && return 0
    user_in_group "$USERNAME" sudo && return 0
    user_in_group "$USERNAME" wheel && return 0
    [ -f "$USER_SUDOERS_DIR/vps-tools-$USERNAME" ] && return 0
    user_has_sudo_access "$USERNAME"
}

user_admin_target_allowed() {
    local USERNAME="$1" USER_ID="$2"
    [ "$USERNAME" != "root" ] && user_password_target_allowed "$USERNAME" "$USER_ID"
}

user_is_elevation_account() {
    local USERNAME="$1" PROTECTED_USER
    for PROTECTED_USER in "${SUDO_USER:-}" "${DOAS_USER:-}"; do
        [ -z "$PROTECTED_USER" ] || [ "$USERNAME" != "$PROTECTED_USER" ] || return 0
    done
    return 1
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
    { [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; } || {
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
}

user_rollback_admin_group() {
    local USERNAME="$1" ADMIN_GROUP="$2" GROUP_ADDED="$3"
    [ "$GROUP_ADDED" = 1 ] || return 0
    if user_remove_from_group "$USERNAME" "$ADMIN_GROUP" >/dev/null 2>&1 \
        && ! user_in_group "$USERNAME" "$ADMIN_GROUP"; then
        return 0
    fi
    error "授权回滚不完整：$USERNAME 仍可能属于 $ADMIN_GROUP 管理员组"
    audit_action "授予用户 $USERNAME 管理权限后用户组回滚不完整" PARTIAL
    return 1
}

user_grant_admin() {
    local USERNAME="$1" ADMIN_GROUP="" SUDOERS_TARGET GROUP_ADDED=0
    user_ensure_sudo || {
        error "sudo 安装或检测失败"
        return 1
    }
    if user_group_exists sudo; then
        ADMIN_GROUP=sudo
    elif user_group_exists wheel; then
        ADMIN_GROUP=wheel
    fi
    if [ -n "$ADMIN_GROUP" ] && ! user_in_group "$USERNAME" "$ADMIN_GROUP"; then
        user_add_to_group "$USERNAME" "$ADMIN_GROUP" || {
            error "无法将 $USERNAME 加入 $ADMIN_GROUP 组"
            return 1
        }
        GROUP_ADDED=1
    fi
    if ! user_write_sudoers "$USERNAME"; then
        user_rollback_admin_group "$USERNAME" "$ADMIN_GROUP" "$GROUP_ADDED" \
            || return 2
        return 1
    fi
    SUDOERS_TARGET="$USER_SUDOERS_DIR/vps-tools-$USERNAME"
    if ! user_has_sudo_access "$USERNAME"; then
        if ! rm -f -- "$SUDOERS_TARGET" \
            || [ -e "$SUDOERS_TARGET" ] || [ -L "$SUDOERS_TARGET" ]; then
            user_rollback_admin_group \
                "$USERNAME" "$ADMIN_GROUP" "$GROUP_ADDED" || true
            error "sudo 验证失败且授权规则无法撤销：$SUDOERS_TARGET"
            warn "账号可能仍拥有 root 权限，请立即使用 visudo 人工处理"
            audit_action "授予用户 $USERNAME 管理权限后回滚不完整" PARTIAL
            return 2
        fi
        if ! user_rollback_admin_group \
            "$USERNAME" "$ADMIN_GROUP" "$GROUP_ADDED"; then
            warn "sudoers 规则已删除，但管理员组权限可能仍然存在"
            return 2
        fi
        error "sudo 未识别新管理员规则，已撤销授权"
        return 1
    fi
    info "已授予 $USERNAME sudo 管理权限 ✓"
}

user_revoke_admin_rights() {
    local USERNAME="$1" GROUP_NAME REMOVED_GROUPS="" SUDOERS_TARGET
    SUDOERS_TARGET="$USER_SUDOERS_DIR/vps-tools-$USERNAME"
    for GROUP_NAME in sudo wheel; do
        user_group_exists "$GROUP_NAME" || continue
        user_in_group "$USERNAME" "$GROUP_NAME" || continue
        if ! user_remove_from_group "$USERNAME" "$GROUP_NAME"; then
            for GROUP_NAME in $REMOVED_GROUPS; do
                user_add_to_group "$USERNAME" "$GROUP_NAME" >/dev/null 2>&1 || true
            done
            error "无法将 $USERNAME 移出管理员组，已尝试恢复先前状态"
            return 1
        fi
        REMOVED_GROUPS="${REMOVED_GROUPS}${REMOVED_GROUPS:+ }$GROUP_NAME"
    done
    if [ ! -e "$SUDOERS_TARGET" ] && [ -z "$REMOVED_GROUPS" ]; then
        error "管理员权限来自其他 sudoers 规则，脚本无法安全自动修改"
        warn "请运行 visudo 和 visudo -f /etc/sudoers.d/<文件> 人工核对"
        return 1
    fi
    if [ -e "$SUDOERS_TARGET" ] && ! rm -f "$SUDOERS_TARGET"; then
        for GROUP_NAME in $REMOVED_GROUPS; do
            user_add_to_group "$USERNAME" "$GROUP_NAME" >/dev/null 2>&1 || true
        done
        error "无法删除管理员 sudoers 规则，已尝试恢复用户组"
        return 1
    fi
    if user_has_sudo_access "$USERNAME"; then
        warn "$USERNAME 仍通过其他 sudoers 规则或用户组拥有 sudo 权限"
        warn "常规管理员权限已撤销，但需要人工检查剩余授权来源"
        return 2
    fi
    return 0
}

user_create_account() {
    local ROLE="$1" ROLE_LABEL="普通" USERNAME="" LOGIN_SHELL SUDOERS_TARGET
    local GRANT_RC=0
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
    if [ -e "$SUDOERS_TARGET" ] || [ -L "$SUDOERS_TARGET" ]; then
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
        if user_remove_created_account "$USERNAME"; then
            audit_action "创建${ROLE_LABEL}用户 $USERNAME" FAILED
        else
            audit_action "创建${ROLE_LABEL}用户 $USERNAME（回滚不完整）" PARTIAL
            error "未完成用户的自动回滚不完整，请立即人工检查账号、主目录和 sudoers"
        fi
        return 1
    fi
    if [ "$ROLE" = admin ]; then
        user_grant_admin "$USERNAME"
        GRANT_RC=$?
        if [ "$GRANT_RC" -ne 0 ]; then
            warn "管理员授权失败，正在删除未完成的用户"
            if user_remove_created_account "$USERNAME"; then
                audit_action "创建管理员用户 $USERNAME" FAILED
            else
                audit_action "创建管理员用户 $USERNAME（回滚不完整）" PARTIAL
                error "管理员创建回滚不完整，请立即人工检查账号、组成员和 sudoers"
            fi
            return 1
        fi
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

user_promote_admin() {
    local USERNAME="" RECORD USER_ID HOME_DIR LOGIN_SHELL GRANT_RC=0
    user_require_root || return 1
    print_header "增加管理员"
    read -rp "  输入要提升为管理员的用户名（输入 0 返回）: " USERNAME
    [ "$USERNAME" != "0" ] || return 0
    RECORD=$(user_account_record "$USERNAME")
    if [ -z "$RECORD" ]; then
        error "用户 $USERNAME 不存在"
        return 1
    fi
    IFS=: read -r _ _ USER_ID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    if ! user_admin_target_allowed "$USERNAME" "$USER_ID"; then
        error "拒绝提升 root 或系统服务账号：$USERNAME"
        warn "该功能只用于把现有普通用户提升为 sudo 管理员"
        return 1
    fi
    if user_is_admin_account "$USERNAME"; then
        warn "用户 $USERNAME 已经拥有管理员权限"
        return 0
    fi
    confirm_change_preview "增加管理员" \
        "用户名：$USERNAME" "UID：$USER_ID" \
        "主目录：$HOME_DIR" "登录 Shell：$LOGIN_SHELL" \
        "权限：可使用 sudo 执行管理员命令" || return 0
    user_grant_admin "$USERNAME"
    GRANT_RC=$?
    if [ "$GRANT_RC" -ne 0 ]; then
        if [ "$GRANT_RC" -eq 2 ]; then
            audit_action "增加管理员 $USERNAME（回滚不完整）" PARTIAL
            return 2
        fi
        audit_action "增加管理员 $USERNAME" FAILED
        return 1
    fi
    audit_action "增加管理员 $USERNAME" SUCCESS
    info "用户 $USERNAME 已提升为管理员 ✓"
    ui_hint "建议切换到该用户后执行 sudo -v 验证权限"
}

user_revoke_admin() {
    local USERNAME="" RECORD USER_ID HOME_DIR LOGIN_SHELL CONFIRM_NAME REVOKE_RC=0
    user_require_root || return 1
    print_header "撤销管理员权限"
    read -rp "  输入要撤销管理员权限的用户名（输入 0 返回）: " USERNAME
    [ "$USERNAME" != "0" ] || return 0
    RECORD=$(user_account_record "$USERNAME")
    if [ -z "$RECORD" ]; then
        error "用户 $USERNAME 不存在"
        return 1
    fi
    IFS=: read -r _ _ USER_ID _ _ HOME_DIR LOGIN_SHELL <<< "$RECORD"
    if ! user_admin_target_allowed "$USERNAME" "$USER_ID"; then
        error "拒绝撤销 root 或系统服务账号权限：$USERNAME"
        return 1
    fi
    if user_is_elevation_account "$USERNAME"; then
        error "不能撤销当前用于 sudo/doas 提权的账号：$USERNAME"
        warn "请直接使用 root 登录，或通过另一个管理员账号执行"
        return 1
    fi
    if ! user_is_admin_account "$USERNAME"; then
        warn "用户 $USERNAME 当前不是管理员"
        return 0
    fi
    confirm_change_preview "撤销管理员权限" \
        "用户名：$USERNAME" "UID：$USER_ID" \
        "主目录：$HOME_DIR" "登录 Shell：$LOGIN_SHELL" \
        "影响：将移出 sudo/wheel 组，并删除本脚本创建的 sudoers 规则" || return 0
    warn "撤销后该用户将不能再通过常规方式执行 sudo 管理命令"
    read -rp "  输入用户名 $USERNAME 确认撤销（其他输入取消）: " CONFIRM_NAME
    if [ "$CONFIRM_NAME" != "$USERNAME" ]; then
        warn "用户名不匹配，已取消撤销"
        return 0
    fi
    if user_revoke_admin_rights "$USERNAME"; then
        REVOKE_RC=0
    else
        REVOKE_RC=$?
    fi
    case "$REVOKE_RC" in
        0)
            audit_action "撤销管理员权限 $USERNAME" SUCCESS
            info "用户 $USERNAME 的管理员权限已撤销 ✓"
            ;;
        2)
            audit_action "撤销管理员权限 $USERNAME（存在其他授权来源）" PARTIAL
            user_print_sudo_access_report "$USERNAME" || true
            ui_pause
            return 1
            ;;
        *)
            audit_action "撤销管理员权限 $USERNAME" FAILED
            if user_has_sudo_access "$USERNAME"; then
                user_print_sudo_access_report "$USERNAME" || true
                ui_pause
            fi
            return 1
            ;;
    esac
}

user_delete_account() {
    local USERNAME="" RECORD USER_ID HOME_DIR LOGIN_SHELL REMOVE_HOME MODE_LABEL CONFIRM_NAME CHOICE DELETE_RC=0
    local HOME_RESOLVED="" HOME_PATH_SNAPSHOT=""
    local CURRENT_RECORD CURRENT_USER_ID CURRENT_HOME CURRENT_RESOLVED CURRENT_PATH_SNAPSHOT
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
    if ! user_runtime_quiescent "$USERNAME" "当前"; then
        warn "请先确认该用户已退出且全部进程已停止，然后再删除用户"
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
                HOME_RESOLVED=$(user_home_resolve_path "$HOME_DIR") || {
                    error "主目录无法可靠解析，拒绝自动删除：$HOME_DIR"
                    return 1
                }
                if ! user_home_owned_by_uid "$HOME_DIR" "$USER_ID"; then
                    error "主目录所有者与目标账号 UID 不一致，拒绝自动删除：$HOME_RESOLVED"
                    warn "请选择“保留工作空间”，或先人工核对目录所有权"
                    return 1
                fi
                if ! user_home_ancestors_root_safe "$HOME_DIR"; then
                    error "主目录的祖先路径可被非 root 改写，拒绝自动删除：$HOME_RESOLVED"
                    warn "请选择“保留工作空间”，或先修正祖先目录的所有者、权限和 ACL"
                    return 1
                fi
                HOME_PATH_SNAPSHOT=$(user_home_path_snapshot "$HOME_DIR") || {
                    error "无法记录主目录路径的设备/inode 快照，拒绝自动删除"
                    return 1
                }
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
    CURRENT_RECORD=$(user_account_record "$USERNAME")
    [ -n "$CURRENT_RECORD" ] || {
        error "确认期间账号记录已发生变化，删除已取消"
        return 1
    }
    IFS=: read -r _ _ CURRENT_USER_ID _ _ CURRENT_HOME _ <<< "$CURRENT_RECORD"
    if [ "$CURRENT_RECORD" != "$RECORD" ] \
        || [ "$CURRENT_USER_ID" != "$USER_ID" ] \
        || user_is_protected_account "$USERNAME" "$CURRENT_USER_ID" \
        || [ "$CURRENT_HOME" != "$HOME_DIR" ]; then
        error "确认期间账号记录已发生变化，删除已取消"
        return 1
    fi
    if [ "$REMOVE_HOME" = "yes" ]; then
        CURRENT_RESOLVED=$(user_home_resolve_path "$CURRENT_HOME") || {
            error "确认期间主目录已变为不安全路径，删除已取消"
            return 1
        }
        CURRENT_PATH_SNAPSHOT=$(user_home_path_snapshot "$CURRENT_HOME") || {
            error "确认期间无法复核主目录路径身份，删除已取消"
            return 1
        }
        if [ "$CURRENT_RESOLVED" != "$HOME_RESOLVED" ] \
            || [ "$CURRENT_PATH_SNAPSHOT" != "$HOME_PATH_SNAPSHOT" ] \
            || user_home_path_protected "$CURRENT_RESOLVED" \
            || ! user_home_mounts_safe "$CURRENT_RESOLVED" \
            || ! user_home_owned_by_uid "$CURRENT_HOME" "$CURRENT_USER_ID" \
            || ! user_home_ancestors_root_safe "$CURRENT_HOME" \
            || user_home_is_shared "$USERNAME" "$CURRENT_HOME"; then
            error "确认期间账号、主目录或共享关系已发生变化，删除已取消"
            return 1
        fi
    fi
    if ! user_runtime_quiescent "$USERNAME" "确认期间"; then
        error "无法确认账号处于静止状态，删除已取消"
        return 1
    fi
    if [ "$REMOVE_HOME" = yes ] && ! user_home_mounts_safe "$CURRENT_RESOLVED"; then
        error "删除前检测到主目录本身或其子目录出现挂载点，删除已取消"
        return 1
    fi

    info "正在删除用户 $USERNAME..."
    user_delete_system_account "$USERNAME" "$REMOVE_HOME" || DELETE_RC=$?
    if user_account_exists "$USERNAME"; then
        error "用户删除失败，账号可能仍有进程或被系统策略保护"
        audit_action "删除用户 $USERNAME（$MODE_LABEL）" FAILED
        return 1
    fi
    if ! rm -f -- "$USER_SUDOERS_DIR/vps-tools-$USERNAME" 2>/dev/null \
        || [ -e "$USER_SUDOERS_DIR/vps-tools-$USERNAME" ] \
        || [ -L "$USER_SUDOERS_DIR/vps-tools-$USERNAME" ]; then
        error "账号已删除，但 sudoers 授权残留无法清理：$USER_SUDOERS_DIR/vps-tools-$USERNAME"
        audit_action "删除用户 $USERNAME（sudoers 残留）" PARTIAL
        return 1
    fi
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
    local UID_MIN USERNAME USER_ID HOME_DIR LOGIN_SHELL ROLE
    UID_MIN=$(user_uid_min)
    print_header "用户列表"
    printf "  %-18s %-8s %-10s %-24s %s\n" "用户名" "UID" "类型" "主目录" "Shell"
    menu_div
    while IFS=: read -r USERNAME _ USER_ID _ _ HOME_DIR LOGIN_SHELL; do
        [ "$USER_ID" = "0" ] || [ "$USER_ID" -ge "$UID_MIN" ] 2>/dev/null || continue
        [ "$USERNAME" != "nobody" ] || continue
        ROLE=普通用户
        [ "$USER_ID" = "0" ] && ROLE=超级用户
        [ "$USER_ID" = "0" ] || ! user_is_admin_account "$USERNAME" || ROLE=管理员
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
        menu_item "5" "增加管理员  ${DIM}提升现有普通用户${NC}" "$YELLOW"
        menu_item "6" "撤销管理员权限"
        menu_item "7" "删除用户  ${DIM}可选择保留或删除工作空间${NC}" "$RED"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-7]: ')" CHOICE
        case "$CHOICE" in
            1) user_create_account regular ;;
            2) user_create_account admin ;;
            3) user_list_accounts ;;
            4) user_change_password ;;
            5) user_promote_admin ;;
            6) user_revoke_admin ;;
            7) user_delete_account ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

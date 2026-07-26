# ══════════════════════════════════════════════════════════
#  防火墙模块
# ══════════════════════════════════════════════════════════

# ── 检测防火墙类型 ────────────────────────────────────────
# 返回: ufw / firewalld / multiple / ambiguous / none
fw_detect() {
    local UFW_INSTALLED=no FIREWALLD_INSTALLED=no
    local UFW_ACTIVE=no FIREWALLD_ACTIVE=no UFW_STATUS=""
    if command -v ufw >/dev/null 2>&1; then
        UFW_INSTALLED=yes
        UFW_STATUS=$(LC_ALL=C ufw status 2>/dev/null) || {
            printf 'ambiguous\n'
            return 1
        }
        case "$UFW_STATUS" in
            *"Status: active"*) UFW_ACTIVE=yes ;;
            *"Status: inactive"*) ;;
            *) printf 'ambiguous\n'; return 1 ;;
        esac
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        FIREWALLD_INSTALLED=yes
        svc_is_active firewalld && FIREWALLD_ACTIVE=yes
    fi
    if [ "$UFW_ACTIVE" = yes ] && [ "$FIREWALLD_ACTIVE" = yes ]; then
        printf 'ambiguous\n'
    elif [ "$UFW_ACTIVE" = yes ]; then
        printf 'ufw\n'
    elif [ "$FIREWALLD_ACTIVE" = yes ]; then
        printf 'firewalld\n'
    elif [ "$UFW_INSTALLED" = yes ] && [ "$FIREWALLD_INSTALLED" = yes ]; then
        printf 'multiple\n'
    elif [ "$UFW_INSTALLED" = yes ]; then
        printf 'ufw\n'
    elif [ "$FIREWALLD_INSTALLED" = yes ]; then
        printf 'firewalld\n'
    else
        printf 'none\n'
    fi
}

# ── 获取防火墙运行状态 ────────────────────────────────────
fw_running() {
    local TYPE="$1"
    case "$TYPE" in
        ufw)      ufw status 2>/dev/null | grep -q "Status: active" && echo "active" || echo "inactive" ;;
        firewalld) svc_is_active firewalld && echo "active" || echo "inactive" ;;
        *) echo "none" ;;
    esac
}

# ── 放行常用端口（安装防火墙后调用）────────────────────────
fw_allow_common_ports() {
    local TYPE="$1"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    info "放行常用端口：SSH ${SSH_PORT} / HTTP 80 / HTTPS 443 ..."
    case "$TYPE" in
        ufw)
            ufw allow "${SSH_PORT}"/tcp 2>/dev/null || { error "无法放行 SSH ${SSH_PORT}/tcp"; return 1; }
            ufw allow 80/tcp 2>/dev/null || { error "无法放行 HTTP 80/tcp"; return 1; }
            ufw allow 443/tcp 2>/dev/null || { error "无法放行 HTTPS 443/tcp"; return 1; }
            info "SSH ${SSH_PORT} / HTTP 80 / HTTPS 443 已放行 ✓"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null || return 1
            firewall-cmd --permanent --add-port="80/tcp" 2>/dev/null || return 1
            firewall-cmd --permanent --add-port="443/tcp" 2>/dev/null || return 1
            firewall-cmd --reload 2>/dev/null || return 1
            info "firewalld 已放行 SSH ${SSH_PORT} / 80 / 443 ✓"
            ;;
    esac
}

# ── 安装防火墙 ────────────────────────────────────────────
fw_install() {
    local TYPE="$1"
    print_header "安装防火墙"
    info "正在更新软件包列表..."
    case "$TYPE" in
        ufw)
            if pkg_install ufw; then
                info "ufw 安装成功 ✓"
                safety_arm firewall_install_ufw || return 1
                fw_allow_common_ports "ufw" || { error "基础端口放行失败，未启用 ufw"; return 1; }
                if ufw --force enable >/dev/null 2>&1 && [ "$(fw_running ufw)" = active ]; then
                    info "ufw 已启用 ✓"
                else
                    error "ufw 启用失败"
                    return 1
                fi
                safety_confirm
            else
                error "安装失败，请检查网络或手动安装：apt/apk install ufw"
                return 1
            fi
            ;;
        firewalld)
            if pkg_install firewalld; then
                safety_arm firewall_install_firewalld || return 1
                svc_enable firewalld || {
                    error "firewalld 开机自启设置失败，保留自动回滚"
                    return 1
                }
                svc_start firewalld || { error "firewalld 启动失败"; return 1; }
                [ "$(fw_running firewalld)" = active ] || { error "firewalld 未进入运行状态"; return 1; }
                info "firewalld 安装并启动成功 ✓"
                fw_allow_common_ports "firewalld" || { error "基础端口放行失败"; return 1; }
                safety_confirm
            else
                error "安装失败，请检查网络或手动安装"
                return 1
            fi
            ;;
    esac
}

# ══════════════════════════════════════════════════════════
#  UFW 子功能
# ══════════════════════════════════════════════════════════

ufw_show_rules() {
    print_header "防火墙规则 — ufw"
    menu_div
    ufw status numbered 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^\['; then
            echo -e "  ${GREEN}${line}${NC}"
        else
            echo -e "  ${line}"
        fi
    done
    menu_div
}

ufw_add_port() {
    local PORT DIR
    print_header "添加端口规则 — ufw"
    echo -e "  示例：80  或  8080/tcp  或  3000:3010/tcp"
    echo ""
    read -rp "  请输入端口（直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return 2; }
    read -rp "  方向 [in/out，默认 in]: " DIR
    DIR="${DIR:-in}"
    echo ""
    if ufw allow "$DIR" "$PORT" 2>/dev/null || ufw allow "$PORT" 2>/dev/null; then
        info "已放行端口 $PORT ✓"
        return 0
    else
        error "添加失败，请检查端口格式"
        return 1
    fi
}

ufw_del_port() {
    while true; do
        print_header "删除端口规则 — ufw"
        ufw status numbered 2>/dev/null | grep -E '^\[' | while IFS= read -r line; do
            echo -e "  ${YELLOW}${line}${NC}"
        done
        echo ""
        menu_div
        echo -e "  ${DIM}输入编号删除，直接回车返回上级${NC}"
        read -rp "  请输入规则编号: " NUM
        [ -z "$NUM" ] && { warn "已取消"; return 2; }
        if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
            error "无效编号"; sleep 1; continue
        fi
        if echo "y" | ufw delete "$NUM" 2>/dev/null; then
            info "规则 [$NUM] 已删除 ✓"
            return 0
        fi
        error "删除失败"
        return 1
    done
}

ufw_block_ip() {
    local IP
    print_header "拉黑 IP — ufw"
    read -rp "  请输入要拉黑的 IP 或 CIDR（如 1.2.3.4 或 1.2.3.0/24）: " IP
    [ -z "$IP" ] && { warn "已取消"; return 2; }
    if ufw deny from "$IP" to any 2>/dev/null; then
        info "已拉黑 $IP ✓"
        return 0
    fi
    error "操作失败"
    return 1
}

ufw_allow_ip() {
    local IP
    print_header "白名单 IP — ufw"
    read -rp "  请输入要放行的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return 2; }
    if ufw allow from "$IP" to any 2>/dev/null; then
        info "已放行 $IP ✓"
        return 0
    fi
    error "操作失败"
    return 1
}

ufw_del_ip() {
    while true; do
        print_header "删除 IP 规则 — ufw"
        ufw status numbered 2>/dev/null | grep -iE 'deny|allow' | grep -E '^\[' | while IFS= read -r line; do
            echo -e "  ${YELLOW}${line}${NC}"
        done
        echo ""
        menu_div
        echo -e "  ${DIM}输入编号删除，直接回车返回上级${NC}"
        read -rp "  请输入规则编号: " NUM
        [ -z "$NUM" ] && { warn "已取消"; return 2; }
        if echo "y" | ufw delete "$NUM" 2>/dev/null; then
            info "规则 [$NUM] 已删除 ✓"
            return 0
        fi
        error "删除失败"
        return 1
    done
}

ufw_quick_allow() {
    print_header "一键放行常用端口 — ufw"
    local SSH_PORT FAILED=no
    SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT"
    echo -e "  ${GREEN}HTTP${NC}  : 80"
    echo -e "  ${GREEN}HTTPS${NC} : 443"
    echo ""
    read -rp "  确认放行？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return 2; fi
    ufw allow "$SSH_PORT"/tcp && info "SSH $SSH_PORT 已放行 ✓" || FAILED=yes
    ufw allow 80/tcp && info "HTTP 80 已放行 ✓" || FAILED=yes
    ufw allow 443/tcp && info "HTTPS 443 已放行 ✓" || FAILED=yes
    [ "$FAILED" = no ]
}

# ── ufw 子菜单 ────────────────────────────────────────────
ufw_menu() {
    local ACTION_RC=0 RESIDUAL
    while true; do
        local STATUS; STATUS=$(fw_running "ufw")
        local ST_COLOR; [ "$STATUS" = "active" ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"

        print_header "防火墙管理 — ufw"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        echo ""
        menu_div
        if [ "$STATUS" = "active" ]; then
            menu_item "1" "关闭防火墙" "$YELLOW"
        else
            menu_item "1" "开启防火墙"
        fi
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行 IP" "7" "删除 IP 规则"
        menu_item "8" "一键放行常用端口"
        menu_pair "u" "安装 / 更新" "9" "卸载 ufw" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-9 / u]: ')" CH

        case "$CH" in 1|3|4|5|6|7|8) safety_arm ufw || continue ;; esac
        ACTION_RC=0

        case "$CH" in
            u|U)
                print_header "安装/更新 ufw"
                info "正在更新 ufw..."
                local NEW_VER=""
                if pkg_install ufw && command -v ufw >/dev/null 2>&1; then
                    NEW_VER=$(ufw version 2>/dev/null | head -1)
                fi
                if [ -n "$NEW_VER" ]; then
                    info "当前版本：$NEW_VER ✓"
                    audit_action "安装或更新 ufw" SUCCESS
                else
                    error "ufw 安装/更新失败，或无法读取安装后的版本"
                    audit_action "安装或更新 ufw" FAILED
                fi
                sleep 1; continue
                ;;
            1)
                if [ "$STATUS" = "active" ]; then
                    if ufw --force disable; then
                        info "防火墙已关闭 ✓"
                    else
                        error "关闭 ufw 失败"
                        ACTION_RC=1
                    fi
                else
                    if ufw --force enable; then
                        info "防火墙已开启 ✓"
                    else
                        error "开启 ufw 失败"
                        ACTION_RC=1
                    fi
                fi
                [ "$ACTION_RC" -ne 0 ] || audit_action "切换ufw状态" SUCCESS
                ;;
            2) ufw_show_rules ;;
            3) ufw_add_port; ACTION_RC=$? ;;
            4) ufw_del_port; ACTION_RC=$? ;;
            5) ufw_block_ip; ACTION_RC=$? ;;
            6) ufw_allow_ip; ACTION_RC=$? ;;
            7) ufw_del_ip; ACTION_RC=$? ;;
            8) ufw_quick_allow; ACTION_RC=$? ;;
            9)
                local UNINSTALL_FAILED=no
                warn "即将卸载 ufw，所有规则将清除"
                read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
                [ -z "${CONFIRM}" ] && CONFIRM="y"
                if echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then
                    # 完整清理：禁用 → 重置规则 → 卸载 → 清残留
                    warn "即将卸载 ufw 并清理其规则（默认策略与其它规则不受影响）"
                    sleep 1
                    ufw --force disable 2>/dev/null || UNINSTALL_FAILED=yes
                    ufw --force reset 2>/dev/null || UNINSTALL_FAILED=yes
                    pkg_remove ufw || UNINSTALL_FAILED=yes
                    # 清理残留文件（防止重装时读到旧配置）
                    rm -rf /etc/ufw /lib/ufw /usr/share/ufw 2>/dev/null \
                        || UNINSTALL_FAILED=yes
                    clear_iptables_residue || UNINSTALL_FAILED=yes
                    hash -r 2>/dev/null || true
                    command -v ufw >/dev/null 2>&1 && UNINSTALL_FAILED=yes
                    for RESIDUAL in /etc/ufw /lib/ufw /usr/share/ufw; do
                        [ ! -e "$RESIDUAL" ] && [ ! -L "$RESIDUAL" ] \
                            || UNINSTALL_FAILED=yes
                    done
                    if [ "$UNINSTALL_FAILED" = no ]; then
                        info "ufw 已完整卸载 ✓（仅清理 ufw 自身规则，SSH 仍可连接）"
                        audit_action "卸载 ufw" SUCCESS
                        return
                    fi
                    error "ufw 卸载或残留清理不完整，请人工核对软件包与规则"
                    audit_action "卸载 ufw 未完整完成" PARTIAL
                    return 1
                else
                    warn "已取消"
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        case "$CH" in
            1|3|4|5|6|7|8)
                case "$ACTION_RC" in
                    0) safety_confirm ;;
                    2)
                        safety_cancel_current_transaction \
                            || warn "取消操作后未能清理防断联任务，请保持当前连接"
                        ;;
                    *) warn "操作失败或仅完成一部分，自动回滚继续保留" ;;
                esac
                ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

# ══════════════════════════════════════════════════════════
#  Firewalld 子功能
# ══════════════════════════════════════════════════════════

fwd_show_rules() {
    print_header "防火墙规则 — firewalld"
    local ZONE; ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
    echo -e "  默认 Zone：${BOLD}${ZONE}${NC}"
    menu_div
    echo -e "  ${BOLD}已开放端口：${NC}"
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | while read -r p; do
        [ -n "$p" ] && echo -e "    ${GREEN}▸${NC} $p"
    done
    echo ""
    echo -e "  ${BOLD}已开放服务：${NC}"
    firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | while read -r s; do
        [ -n "$s" ] && echo -e "    ${GREEN}▸${NC} $s"
    done
    echo ""
    echo -e "  ${BOLD}拒绝 IP：${NC}"
    firewall-cmd --list-rich-rules 2>/dev/null | grep "reject\|drop" | while IFS= read -r r; do
        echo -e "    ${RED}▸${NC} $r"
    done
    menu_div
}

fwd_add_port() {
    local PORT
    print_header "添加端口规则 — firewalld"
    echo -e "  示例：80/tcp  或  3000-3010/tcp"
    echo ""
    read -rp "  请输入端口（直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return 2; }
    if firewall-cmd --permanent --add-port="$PORT" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null; then
        info "已放行端口 $PORT ✓"
        return 0
    fi
    error "添加失败，请检查格式（需含协议，如 80/tcp）"
    return 1
}

fwd_del_port() {
    local PORT
    print_header "删除端口规则 — firewalld"
    echo -e "  当前开放端口："
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | nl | while read -r i p; do
        echo -e "  ${GREEN}[$i]${NC} $p"
    done
    echo ""
    read -rp "  请输入要删除的端口（如 80/tcp，直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return 2; }
    if firewall-cmd --permanent --remove-port="$PORT" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null; then
        info "端口 $PORT 已删除 ✓"
        return 0
    fi
    error "删除失败"
    return 1
}

fwd_block_ip() {
    local IP
    print_header "拉黑 IP — firewalld"
    read -rp "  请输入要拉黑的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return 2; }
    if firewall-cmd --permanent \
        --add-rich-rule="rule family='ipv4' source address='${IP}' reject" \
        2>/dev/null && firewall-cmd --reload 2>/dev/null; then
        info "已拉黑 $IP ✓"
        return 0
    fi
    error "操作失败"
    return 1
}

fwd_allow_ip() {
    local IP
    print_header "白名单 IP — firewalld"
    read -rp "  请输入要放行的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return 2; }
    if firewall-cmd --permanent \
        --add-rich-rule="rule family='ipv4' source address='${IP}' accept" \
        2>/dev/null && firewall-cmd --reload 2>/dev/null; then
        info "已放行 $IP ✓"
        return 0
    fi
    error "操作失败"
    return 1
}

fwd_del_ip() {
    while true; do
        print_header "删除 IP 规则 — firewalld"
        echo -e "  当前 Rich Rules："
        local RULES; RULES=$(firewall-cmd --list-rich-rules 2>/dev/null)
        if [ -z "$RULES" ]; then
            echo -e "  ${YELLOW}暂无 IP 规则${NC}"
            echo ""
            ui_pause
            return 2
        fi
        local i=1
        while IFS= read -r r; do
            echo -e "  ${YELLOW}[$i]${NC} $r"
            i=$((i+1))
        done <<< "$RULES"
        echo ""
        menu_div
        echo -e "  ${DIM}输入 IP 地址删除，直接回车返回上级${NC}"
        read -rp "  请输入 IP: " IP
        [ -z "$IP" ] && { warn "已取消"; return 2; }
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' reject" 2>/dev/null
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' accept" 2>/dev/null
        if firewall-cmd --reload 2>/dev/null; then
            info "IP $IP 相关规则已删除 ✓"
            return 0
        fi
        error "删除失败"
        return 1
    done
}

fwd_quick_allow() {
    print_header "一键放行常用端口 — firewalld"
    local SSH_PORT FAILED=no
    SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT/tcp"
    echo -e "  ${GREEN}HTTP${NC}  : 80/tcp"
    echo -e "  ${GREEN}HTTPS${NC} : 443/tcp"
    echo ""
    read -rp "  确认放行？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return 2; fi
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" \
        && info "SSH $SSH_PORT 已放行 ✓" || FAILED=yes
    firewall-cmd --permanent --add-port="80/tcp" \
        && info "HTTP 80 已放行 ✓" || FAILED=yes
    firewall-cmd --permanent --add-port="443/tcp" \
        && info "HTTPS 443 已放行 ✓" || FAILED=yes
    firewall-cmd --reload && info "规则已重载 ✓" || FAILED=yes
    [ "$FAILED" = no ]
}

# ── firewalld 子菜单 ──────────────────────────────────────
fwd_menu() {
    local ACTION_RC=0 RESIDUAL
    while true; do
        local STATUS; STATUS=$(fw_running "firewalld")
        local ST_COLOR; [ "$STATUS" = "active" ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"

        print_header "防火墙管理 — firewalld"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        echo ""
        menu_div
        if [ "$STATUS" = "active" ]; then
            menu_item "1" "关闭防火墙" "$YELLOW"
        else
            menu_item "1" "开启防火墙"
        fi
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行 IP" "7" "删除 IP 规则"
        menu_item "8" "一键放行常用端口"
        menu_item "9" "卸载 firewalld" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-9]: ')" CH

        case "$CH" in 1|3|4|5|6|7|8) safety_arm firewalld || continue ;; esac
        ACTION_RC=0

        case "$CH" in
            1)
                if [ "$STATUS" = "active" ]; then
                    if svc_stop firewalld; then
                        info "防火墙已关闭 ✓"
                    else
                        error "关闭 firewalld 失败"
                        ACTION_RC=1
                    fi
                else
                    if svc_start firewalld; then
                        info "防火墙已开启 ✓"
                    else
                        error "开启 firewalld 失败"
                        ACTION_RC=1
                    fi
                fi
                [ "$ACTION_RC" -ne 0 ] \
                    || audit_action "切换firewalld状态" SUCCESS
                ;;
            2) fwd_show_rules ;;
            3) fwd_add_port; ACTION_RC=$? ;;
            4) fwd_del_port; ACTION_RC=$? ;;
            5) fwd_block_ip; ACTION_RC=$? ;;
            6) fwd_allow_ip; ACTION_RC=$? ;;
            7) fwd_del_ip; ACTION_RC=$? ;;
            8) fwd_quick_allow; ACTION_RC=$? ;;
            9)
                local UNINSTALL_FAILED=no
                warn "即将卸载 firewalld，所有规则将清除"
                read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
                [ -z "${CONFIRM}" ] && CONFIRM="y"
                if echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then
                    if svc_is_active firewalld; then
                        svc_stop firewalld || UNINSTALL_FAILED=yes
                    fi
                    svc_disable firewalld || UNINSTALL_FAILED=yes
                    pkg_remove firewalld || UNINSTALL_FAILED=yes
                    # 清理残留配置
                    rm -rf /etc/firewalld/zones /etc/firewalld/services \
                        2>/dev/null || UNINSTALL_FAILED=yes
                    clear_iptables_residue || UNINSTALL_FAILED=yes
                    hash -r 2>/dev/null || true
                    command -v firewall-cmd >/dev/null 2>&1 \
                        && UNINSTALL_FAILED=yes
                    for RESIDUAL in /etc/firewalld/zones /etc/firewalld/services; do
                        [ ! -e "$RESIDUAL" ] && [ ! -L "$RESIDUAL" ] \
                            || UNINSTALL_FAILED=yes
                    done
                    if [ "$UNINSTALL_FAILED" = no ]; then
                        info "firewalld 已完整卸载 ✓（仅清理 firewalld 自身规则）"
                        audit_action "卸载 firewalld" SUCCESS
                        return
                    fi
                    error "firewalld 卸载或残留清理不完整，请人工核对软件包与规则"
                    audit_action "卸载 firewalld 未完整完成" PARTIAL
                    return 1
                else
                    warn "已取消"
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        case "$CH" in
            1|3|4|5|6|7|8)
                case "$ACTION_RC" in
                    0) safety_confirm ;;
                    2)
                        safety_cancel_current_transaction \
                            || warn "取消操作后未能清理防断联任务，请保持当前连接"
                        ;;
                    *) warn "操作失败或仅完成一部分，自动回滚继续保留" ;;
                esac
                ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

# ══════════════════════════════════════════════════════════
#  防火墙总入口
# ══════════════════════════════════════════════════════════
firewall_menu() {
    while true; do
        local FW_TYPE; FW_TYPE=$(fw_detect)

        if [ "$FW_TYPE" = "ambiguous" ]; then
            error "检测到多个活跃防火墙或无法可靠读取状态，拒绝自动选择管理后端"
            warn "请先人工确认 ufw 与 firewalld 的运行状态"
            ui_pause
            return 1
        fi
        if [ "$FW_TYPE" = "multiple" ]; then
            print_header "防火墙管理"
            warn "ufw 与 firewalld 均已安装但当前都未运行，请明确选择要管理的后端。"
            menu_item "1" "管理 ufw"
            menu_item "2" "管理 firewalld"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            read -rp "$(ui_prompt '选择防火墙 [0-2]: ')" CH
            case "$CH" in
                1) ufw_menu; return ;;
                2) fwd_menu; return ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi
        if [ "$FW_TYPE" = "none" ]; then
            print_header "防火墙管理"
            warn "未检测到已安装的防火墙！"
            echo ""
            menu_div
            echo -e "  请选择要安装的防火墙："
            menu_item "1" "ufw  ${DIM}Ubuntu / Debian 推荐${NC}"
            menu_item "2" "firewalld  ${DIM}Rocky / Fedora 推荐${NC}"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            menu_div
            echo ""
            read -rp "$(ui_prompt '选择防火墙 [0-2]: ')" CH
            case "$CH" in
                1) fw_install "ufw";       ui_continue ;;
                2) fw_install "firewalld"; ui_continue ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi

        # 已安装：直接进子菜单，子菜单按 0 返回后退出 firewall_menu
        case "$FW_TYPE" in
            ufw)       ufw_menu ;;
            firewalld) fwd_menu ;;
        esac
        # 子菜单返回后（按 0 或卸载后）直接返回主菜单
        return
    done
}

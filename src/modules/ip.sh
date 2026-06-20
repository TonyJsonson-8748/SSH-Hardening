# ══════════════════════════════════════════════════════════
#  IPv4/IPv6 配置模块
# ══════════════════════════════════════════════════════════

ip_show_status() {
    print_header "IPv4 / IPv6 状态"

    # ── IPv4 状态 ──────────────────────────────────────────
    echo -e "  ${BOLD}IPv4：${NC}"
    local V4_ADDRS
    V4_ADDRS=$(ip -4 addr show scope global 2>/dev/null | grep "inet " | awk '{print $2}')
    if [ -n "$V4_ADDRS" ]; then
        while IFS= read -r addr; do
            echo -e "    ${GREEN}▸${NC} $addr"
        done <<< "$V4_ADDRS"
    else
        echo -e "    ${YELLOW}未检测到 IPv4 地址${NC}"
    fi

    # ── IPv6 状态 ──────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}IPv6：${NC}"
    local V6_DISABLED
    V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$V6_DISABLED" = "1" ]; then
        echo -e "    ${RED}▸ IPv6 已禁用${NC}"
    else
        local V6_ADDRS
        V6_ADDRS=$(ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print $2}')
        if [ -n "$V6_ADDRS" ]; then
            while IFS= read -r addr; do
                echo -e "    ${GREEN}▸${NC} $addr"
            done <<< "$V6_ADDRS"
        else
            echo -e "    ${YELLOW}▸ IPv6 已启用但无全局地址${NC}"
        fi
    fi

    # ── 优先级状态 ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}优先级策略：${NC}"
    local GAICONF="/etc/gai.conf"
    if grep -q "^precedence ::ffff:0:0/96  100" "$GAICONF" 2>/dev/null; then
        echo -e "    ${CYAN}▸ 当前优先：IPv4${NC}"
    else
        echo -e "    ${CYAN}▸ 当前优先：IPv6（系统默认）${NC}"
    fi

    # ── 默认路由 ───────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}默认路由：${NC}"
    ip -4 route show default 2>/dev/null | while IFS= read -r r; do
        echo -e "    ${GREEN}v4${NC} $r"
    done
    ip -6 route show default 2>/dev/null | while IFS= read -r r; do
        echo -e "    ${CYAN}v6${NC} $r"
    done
}

ip_prefer_v4() {
    print_header "设置 IPv4 优先"
    local GAICONF="/etc/gai.conf"
    confirm_change_preview "IPv4 优先" "写入 gai.conf 地址优先级规则" "不关闭 IPv6" || { warn "已取消"; return; }
    safety_arm prefer_v4 || return 1

    # 备份
    cp "$GAICONF" "${GAICONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

    # 注释掉已有的 precedence ::ffff 行，再追加正确的
    sed -i '/^precedence ::ffff:0:0\/96/d' "$GAICONF" 2>/dev/null
    # 确保文件存在
    [ -f "$GAICONF" ] || touch "$GAICONF"
    echo "precedence ::ffff:0:0/96  100" >> "$GAICONF"

    info "已写入 IPv4 优先规则到 $GAICONF ✓"

    # 同时通过 sysctl 设置（影响内核层面）
    sysctl -w net.ipv4.conf.all.promote_secondaries=1 &>/dev/null

    echo ""
    warn "IPv4 优先已生效，部分程序需重启才能感知变化"
    echo ""
    echo -e "  验证（应显示 IPv4 连接）："
    echo -e "  ${DIM}curl -s --max-time 5 ip.sb${NC}"
    local RESULT; RESULT=$(curl -s --max-time 5 ip.sb 2>/dev/null)
    [ -n "$RESULT" ] && echo -e "  当前出口 IP：${BOLD}${RESULT}${NC}" || warn "无法连接 ip.sb 进行验证"
    audit_action "设置IPv4优先" SUCCESS
    safety_confirm
}

ip_prefer_v6() {
    print_header "设置 IPv6 优先"
    local GAICONF="/etc/gai.conf"
    confirm_change_preview "IPv6 优先" "移除脚本写入的 IPv4 优先规则" "恢复系统默认地址选择策略" || { warn "已取消"; return; }
    safety_arm prefer_v6 || return 1

    [ -f "$GAICONF" ] && cp "$GAICONF" "${GAICONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    [ -f "$GAICONF" ] || touch "$GAICONF"

    # 移除本脚本写入的 IPv4 优先规则，恢复 glibc 默认地址选择策略（IPv6 优先）。
    sed -i '/^precedence ::ffff:0:0\/96[[:space:]]\+100/d' "$GAICONF" 2>/dev/null

    info "已移除 IPv4 优先规则，恢复 IPv6 优先（系统默认）✓"
    echo ""
    warn "IPv6 优先已生效，部分程序需重启才能感知变化"
    echo ""
    echo -e "  验证（如网络可用，应显示 IPv6 连接）："
    echo -e "  ${DIM}curl -6 -s --max-time 5 ip.sb${NC}"
    local RESULT; RESULT=$(curl -6 -s --max-time 5 ip.sb 2>/dev/null)
    [ -n "$RESULT" ] && echo -e "  当前 IPv6 出口：${BOLD}${RESULT}${NC}" || warn "无法通过 IPv6 连接 ip.sb 进行验证"
    audit_action "设置IPv6优先" SUCCESS
    safety_confirm
}

ip_disable_v6() {
    print_header "关闭 IPv6"
    warn "关闭 IPv6 后，仅 IPv6 的服务将无法访问！"
    echo ""
    read -rp "  确认关闭？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    confirm_change_preview "关闭 IPv6" "立即禁用所有接口 IPv6" "写入 sysctl 持久化配置" || { warn "已取消"; return; }
    safety_arm disable_v6 || return 1

    local SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"

    # 写入 sysctl
    for KEY in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
        if grep -q "^${KEY}" "$SYSCTL_FILE" 2>/dev/null; then
            sed -i "s|^${KEY}.*|${KEY} = 1|" "$SYSCTL_FILE"
        else
            echo "${KEY} = 1" >> "$SYSCTL_FILE"
        fi
    done

    ensure_sysctl && sysctl -p "$SYSCTL_FILE" &>/dev/null
    info "IPv6 已通过 sysctl 禁用 ✓"

    # 立即生效（无需重启）
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null

    echo ""
    echo -e "  当前 IPv6 状态：${RED}${BOLD}已禁用${NC}"
    warn "如 SSH 监听了 IPv6，建议确认 SSH 配置正常后再断开连接"
    audit_action "关闭IPv6" SUCCESS
    safety_confirm
}

ip_enable_v6() {
    print_header "开启 IPv6"
    local SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"
    confirm_change_preview "开启 IPv6" "移除 IPv6 禁用状态" "地址获取取决于服务商和 SLAAC" || { warn "已取消"; return; }
    safety_arm enable_v6 || return 1

    # 移除或改为 0
    for KEY in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
        if grep -q "^${KEY}" "$SYSCTL_FILE" 2>/dev/null; then
            sed -i "s|^${KEY}.*|${KEY} = 0|" "$SYSCTL_FILE"
        else
            echo "${KEY} = 0" >> "$SYSCTL_FILE"
        fi
    done

    sysctl -p "$SYSCTL_FILE" &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 &>/dev/null

    info "IPv6 已开启 ✓"
    echo ""

    # 检查是否拿到地址
    sleep 1
    local V6_ADDRS; V6_ADDRS=$(ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print $2}')
    if [ -n "$V6_ADDRS" ]; then
        echo -e "  检测到 IPv6 地址："
        while IFS= read -r addr; do
            echo -e "    ${GREEN}▸${NC} $addr"
        done <<< "$V6_ADDRS"
    else
        warn "已开启但暂未获取到 IPv6 地址，可能需要重启网络服务或等待 SLAAC"
        echo -e "  ${DIM}可尝试：systemctl restart networking 或 reboot${NC}"
    fi
    audit_action "开启IPv6" SUCCESS
    safety_confirm
}

ip_config_menu() {
    while true; do
        print_header "IPv4 / IPv6 配置"

        # 状态摘要
        local V6_DISABLED; V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        local V6_STATUS; [ "$V6_DISABLED" = "1" ] && V6_STATUS="${RED}${BOLD}已禁用${NC}" || V6_STATUS="${GREEN}${BOLD}已启用${NC}"
        local V4_PREF="系统默认（IPv6优先）"
        grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null && V4_PREF="${CYAN}${BOLD}IPv4 优先${NC}"

        echo -e "  IPv6 状态：$V6_STATUS"
        echo -e "  优先级：$V4_PREF"
        echo ""
        menu_div
        menu_item "1" "查看 IPv4 / IPv6 状态"
        menu_pair "2" "设置 IPv4 优先" "3" "设置 IPv6 优先"
        menu_pair "4" "关闭 IPv6" "5" "开启 IPv6"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH

        case "$CH" in
            1) ip_show_status ;;
            2) ip_prefer_v4 ;;
            3) ip_prefer_v6 ;;
            4) ip_disable_v6 ;;
            5) ip_enable_v6 ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

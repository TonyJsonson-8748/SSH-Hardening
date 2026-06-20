# ══════════════════════════════════════════════════════════
#  脚本自我管理模块

# ── DDNS 主菜单 ───────────────────────────────────────────


# ══════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════
# ── 后台版本检测 ────────────────────────────────────────
self_check_update() {
    local REMOTE_VER
    REMOTE_VER=$(curl -fsSL --max-time 5 "$SCRIPT_URL" 2>/dev/null \
        | grep -oE 'VPS 开荒脚本 V[0-9]+[.][0-9]+[.][0-9]+|VPS 开荒脚本 V[0-9]+[.][0-9]+' \
        | head -1 | grep -oE 'V[0-9]+[.][0-9]+([.][0-9]+)?')
    [ -z "$REMOTE_VER" ] && return
    local CUR_VER
    CUR_VER=$(grep -oE 'VPS 开荒脚本 V[0-9]+[.][0-9]+[.][0-9]+|VPS 开荒脚本 V[0-9]+[.][0-9]+' "$0" 2>/dev/null \
        | head -1 | grep -oE 'V[0-9]+[.][0-9]+([.][0-9]+)?')
    [ -z "$CUR_VER" ] && return
    if [ "$REMOTE_VER" = "$CUR_VER" ]; then
        rm -f /tmp/.vps_new_version 2>/dev/null
        return
    fi
    echo "$REMOTE_VER" > /tmp/.vps_new_version 2>/dev/null
}

main_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)
        local F2B_STAT; F2B_STAT=$(f2b_status)

        safe_clear
        echo ""
        volcano_art_banner
        echo ""
        box_top
        echo -e "  ${BOLD}${CYAN}VPS 开荒脚本${NC}  ${DIM}V3.8.2 · 银趴火山帮${NC}"
        echo ""
        # 收集状态数据
        local FW_TYPE FW_STAT FW_STATE
        FW_TYPE=$(fw_detect)
        if [ "$FW_TYPE" = "none" ]; then
            FW_STAT="未安装"; FW_STATE="unknown"
        elif [ "$(fw_running "$FW_TYPE")" = "active" ]; then
            FW_STAT="${FW_TYPE} 运行中"; FW_STATE="active"
        else
            FW_STAT="${FW_TYPE} 已停止"; FW_STATE="inactive"
        fi
        local BBR_CC; BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        local TC_RATE; TC_RATE=$(tc qdisc show dev "$(default_iface)" 2>/dev/null | grep -oE '(maxrate|rate) [^ ]+' | head -1 | awk '{print $2}'); [ -z "$TC_RATE" ] && TC_RATE="无限速"
        local CADDY_ST; CADDY_ST=$(caddy_status)
        local CADDY_LABEL
        case "$CADDY_ST" in
            running)       CADDY_LABEL="运行中" ;;
            stopped)       CADDY_LABEL="已停止" ;;
            not_installed) CADDY_LABEL="未安装" ;;
        esac
        local DDNS_ST; DDNS_ST=$(ddns_status)
        local DDNS_LABEL
        case "$DDNS_ST" in
            running)       DDNS_LABEL="运行中" ;;
            stopped)       DDNS_LABEL="已停止" ;;
            not_installed) DDNS_LABEL="未安装" ;;
        esac
        local SYS_TIME SYS_TZ
        SYS_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        SYS_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || date '+%Z')

        # 状态仪表盘
        local AUTH_LABEL AUTH_STATE CADDY_STATE DDNS_STATE BBR_STATE F2B_LABEL F2B_STATE
        if [ "$CUR_PWD" = "no" ] && [ "$CUR_PUBKEY" = "yes" ]; then AUTH_LABEL="仅密钥"; AUTH_STATE="active"
        elif [ "$CUR_PWD" = "yes" ]; then AUTH_LABEL="允许密码"; AUTH_STATE="warning"
        else AUTH_LABEL="未确认"; AUTH_STATE="unknown"; fi
        [ "$CADDY_ST" = "running" ] && CADDY_STATE="active" || CADDY_STATE="$CADDY_ST"
        [ "$DDNS_ST" = "running" ] && DDNS_STATE="active" || DDNS_STATE="$DDNS_ST"
        [ "$BBR_CC" = "bbr" ] && BBR_STATE="active" || BBR_STATE="unknown"
        case "$F2B_STAT" in
            running) F2B_LABEL="运行中"; F2B_STATE="active" ;;
            stopped) F2B_LABEL="已停止"; F2B_STATE="inactive" ;;
            *) F2B_LABEL="未安装"; F2B_STATE="unknown" ;;
        esac

        menu_group "系统概览"
        status_pair "SSH" "${CUR_PORT:-22} · ${KEYCOUNT} 公钥" "active" "认证" "$AUTH_LABEL" "$AUTH_STATE"
        status_pair "BBR" "$BBR_CC · $TC_RATE" "$BBR_STATE" "Fail2ban" "$F2B_LABEL" "$F2B_STATE"
        status_pair "防火墙" "$FW_STAT" "$FW_STATE" "Caddy" "$CADDY_LABEL" "$CADDY_STATE"
        status_pair "DDNS" "$DDNS_LABEL" "$DDNS_STATE" "时间" "$SYS_TIME" "active"
        ui_hint "时区 $SYS_TZ"
        # 更新提示
        if [ -f /tmp/.vps_new_version ]; then
            local NEW_VER; NEW_VER=$(cat /tmp/.vps_new_version 2>/dev/null)
            [ -n "$NEW_VER" ] && echo -e "  ${YELLOW}${BOLD}! 新版本 ${NEW_VER} 可用${NC}  ${DIM}输入 m 后选择 2 更新${NC}"
        fi
        box_sep
        menu_group "安全与网络"
        menu_pair "1" "SSH 工具集" "2" "Fail2ban 管理"
        menu_pair "3" "BBR TCP 调优" "4" "防火墙管理"
        menu_pair "5" "DNS 优化" "6" "Cloudflare DDNS"
        echo ""
        menu_group "系统与服务"
        menu_pair "7" "系统换源" "8" "IPv4 / IPv6"
        menu_pair "9" "Caddy 管理" "n" "NFT 转发"
        menu_pair "t" "时间与时区" "s" "Swap 管理"
        menu_pair "h" "安全与诊断" "m" "脚本管理"
        echo ""
        menu_item "0" "退出脚本" "$RED"
        box_bot
        echo ""
        read -rp "$(ui_prompt '选择功能 [0-9 / n / t / s / h / m]: ')" CHOICE
        audit_action "主菜单选择 $CHOICE" INFO

        case "$CHOICE" in
            1) ssh_tools_menu ;;
            2) fail2ban_menu ;;
            3) bbr_menu ;;
            4) firewall_menu ;;
            5) dns_menu ;;
            6) ddns_menu ;;
            7) mirror_menu ;;
            8) ip_config_menu ;;
            9) caddy_menu ;;
            n|N) nft_menu ;;
            t|T) timesync_menu ;;
            s|S) swap_menu ;;
            h|H) system_toolbox_menu ;;
            m|M) self_manage_menu ;;
            0) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
        continue
    done
}

# 测试模式只加载函数，不启动菜单或后台任务。
if [ "${VPS_TOOLS_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# CLI 处理：systemd timer 调用 DDNS 刷新（非交互）
if [ "${1:-}" = "--nft-refresh-ddns" ]; then
    nft_refresh_ddns
    exit $?
fi

self_check_first_run
# 后台检测新版本（不阻塞主菜单）
self_check_update &
main_menu

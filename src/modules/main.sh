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
        box_title "VPS 开荒脚本 V3.8.0"
        box_title "· · 银趴火山帮 · ·"
        box_sep
        # 收集状态数据
        local FW_TYPE FW_STAT FW_COLOR
        FW_TYPE=$(fw_detect)
        if [ "$FW_TYPE" = "none" ]; then
            FW_STAT="未安装"; FW_COLOR="$YELLOW"
        elif [ "$(fw_running "$FW_TYPE")" = "active" ]; then
            FW_STAT="${FW_TYPE} active"; FW_COLOR="$GREEN"
        else
            FW_STAT="${FW_TYPE} inactive"; FW_COLOR="$RED"
        fi
        local BBR_CC; BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        local TC_RATE; TC_RATE=$(tc qdisc show dev "$(default_iface)" 2>/dev/null | grep -oE '(maxrate|rate) [^ ]+' | head -1 | awk '{print $2}'); [ -z "$TC_RATE" ] && TC_RATE="无限速"
        local CADDY_ST; CADDY_ST=$(caddy_status)
        local CADDY_COLOR CADDY_LABEL
        case "$CADDY_ST" in
            running)       CADDY_COLOR="$GREEN";  CADDY_LABEL="running" ;;
            stopped)       CADDY_COLOR="$RED";    CADDY_LABEL="stopped" ;;
            not_installed) CADDY_COLOR="$YELLOW"; CADDY_LABEL="未安装" ;;
        esac
        local DDNS_ST; DDNS_ST=$(ddns_status)
        local DDNS_COLOR DDNS_LABEL
        case "$DDNS_ST" in
            running)       DDNS_COLOR="$GREEN";  DDNS_LABEL="运行中" ;;
            stopped)       DDNS_COLOR="$RED";    DDNS_LABEL="已停止" ;;
            not_installed) DDNS_COLOR="$YELLOW"; DDNS_LABEL="未安装" ;;
        esac
        local SYS_TIME SYS_TZ
        SYS_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        SYS_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || date '+%Z')

        # 状态栏
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}"                  "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}"                  "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        box_line "  BBR: ${BBR_CC}  |  限速: ${TC_RATE}"                  "  BBR: ${BOLD}${BBR_CC}${NC}  |  限速: ${BOLD}${TC_RATE}${NC}"
        if [ "$F2B_STAT" = "running" ]; then
            box_line "  Fail2ban: running" "  Fail2ban: ${GREEN}${BOLD}running${NC}"
        elif [ "$F2B_STAT" = "stopped" ]; then
            box_line "  Fail2ban: stopped" "  Fail2ban: ${RED}${BOLD}stopped${NC}"
        else
            box_line "  Fail2ban: 未安装"  "  Fail2ban: ${YELLOW}${BOLD}未安装${NC}"
        fi
        box_line "  防火墙: ${FW_STAT}" "  防火墙: ${FW_COLOR}${BOLD}${FW_STAT}${NC}"
        box_line "  Caddy: ${CADDY_LABEL}" "  Caddy: ${CADDY_COLOR}${BOLD}${CADDY_LABEL}${NC}"
        box_line "  DDNS: ${DDNS_LABEL}" "  DDNS: ${DDNS_COLOR}${BOLD}${DDNS_LABEL}${NC}"
        box_line "  时间: ${SYS_TIME}  ${SYS_TZ}" "  时间: ${BOLD}${SYS_TIME}${NC}  ${DIM}${SYS_TZ}${NC}"
        # 更新提示
        if [ -f /tmp/.vps_new_version ]; then
            local NEW_VER; NEW_VER=$(cat /tmp/.vps_new_version 2>/dev/null)
            [ -n "$NEW_VER" ] && box_line "  🔔 新版本 ${NEW_VER} 可用！"                 "  ${YELLOW}${BOLD}🔔 新版本 ${NEW_VER} 可用！${NC}  ${DIM}m→2 一键更新${NC}"
        fi
        box_sep
        menu_group "安全与网络"
        menu_item "1" "SSH 工具集"
        menu_item "2" "Fail2ban 管理"
        menu_item "3" "BBR TCP 调优"
        menu_item "4" "防火墙管理"
        menu_item "5" "DNS 优化"
        menu_item "6" "Cloudflare DDNS"
        echo ""
        menu_group "系统与服务"
        menu_item "7" "系统换源"
        menu_item "8" "IPv4/IPv6 配置"
        menu_item "9" "Caddy 管理"
        menu_item "n" "NFT 转发管理 ${DIM}（端口转发 / DDNS / 访问控制）${NC}"
        menu_item "t" "时间同步"
        menu_item "s" "Swap 管理"
        menu_item "h" "安全与诊断工具箱"
        menu_item "m" "脚本管理 ${DIM}（安装 / 更新 / 卸载）${NC}"
        echo ""
        menu_item "0" "退出" "$RED"
        box_bot
        echo ""
        read -rp "  请选择功能 [0-9/n/t/s/h/m]: " CHOICE
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

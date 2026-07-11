# ══════════════════════════════════════════════════════════
#  时间同步模块
# ══════════════════════════════════════════════════════════

timesync_menu() {
    while true; do
        print_header "时间同步 / 时区设置"

        # 当前状态
        local CUR_TZ CUR_TIME CUR_DATE NTP_STATUS
        CUR_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")
        CUR_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        CUR_DATE=$(date '+%Z %z')

        # NTP 状态
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            NTP_STATUS="${GREEN}已同步${NC}"
        elif command -v chronyc &>/dev/null && chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
            NTP_STATUS="${GREEN}已同步(chrony)${NC}"
        else
            NTP_STATUS="${YELLOW}未同步${NC}"
        fi

        echo -e "  当前时区：${BOLD}${CUR_TZ}${NC}"
        echo -e "  当前时间：${BOLD}${CUR_TIME}${NC}  ${DIM}${CUR_DATE}${NC}"
        echo -e "  NTP状态 ：${NTP_STATUS}"
        echo ""
        menu_div
        menu_item "1" "强制同步时间"
        menu_pair "2" "设置北京时区" "3" "同步并设为北京"
        menu_pair "4" "设置其他时区" "5" "开启 NTP 自动同步"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH

        case "$CH" in
            1) ts_sync_time ;;
            2) ts_set_beijing ;;
            3) ts_set_beijing; ts_sync_time ;;
            4) ts_set_custom_tz ;;
            5) ts_enable_ntp ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

# ── 强制同步时间 ──────────────────────────────────────────
ts_sync_time() {
    print_header "强制同步系统时间"
    echo -e "  ${DIM}尝试多种方式同步时间...${NC}"
    echo ""

    local SYNCED=false

    # 方法1：timedatectl + systemd-timesyncd
    if command -v timedatectl &>/dev/null && systemd_available; then
        info "尝试 systemd-timesyncd..."
        timedatectl set-ntp true 2>/dev/null
        # 重启 timesyncd 强制立即同步
        systemctl restart systemd-timesyncd 2>/dev/null
        sleep 2
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            info "systemd-timesyncd 同步成功 ✓"
            SYNCED=true
        fi
    fi

    # 方法2：chrony
    if [ "$SYNCED" = false ] && command -v chronyc &>/dev/null; then
        info "尝试 chrony..."
        systemctl restart chronyd 2>/dev/null || rc-service chronyd restart 2>/dev/null || true
        sleep 1
        chronyc makestep 2>/dev/null && info "chrony 强制同步成功 ✓" && SYNCED=true
    fi

    # 方法3：ntpdate（直连 NTP 服务器）
    if [ "$SYNCED" = false ]; then
        local NTP_SERVERS="ntp.aliyun.com time.cloudflare.com pool.ntp.org time.google.com"
        if command -v ntpdate &>/dev/null; then
            info "尝试 ntpdate..."
            for srv in $NTP_SERVERS; do
                if ntpdate -u "$srv" &>/dev/null; then
                    info "ntpdate 同步成功（$srv）✓"
                    SYNCED=true
                    break
                fi
            done
        else
            # 安装 ntpdate 再同步
            info "ntpdate 未安装，尝试安装..."
            pkg_install ntpdate &>/dev/null
            if command -v ntpdate &>/dev/null; then
                for srv in $NTP_SERVERS; do
                    if ntpdate -u "$srv" &>/dev/null; then
                        info "ntpdate 同步成功（$srv）✓"
                        SYNCED=true
                        break
                    fi
                done
            fi
        fi
    fi

    # 方法4：date 命令从 HTTP 头获取时间（极端兜底，未经认证，可被中间人伪造）
    if [ "$SYNCED" = false ]; then
        warn "HTTP 时间同步未经认证，仅作最后兜底"
        info "尝试从 HTTP 头获取时间..."
        local HTTP_DATE
        HTTP_DATE=$(curl -sI --max-time 5 https://www.aliyun.com 2>/dev/null | grep -i "^date:" | cut -d' ' -f2- | tr -d '\r')
        if [ -n "$HTTP_DATE" ]; then
            date -s "$HTTP_DATE" &>/dev/null && info "HTTP 时间同步成功 ✓" && SYNCED=true
        fi
    fi

    echo ""
    if [ "$SYNCED" = true ]; then
        info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    else
        error "自动同步失败，请检查网络连接"
        echo -e "  ${DIM}手动同步：ntpdate ntp.aliyun.com${NC}"
    fi
}

# ── 设置北京时区 ──────────────────────────────────────────
ts_set_beijing() {
    print_header "设置北京时区"
    info "设置时区为 Asia/Shanghai（北京 UTC+8）..."

    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null && info "时区已设置 ✓"
    elif [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
        info "时区已设置 ✓"
    else
        error "找不到时区文件，尝试安装 tzdata..."
        pkg_install tzdata &>/dev/null
        if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
            echo "Asia/Shanghai" > /etc/timezone
            info "时区已设置 ✓"
        else
            error "设置失败，请手动执行：timedatectl set-timezone Asia/Shanghai"
            return
        fi
    fi

    echo ""
    info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
}

# ── 设置自定义时区 ────────────────────────────────────────
ts_set_custom_tz() {
    print_header "设置自定义时区"
    echo -e "  常用时区参考："
    echo -e "  ${GREEN}Asia/Shanghai${NC}       北京 UTC+8"
    echo -e "  ${GREEN}Asia/Tokyo${NC}          东京 UTC+9"
    echo -e "  ${GREEN}America/New_York${NC}    纽约 UTC-5"
    echo -e "  ${GREEN}America/Los_Angeles${NC} 洛杉矶 UTC-8"
    echo -e "  ${GREEN}Europe/London${NC}       伦敦 UTC+0"
    echo -e "  ${GREEN}Europe/Paris${NC}        巴黎 UTC+1"
    echo ""
    read -rp "  请输入时区名称（直接回车取消）: " TZ_INPUT
    [ -z "$TZ_INPUT" ] && { warn "已取消"; return; }

    if [ ! -f "/usr/share/zoneinfo/${TZ_INPUT}" ]; then
        error "时区 '${TZ_INPUT}' 不存在，请检查拼写"
        return
    fi

    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$TZ_INPUT" 2>/dev/null && info "时区已设置为 ${TZ_INPUT} ✓"
    else
        ln -sf "/usr/share/zoneinfo/${TZ_INPUT}" /etc/localtime
        echo "$TZ_INPUT" > /etc/timezone
        info "时区已设置为 ${TZ_INPUT} ✓"
    fi

    echo ""
    info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
}

# ── 开启 NTP 自动同步 ─────────────────────────────────────
ts_enable_ntp() {
    print_header "开启 NTP 自动同步"

    # 检测 CanNTP — 判断是否有 timesyncd
    local CAN_NTP
    CAN_NTP=$(timedatectl show --property=CanNTP --value 2>/dev/null || echo "no")

    if [ "$CAN_NTP" = "yes" ] && command -v systemctl &>/dev/null \
        && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
        # systemd-timesyncd 可用
        timedatectl set-ntp true 2>/dev/null || { error "无法启用系统 NTP"; return 1; }
        systemctl enable systemd-timesyncd --quiet 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || { error "systemd-timesyncd 启动失败"; return 1; }
        systemctl is-active --quiet systemd-timesyncd 2>/dev/null || { error "systemd-timesyncd 未运行"; return 1; }
        info "systemd-timesyncd NTP 已开启 ✓"
    elif command -v chronyc &>/dev/null; then
        # chrony 已安装，自动探测服务名
        local CHRONY_SVC="chronyd"
        systemctl list-unit-files 2>/dev/null | grep -q "^chrony.service" && CHRONY_SVC="chrony"
        svc_enable "$CHRONY_SVC"
        svc_start "$CHRONY_SVC" || { error "chrony 启动失败"; return 1; }
        sleep 1
        chronyc makestep &>/dev/null && info "chrony 强制同步 ✓"
        info "chrony NTP 自动同步已开启 ✓"
    else
        # 都没有，安装 chrony
        info "正在安装 chrony..."
        if pkg_install chrony; then
            # Debian 服务名是 chrony，CentOS/Alpine 是 chronyd
            local CHRONY_SVC="chronyd"
            systemctl list-unit-files 2>/dev/null | grep -q "^chrony.service" && CHRONY_SVC="chrony"
            svc_enable "$CHRONY_SVC"
            svc_start "$CHRONY_SVC" || { error "chrony 启动失败"; return 1; }
            sleep 2
            chronyc makestep &>/dev/null && info "chrony 强制同步 ✓"
            info "chrony 已安装并开启自动同步 ✓"
        else
            error "chrony 安装失败，请手动执行：apt-get install -y chrony"
            return
        fi
    fi

    echo ""
    sleep 2
    # 验证同步状态
    local SYNC_ST
    SYNC_ST=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
    if [ "$SYNC_ST" = "yes" ]; then
        info "NTP 状态：已同步 ✓"
        info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    else
        warn "NTP 状态：同步中（chrony 可能需要几秒完成首次同步）"
        # 尝试 chrony 状态
        if command -v chronyc &>/dev/null; then
            chronyc tracking 2>/dev/null | grep -E "Reference|System time|Last offset" | while IFS= read -r l; do
                echo -e "  ${DIM}$l${NC}"
            done
        fi
    fi
}

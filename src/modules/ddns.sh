# ══════════════════════════════════════════════════════════
#  Cloudflare DDNS 模块
# ══════════════════════════════════════════════════════════

DDNS_SCRIPT="/root/ddns.sh"
DDNS_TOKEN_FILE="/root/.cf_token"
DDNS_LOG="/var/log/ddns.log"
DDNS_ZONE_FILE="/root/.cf_zone"
DDNS_TG_FILE="/root/.cf_tg"    # Telegram 通知配置

ddns_cfg_get() {
    local key="$1"
    [ -f "$DDNS_ZONE_FILE" ] || return 1
    grep "^${key}=" "$DDNS_ZONE_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

ddns_log_path() {
    local log_path
    log_path=$(ddns_cfg_get LOG 2>/dev/null)
    if [ -n "$log_path" ]; then
        echo "$log_path"
    elif [ -f "$DDNS_LOG" ]; then
        echo "$DDNS_LOG"
    else
        echo "$HOME/ddns.log"
    fi
}

ddns_ensure_cron() {
    command -v crontab &>/dev/null && return 0
    info "未检测到 crontab，正在安装 cron..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y cron 2>/dev/null || apt-get install -y cronie 2>/dev/null || return 1
    elif command -v apk &>/dev/null; then
        apk add --no-cache dcron 2>/dev/null || apk add --no-cache cronie 2>/dev/null || return 1
    elif command -v yum &>/dev/null; then
        yum install -y cronie 2>/dev/null || return 1
    elif command -v dnf &>/dev/null; then
        dnf install -y cronie 2>/dev/null || return 1
    else
        error "找不到包管理器，请手动安装 cron：apt-get install -y cron"
        return 1
    fi
    # 安装后立即启动服务
    ddns_start_cron_service >/dev/null 2>&1 || true
    sleep 1
    if command -v crontab &>/dev/null; then
        info "cron 安装并启动成功 ✓"
        return 0
    else
        error "cron 安装后仍无法使用，请重新登录后重试"
        return 1
    fi
}

ddns_start_cron_service() {
    for svc in cron crond dcron; do
        if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
            systemctl enable "$svc" --quiet 2>/dev/null || true
            systemctl start "$svc" 2>/dev/null && return 0
        fi
        if command -v rc-service &>/dev/null; then
            rc-service "$svc" start 2>/dev/null && return 0
        fi
    done
    return 1
}

# ── 检测 DDNS 安装状态 ────────────────────────────────────
ddns_status() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        echo "not_installed"
    elif ! command -v crontab &>/dev/null; then
        echo "no_cron"
    elif ! crontab -l 2>/dev/null | grep -q "ddns.sh"; then
        echo "stopped"
    else
        echo "running"
    fi
}

# ── 安装/配置 DDNS ────────────────────────────────────────
ddns_install() {
    print_header "Cloudflare DDNS 配置"
    echo -e "  ${DIM}动态 DNS：自动将域名 A 记录更新为本机公网 IP${NC}"
    echo ""

    for cmd in curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            info "安装依赖 $cmd..."
            pkg_install "$cmd" &>/dev/null
        fi
    done
    if ! ddns_ensure_cron; then
        error "无法安装或启用 crontab/cron，请先手动安装 cron 后重试"
        return
    fi
    ddns_start_cron_service >/dev/null 2>&1 || warn "cron 服务未能自动启动，请稍后手动检查"

    menu_div
    read -rp "  子域名（如 home）: " DDNS_SUB
    [ -z "$DDNS_SUB" ] && { warn "已取消"; return; }

    read -rp "  根域名（如 example.com）: " DDNS_ZONE_NAME
    [ -z "$DDNS_ZONE_NAME" ] && { warn "已取消"; return; }

    local DDNS_DOMAIN="${DDNS_SUB}.${DDNS_ZONE_NAME}"

    read -rp "  Cloudflare API Token: " DDNS_TOKEN
    [ -z "$DDNS_TOKEN" ] && { warn "已取消"; return; }

    local DDNS_MODE="ipv4"
    read -rp "  记录模式 [1=仅IPv4 / 2=IPv4+IPv6，默认1]: " DDNS_MODE_CH
    case "$DDNS_MODE_CH" in
        2) DDNS_MODE="dual" ;;
        *) DDNS_MODE="ipv4" ;;
    esac

    local DDNS_PROXIED="false"
    read -rp "  是否开启 Cloudflare 代理（橙云）？(y/N，默认N): " DDNS_PROXY_CH
    echo "$DDNS_PROXY_CH" | grep -qiE '^y(es)?$' && DDNS_PROXIED="true"

    local DDNS_TTL="60"
    read -rp "  TTL 秒数（默认60）: " DDNS_TTL_IN
    [ -n "$DDNS_TTL_IN" ] && echo "$DDNS_TTL_IN" | grep -qE '^[0-9]+$' && DDNS_TTL="$DDNS_TTL_IN"

    echo ""
    menu_div
    echo -e "  域名   : ${BOLD}${DDNS_DOMAIN}${NC}"
    echo -e "  模式   : ${BOLD}$([ "$DDNS_MODE" = "dual" ] && echo 'IPv4 + IPv6' || echo '仅 IPv4')${NC}"
    echo -e "  代理   : ${BOLD}$([ "$DDNS_PROXIED" = "true" ] && echo '开启' || echo '关闭')${NC}"
    echo -e "  TTL    : ${BOLD}${DDNS_TTL}${NC}"
    echo -e "  Token  : ${BOLD}${DDNS_TOKEN:0:8}…${NC}"
    menu_div
    echo ""
    read -rp "  确认安装？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    echo ""
    info "验证 Token 和域名..."
    local ZONE_RESP ZONE_OK ZONE_COUNT ZONE_ID
    ZONE_RESP=$(curl -s --max-time 10         "https://api.cloudflare.com/client/v4/zones?name=${DDNS_ZONE_NAME}"         -H "Authorization: Bearer ${DDNS_TOKEN}")
    ZONE_OK=$(echo "$ZONE_RESP" | python3 -c         "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
    if [ "$ZONE_OK" != "True" ]; then
        error "Token 验证失败，请检查 Token 权限（需要 Zone:DNS:Edit）"
        return
    fi
    ZONE_COUNT=$(echo "$ZONE_RESP" | python3 -c         "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
    if [ "$ZONE_COUNT" = "0" ]; then
        error "找不到域名 ${DDNS_ZONE_NAME}，请确认已托管到此 Cloudflare 账号"
        return
    fi
    ZONE_ID=$(echo "$ZONE_RESP" | python3 -c         "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")
    info "Token 有效，Zone ID: ${ZONE_ID} ✓"

    # 检查/创建 A 记录
    local RECORD_RESP RECORD_COUNT CREATE_RESP CREATE_OK
    RECORD_RESP=$(curl -s --max-time 10         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DDNS_DOMAIN}&type=A"         -H "Authorization: Bearer ${DDNS_TOKEN}")
    RECORD_COUNT=$(echo "$RECORD_RESP" | python3 -c         "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
    if [ "$RECORD_COUNT" = "0" ]; then
        warn "未找到 A 记录，正在自动创建..."
        CREATE_BODY=$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
            "$DDNS_DOMAIN" "1.1.1.1" "$DDNS_TTL" "$DDNS_PROXIED")
        CREATE_RESP=$(curl -s -X POST --max-time 10             "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records"             -H "Authorization: Bearer ${DDNS_TOKEN}"             -H "Content-Type: application/json"             --data "$CREATE_BODY")
        CREATE_OK=$(echo "$CREATE_RESP" | python3 -c             "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
        [ "$CREATE_OK" = "True" ] && info "A 记录已创建 ✓" || { error "创建 A 记录失败"; return; }
    else
        info "A 记录已存在 ✓"
    fi

    # 双栈：检查/创建 AAAA 记录
    if [ "$DDNS_MODE" = "dual" ]; then
        RECORD_RESP=$(curl -s --max-time 10             "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DDNS_DOMAIN}&type=AAAA"             -H "Authorization: Bearer ${DDNS_TOKEN}")
        RECORD_COUNT=$(echo "$RECORD_RESP" | python3 -c             "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
        if [ "$RECORD_COUNT" = "0" ]; then
            warn "未找到 AAAA 记录，正在自动创建..."
            CREATE_BODY=$(printf '{"type":"AAAA","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
                "$DDNS_DOMAIN" "::1" "$DDNS_TTL" "$DDNS_PROXIED")
            CREATE_RESP=$(curl -s -X POST --max-time 10                 "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records"                 -H "Authorization: Bearer ${DDNS_TOKEN}"                 -H "Content-Type: application/json"                 --data "$CREATE_BODY")
            CREATE_OK=$(echo "$CREATE_RESP" | python3 -c                 "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
            if [ "$CREATE_OK" = "True" ]; then
                info "AAAA 记录已创建 ✓"
            else
                warn "AAAA 记录创建失败，将仅更新 IPv4"
                DDNS_MODE="ipv4"
            fi
        else
            info "AAAA 记录已存在 ✓"
        fi
    fi

    # 保存配置
    echo "$DDNS_TOKEN" > "$DDNS_TOKEN_FILE"
    chmod 600 "$DDNS_TOKEN_FILE"
    touch "$DDNS_LOG" 2>/dev/null || { DDNS_LOG="$HOME/ddns.log"; touch "$DDNS_LOG"; }
    chmod 644 "$DDNS_LOG" 2>/dev/null || true
    {
        echo "DOMAIN=${DDNS_DOMAIN}"
        echo "ZONE=${DDNS_ZONE_NAME}"
        echo "MODE=${DDNS_MODE}"
        echo "PROXIED=${DDNS_PROXIED}"
        echo "TTL=${DDNS_TTL}"
        echo "LOG=${DDNS_LOG}"
    } > "$DDNS_ZONE_FILE"

    # 生成 DDNS 执行脚本
    cat > "$DDNS_SCRIPT" << 'DDNS_INNER'
#!/bin/bash
# 注入 PATH，确保 crontab 环境下能找到 curl / python3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN="__DOMAIN__"
ZONE="__ZONE__"
MODE="__MODE__"
PROXIED="__PROXIED__"
TTL="__TTL__"
TOKEN_FILE="/root/.cf_token"
LOG_FILE="__LOG__"

API_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
[ -z "$API_TOKEN" ] && exit 1

# 日志轮转：最多保留 500 条记录（每次运行检查）
if [ -f "$LOG_FILE" ]; then
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_LINES" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

# 发送 Telegram 通知（每次调用时实时读取配置文件，避免 crontab 变量丢失）
tg_notify() {
    local MSG="$1"
    local TG_FILE="/root/.cf_tg"
    [ -f "$TG_FILE" ] || return 0
    local B_TOKEN C_ID
    B_TOKEN=$(grep "^BOT_TOKEN=" "$TG_FILE" | cut -d= -f2-)
    C_ID=$(grep "^CHAT_ID=" "$TG_FILE" | cut -d= -f2-)
    [ -z "$B_TOKEN" ] || [ -z "$C_ID" ] && return 0
    curl -s --max-time 15         "https://api.telegram.org/bot${B_TOKEN}/sendMessage"         -d "chat_id=${C_ID}"         -d "text=${MSG}"         -d "parse_mode=HTML" > /dev/null 2>&1
}

CURRENT_IP4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null     || curl -4 -s --max-time 5 https://ifconfig.me/ip 2>/dev/null | tr -d '
 '     || curl -4 -s --max-time 5 https://ip.sb 2>/dev/null | tr -d '
 ')
CURRENT_IP6=""
if [ "$MODE" = "dual" ]; then
    CURRENT_IP6=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null         || curl -6 -s --max-time 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '
 ')
fi

if [ -z "$CURRENT_IP4" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 无法获取公网 IPv4（可能仅有 IPv6 网络）" >> "$LOG_FILE"
    exit 1
fi

# 校验是否为合法 IPv4 格式（每段 0-255，防止获取到 IPv6 或 HTML 错误页）
if ! echo "$CURRENT_IP4" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || \
   ! echo "$CURRENT_IP4" | awk -F. '{for(i=1;i<=4;i++) if($i<0||$i>255) exit 1}'; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取到的 IP 非法：${CURRENT_IP4}（可能为 IPv6 或网络异常）" >> "$LOG_FILE"
    exit 1
fi

ZONE_ID=$(curl -s --max-time 8 "https://api.cloudflare.com/client/v4/zones?name=${ZONE}"     -H "Authorization: Bearer ${API_TOKEN}" |     python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
[ -z "$ZONE_ID" ] && {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取 Zone ID 失败" >> "$LOG_FILE"
    exit 1
}

update_record() {
    local TYPE="$1" NEW_IP="$2"
    [ -z "$NEW_IP" ] && return 0
    local RECORD_ID OLD_IP RESULT SUCCESS
    RECORD_ID=$(curl -s --max-time 8         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN}&type=${TYPE}"         -H "Authorization: Bearer ${API_TOKEN}" |         python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
    [ -z "$RECORD_ID" ] && {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 记录不存在" >> "$LOG_FILE"
        return 1
    }
    OLD_IP=$(curl -s --max-time 8         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}"         -H "Authorization: Bearer ${API_TOKEN}" |         python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)
    # OLD_IP 为空说明查询失败，跳过本次更新避免误推 Telegram
    if [ -z "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${TYPE} 无法获取当前记录值，跳过更新" >> "$LOG_FILE"
        return 0
    fi
    if [ "$NEW_IP" = "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} 未变化 ${NEW_IP}" >> "$LOG_FILE"
        return 0
    fi
    # 二次校验：再次查询确认 OLD_IP 是否真的不一样（防止偶发查询返回错误数据）
    local VERIFY_IP
    VERIFY_IP=$(curl -s --max-time 8 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)
    if [ -z "$VERIFY_IP" ] || [ "$VERIFY_IP" != "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${TYPE} 二次校验异常 (1st:${OLD_IP} 2nd:${VERIFY_IP})，跳过更新" >> "$LOG_FILE"
        return 0
    fi
    if [ "$NEW_IP" = "$VERIFY_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} 未变化 ${NEW_IP}（二次确认）" >> "$LOG_FILE"
        return 0
    fi
    local JSON_BODY
    JSON_BODY=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
        "$TYPE" "$DOMAIN" "$NEW_IP" "$TTL" "$PROXIED")
    RESULT=$(curl -s -X PUT --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$JSON_BODY")
    SUCCESS=$(echo "$RESULT" | python3 -c         "import sys,json; print(json.load(sys.stdin).get('success'))" 2>/dev/null)
    if [ "$SUCCESS" = "True" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} 更新成功 ${OLD_IP} → ${NEW_IP}" >> "$LOG_FILE"
        # 记录最后一次 IP 变更（时间|类型|旧IP|新IP），供菜单显示
        echo "$(date '+%Y-%m-%d %H:%M:%S')|${TYPE}|${OLD_IP}|${NEW_IP}" > /root/.cf_last_change 2>/dev/null
        chmod 600 /root/.cf_last_change 2>/dev/null
        tg_notify "🌐 <b>DDNS IP 已更新</b>
域名：<code>${DOMAIN}</code>
类型：${TYPE}
旧IP：<code>${OLD_IP}</code>
新IP：<code>${NEW_IP}</code>
时间：$(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 更新失败 $RESULT" >> "$LOG_FILE"
        return 1
    fi
}

update_record A "$CURRENT_IP4"
if [ "$MODE" = "dual" ]; then
    if [ -n "$CURRENT_IP6" ]; then
        update_record AAAA "$CURRENT_IP6"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: 未获取到公网 IPv6，跳过 AAAA" >> "$LOG_FILE"
    fi
fi
DDNS_INNER

    sed -i "s/__DOMAIN__/${DDNS_DOMAIN}/g" "$DDNS_SCRIPT"
    sed -i "s/__ZONE__/${DDNS_ZONE_NAME}/g" "$DDNS_SCRIPT"
    sed -i "s/__MODE__/${DDNS_MODE}/g" "$DDNS_SCRIPT"
    sed -i "s/__PROXIED__/${DDNS_PROXIED}/g" "$DDNS_SCRIPT"
    sed -i "s/__TTL__/${DDNS_TTL}/g" "$DDNS_SCRIPT"
    local DDNS_LOG_ESC
    DDNS_LOG_ESC=$(printf '%s' "$DDNS_LOG" | sed 's/[&|\\]/\\&/g')
    sed -i "s|__LOG__|${DDNS_LOG_ESC}|g" "$DDNS_SCRIPT"
    chmod 700 "$DDNS_SCRIPT"

    local CRON_JOB="*/5 * * * * ${DDNS_SCRIPT} >> ${DDNS_LOG} 2>&1"
    ( crontab -l 2>/dev/null | grep -v "ddns.sh"; echo "$CRON_JOB" ) | crontab -
    info "crontab 已设置（每5分钟自动更新）✓"
    ddns_start_cron_service >/dev/null 2>&1 || true

    echo ""
    info "立即执行一次测试..."
    if bash "$DDNS_SCRIPT"; then
        tail -1 "$DDNS_LOG" 2>/dev/null | while IFS= read -r l; do echo -e "  ${GREEN}$l${NC}"; done
    else
        error "执行失败，请查看日志"
    fi
    echo ""
    info "DDNS 配置完成 ✓"
    echo -e "  域名 : ${BOLD}${DDNS_DOMAIN}${NC}"
    echo -e "  日志 : ${DIM}${DDNS_LOG}${NC}"
}

# ── 暂停/恢复 DDNS ────────────────────────────────────────
ddns_pause() {
    [ ! -f "$DDNS_SCRIPT" ] && { error "DDNS 未安装"; return; }
    ( crontab -l 2>/dev/null | grep -v "ddns.sh" ) | crontab - 2>/dev/null
    info "DDNS 自动更新已暂停 ✓"
}

ddns_resume() {
    [ ! -f "$DDNS_SCRIPT" ] && { error "DDNS 未安装"; return; }
    if ! command -v crontab &>/dev/null; then
        info "检测到 cron 未安装，正在自动安装..."
        if ! ddns_ensure_cron; then
            error "cron 安装失败，请手动执行：apt-get install -y cron"
            return
        fi
    fi
    local LOG; LOG=$(ddns_log_path)
    local CRON_JOB="*/5 * * * * ${DDNS_SCRIPT} >> ${LOG} 2>&1"
    ( crontab -l 2>/dev/null | grep -v "ddns.sh"; echo "$CRON_JOB" ) | crontab -
    ddns_start_cron_service >/dev/null 2>&1 || true
    info "DDNS 自动更新已恢复 ✓"
}

# ── 卸载 DDNS ─────────────────────────────────────────────
# ── Telegram 通知配置 ─────────────────────────────────────
ddns_tg_config() {
    print_header "Telegram 通知配置"
    echo -e "  ${DIM}IP 变化时自动发送 Telegram 通知${NC}"
    echo ""

    if [ -f "$DDNS_TG_FILE" ]; then
        local CUR_BOT CUR_CHAT
        CUR_BOT=$(grep "^BOT_TOKEN=" "$DDNS_TG_FILE" | cut -d= -f2-)
        CUR_CHAT=$(grep "^CHAT_ID=" "$DDNS_TG_FILE" | cut -d= -f2-)
        echo -e "  当前状态：${GREEN}${BOLD}已配置${NC}"
        echo -e "  Bot Token：${DIM}${CUR_BOT:0:10}…${NC}"
        echo -e "  Chat ID  ：${BOLD}${CUR_CHAT}${NC}"
    else
        echo -e "  当前状态：${YELLOW}未配置${NC}"
    fi

    echo ""
    menu_div
    echo -e "  ${DIM}如何获取：${NC}"
    echo -e "  ${DIM}① Telegram 搜索 @BotFather → /newbot 创建机器人${NC}"
    echo -e "  ${DIM}② 获取 Bot Token（格式：123456:ABC-xxx）${NC}"
    echo -e "  ${DIM}③ 与机器人发一条消息，再访问：${NC}"
    echo -e "  ${DIM}   https://api.telegram.org/bot<TOKEN>/getUpdates${NC}"
    echo -e "  ${DIM}④ 从返回的 chat.id 字段获取 Chat ID${NC}"
    menu_div
    echo ""
    menu_pair "1" "配置 Telegram 通知" "2" "发送测试消息"
    [ -f "$DDNS_TG_FILE" ] && menu_item "3" "关闭 Telegram 通知" "$YELLOW"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择操作: ')" CH

    case "$CH" in
        1)
            echo ""
            read -rp "  Bot Token: " TG_BOT
            [ -z "$TG_BOT" ] && { warn "已取消"; return; }
            read -rp "  Chat ID: " TG_CHAT
            [ -z "$TG_CHAT" ] && { warn "已取消"; return; }
            {
                echo "BOT_TOKEN=${TG_BOT}"
                echo "CHAT_ID=${TG_CHAT}"
            } > "$DDNS_TG_FILE"
            chmod 600 "$DDNS_TG_FILE"
            info "Telegram 通知已配置 ✓"
            ;;
        2)
            if [ ! -f "$DDNS_TG_FILE" ]; then
                error "请先配置 Telegram 通知"; return
            fi
            local BOT CHAT
            BOT=$(grep "^BOT_TOKEN=" "$DDNS_TG_FILE" | cut -d= -f2-)
            CHAT=$(grep "^CHAT_ID=" "$DDNS_TG_FILE" | cut -d= -f2-)
            info "发送测试消息..."
            local RESP
            RESP=$(curl -s --max-time 10 \
                "https://api.telegram.org/bot${BOT}/sendMessage" \
                --data-urlencode "chat_id=${CHAT}" \
                --data-urlencode "text=🔔 DDNS 通知测试
域名：$(ddns_cfg_get DOMAIN)
时间：$(date '+%Y-%m-%d %H:%M:%S')
✅ 通知配置成功！" \
                -d "parse_mode=HTML")
            echo "$RESP" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print('发送成功 ✓' if d.get('ok') else '发送失败：' + str(d.get('description','')))" 2>/dev/null \
                | while IFS= read -r l; do info "$l"; done
            ;;
        3)
            rm -f "$DDNS_TG_FILE" && info "Telegram 通知已关闭 ✓"
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

ddns_uninstall() {
    print_header "卸载 DDNS"
    warn "将移除 crontab 定时任务、DDNS 脚本和 Token 文件"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    ( crontab -l 2>/dev/null | grep -v "ddns.sh" ) | crontab - 2>/dev/null
    info "crontab 定时任务已移除 ✓"
    rm -f "$DDNS_SCRIPT" && info "DDNS 脚本已删除 ✓"
    rm -f "$DDNS_TOKEN_FILE" && info "Token 文件已删除 ✓"
    rm -f "$DDNS_ZONE_FILE"
    rm -f /root/.cf_last_change
    warn "日志文件保留：${DDNS_LOG}"
}

# ── 查看日志 ──────────────────────────────────────────────
ddns_view_logs() {
    while true; do
        print_header "DDNS 日志"
        local LOG; LOG=$(ddns_log_path)
        if [ ! -f "$LOG" ]; then warn "日志文件不存在"; return; fi
        echo -e "  ${DIM}${LOG}${NC}"
        menu_div
        tail -20 "$LOG" | while IFS= read -r line; do
            if echo "$line" | grep -q "ERROR"; then
                echo -e "  ${RED}$line${NC}"
            elif echo "$line" | grep -q "OK:.*更新成功"; then
                echo -e "  ${GREEN}$line${NC}"
            else
                echo -e "  ${DIM}$line${NC}"
            fi
        done
        echo ""
        menu_div
        menu_item "1" "实时跟踪  ${DIM}Ctrl+C 返回${NC}"
        menu_item "2" "查看完整日志"
        menu_item "0" "返回上级" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择查看方式: ')" CH
        case "$CH" in
            1)
                # 设置 trap 后再 tail -f；trap 仅在 tail 进程内生效
                trap "echo ''; info '已退出实时跟踪'" INT
                tail -f "$LOG"
                trap - INT
                ;;
            2)
                LANG=C.UTF-8 LESSCHARSET=utf-8 less -R "$LOG"
                ;;
            0|"")
                return
                ;;
            *)
                warn "无效选项"; sleep 1
                ;;
        esac
    done
}

# ── 手动立即更新 ──────────────────────────────────────────
ddns_run_now() {
    print_header "手动更新 DDNS"
    [ ! -f "$DDNS_SCRIPT" ] && { error "DDNS 未安装"; return; }
    info "正在更新..."
    if bash "$DDNS_SCRIPT"; then
        local LOG; LOG=$(ddns_log_path)
        tail -1 "$LOG" 2>/dev/null | while IFS= read -r l; do echo -e "  ${GREEN}$l${NC}"; done
    else
        error "更新失败，请查看日志"
    fi
}

# ── DDNS 主菜单 ───────────────────────────────────────────
ddns_menu() {
    while true; do
        local D_ST; D_ST=$(ddns_status)
        local D_COLOR D_LABEL
        case "$D_ST" in
            running)       D_COLOR="$GREEN";  D_LABEL="运行中" ;;
            stopped)       D_COLOR="$RED";    D_LABEL="已停止（cron任务未设置）" ;;
            no_cron)       D_COLOR="$RED";    D_LABEL="已停止（cron未安装）" ;;
            not_installed) D_COLOR="$YELLOW"; D_LABEL="未安装" ;;
        esac

        print_header "Cloudflare DDNS"

        if [ "$D_ST" != "not_installed" ] && [ -f "$DDNS_ZONE_FILE" ]; then
            local D_DOMAIN D_MODE D_PROXIED D_TTL D_LOG
            D_DOMAIN=$(ddns_cfg_get DOMAIN)
            D_MODE=$(ddns_cfg_get MODE)
            D_PROXIED=$(ddns_cfg_get PROXIED)
            D_TTL=$(ddns_cfg_get TTL)
            D_LOG=$(ddns_log_path)
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo -e "  域名 : ${BOLD}${D_DOMAIN}${NC}"
            echo -e "  模式 : ${BOLD}$([ "$D_MODE" = "dual" ] && echo 'IPv4 + IPv6' || echo '仅 IPv4')${NC}"
            echo -e "  代理 : ${BOLD}$([ "$D_PROXIED" = "true" ] && echo '开启' || echo '关闭')${NC}"
            echo -e "  TTL  : ${BOLD}${D_TTL:-60}${NC}"
            echo -e "  定时 : ${DIM}每5分钟自动更新${NC}"
            local LAST_LOG; LAST_LOG=$(tail -1 "$D_LOG" 2>/dev/null)
            [ -n "$LAST_LOG" ] && echo -e "  最新 : ${DIM}${LAST_LOG}${NC}"
            # 最后一次 IP 变更（时间 + 新旧 IP）
            if [ -f /root/.cf_last_change ]; then
                local LC_TIME LC_TYPE LC_OLD LC_NEW LC_LINE
                LC_LINE=$(cat /root/.cf_last_change 2>/dev/null)
                LC_TIME=$(echo "$LC_LINE" | cut -d'|' -f1)
                LC_TYPE=$(echo "$LC_LINE" | cut -d'|' -f2)
                LC_OLD=$(echo "$LC_LINE" | cut -d'|' -f3)
                LC_NEW=$(echo "$LC_LINE" | cut -d'|' -f4)
                if [ -n "$LC_TIME" ]; then
                    echo -e "  变更 : ${BOLD}${LC_TIME}${NC} ${DIM}(${LC_TYPE})${NC}"
                    echo -e "  IP   : ${DIM}${LC_OLD:-?}${NC} ${YELLOW}→${NC} ${GREEN}${BOLD}${LC_NEW}${NC}"
                fi
            else
                echo -e "  变更 : ${DIM}暂无 IP 变更记录${NC}"
            fi
        elif [ -f "$DDNS_ZONE_FILE" ]; then
            local D_DOMAIN D_MODE D_TOKEN_HINT
            D_DOMAIN=$(ddns_cfg_get DOMAIN)
            D_MODE=$(ddns_cfg_get MODE)
            [ -f "$DDNS_TOKEN_FILE" ] && D_TOKEN_HINT="${DIM}Token 已保存${NC}" || D_TOKEN_HINT="${YELLOW}Token 未找到${NC}"
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo -e "  域名 : ${BOLD}${D_DOMAIN}${NC}"
            echo -e "  模式 : ${BOLD}$([ "$D_MODE" = "dual" ] && echo 'IPv4 + IPv6' || echo '仅 IPv4')${NC}"
            echo -e "  Token : $D_TOKEN_HINT"
            echo ""
            echo -e "  ${DIM}检测到历史配置，可重新安装恢复定时任务${NC}"
        else
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo ""
            echo -e "  ${DIM}将动态 DNS 解析到本机 IP，适合家宽/动态 IP 场景${NC}"
            echo ""
            echo -e "  ${BOLD}安装前准备：${NC}"
            menu_div
            echo -e "  ${GREEN}①${NC} 域名已托管到 Cloudflare"
            echo -e "     将域名 NS 记录指向 Cloudflare 提供的 nameserver"
            echo ""
            echo -e "  ${GREEN}②${NC} 创建 API Token（需要以下权限）："
            echo -e "     ${DIM}→ 登录 https://dash.cloudflare.com${NC}"
            echo -e "     ${DIM}→ 右上角头像 → My Profile → API Tokens${NC}"
            echo -e "     ${DIM}→ Create Token → Custom Token${NC}"
            echo -e "     ${DIM}→ 权限：Zone / DNS / Edit${NC}"
            echo -e "     ${DIM}→ Zone Resources：Include / Specific zone / 你的域名${NC}"
            echo -e "     ${DIM}→ 点击 Continue to summary → Create Token${NC}"
            echo -e "     ${DIM}→ 复制 Token（只显示一次！）${NC}"
            echo ""
            echo -e "  ${GREEN}③${NC} 准备子域名（如 home.example.com 的 home 部分）"
            menu_div
        fi

        echo ""
        menu_div
        if [ "$D_ST" = "not_installed" ]; then
            menu_item "1" "开始安装并配置 DDNS"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        else
            menu_pair "1" "立即更新" "2" "查看日志"
            menu_pair "3" "修改配置" "6" "Telegram 通知"
            if [ "$D_ST" = "running" ]; then
                menu_pair "4" "暂停自动更新" "5" "卸载 DDNS" "$YELLOW" "$YELLOW"
            elif [ "$D_ST" = "no_cron" ]; then
                menu_pair "4" "安装 cron 并恢复" "5" "卸载 DDNS" "$GREEN" "$YELLOW"
            else
                menu_pair "4" "恢复自动更新" "5" "卸载 DDNS" "$GREEN" "$YELLOW"
            fi
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        fi
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作: ')" CH

        if [ "$D_ST" = "not_installed" ]; then
            case "$CH" in
                1) ddns_install ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1; continue ;;
            esac
        else
            case "$CH" in
                1) ddns_run_now ;;
                2) ddns_view_logs ;;
                3) warn "修改配置将重新安装 DDNS"
                   read -rp "  确认继续？(Y/n，默认Y): " C
                   [ -z "$C" ] && C="y"
                   echo "$C" | grep -qiE '^y(es)?$' && ddns_install || warn "已取消" ;;
                4) [ "$D_ST" = "running" ] && ddns_pause || ddns_resume ;;
                5) ddns_uninstall ;;
                6) ddns_tg_config ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1; continue ;;
            esac
        fi

        # 日志查看后不需要再 Enter 一次（内部已有循环）
        if [ "$CH" != "0" ] && [ "$CH" != "2" ]; then
            ui_pause
        fi
    done
}

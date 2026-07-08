# ══════════════════════════════════════════════════════════
#  DDNS 模块
# ══════════════════════════════════════════════════════════

DDNS_SCRIPT="/root/ddns.sh"
DDNS_TOKEN_FILE="/root/.cf_token"
DDNS_HUAWEI_KEY_FILE="/root/.hw_dns_aksk"
DDNS_LOG="/var/log/ddns.log"
DDNS_ZONE_FILE="/root/.cf_zone"
DDNS_TG_FILE="/root/.cf_tg"    # Telegram 通知配置

ddns_cfg_get() {
    local key="$1"
    [ -f "$DDNS_ZONE_FILE" ] || return 1
    grep "^${key}=" "$DDNS_ZONE_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

ddns_provider() {
    local provider
    provider=$(ddns_cfg_get PROVIDER 2>/dev/null || true)
    [ -n "$provider" ] || provider="cloudflare"
    echo "$provider"
}

ddns_provider_label() {
    case "$(ddns_provider)" in
        huawei) echo "华为云 DNS" ;;
        *) echo "Cloudflare" ;;
    esac
}

ddns_sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

ddns_domain_dot() {
    local domain="$1"
    case "$domain" in
        *.) echo "$domain" ;;
        *) echo "${domain}." ;;
    esac
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

ddns_truthy() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

ddns_cfg_enable_a() {
    local enabled mode
    enabled=$(ddns_cfg_get ENABLE_A 2>/dev/null || true)
    if [ -n "$enabled" ]; then
        ddns_truthy "$enabled"
        return
    fi
    mode=$(ddns_cfg_get MODE 2>/dev/null || true)
    [ "$mode" != "ipv6" ] && [ "$mode" != "aaaa" ]
}

ddns_cfg_enable_aaaa() {
    local enabled mode
    enabled=$(ddns_cfg_get ENABLE_AAAA 2>/dev/null || true)
    if [ -n "$enabled" ]; then
        ddns_truthy "$enabled"
        return
    fi
    mode=$(ddns_cfg_get MODE 2>/dev/null || true)
    [ "$mode" = "dual" ] || [ "$mode" = "ipv6" ] || [ "$mode" = "aaaa" ]
}

ddns_cfg_domain4() {
    local domain
    domain=$(ddns_cfg_get DOMAIN4 2>/dev/null || true)
    [ -n "$domain" ] || domain=$(ddns_cfg_get DOMAIN 2>/dev/null || true)
    echo "$domain"
}

ddns_cfg_domain6() {
    local domain mode
    domain=$(ddns_cfg_get DOMAIN6 2>/dev/null || true)
    if [ -z "$domain" ]; then
        mode=$(ddns_cfg_get MODE 2>/dev/null || true)
        if [ "$mode" = "dual" ] || [ "$mode" = "ipv6" ] || [ "$mode" = "aaaa" ]; then
            domain=$(ddns_cfg_get DOMAIN 2>/dev/null || true)
        fi
    fi
    echo "$domain"
}

ddns_primary_domain() {
    local domain
    if ddns_cfg_enable_a; then
        domain=$(ddns_cfg_domain4)
        [ -n "$domain" ] && { echo "$domain"; return; }
    fi
    if ddns_cfg_enable_aaaa; then
        domain=$(ddns_cfg_domain6)
        [ -n "$domain" ] && { echo "$domain"; return; }
    fi
    ddns_cfg_get DOMAIN 2>/dev/null || true
}

ddns_mode_label() {
    local domain4 domain6 has_a="false" has_aaaa="false"
    ddns_cfg_enable_a && has_a="true"
    ddns_cfg_enable_aaaa && has_aaaa="true"
    domain4=$(ddns_cfg_domain4)
    domain6=$(ddns_cfg_domain6)
    if [ "$has_a" = "true" ] && [ "$has_aaaa" = "true" ]; then
        if [ "$domain4" = "$domain6" ]; then
            echo "IPv4 + IPv6（同域名）"
        else
            echo "IPv4 + IPv6（分别设置）"
        fi
    elif [ "$has_aaaa" = "true" ]; then
        echo "仅 IPv6"
    else
        echo "仅 IPv4"
    fi
}

ddns_build_domain() {
    local sub="$1" zone="$2"
    case "$sub" in
        @) echo "$zone" ;;
        *."$zone") echo "$sub" ;;
        *) echo "${sub}.${zone}" ;;
    esac
}

ddns_cf_record_ensure() {
    local zone_id="$1" token="$2" type="$3" domain="$4" placeholder="$5" ttl="$6" proxied="$7"
    local record_resp record_count create_body create_resp create_ok
    record_resp=$(curl -s --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${domain}&type=${type}" \
        -H "Authorization: Bearer ${token}")
    record_count=$(echo "$record_resp" | python3 -c \
        "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
    if [ "$record_count" = "0" ]; then
        warn "未找到 ${type} 记录 ${domain}，正在自动创建..."
        create_body=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
            "$type" "$domain" "$placeholder" "$ttl" "$proxied")
        create_resp=$(curl -s -X POST --max-time 10 \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "$create_body")
        create_ok=$(echo "$create_resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
        if [ "$create_ok" = "True" ]; then
            info "${type} 记录已创建 ✓"
        else
            error "创建 ${type} 记录失败"
            return 1
        fi
    else
        info "${type} 记录 ${domain} 已存在 ✓"
    fi
}

ddns_type_status_file() {
    case "$1" in
        A|AAAA) echo "/root/.cf_last_status_$1" ;;
        *) echo "/root/.cf_last_status" ;;
    esac
}

ddns_type_change_file() {
    case "$1" in
        A|AAAA) echo "/root/.cf_last_change_$1" ;;
        *) echo "/root/.cf_last_change" ;;
    esac
}

ddns_line_from_state_file() {
    local type="$1" domain_filter="${2:-}" file ts record_type domain state old_ip new_ip
    file=$(ddns_type_status_file "$type")
    [ -f "$file" ] || return 1
    IFS='|' read -r ts record_type domain state old_ip new_ip < "$file"
    [ -n "$ts" ] && [ -n "$record_type" ] && [ -n "$domain" ] || return 1
    [ -z "$domain_filter" ] || [ "$domain" = "$domain_filter" ] || return 1
    case "$state" in
        unchanged) printf '[%s] OK: %s %s 未变化 %s\n' "$ts" "$record_type" "$domain" "${new_ip:-$old_ip}" ;;
        updated) printf '[%s] OK: %s %s 更新成功 %s → %s\n' "$ts" "$record_type" "$domain" "${old_ip:-?}" "${new_ip:-?}" ;;
        fetch_failed) printf '[%s] ERROR: %s %s 无法获取公网 IP\n' "$ts" "$record_type" "$domain" ;;
        invalid_ip) printf '[%s] ERROR: %s %s 获取到的 IP 非法：%s\n' "$ts" "$record_type" "$domain" "${new_ip:-?}" ;;
        missing) printf '[%s] ERROR: %s 记录不存在 %s\n' "$ts" "$record_type" "$domain" ;;
        query_failed) printf '[%s] WARN: %s %s 无法获取当前记录值\n' "$ts" "$record_type" "$domain" ;;
        verify_skipped) printf '[%s] WARN: %s %s 二次校验异常，跳过更新\n' "$ts" "$record_type" "$domain" ;;
        update_failed) printf '[%s] ERROR: %s %s 更新失败 %s → %s\n' "$ts" "$record_type" "$domain" "${old_ip:-?}" "${new_ip:-?}" ;;
        *) printf '[%s] %s: %s %s %s → %s\n' "$ts" "$state" "$record_type" "$domain" "${old_ip:-?}" "${new_ip:-?}" ;;
    esac
}

ddns_line_from_change_file() {
    local type="$1" domain_filter="${2:-}" file ts record_type domain old_ip new_ip line
    file=$(ddns_type_change_file "$type")
    if [ ! -f "$file" ] && [ -f /root/.cf_last_change ]; then
        line=$(cat /root/.cf_last_change 2>/dev/null)
        record_type=$(echo "$line" | cut -d'|' -f2)
        domain=$(echo "$line" | cut -d'|' -f5)
        if [ "$record_type" = "$type" ] && { [ -z "$domain_filter" ] || [ "$domain" = "$domain_filter" ]; }; then
            file="/root/.cf_last_change"
        fi
    fi
    [ -f "$file" ] || return 1
    IFS='|' read -r ts record_type old_ip new_ip domain < "$file"
    [ -n "$ts" ] && [ "$record_type" = "$type" ] || return 1
    [ -z "$domain_filter" ] || [ "$domain" = "$domain_filter" ] || return 1
    printf '[%s] OK: %s %s 更新成功 %s → %s\n' "$ts" "$record_type" "${domain:-?}" "${old_ip:-?}" "${new_ip:-?}"
}

ddns_latest_log_line() {
    local type="$1" domain="$2" log="$3"
    [ -n "$domain" ] && [ -f "$log" ] || return 1
    grep -F "OK: ${type} ${domain} " "$log" 2>/dev/null | tail -1
}

ddns_latest_change_log_line() {
    local type="$1" domain="$2" log="$3"
    [ -n "$domain" ] && [ -f "$log" ] || return 1
    grep -F "OK: ${type} ${domain} 更新成功" "$log" 2>/dev/null | tail -1
}

ddns_record_status_line() {
    local type="$1" domain="$2" log="$3" line
    line=$(ddns_line_from_state_file "$type" "$domain" 2>/dev/null || true)
    [ -n "$line" ] && { echo "$line"; return 0; }
    ddns_latest_log_line "$type" "$domain" "$log"
}

ddns_record_change_line() {
    local type="$1" domain="$2" log="$3" line
    line=$(ddns_line_from_change_file "$type" "$domain" 2>/dev/null || true)
    [ -n "$line" ] && { echo "$line"; return 0; }
    ddns_latest_change_log_line "$type" "$domain" "$log"
}

ddns_print_record_summary() {
    local label="$1" type="$2" domain="$3" log="$4" status_line change_line
    [ -n "$domain" ] || return 0
    status_line=$(ddns_record_status_line "$type" "$domain" "$log" 2>/dev/null || true)
    if [ -n "$status_line" ]; then
        echo -e "  最新 ${label}: ${DIM}${status_line}${NC}"
    else
        echo -e "  最新 ${label}: ${DIM}等待下一次更新${NC}"
    fi
    change_line=$(ddns_record_change_line "$type" "$domain" "$log" 2>/dev/null || true)
    if [ -n "$change_line" ]; then
        echo -e "  变更 ${label}: ${DIM}${change_line}${NC}"
    else
        echo -e "  变更 ${label}: ${DIM}暂无 IP 变更记录${NC}"
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
        if systemd_available; then
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
ddns_install_cloudflare() {
    print_header "Cloudflare DDNS 配置"
    echo -e "  ${DIM}动态 DNS：可分别将 A / AAAA 记录更新为本机公网 IP${NC}"
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
    read -rp "  根域名（如 example.com）: " DDNS_ZONE_NAME
    [ -z "$DDNS_ZONE_NAME" ] && { warn "已取消"; return; }

    local DDNS_ENABLE_A="true" DDNS_ENABLE_AAAA="false"
    local DDNS_SUB4="" DDNS_SUB6="" DDNS_DOMAIN4="" DDNS_DOMAIN6=""

    read -rp "  启用 IPv4 A 记录？(Y/n，默认Y): " DDNS_A_CH
    if echo "$DDNS_A_CH" | grep -qiE '^n(o)?$'; then
        DDNS_ENABLE_A="false"
    else
        read -rp "  IPv4 子域名（A，如 home；@ 表示根域）: " DDNS_SUB4
        [ -z "$DDNS_SUB4" ] && { warn "已取消"; return; }
        DDNS_DOMAIN4=$(ddns_build_domain "$DDNS_SUB4" "$DDNS_ZONE_NAME")
    fi

    local V6_DEFAULT="N"
    [ "$DDNS_ENABLE_A" = "false" ] && V6_DEFAULT="Y"
    read -rp "  启用 IPv6 AAAA 记录？($([ "$V6_DEFAULT" = "Y" ] && echo 'Y/n' || echo 'y/N')，默认${V6_DEFAULT}): " DDNS_AAAA_CH
    case "$DDNS_AAAA_CH" in
        "")
            [ "$V6_DEFAULT" = "Y" ] && DDNS_ENABLE_AAAA="true" || DDNS_ENABLE_AAAA="false"
            ;;
        y|Y|yes|YES) DDNS_ENABLE_AAAA="true" ;;
        *) DDNS_ENABLE_AAAA="false" ;;
    esac

    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        local DDNS_SUB6_DEFAULT="${DDNS_SUB4:-home}"
        read -rp "  IPv6 子域名（AAAA，默认 ${DDNS_SUB6_DEFAULT}；@ 表示根域）: " DDNS_SUB6
        [ -z "$DDNS_SUB6" ] && DDNS_SUB6="$DDNS_SUB6_DEFAULT"
        DDNS_DOMAIN6=$(ddns_build_domain "$DDNS_SUB6" "$DDNS_ZONE_NAME")
    fi

    if [ "$DDNS_ENABLE_A" != "true" ] && [ "$DDNS_ENABLE_AAAA" != "true" ]; then
        error "至少需要启用 IPv4 A 或 IPv6 AAAA 其中一种记录"
        return
    fi

    read -rp "  Cloudflare API Token: " DDNS_TOKEN
    [ -z "$DDNS_TOKEN" ] && { warn "已取消"; return; }

    local DDNS_MODE="ipv4"
    if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        DDNS_MODE="dual"
    elif [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        DDNS_MODE="ipv6"
    fi

    local DDNS_PROXIED="false"
    read -rp "  是否开启 Cloudflare 代理（橙云）？(y/N，默认N): " DDNS_PROXY_CH
    echo "$DDNS_PROXY_CH" | grep -qiE '^y(es)?$' && DDNS_PROXIED="true"

    local DDNS_TTL="60"
    read -rp "  TTL 秒数（默认60）: " DDNS_TTL_IN
    [ -n "$DDNS_TTL_IN" ] && echo "$DDNS_TTL_IN" | grep -qE '^[0-9]+$' && DDNS_TTL="$DDNS_TTL_IN"

    echo ""
    menu_div
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 A : ${BOLD}${DDNS_DOMAIN4}${NC}" || echo -e "  IPv4 A : ${DIM}未启用${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 AAAA : ${BOLD}${DDNS_DOMAIN6}${NC}" || echo -e "  IPv6 AAAA : ${DIM}未启用${NC}"
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

    if [ "$DDNS_ENABLE_A" = "true" ]; then
        ddns_cf_record_ensure "$ZONE_ID" "$DDNS_TOKEN" A "$DDNS_DOMAIN4" "1.1.1.1" "$DDNS_TTL" "$DDNS_PROXIED" || return
    fi
    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        ddns_cf_record_ensure "$ZONE_ID" "$DDNS_TOKEN" AAAA "$DDNS_DOMAIN6" "::1" "$DDNS_TTL" "$DDNS_PROXIED" || return
    fi

    # 保存配置
    echo "$DDNS_TOKEN" > "$DDNS_TOKEN_FILE"
    chmod 600 "$DDNS_TOKEN_FILE"
    touch "$DDNS_LOG" 2>/dev/null || { DDNS_LOG="$HOME/ddns.log"; touch "$DDNS_LOG"; }
    chmod 644 "$DDNS_LOG" 2>/dev/null || true
    local DDNS_PRIMARY_DOMAIN="${DDNS_DOMAIN4:-$DDNS_DOMAIN6}"
    {
        echo "PROVIDER=cloudflare"
        echo "DOMAIN=${DDNS_PRIMARY_DOMAIN}"
        echo "DOMAIN4=${DDNS_DOMAIN4}"
        echo "DOMAIN6=${DDNS_DOMAIN6}"
        echo "ZONE=${DDNS_ZONE_NAME}"
        echo "MODE=${DDNS_MODE}"
        echo "ENABLE_A=${DDNS_ENABLE_A}"
        echo "ENABLE_AAAA=${DDNS_ENABLE_AAAA}"
        echo "PROXIED=${DDNS_PROXIED}"
        echo "TTL=${DDNS_TTL}"
        echo "LOG=${DDNS_LOG}"
    } > "$DDNS_ZONE_FILE"

    # 生成 DDNS 执行脚本
    cat > "$DDNS_SCRIPT" << 'DDNS_INNER'
#!/bin/bash
# 注入 PATH，确保 crontab 环境下能找到 curl / python3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN4="__DOMAIN4__"
DOMAIN6="__DOMAIN6__"
ZONE="__ZONE__"
ENABLE_A="__ENABLE_A__"
ENABLE_AAAA="__ENABLE_AAAA__"
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

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

record_status_file() {
    case "$1" in
        A|AAAA) echo "/root/.cf_last_status_$1" ;;
        *) echo "/root/.cf_last_status" ;;
    esac
}

record_change_file() {
    case "$1" in
        A|AAAA) echo "/root/.cf_last_change_$1" ;;
        *) echo "/root/.cf_last_change" ;;
    esac
}

write_record_status() {
    local TYPE="$1" DOMAIN_NAME="$2" STATE="$3" OLD_IP="${4:-}" NEW_IP="${5:-}" FILE
    FILE=$(record_status_file "$TYPE")
    printf '%s|%s|%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TYPE" "$DOMAIN_NAME" "$STATE" "$OLD_IP" "$NEW_IP" > "$FILE" 2>/dev/null || return 0
    chmod 600 "$FILE" 2>/dev/null || true
}

write_record_change() {
    local TYPE="$1" DOMAIN_NAME="$2" OLD_IP="$3" NEW_IP="$4" LINE FILE
    LINE="$(date '+%Y-%m-%d %H:%M:%S')|${TYPE}|${OLD_IP}|${NEW_IP}|${DOMAIN_NAME}"
    FILE=$(record_change_file "$TYPE")
    printf '%s\n' "$LINE" > "$FILE" 2>/dev/null || true
    chmod 600 "$FILE" 2>/dev/null || true
    printf '%s\n' "$LINE" > /root/.cf_last_change 2>/dev/null || true
    chmod 600 /root/.cf_last_change 2>/dev/null || true
}

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

fetch_ip4() {
    (
        curl -4 -fsS --max-time 5 https://api.ipify.org ||
        curl -4 -fsS --max-time 5 https://ifconfig.me/ip ||
        curl -4 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n'
}

fetch_ip6() {
    local IP
    IP=$( (
        curl -6 -fsS --max-time 5 https://api64.ipify.org ||
        curl -6 -fsS --max-time 5 https://ipv6.icanhazip.com ||
        curl -6 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n')
    [ -n "$IP" ] && { echo "$IP"; return 0; }
    fetch_ip6_local
}

fetch_ip6_local() {
    command -v ip >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    ip -6 -o addr show scope global 2>/dev/null | python3 -c '
import ipaddress
import sys
candidates = []
for line in sys.stdin:
    parts = line.split()
    if "inet6" not in parts:
        continue
    try:
        addr = parts[parts.index("inet6") + 1].split("/")[0]
        ip = ipaddress.ip_address(addr)
    except Exception:
        continue
    if ip.version != 6 or ip.is_link_local or ip.is_loopback or ip.is_multicast or ip.is_unspecified:
        continue
    flags = set(parts)
    score = 0
    if "deprecated" in flags:
        score += 100
    if "temporary" in flags:
        score += 10
    candidates.append((score, str(ip)))
if candidates:
    print(sorted(candidates)[0][1])
'
}

valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && \
    echo "$1" | awk -F. '{for(i=1;i<=4;i++) if($i<0||$i>255) exit 1}'
}

valid_ipv6() {
    python3 -c "import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == 6 else 1)" "$1" 2>/dev/null
}

ZONE_ID=$(curl -s --max-time 8 "https://api.cloudflare.com/client/v4/zones?name=${ZONE}"     -H "Authorization: Bearer ${API_TOKEN}" |     python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
[ -z "$ZONE_ID" ] && {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取 Zone ID 失败" >> "$LOG_FILE"
    exit 1
}

update_record() {
    local TYPE="$1" DOMAIN_NAME="$2" NEW_IP="$3"
    [ -z "$NEW_IP" ] && return 0
    [ -z "$DOMAIN_NAME" ] && return 0
    local RECORD_ID OLD_IP RESULT SUCCESS
    RECORD_ID=$(curl -s --max-time 8         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN_NAME}&type=${TYPE}"         -H "Authorization: Bearer ${API_TOKEN}" |         python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
    [ -z "$RECORD_ID" ] && {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 记录不存在 ${DOMAIN_NAME}" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" missing "" "$NEW_IP"
        return 1
    }
    OLD_IP=$(curl -s --max-time 8         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}"         -H "Authorization: Bearer ${API_TOKEN}" |         python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)
    # OLD_IP 为空说明查询失败，跳过本次更新避免误推 Telegram
    if [ -z "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${TYPE} 无法获取当前记录值，跳过更新" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" query_failed "" "$NEW_IP"
        return 0
    fi
    if [ "$NEW_IP" = "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} 未变化 ${NEW_IP}" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" unchanged "$OLD_IP" "$NEW_IP"
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
        write_record_status "$TYPE" "$DOMAIN_NAME" verify_skipped "$OLD_IP" "$NEW_IP"
        return 0
    fi
    if [ "$NEW_IP" = "$VERIFY_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} 未变化 ${NEW_IP}（二次确认）" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" unchanged "$VERIFY_IP" "$NEW_IP"
        return 0
    fi
    local JSON_BODY
    JSON_BODY=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
        "$TYPE" "$DOMAIN_NAME" "$NEW_IP" "$TTL" "$PROXIED")
    RESULT=$(curl -s -X PUT --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$JSON_BODY")
    SUCCESS=$(echo "$RESULT" | python3 -c         "import sys,json; print(json.load(sys.stdin).get('success'))" 2>/dev/null)
    if [ "$SUCCESS" = "True" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} 更新成功 ${OLD_IP} → ${NEW_IP}" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" updated "$OLD_IP" "$NEW_IP"
        write_record_change "$TYPE" "$DOMAIN_NAME" "$OLD_IP" "$NEW_IP"
        tg_notify "🌐 <b>DDNS IP 已更新</b>
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${OLD_IP}</code>
新IP：<code>${NEW_IP}</code>
时间：$(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 更新失败 $RESULT" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "$OLD_IP" "$NEW_IP"
        return 1
    fi
}

EXIT_CODE=0

if is_true "$ENABLE_A"; then
    CURRENT_IP4=$(fetch_ip4)
    if [ -z "$CURRENT_IP4" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 无法获取公网 IPv4" >> "$LOG_FILE"
        write_record_status A "$DOMAIN4" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv4 "$CURRENT_IP4"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取到的 IPv4 非法：${CURRENT_IP4}" >> "$LOG_FILE"
        write_record_status A "$DOMAIN4" invalid_ip "" "$CURRENT_IP4"
        EXIT_CODE=1
    else
        update_record A "$DOMAIN4" "$CURRENT_IP4" || EXIT_CODE=1
    fi
fi

if is_true "$ENABLE_AAAA"; then
    CURRENT_IP6=$(fetch_ip6)
    if [ -z "$CURRENT_IP6" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 无法获取公网 IPv6" >> "$LOG_FILE"
        write_record_status AAAA "$DOMAIN6" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv6 "$CURRENT_IP6"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取到的 IPv6 非法：${CURRENT_IP6}" >> "$LOG_FILE"
        write_record_status AAAA "$DOMAIN6" invalid_ip "" "$CURRENT_IP6"
        EXIT_CODE=1
    else
        update_record AAAA "$DOMAIN6" "$CURRENT_IP6" || EXIT_CODE=1
    fi
fi

exit "$EXIT_CODE"
DDNS_INNER

    local DDNS_DOMAIN4_ESC DDNS_DOMAIN6_ESC DDNS_ZONE_ESC DDNS_LOG_ESC
    DDNS_DOMAIN4_ESC=$(ddns_sed_escape "$DDNS_DOMAIN4")
    DDNS_DOMAIN6_ESC=$(ddns_sed_escape "$DDNS_DOMAIN6")
    DDNS_ZONE_ESC=$(ddns_sed_escape "$DDNS_ZONE_NAME")
    DDNS_LOG_ESC=$(ddns_sed_escape "$DDNS_LOG")
    sed -i "s|__DOMAIN4__|${DDNS_DOMAIN4_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__DOMAIN6__|${DDNS_DOMAIN6_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__ZONE__|${DDNS_ZONE_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__ENABLE_A__|${DDNS_ENABLE_A}|g" "$DDNS_SCRIPT"
    sed -i "s|__ENABLE_AAAA__|${DDNS_ENABLE_AAAA}|g" "$DDNS_SCRIPT"
    sed -i "s|__PROXIED__|${DDNS_PROXIED}|g" "$DDNS_SCRIPT"
    sed -i "s|__TTL__|${DDNS_TTL}|g" "$DDNS_SCRIPT"
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
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 : ${BOLD}${DDNS_DOMAIN4}${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 : ${BOLD}${DDNS_DOMAIN6}${NC}"
    echo -e "  日志 : ${DIM}${DDNS_LOG}${NC}"
}

ddns_install_huawei() {
    print_header "华为云 DDNS 配置"
    echo -e "  ${DIM}动态 DNS：通过华为云 DNS API 更新 A / AAAA 记录${NC}"
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
    read -rp "  根域名（如 example.com，需已托管到华为云 DNS）: " DDNS_ZONE_NAME
    [ -z "$DDNS_ZONE_NAME" ] && { warn "已取消"; return; }
    DDNS_ZONE_NAME=${DDNS_ZONE_NAME%.}

    local DDNS_ENDPOINT="https://dns.myhuaweicloud.com"
    read -rp "  API Endpoint（默认 ${DDNS_ENDPOINT}）: " DDNS_ENDPOINT_IN
    [ -n "$DDNS_ENDPOINT_IN" ] && DDNS_ENDPOINT="$DDNS_ENDPOINT_IN"
    DDNS_ENDPOINT=${DDNS_ENDPOINT%/}
    case "$DDNS_ENDPOINT" in
        http://*|https://*) : ;;
        *) DDNS_ENDPOINT="https://${DDNS_ENDPOINT}" ;;
    esac

    local DDNS_ENABLE_A="true" DDNS_ENABLE_AAAA="false"
    local DDNS_SUB4="" DDNS_SUB6="" DDNS_DOMAIN4="" DDNS_DOMAIN6=""

    read -rp "  启用 IPv4 A 记录？(Y/n，默认Y): " DDNS_A_CH
    if echo "$DDNS_A_CH" | grep -qiE '^n(o)?$'; then
        DDNS_ENABLE_A="false"
    else
        read -rp "  IPv4 子域名（A，如 home；@ 表示根域）: " DDNS_SUB4
        [ -z "$DDNS_SUB4" ] && { warn "已取消"; return; }
        DDNS_DOMAIN4=$(ddns_build_domain "$DDNS_SUB4" "$DDNS_ZONE_NAME")
    fi

    local V6_DEFAULT="N"
    [ "$DDNS_ENABLE_A" = "false" ] && V6_DEFAULT="Y"
    read -rp "  启用 IPv6 AAAA 记录？($([ "$V6_DEFAULT" = "Y" ] && echo 'Y/n' || echo 'y/N')，默认${V6_DEFAULT}): " DDNS_AAAA_CH
    case "$DDNS_AAAA_CH" in
        "")
            [ "$V6_DEFAULT" = "Y" ] && DDNS_ENABLE_AAAA="true" || DDNS_ENABLE_AAAA="false"
            ;;
        y|Y|yes|YES) DDNS_ENABLE_AAAA="true" ;;
        *) DDNS_ENABLE_AAAA="false" ;;
    esac

    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        local DDNS_SUB6_DEFAULT="${DDNS_SUB4:-home}"
        read -rp "  IPv6 子域名（AAAA，默认 ${DDNS_SUB6_DEFAULT}；@ 表示根域）: " DDNS_SUB6
        [ -z "$DDNS_SUB6" ] && DDNS_SUB6="$DDNS_SUB6_DEFAULT"
        DDNS_DOMAIN6=$(ddns_build_domain "$DDNS_SUB6" "$DDNS_ZONE_NAME")
    fi

    if [ "$DDNS_ENABLE_A" != "true" ] && [ "$DDNS_ENABLE_AAAA" != "true" ]; then
        error "至少需要启用 IPv4 A 或 IPv6 AAAA 其中一种记录"
        return
    fi

    read -rp "  华为云 Access Key ID（AK）: " DDNS_HW_AK
    [ -z "$DDNS_HW_AK" ] && { warn "已取消"; return; }
    read -rp "  华为云 Secret Access Key（SK）: " DDNS_HW_SK
    [ -z "$DDNS_HW_SK" ] && { warn "已取消"; return; }

    local DDNS_TTL="300"
    read -rp "  TTL 秒数（默认300）: " DDNS_TTL_IN
    [ -n "$DDNS_TTL_IN" ] && echo "$DDNS_TTL_IN" | grep -qE '^[0-9]+$' && DDNS_TTL="$DDNS_TTL_IN"

    echo ""
    menu_div
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 A    : ${BOLD}${DDNS_DOMAIN4}${NC}" || echo -e "  IPv4 A    : ${DIM}未启用${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 AAAA : ${BOLD}${DDNS_DOMAIN6}${NC}" || echo -e "  IPv6 AAAA : ${DIM}未启用${NC}"
    echo -e "  Endpoint  : ${BOLD}${DDNS_ENDPOINT}${NC}"
    echo -e "  TTL       : ${BOLD}${DDNS_TTL}${NC}"
    echo -e "  AK        : ${BOLD}${DDNS_HW_AK:0:8}…${NC}"
    menu_div
    echo ""
    read -rp "  确认安装？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    {
        echo "AK=${DDNS_HW_AK}"
        echo "SK=${DDNS_HW_SK}"
    } > "$DDNS_HUAWEI_KEY_FILE"
    chmod 600 "$DDNS_HUAWEI_KEY_FILE"

    touch "$DDNS_LOG" 2>/dev/null || { DDNS_LOG="$HOME/ddns.log"; touch "$DDNS_LOG"; }
    chmod 644 "$DDNS_LOG" 2>/dev/null || true
    local DDNS_PRIMARY_DOMAIN="${DDNS_DOMAIN4:-$DDNS_DOMAIN6}"
    {
        echo "PROVIDER=huawei"
        echo "DOMAIN=${DDNS_PRIMARY_DOMAIN}"
        echo "DOMAIN4=${DDNS_DOMAIN4}"
        echo "DOMAIN6=${DDNS_DOMAIN6}"
        echo "ZONE=${DDNS_ZONE_NAME}"
        echo "MODE=$([ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ] && echo dual || { [ "$DDNS_ENABLE_AAAA" = "true" ] && echo ipv6 || echo ipv4; })"
        echo "ENABLE_A=${DDNS_ENABLE_A}"
        echo "ENABLE_AAAA=${DDNS_ENABLE_AAAA}"
        echo "ENDPOINT=${DDNS_ENDPOINT}"
        echo "TTL=${DDNS_TTL}"
        echo "LOG=${DDNS_LOG}"
    } > "$DDNS_ZONE_FILE"

    cat > "$DDNS_SCRIPT" << 'DDNS_HUAWEI_INNER'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN4="__DOMAIN4__"
DOMAIN6="__DOMAIN6__"
ZONE="__ZONE__"
ENDPOINT="__ENDPOINT__"
ENABLE_A="__ENABLE_A__"
ENABLE_AAAA="__ENABLE_AAAA__"
TTL="__TTL__"
KEY_FILE="/root/.hw_dns_aksk"
LOG_FILE="__LOG__"

ENDPOINT=${ENDPOINT%/}
ZONE_DOT="${ZONE%.}."
AK=$(grep "^AK=" "$KEY_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
SK=$(grep "^SK=" "$KEY_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [ -z "$AK" ] || [ -z "$SK" ]; then
    exit 1
fi

if [ -f "$LOG_FILE" ]; then
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_LINES" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

fqdn_dot() {
    local NAME="$1"
    case "$NAME" in
        *.) echo "$NAME" ;;
        *) echo "${NAME}." ;;
    esac
}

log_line() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
}

record_status_file() {
    case "$1" in
        A|AAAA) echo "/root/.cf_last_status_$1" ;;
        *) echo "/root/.cf_last_status" ;;
    esac
}

record_change_file() {
    case "$1" in
        A|AAAA) echo "/root/.cf_last_change_$1" ;;
        *) echo "/root/.cf_last_change" ;;
    esac
}

write_record_status() {
    local TYPE="$1" DOMAIN_NAME="$2" STATE="$3" OLD_IP="${4:-}" NEW_IP="${5:-}" FILE
    FILE=$(record_status_file "$TYPE")
    printf '%s|%s|%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TYPE" "$DOMAIN_NAME" "$STATE" "$OLD_IP" "$NEW_IP" > "$FILE" 2>/dev/null || return 0
    chmod 600 "$FILE" 2>/dev/null || true
}

write_record_change() {
    local TYPE="$1" DOMAIN_NAME="$2" OLD_IP="$3" NEW_IP="$4" LINE FILE
    LINE="$(date '+%Y-%m-%d %H:%M:%S')|${TYPE}|${OLD_IP}|${NEW_IP}|${DOMAIN_NAME}"
    FILE=$(record_change_file "$TYPE")
    printf '%s\n' "$LINE" > "$FILE" 2>/dev/null || true
    chmod 600 "$FILE" 2>/dev/null || true
    printf '%s\n' "$LINE" > /root/.cf_last_change 2>/dev/null || true
    chmod 600 /root/.cf_last_change 2>/dev/null || true
}

tg_notify() {
    local MSG="$1"
    local TG_FILE="/root/.cf_tg"
    [ -f "$TG_FILE" ] || return 0
    local B_TOKEN C_ID
    B_TOKEN=$(grep "^BOT_TOKEN=" "$TG_FILE" | cut -d= -f2-)
    C_ID=$(grep "^CHAT_ID=" "$TG_FILE" | cut -d= -f2-)
    [ -z "$B_TOKEN" ] || [ -z "$C_ID" ] && return 0
    curl -s --max-time 15 \
        "https://api.telegram.org/bot${B_TOKEN}/sendMessage" \
        -d "chat_id=${C_ID}" \
        -d "text=${MSG}" \
        -d "parse_mode=HTML" > /dev/null 2>&1
}

fetch_ip4() {
    (
        curl -4 -fsS --max-time 5 https://api.ipify.org ||
        curl -4 -fsS --max-time 5 https://ifconfig.me/ip ||
        curl -4 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n'
}

fetch_ip6() {
    local IP
    IP=$( (
        curl -6 -fsS --max-time 5 https://api64.ipify.org ||
        curl -6 -fsS --max-time 5 https://ipv6.icanhazip.com ||
        curl -6 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n')
    [ -n "$IP" ] && { echo "$IP"; return 0; }
    fetch_ip6_local
}

fetch_ip6_local() {
    command -v ip >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    ip -6 -o addr show scope global 2>/dev/null | python3 -c '
import ipaddress
import sys
candidates = []
for line in sys.stdin:
    parts = line.split()
    if "inet6" not in parts:
        continue
    try:
        addr = parts[parts.index("inet6") + 1].split("/")[0]
        ip = ipaddress.ip_address(addr)
    except Exception:
        continue
    if ip.version != 6 or ip.is_link_local or ip.is_loopback or ip.is_multicast or ip.is_unspecified:
        continue
    flags = set(parts)
    score = 0
    if "deprecated" in flags:
        score += 100
    if "temporary" in flags:
        score += 10
    candidates.append((score, str(ip)))
if candidates:
    print(sorted(candidates)[0][1])
'
}

valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && \
    echo "$1" | awk -F. '{for(i=1;i<=4;i++) if($i<0||$i>255) exit 1}'
}

valid_ipv6() {
    python3 -c "import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == 6 else 1)" "$1" 2>/dev/null
}

huawei_api() {
    local METHOD="$1" API_PATH="$2" QUERY="${3:-}" BODY="${4:-}"
    HUAWEI_AK="$AK" HUAWEI_SK="$SK" HUAWEI_ENDPOINT="$ENDPOINT" \
    HUAWEI_METHOD="$METHOD" HUAWEI_PATH="$API_PATH" HUAWEI_QUERY="$QUERY" HUAWEI_BODY="$BODY" \
    python3 <<'PY'
import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ak = os.environ["HUAWEI_AK"]
sk = os.environ["HUAWEI_SK"].encode()
endpoint = os.environ["HUAWEI_ENDPOINT"].rstrip("/")
if "://" not in endpoint:
    endpoint = "https://" + endpoint
method = os.environ["HUAWEI_METHOD"].upper()
api_path = os.environ["HUAWEI_PATH"]
query = os.environ.get("HUAWEI_QUERY", "")
body = os.environ.get("HUAWEI_BODY", "")

parts = urllib.parse.urlsplit(endpoint)
base_path = parts.path.rstrip("/")
path = base_path + (api_path if api_path.startswith("/") else "/" + api_path)
host = parts.netloc
sdk_date = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

params = urllib.parse.parse_qsl(query, keep_blank_values=True)
canonical_query = urllib.parse.urlencode(sorted(params), doseq=True, safe="-_.~")
canonical_uri = urllib.parse.quote(path, safe="/-_.~")
if not canonical_uri.endswith("/"):
    canonical_uri += "/"
payload_hash = hashlib.sha256(body.encode()).hexdigest()
signed_headers = "content-type;host;x-sdk-date"
canonical_headers = (
    "content-type:application/json\n"
    f"host:{host}\n"
    f"x-sdk-date:{sdk_date}\n"
)
canonical_request = "\n".join([
    method,
    canonical_uri,
    canonical_query,
    canonical_headers,
    signed_headers,
    payload_hash,
])
algorithm = "SDK-HMAC-SHA256"
hashed_request = hashlib.sha256(canonical_request.encode()).hexdigest()
string_to_sign = "\n".join([algorithm, sdk_date, hashed_request])
signature = hmac.new(sk, string_to_sign.encode(), hashlib.sha256).hexdigest()
authorization = f"{algorithm} Access={ak}, SignedHeaders={signed_headers}, Signature={signature}"

url = f"{parts.scheme}://{host}{path}"
if canonical_query:
    url += "?" + canonical_query
data = body.encode() if method not in ("GET", "HEAD") else None
headers = {
    "Content-Type": "application/json",
    "Host": host,
    "X-Sdk-Date": sdk_date,
    "Authorization": authorization,
}
req = urllib.request.Request(url, data=data, headers=headers, method=method)
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        sys.stdout.write(resp.read().decode())
except urllib.error.HTTPError as exc:
    sys.stdout.write(exc.read().decode())
except Exception:
    sys.exit(1)
PY
}

json_zone_id() {
    JSON_INPUT=$(cat) python3 - "$ZONE_DOT" <<'PY'
import json
import os
import sys
target = sys.argv[1].rstrip(".") + "."
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    sys.exit(0)
for zone in data.get("zones", []):
    name = (zone.get("name") or "").rstrip(".") + "."
    if name == target and zone.get("zone_type", "public") == "public":
        print(zone.get("id", ""))
        break
PY
}

json_record_info() {
    local TYPE="$1" DOMAIN_NAME="$2"
    JSON_INPUT=$(cat) python3 - "$TYPE" "$DOMAIN_NAME" <<'PY'
import json
import os
import sys
rtype = sys.argv[1]
target = sys.argv[2].rstrip(".") + "."
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    sys.exit(0)
for record in data.get("recordsets", []):
    name = (record.get("name") or "").rstrip(".") + "."
    if name == target and record.get("type") == rtype:
        records = record.get("records") or []
        print(f"{record.get('id', '')}|{records[0] if records else ''}")
        break
PY
}

json_top_record() {
    JSON_INPUT=$(cat) python3 <<'PY'
import json
import os
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    raise SystemExit(0)
records = data.get("records") or []
print(records[0] if records else "")
PY
}

json_top_id() {
    JSON_INPUT=$(cat) python3 <<'PY'
import json
import os
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    raise SystemExit(0)
print(data.get("id", ""))
PY
}

record_body() {
    local TYPE="$1" DOMAIN_NAME="$2" NEW_IP="$3"
    python3 - "$TYPE" "$DOMAIN_NAME" "$TTL" "$NEW_IP" <<'PY'
import json
import sys
rtype, name, ttl, value = sys.argv[1:]
body = {
    "name": name.rstrip(".") + ".",
    "type": rtype,
    "ttl": int(ttl),
    "records": [value],
    "description": "VPS TOOLS DDNS",
}
print(json.dumps(body, separators=(",", ":")))
PY
}

ZONE_RESP=$(huawei_api GET "/v2/zones" "type=public&limit=500" "")
ZONE_ID=$(printf '%s' "$ZONE_RESP" | json_zone_id)
[ -z "$ZONE_ID" ] && {
    log_line ERROR "获取华为云 Zone ID 失败，请检查 AK/SK、Endpoint 和域名 ${ZONE}"
    exit 1
}

update_record() {
    local TYPE="$1" DOMAIN_NAME="$2" NEW_IP="$3"
    [ -z "$NEW_IP" ] && return 0
    [ -z "$DOMAIN_NAME" ] && return 0
    local DOMAIN_DOT RECORD_RESP RECORD_INFO RECORD_ID OLD_IP BODY RESULT UPDATED_IP CREATED_ID
    DOMAIN_DOT=$(fqdn_dot "$DOMAIN_NAME")
    RECORD_RESP=$(huawei_api GET "/v2/zones/${ZONE_ID}/recordsets" "search_mode=equal&type=${TYPE}&name=${DOMAIN_DOT}&limit=100" "")
    RECORD_INFO=$(printf '%s' "$RECORD_RESP" | json_record_info "$TYPE" "$DOMAIN_DOT")
    RECORD_ID=${RECORD_INFO%%|*}
    OLD_IP=${RECORD_INFO#*|}
    if [ -z "$RECORD_ID" ]; then
        BODY=$(record_body "$TYPE" "$DOMAIN_DOT" "$NEW_IP")
        RESULT=$(huawei_api POST "/v2/zones/${ZONE_ID}/recordsets" "" "$BODY")
        CREATED_ID=$(printf '%s' "$RESULT" | json_top_id)
        if [ -n "$CREATED_ID" ]; then
            log_line OK "${TYPE} ${DOMAIN_NAME} 创建成功 ${NEW_IP}"
            write_record_status "$TYPE" "$DOMAIN_NAME" updated "" "$NEW_IP"
            write_record_change "$TYPE" "$DOMAIN_NAME" "" "$NEW_IP"
            return 0
        fi
        log_line ERROR "${TYPE} ${DOMAIN_NAME} 创建失败 ${RESULT}"
        write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "" "$NEW_IP"
        return 1
    fi
    if [ -z "$OLD_IP" ]; then
        log_line WARN "${TYPE} ${DOMAIN_NAME} 无法获取当前记录值，跳过更新"
        write_record_status "$TYPE" "$DOMAIN_NAME" query_failed "" "$NEW_IP"
        return 0
    fi
    if [ "$NEW_IP" = "$OLD_IP" ]; then
        log_line OK "${TYPE} ${DOMAIN_NAME} 未变化 ${NEW_IP}"
        write_record_status "$TYPE" "$DOMAIN_NAME" unchanged "$OLD_IP" "$NEW_IP"
        return 0
    fi
    BODY=$(record_body "$TYPE" "$DOMAIN_DOT" "$NEW_IP")
    RESULT=$(huawei_api PUT "/v2.1/zones/${ZONE_ID}/recordsets/${RECORD_ID}" "" "$BODY")
    UPDATED_IP=$(printf '%s' "$RESULT" | json_top_record)
    if [ "$UPDATED_IP" = "$NEW_IP" ]; then
        log_line OK "${TYPE} ${DOMAIN_NAME} 更新成功 ${OLD_IP} → ${NEW_IP}"
        write_record_status "$TYPE" "$DOMAIN_NAME" updated "$OLD_IP" "$NEW_IP"
        write_record_change "$TYPE" "$DOMAIN_NAME" "$OLD_IP" "$NEW_IP"
        tg_notify "🌐 <b>DDNS IP 已更新</b>
服务商：华为云 DNS
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${OLD_IP}</code>
新IP：<code>${NEW_IP}</code>
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        return 0
    fi
    log_line ERROR "${TYPE} ${DOMAIN_NAME} 更新失败 ${RESULT}"
    write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "$OLD_IP" "$NEW_IP"
    return 1
}

EXIT_CODE=0

if is_true "$ENABLE_A"; then
    CURRENT_IP4=$(fetch_ip4)
    if [ -z "$CURRENT_IP4" ]; then
        log_line ERROR "A ${DOMAIN4} 无法获取公网 IPv4"
        write_record_status A "$DOMAIN4" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv4 "$CURRENT_IP4"; then
        log_line ERROR "A ${DOMAIN4} 获取到的 IPv4 非法：${CURRENT_IP4}"
        write_record_status A "$DOMAIN4" invalid_ip "" "$CURRENT_IP4"
        EXIT_CODE=1
    else
        update_record A "$DOMAIN4" "$CURRENT_IP4" || EXIT_CODE=1
    fi
fi

if is_true "$ENABLE_AAAA"; then
    CURRENT_IP6=$(fetch_ip6)
    if [ -z "$CURRENT_IP6" ]; then
        log_line ERROR "AAAA ${DOMAIN6} 无法获取公网 IPv6"
        write_record_status AAAA "$DOMAIN6" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv6 "$CURRENT_IP6"; then
        log_line ERROR "AAAA ${DOMAIN6} 获取到的 IPv6 非法：${CURRENT_IP6}"
        write_record_status AAAA "$DOMAIN6" invalid_ip "" "$CURRENT_IP6"
        EXIT_CODE=1
    else
        update_record AAAA "$DOMAIN6" "$CURRENT_IP6" || EXIT_CODE=1
    fi
fi

exit "$EXIT_CODE"
DDNS_HUAWEI_INNER

    local DDNS_DOMAIN4_ESC DDNS_DOMAIN6_ESC DDNS_ZONE_ESC DDNS_ENDPOINT_ESC DDNS_LOG_ESC
    DDNS_DOMAIN4_ESC=$(ddns_sed_escape "$DDNS_DOMAIN4")
    DDNS_DOMAIN6_ESC=$(ddns_sed_escape "$DDNS_DOMAIN6")
    DDNS_ZONE_ESC=$(ddns_sed_escape "$DDNS_ZONE_NAME")
    DDNS_ENDPOINT_ESC=$(ddns_sed_escape "$DDNS_ENDPOINT")
    DDNS_LOG_ESC=$(ddns_sed_escape "$DDNS_LOG")
    sed -i "s|__DOMAIN4__|${DDNS_DOMAIN4_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__DOMAIN6__|${DDNS_DOMAIN6_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__ZONE__|${DDNS_ZONE_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__ENDPOINT__|${DDNS_ENDPOINT_ESC}|g" "$DDNS_SCRIPT"
    sed -i "s|__ENABLE_A__|${DDNS_ENABLE_A}|g" "$DDNS_SCRIPT"
    sed -i "s|__ENABLE_AAAA__|${DDNS_ENABLE_AAAA}|g" "$DDNS_SCRIPT"
    sed -i "s|__TTL__|${DDNS_TTL}|g" "$DDNS_SCRIPT"
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
    info "华为云 DDNS 配置完成 ✓"
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 : ${BOLD}${DDNS_DOMAIN4}${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 : ${BOLD}${DDNS_DOMAIN6}${NC}"
    echo -e "  日志 : ${DIM}${DDNS_LOG}${NC}"
}

ddns_install() {
    print_header "DDNS 服务商"
    echo -e "  ${DIM}选择要使用的 DNS 服务商。已有 Cloudflare 配置不会自动迁移。${NC}"
    echo ""
    menu_div
    menu_item "1" "Cloudflare"
    menu_item "2" "华为云 DNS"
    menu_item "0" "返回上级" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择服务商 [1-2]: ')" PROVIDER_CH
    case "$PROVIDER_CH" in
        1|"") ddns_install_cloudflare ;;
        2) ddns_install_huawei ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
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
            local TG_DOMAIN_TEXT
            TG_DOMAIN_TEXT="服务商：$(ddns_provider_label)
模式：$(ddns_mode_label)"
            if ddns_cfg_enable_a; then
                TG_DOMAIN_TEXT="${TG_DOMAIN_TEXT}
IPv4：$(ddns_cfg_domain4)"
            fi
            if ddns_cfg_enable_aaaa; then
                TG_DOMAIN_TEXT="${TG_DOMAIN_TEXT}
IPv6：$(ddns_cfg_domain6)"
            fi
            RESP=$(curl -s --max-time 10 \
                "https://api.telegram.org/bot${BOT}/sendMessage" \
                --data-urlencode "chat_id=${CHAT}" \
                --data-urlencode "text=🔔 DDNS 通知测试
${TG_DOMAIN_TEXT}
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
    warn "将移除 crontab 定时任务、DDNS 脚本和 API 凭据文件"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    ( crontab -l 2>/dev/null | grep -v "ddns.sh" ) | crontab - 2>/dev/null
    info "crontab 定时任务已移除 ✓"
    rm -f "$DDNS_SCRIPT" && info "DDNS 脚本已删除 ✓"
    rm -f "$DDNS_TOKEN_FILE" && info "Token 文件已删除 ✓"
    rm -f "$DDNS_HUAWEI_KEY_FILE" && info "华为云 AK/SK 文件已删除 ✓"
    rm -f "$DDNS_ZONE_FILE"
    rm -f /root/.cf_last_change /root/.cf_last_change_A /root/.cf_last_change_AAAA
    rm -f /root/.cf_last_status_A /root/.cf_last_status_AAAA
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

        local D_PROVIDER_LABEL D_TITLE
        if [ -f "$DDNS_ZONE_FILE" ]; then
            D_PROVIDER_LABEL=$(ddns_provider_label)
            D_TITLE="${D_PROVIDER_LABEL} DDNS"
        else
            D_PROVIDER_LABEL="DDNS"
            D_TITLE="DDNS"
        fi
        print_header "$D_TITLE"

        if [ "$D_ST" != "not_installed" ] && [ -f "$DDNS_ZONE_FILE" ]; then
            local D_DOMAIN4 D_DOMAIN6 D_MODE_LABEL D_PROVIDER D_PROXIED D_ENDPOINT D_TTL D_LOG
            D_DOMAIN4=$(ddns_cfg_domain4)
            D_DOMAIN6=$(ddns_cfg_domain6)
            D_MODE_LABEL=$(ddns_mode_label)
            D_PROVIDER=$(ddns_provider)
            D_PROXIED=$(ddns_cfg_get PROXIED)
            D_ENDPOINT=$(ddns_cfg_get ENDPOINT)
            D_TTL=$(ddns_cfg_get TTL)
            D_LOG=$(ddns_log_path)
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo -e "  服务商 : ${BOLD}${D_PROVIDER_LABEL}${NC}"
            echo -e "  模式 : ${BOLD}${D_MODE_LABEL}${NC}"
            if ddns_cfg_enable_a; then
                echo -e "  IPv4 : ${BOLD}${D_DOMAIN4:-未配置}${NC} ${DIM}(A)${NC}"
            else
                echo -e "  IPv4 : ${DIM}未启用${NC}"
            fi
            if ddns_cfg_enable_aaaa; then
                echo -e "  IPv6 : ${BOLD}${D_DOMAIN6:-未配置}${NC} ${DIM}(AAAA)${NC}"
            else
                echo -e "  IPv6 : ${DIM}未启用${NC}"
            fi
            if [ "$D_PROVIDER" = "huawei" ]; then
                echo -e "  Endpoint : ${BOLD}${D_ENDPOINT:-https://dns.myhuaweicloud.com}${NC}"
            else
                echo -e "  代理 : ${BOLD}$([ "$D_PROXIED" = "true" ] && echo '开启' || echo '关闭')${NC}"
            fi
            echo -e "  TTL  : ${BOLD}${D_TTL:-60}${NC}"
            echo -e "  定时 : ${DIM}每5分钟自动更新${NC}"
            ddns_cfg_enable_a && ddns_print_record_summary "IPv4" A "$D_DOMAIN4" "$D_LOG"
            ddns_cfg_enable_aaaa && ddns_print_record_summary "IPv6" AAAA "$D_DOMAIN6" "$D_LOG"
        elif [ -f "$DDNS_ZONE_FILE" ]; then
            local D_DOMAIN4 D_DOMAIN6 D_MODE_LABEL D_PROVIDER D_TOKEN_HINT
            D_DOMAIN4=$(ddns_cfg_domain4)
            D_DOMAIN6=$(ddns_cfg_domain6)
            D_MODE_LABEL=$(ddns_mode_label)
            D_PROVIDER=$(ddns_provider)
            if [ "$D_PROVIDER" = "huawei" ]; then
                [ -f "$DDNS_HUAWEI_KEY_FILE" ] && D_TOKEN_HINT="${DIM}AK/SK 已保存${NC}" || D_TOKEN_HINT="${YELLOW}AK/SK 未找到${NC}"
            else
                [ -f "$DDNS_TOKEN_FILE" ] && D_TOKEN_HINT="${DIM}Token 已保存${NC}" || D_TOKEN_HINT="${YELLOW}Token 未找到${NC}"
            fi
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo -e "  服务商 : ${BOLD}${D_PROVIDER_LABEL}${NC}"
            echo -e "  模式 : ${BOLD}${D_MODE_LABEL}${NC}"
            ddns_cfg_enable_a && echo -e "  IPv4 : ${BOLD}${D_DOMAIN4:-未配置}${NC} ${DIM}(A)${NC}"
            ddns_cfg_enable_aaaa && echo -e "  IPv6 : ${BOLD}${D_DOMAIN6:-未配置}${NC} ${DIM}(AAAA)${NC}"
            echo -e "  凭据 : $D_TOKEN_HINT"
            echo ""
            echo -e "  ${DIM}检测到历史配置，可重新安装恢复定时任务${NC}"
        else
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo ""
            echo -e "  ${DIM}将动态 DNS 解析到本机 IP，适合家宽/动态 IP 场景${NC}"
            echo ""
            echo -e "  ${BOLD}安装前准备：${NC}"
            menu_div
            echo -e "  ${GREEN}①${NC} 域名已托管到 Cloudflare 或华为云 DNS"
            echo -e "     将域名 NS 记录指向对应服务商提供的 nameserver"
            echo ""
            echo -e "  ${GREEN}②${NC} 准备 API 凭据"
            echo -e "     ${DIM}Cloudflare：API Token，权限 Zone / DNS / Edit${NC}"
            echo -e "     ${DIM}华为云：Access Key ID（AK）和 Secret Access Key（SK），账号需有 DNS 写权限${NC}"
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
                   if echo "$C" | grep -qiE '^y(es)?$'; then
                       ddns_install
                   else
                       warn "已取消"
                   fi ;;
                4)
                   if [ "$D_ST" = "running" ]; then
                       ddns_pause
                   else
                       ddns_resume
                   fi ;;
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

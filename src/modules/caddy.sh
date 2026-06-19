# ══════════════════════════════════════════════════════════
#  Caddy 模块
# ══════════════════════════════════════════════════════════

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_LOG="/var/log/caddy/access.log"

# ── 检测 Caddy 状态 ───────────────────────────────────────
caddy_status() {
    if ! command -v caddy &>/dev/null; then
        echo "not_installed"
    elif svc_is_active caddy; then
        echo "running"
    else
        echo "stopped"
    fi
}

# ── 安装后初始化 ──────────────────────────────────────────

caddy_post_install() {
    mkdir -p /etc/caddy /var/log/caddy
    if [ ! -f "$CADDYFILE" ]; then
        cat > "$CADDYFILE" << 'CEOF'
# Caddy 配置文件 — 由 VPS 开荒脚本生成
# 文档：https://caddyserver.com/docs/caddyfile

# 反向代理示例：
# example.com {
#     reverse_proxy localhost:8080
# }

# 静态网站示例：
# example.com {
#     root * /var/www/html
#     file_server
# }
CEOF
        info "已创建默认 Caddyfile：$CADDYFILE"
    fi
    svc_enable caddy
    svc_start caddy || true
    info "Caddy 已启动 ✓"
}

# ── 安装 Caddy（apt/apk/yum/二进制）─────────────────────
caddy_install() {
    print_header "安装 Caddy"
    info "开始安装 Caddy..."
    echo ""

    if command -v apt-get &>/dev/null; then
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl &>/dev/null
        curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
            | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
            | tee /etc/apt/sources.list.d/caddy-stable.list &>/dev/null
        apt-get update -qq &>/dev/null
        apt-get install -y caddy 2>/dev/null && info "Caddy 安装成功 ✓" || caddy_install_binary
    elif command -v apk &>/dev/null; then
        apk add --no-cache caddy 2>/dev/null && info "Caddy 安装成功 ✓" || caddy_install_binary
    elif command -v yum &>/dev/null; then
        yum install -y yum-plugin-copr &>/dev/null
        yum copr enable @caddy/caddy -y &>/dev/null
        yum install -y caddy 2>/dev/null && info "Caddy 安装成功 ✓" || caddy_install_binary
    elif command -v dnf &>/dev/null; then
        dnf install -y yum-plugin-copr &>/dev/null
        dnf copr enable @caddy/caddy -y &>/dev/null
        dnf install -y caddy 2>/dev/null && info "Caddy 安装成功 ✓" || caddy_install_binary
    else
        caddy_install_binary
    fi

    caddy_post_install
}

# 二进制安装（通用回退）
caddy_install_binary() {
    info "从 GitHub 下载 Caddy 二进制..."
    local ARCH; ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) error "不支持的架构：$ARCH"; return 1 ;;
    esac

    local TMP; TMP=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/caddy_tmp_$$" && echo "/tmp/caddy_tmp_$$"; })
    local URL="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${ARCH}.tar.gz"

    if curl -fsSL "$URL" -o "$TMP/caddy.tar.gz"; then
        tar -xzf "$TMP/caddy.tar.gz" -C "$TMP"
        install -m 755 "$TMP/caddy" /usr/local/bin/caddy
        rm -rf "$TMP"
        info "Caddy 二进制安装到 /usr/local/bin/caddy ✓"
    else
        rm -rf "$TMP"
        error "下载失败，请检查网络"
        return 1
    fi

    # 创建 systemd service
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        useradd -r -d /var/lib/caddy -s /sbin/nologin caddy 2>/dev/null || true
        cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit]
Description=Caddy Web Server
After=network.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCEOF
        svc_daemon_reload
    fi
}

# ── 卸载 Caddy ────────────────────────────────────────────
caddy_uninstall() {
    print_header "卸载 Caddy"
    warn "即将卸载 Caddy（配置文件保留）"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    svc_stop caddy || true
    svc_disable caddy
    pkg_remove caddy 2>/dev/null
    rm -f /usr/local/bin/caddy /etc/systemd/system/caddy.service
    svc_daemon_reload
    info "Caddy 已卸载 ✓（配置文件已保留）"
}

# ── 重载配置 ──────────────────────────────────────────────
# 安全追加 Caddy 配置块：先备份 → 追加 → validate，失败则还原，不污染正式配置
caddy_append_safe() {
    local BLOCK="$1"
    local BAK
    BAK="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDYFILE" "$BAK" 2>/dev/null
    printf '%s\n' "$BLOCK" >> "$CADDYFILE"
    if caddy validate --config "$CADDYFILE" 2>/tmp/caddy_err; then
        rm -f "$BAK" 2>/dev/null
        return 0
    fi
    # 验证失败：还原备份
    cp "$BAK" "$CADDYFILE" 2>/dev/null
    rm -f "$BAK" 2>/dev/null
    error "新配置验证失败，已还原（未写入）："
    while IFS= read -r l; do echo -e "  ${RED}$l${NC}"; done < /tmp/caddy_err
    return 1
}

caddy_reload_config() {
    echo ""
    info "验证 Caddyfile 语法..."
    if caddy validate --config "$CADDYFILE" 2>/tmp/caddy_err; then
        info "语法验证通过 ✓"
        if svc_is_active caddy; then
            caddy reload --config "$CADDYFILE" 2>/dev/null && info "配置已重载 ✓"
        else
            svc_start caddy \
                || caddy start --config "$CADDYFILE" &>/dev/null
            info "Caddy 已启动 ✓"
        fi
    else
        error "Caddyfile 语法错误："
        while IFS= read -r l; do echo -e "  ${RED}$l${NC}"; done < /tmp/caddy_err
        return 1
    fi
}

# ── 查看所有站点 ──────────────────────────────────────────
caddy_list_sites() {
    print_header "当前 Caddy 站点"
    if [ ! -f "$CADDYFILE" ]; then warn "Caddyfile 不存在"; return; fi

    menu_div
    local i=0
    while IFS= read -r line; do
        echo "$line" | grep -qE '^\s*#|^\s*$' && continue
        if echo "$line" | grep -qE '^[^ ].*\{'; then
            local bname; bname=$(echo "$line" | awk '{print $1}')
            i=$((i+1))
            echo -e "  ${GREEN}[$i]${NC} ${BOLD}${bname}${NC}"
        elif echo "$line" | grep -qE '^\s+(reverse_proxy|root|file_server|redir)'; then
            local dir; dir=$(echo "$line" | awk '{print $1}')
            local tgt; tgt=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')
            echo -e "      ${DIM}${dir}${NC} → ${CYAN}${tgt}${NC}"
        elif echo "$line" | grep -qE '^\}'; then
            echo ""
        fi
    done < "$CADDYFILE"
    [ "$i" -eq 0 ] && echo -e "  ${YELLOW}暂无站点配置${NC}\n"
    menu_div
}

# ── 添加反向代理站点 ──────────────────────────────────────
caddy_add_proxy() {
    print_header "添加反向代理站点"
    echo -e "  ${DIM}Caddy 会自动申请 SSL 证书（需域名已解析到本机）${NC}"
    echo ""
    read -rp "  域名（如 example.com 或 example.com:36366）: " DOMAIN
    [ -z "$DOMAIN" ] && { warn "已取消"; return; }
    read -rp "  转发到（如 127.0.0.1:8080）: " BACKEND
    [ -z "$BACKEND" ] && { warn "已取消"; return; }

    if grep -q "^${DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        warn "域名 ${DOMAIN} 已存在，请先删除再添加"; return
    fi

    # 判断是否是带端口的域名（如 example.com:36366）
    local HAS_PORT=false
    local BARE_DOMAIN="$DOMAIN"
    if echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9].*:[0-9]+$'; then
        HAS_PORT=true
        BARE_DOMAIN=$(echo "$DOMAIN" | cut -d: -f1)
    fi

    # 判断是否是域名（非 IP）
    local IS_DOMAIN=false
    if echo "$BARE_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)+[a-zA-Z]{2,}$'; then
        IS_DOMAIN=true
    fi

    local SSL_LABEL CADDY_BLOCK
    if [ "$IS_DOMAIN" = true ]; then
        if [ "$HAS_PORT" = true ]; then
            # 带端口：检查裸域名站点是否存在（需先有裸域名才能复用证书）
            if grep -q "^${BARE_DOMAIN}" "$CADDYFILE" 2>/dev/null; then
                SSL_LABEL="${GREEN}复用 ${BARE_DOMAIN} 的证书 ✓${NC}"
            else
                SSL_LABEL="${YELLOW}注意：未找到 ${BARE_DOMAIN} 裸域名站点，建议先添加裸域名站点申请证书${NC}"
            fi
        else
            SSL_LABEL="${GREEN}自动 HTTPS（Let's Encrypt）${NC}"
        fi
        CADDY_BLOCK=$(printf '
%s {
    reverse_proxy %s
    encode gzip
}
' "$DOMAIN" "$BACKEND")
    else
        # IP 地址：不申请证书
        SSL_LABEL="${YELLOW}无 SSL（IP 地址无法申请证书）${NC}"
        CADDY_BLOCK=$(printf '
http://%s {
    reverse_proxy %s
}
' "$DOMAIN" "$BACKEND")
    fi

    echo ""
    menu_div
    echo -e "  域名 : ${BOLD}${DOMAIN}${NC}"
    echo -e "  后端 : ${BOLD}${BACKEND}${NC}"
    echo -e "  SSL  : ${SSL_LABEL}"
    menu_div
    echo ""
    read -rp "  确认添加？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    if caddy_append_safe "$CADDY_BLOCK"; then
        caddy_reload_config && info "站点 ${DOMAIN} 已添加 ✓"
    fi
}

# ── 添加静态网站 ──────────────────────────────────────────
caddy_add_static() {
    print_header "添加静态网站"
    echo -e "  ${DIM}Caddy 会自动申请 SSL 证书（需域名已解析到本机）${NC}"
    echo ""
    read -rp "  域名（如 example.com 或 example.com:8443）: " DOMAIN
    [ -z "$DOMAIN" ] && { warn "已取消"; return; }
    read -rp "  网站根目录（默认 /var/www/html）: " WEBROOT
    WEBROOT="${WEBROOT:-/var/www/html}"

    if grep -q "^${DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        warn "域名 ${DOMAIN} 已存在，请先删除再添加"; return
    fi

    local HAS_PORT=false
    local BARE_DOMAIN="$DOMAIN"
    if echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9].*:[0-9]+$'; then
        HAS_PORT=true
        BARE_DOMAIN=$(echo "$DOMAIN" | cut -d: -f1)
    fi

    local IS_DOMAIN=false
    if echo "$BARE_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)+[a-zA-Z]{2,}$'; then
        IS_DOMAIN=true
    fi

    local SSL_LABEL CADDY_BLOCK
    if [ "$IS_DOMAIN" = true ]; then
        if [ "$HAS_PORT" = true ]; then
            SSL_LABEL="${GREEN}复用 ${BARE_DOMAIN} 证书（需先添加裸域名站点申请证书）${NC}"
        else
            SSL_LABEL="${GREEN}自动 HTTPS（Let's Encrypt）${NC}"
        fi
        CADDY_BLOCK=$(printf '
%s {
    root * %s
    file_server
}
' "$DOMAIN" "$WEBROOT")
    else
        SSL_LABEL="${YELLOW}无 SSL（IP 地址无法申请证书）${NC}"
        CADDY_BLOCK=$(printf '
http://%s {
    root * %s
    file_server
}
' "$DOMAIN" "$WEBROOT")
    fi

    echo ""
    menu_div
    echo -e "  域名 : ${BOLD}${DOMAIN}${NC}"
    echo -e "  目录 : ${BOLD}${WEBROOT}${NC}"
    echo -e "  SSL  : ${SSL_LABEL}"
    menu_div
    echo ""
    read -rp "  确认添加？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    mkdir -p "$WEBROOT"
    if caddy_append_safe "$CADDY_BLOCK"; then
        caddy_reload_config && info "静态站点 ${DOMAIN} 已添加 ✓"
    fi
}

# ── 删除站点 ──────────────────────────────────────────────
caddy_del_site() {
    print_header "删除站点"
    caddy_list_sites

    # 收集所有站点
    local SITES=()
    while IFS= read -r line; do
        echo "$line" | grep -qE '^\s*#|^\s*$' && continue
        if echo "$line" | grep -qE '^[^ ].*\{'; then
            local bname; bname=$(echo "$line" | awk '{print $1}')
            SITES+=("$bname")
        fi
    done < "$CADDYFILE"

    if [ ${#SITES[@]} -eq 0 ]; then warn "暂无站点配置"; return; fi

    echo ""
    local i=1
    for site in "${SITES[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} ${BOLD}${site}${NC}"
        i=$((i+1))
    done
    echo ""
    menu_div
    read -rp "  请输入编号删除（直接回车取消）: " NUM
    [ -z "$NUM" ] && { warn "已取消"; return; }
    if ! echo "$NUM" | grep -qE '^[0-9]+$' || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#SITES[@]} ]; then
        error "无效编号"; return
    fi
    local DOMAIN="${SITES[$((NUM-1))]}"
    echo ""
    warn "即将删除站点：${BOLD}${DOMAIN}${NC}"
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    python3 - "$CADDYFILE" "$DOMAIN" << 'PYEOF'
import sys
path, domain = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
result = []
skip = False
depth = 0
for line in lines:
    s = line.strip()
    if not skip and s.startswith(domain) and '{' in s:
        skip = True
        depth = s.count('{') - s.count('}')
        while result and result[-1].strip() == '':
            result.pop()
        continue
    if skip:
        depth += s.count('{') - s.count('}')
        if depth <= 0:
            skip = False
        continue
    result.append(line)
with open(path, 'w') as f:
    f.writelines(result)
PYEOF

    caddy_reload_config && info "站点 ${DOMAIN} 已删除 ✓"
}

# ── SSL 证书状态 ──────────────────────────────────────────
caddy_ssl_status() {
    print_header "SSL 证书状态"
    echo -e "  ${DIM}Caddy 自动管理证书，首次访问时自动申请${NC}"
    echo ""

    local CERT_DIR=""
    for d in /var/lib/caddy/.local/share/caddy/certificates \
              /root/.local/share/caddy/certificates \
              /home/caddy/.local/share/caddy/certificates; do
        [ -d "$d" ] && CERT_DIR="$d" && break
    done

    if [ -z "$CERT_DIR" ]; then
        warn "未找到证书目录（证书将在首次访问时自动申请）"
        return
    fi

    echo -e "  证书目录：${DIM}${CERT_DIR}${NC}"
    menu_div
    find "$CERT_DIR" -name "*.crt" 2>/dev/null | while read -r cert; do
        local DN; DN=$(basename "$(dirname "$cert")")
        local EXP; EXP=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        echo -e "  ${GREEN}▸${NC} ${BOLD}${DN}${NC}"
        [ -n "$EXP" ] && echo -e "    ${DIM}到期：${NC}${EXP}"
    done
    menu_div
}

# ── 查看访问日志 ──────────────────────────────────────────
caddy_view_logs() {
    print_header "Caddy 访问日志"
    local LOG_FILE="$CADDY_LOG"
    [ ! -f "$LOG_FILE" ] && LOG_FILE=$(find /var/log/caddy /var/log -name "*.log" 2>/dev/null | grep -i caddy | head -1)

    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        if command -v journalctl &>/dev/null; then
            echo -e "  ${DIM}使用 journalctl${NC}"
            echo ""
            journalctl -u caddy -n 50 --no-pager 2>/dev/null | while IFS= read -r line; do
                echo -e "  $line"
            done
            echo ""
            echo -e "  ${GREEN}1${NC}) 开启实时跟踪（Ctrl+C 停止返回菜单）"
            echo -e "  ${RED}0${NC}) 返回"
            echo ""
            read -rp "  请选择: " _CH
            if [ "$_CH" = "1" ]; then
                trap 'echo ""; info "已退出实时跟踪"; trap - INT' INT
                journalctl -u caddy -f 2>/dev/null
                trap - INT
            fi
        else
            warn "未找到 Caddy 日志文件，请确认 Caddyfile 中已配置 log 指令"
        fi
        return
    fi

    echo -e "  ${DIM}${LOG_FILE}${NC}"
    menu_div
    echo ""
    tail -n 30 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        local STATUS; STATUS=$(echo "$line" | python3 -c \
            "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('status',''))
except: print('')" 2>/dev/null)
        if [ -n "$STATUS" ]; then
            local SC="$GREEN"
            [ "$STATUS" -ge 400 ] 2>/dev/null && SC="$YELLOW"
            [ "$STATUS" -ge 500 ] 2>/dev/null && SC="$RED"
            local TS METHOD URI
            TS=$(echo "$line" | python3 -c \
                "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('ts','')[:19].replace('T',' '))
except: print('')" 2>/dev/null)
            METHOD=$(echo "$line" | python3 -c \
                "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('request',{}).get('method',''))
except: print('')" 2>/dev/null)
            URI=$(echo "$line" | python3 -c \
                "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('request',{}).get('uri',''))
except: print('')" 2>/dev/null)
            echo -e "  ${DIM}${TS}${NC} ${BOLD}${METHOD}${NC} ${URI} ${SC}${STATUS}${NC}"
        else
            echo -e "  $line"
        fi
    done
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 开启实时跟踪（Ctrl+C 停止返回菜单）"
    echo -e "  ${RED}0${NC}) 返回"
    echo ""
    read -rp "  请选择: " _CH
    if [ "$_CH" = "1" ]; then
        trap 'echo ""; info "已退出实时跟踪"; trap - INT' INT
        tail -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "  $line"; done
        trap - INT
    fi
}

# ── 编辑 Caddyfile ────────────────────────────────────────
caddy_edit_raw() {
    print_header "编辑 Caddyfile"
    echo -e "  配置文件：${BOLD}${CADDYFILE}${NC}"
    echo ""
    warn "$(get_editor) 打开 Caddyfile，保存退出后自动验证并重载"
    echo ""
    read -rp "  按 Enter 开始编辑..." _
    [ -f "$CADDYFILE" ] || { mkdir -p /etc/caddy; touch "$CADDYFILE"; }
    open_editor "$CADDYFILE"
    echo ""
    caddy_reload_config
}

# ── Caddy 主菜单 ──────────────────────────────────────────
caddy_menu() {
    while true; do
        local C_ST; C_ST=$(caddy_status)
        local C_COLOR
        case "$C_ST" in
            running)       C_COLOR="$GREEN" ;;
            stopped)       C_COLOR="$RED" ;;
            not_installed) C_COLOR="$YELLOW" ;;
        esac

        print_header "Caddy 管理"

        if [ "$C_ST" = "not_installed" ]; then
            echo -e "  服务状态: ${C_COLOR}${BOLD}未安装${NC}"
            echo ""
            echo -e "  ${DIM}Caddy 是一个自动 HTTPS 的现代 Web 服务器，支持反向代理和静态托管${NC}"
            echo ""
            menu_div
            echo -e "  ${GREEN}1${NC}) 立即安装 Caddy"
            echo -e "  ${RED}0${NC}) 返回"
            echo -e "  ${RED}00${NC}) 退出脚本"
            menu_div
            echo ""
            read -rp "  请选择 [0-1]: " CH
            case "$CH" in
                1) caddy_install; echo ""; read -rp "  按 Enter 继续..." _ ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi

        local C_VER; C_VER=$(caddy version 2>/dev/null | awk '{print $1}')
        local SITE_COUNT; SITE_COUNT=$(grep -cE '^[^ ].*\{' "$CADDYFILE" 2>/dev/null || echo 0)

        echo -e "  服务: ${C_COLOR}${BOLD}${C_ST}${NC}  版本: ${BOLD}${C_VER:-未知}${NC}  站点数: ${BOLD}${SITE_COUNT}${NC}"
        echo ""
        menu_div
        menu_pair "1" "查看站点" "2" "添加反向代理"
        menu_pair "3" "添加静态网站" "4" "删除站点"
        menu_pair "5" "SSL 证书状态" "6" "查看日志"
        menu_pair "7" "编辑 Caddyfile" "8" "重载配置"
        if [ "$C_ST" = "running" ]; then
            menu_item "9" "停止服务" "$YELLOW"
        else
            menu_item "9" "启动服务"
        fi
        menu_pair "u" "安装 / 更新" "d" "卸载 Caddy" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作: ')" CH

        case "$CH" in
            1) caddy_list_sites ;;
            2) caddy_add_proxy ;;
            3) caddy_add_static ;;
            4) caddy_del_site ;;
            5) caddy_ssl_status ;;
            6) caddy_view_logs ;;
            7) caddy_edit_raw ;;
            8) caddy_reload_config ;;
            u|U)
                print_header "安装/更新 Caddy"
                info "正在更新 Caddy..."
                caddy_install
                local NEW_VER; NEW_VER=$(caddy version 2>/dev/null | awk '{print $1}')
                info "当前版本：${NEW_VER:-未知} ✓"
                ;;
            9)
                if [ "$C_ST" = "running" ]; then
                    svc_stop caddy
                    info "Caddy 已停止 ✓"
                else
                    svc_start caddy \
                        || caddy start --config "$CADDYFILE" &>/dev/null
                    info "Caddy 已启动 ✓"
                fi
                sleep 1; continue
                ;;
            d|D) caddy_uninstall ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

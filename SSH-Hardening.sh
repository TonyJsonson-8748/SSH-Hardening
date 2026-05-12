#!/bin/bash

# ============================================================
#  VPS 开荒脚本 V3.0.8 — 银趴火山帮
#  功能：SSH管理 / Fail2ban / BBR TCP 调优 / Cloudflare DDNS
#  修复：解决 Crontab 环境下 Telegram 通知失效的问题
# ============================================================

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTH_KEYS="$HOME/.ssh/authorized_keys"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
error() { echo -e "  ${RED}✘${NC}  $1"; }

# 兼容 dumb 终端
safe_clear() {
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear 2>/dev/null || true
    fi
}

# 主菜单 ASCII Banner
volcano_art_banner() {
    echo -e "${RED}${BOLD}"
    cat << 'BANNER_EOF'
    ______  _______  ___    ____  ______    ____  ____  _____
   /  _/  |/  / __ \/   |  / __ \/_  __/   / __ \/ __ \/ ___/
   / // /|_/ / /_/ / /| | / /_/ / / /     / / / / /_/ /\__ \ 
 _/ // /  / / ____/ ___ |/ _, _/ / /     / /_/ / ____/___/ / 
/___/_/  /_/_/   /_/  |_/_/ |_| /_/      \____/_/    /____/  
BANNER_EOF
    echo -e "${NC}"
}

# ── 可见宽度计算 ────────────
vis_len() {
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s))
" "$1" 2>/dev/null || echo "${#1}"
}

# ── 边框常量 ──────────────────────────────
BOX_W=42

box_top() { printf "${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_bot() { printf "${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_sep() { printf "${CYAN}"; printf '─%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }

box_title() {
    local TEXT="$1"
    local LEN; LEN=$(vis_len "$TEXT")
    local INNER=$((BOX_W - 2))
    local PAD_TOTAL=$(( INNER - LEN ))
    local PAD_L=$(( PAD_TOTAL / 2 ))
    local PAD_R=$(( PAD_TOTAL - PAD_L ))
    printf '%*s' "$PAD_L" ''
    printf "${BOLD}${CYAN}%s${NC}" "$TEXT"
    printf '%*s' "$PAD_R" ''
    printf "\n"
}

box_line() {
    local PLAIN="$1"
    local COLORED="${2:-$1}"
    echo -e "$COLORED"
}

box_empty() { echo ""; }

print_header() {
    safe_clear
    echo ""
    box_top
    box_title "VPS 开荒脚本 V3.0.8"
    box_line "  ··银趴火山帮··" "  ${DIM}··银趴火山帮··${NC}"
    box_sep
    box_title "$1"
    box_bot
    echo ""
}

# ── 兼容工具函数 ─────────────────
restart_ssh() {
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null
    elif command -v service &>/dev/null; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    else
        return 1
    fi
}

pkg_install() {
    local PKG="$1"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y "$PKG" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache "$PKG" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y "$PKG" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y "$PKG" 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "$PKG" 2>/dev/null
    else
        return 1
    fi
}

pkg_remove() {
    local PKG="$1"
    if command -v apt-get &>/dev/null; then
        apt-get remove -y "$PKG" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk del "$PKG" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum remove -y "$PKG" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf remove -y "$PKG" 2>/dev/null
    else
        return 1
    fi
}

svc_enable() {
    local SVC="$1"
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl unmask "$SVC" 2>/dev/null || true
        systemctl enable "$SVC" --quiet 2>/dev/null || true
    elif command -v rc-update &>/dev/null; then
        rc-update add "$SVC" default 2>/dev/null
    elif command -v update-rc.d &>/dev/null; then
        update-rc.d "$SVC" enable 2>/dev/null
    fi
}

svc_disable() {
    local SVC="$1"
    if command -v systemctl &>/dev/null; then
        systemctl disable "$SVC" --quiet 2>/dev/null
    elif command -v rc-update &>/dev/null; then
        rc-update del "$SVC" 2>/dev/null
    fi
}

svc_is_active() {
    local SVC="$1"
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" status &>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" status &>/dev/null
    else
        return 1
    fi
}

svc_daemon_reload() {
    command -v systemctl &>/dev/null && systemctl daemon-reload 2>/dev/null || true
}

get_codename() {
    if command -v lsb_release &>/dev/null; then
        lsb_release -cs 2>/dev/null
    elif [ -f /etc/os-release ]; then
        grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"'
    elif [ -f /etc/debian_version ]; then
        cat /etc/debian_version | cut -d. -f1
    else
        echo "unknown"
    fi
}

get_config() {
    grep -E "^[[:space:]]*$1[[:space:]]" "$SSHD_CONFIG" 2>/dev/null \
        | tail -1 | awk '{print $2}'
}

set_config() {
    local KEY="$1" VALUE="$2"
    if grep -qE "^#?[[:space:]]*${KEY}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i "s|^#\?[[:space:]]*${KEY}[[:space:]].*|${KEY} ${VALUE}|" "$SSHD_CONFIG"
    else
        echo "${KEY} ${VALUE}" >> "$SSHD_CONFIG"
    fi
}

backup_config() {
    local BACKUP="$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP"
    info "配置已备份：$BACKUP"
}

apply_and_restart() {
    if ! sshd -t 2>/dev/null; then
        error "配置文件语法错误，已取消应用"
        return 1
    fi
    if restart_ssh; then
        info "SSH 服务已重启 ✓"
    else
        error "SSH 服务重启失败"
        return 1
    fi
}

# ── 权限检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ══════════════════════════════════════════════════════════
#  SSH 模块
# ══════════════════════════════════════════════════════════

list_keys() {
    if [ ! -f "$AUTH_KEYS" ] || ! grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null; then
        echo -e "  ${YELLOW}（暂无公钥）${NC}"
        return 1
    fi
    local i=1
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
            local TYPE COMMENT FINGER
            TYPE=$(echo "$line" | awk '{print $1}')
            COMMENT=$(echo "$line" | awk '{print $3}')
            FINGER=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || echo "N/A")
            echo -e "  ${GREEN}[$i]${NC} ${BOLD}$TYPE${NC}"
            echo -e "      ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
            echo -e "      ${DIM}备注：${NC}${YELLOW}${COMMENT:-（无备注）}${NC}"
            echo ""
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"
    return 0
}

show_keys() { print_header "查看已有公钥"; list_keys; }

add_key() {
    print_header "添加 SSH 公钥"
    echo -e "  请粘贴公钥内容（以 ssh-ed25519 / ssh-rsa 等开头）"
    echo -e "  粘贴完成后按 ${BOLD}Enter${NC}，再按 ${BOLD}Ctrl+D${NC} 结束输入："
    echo ""
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)
    if [ -z "$PUBKEY_INPUT" ]; then warn "内容为空。"; return; fi
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    echo "$PUBKEY_INPUT" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
    info "公钥已添加！✓"
}

delete_key() {
    print_header "删除 SSH 公钥"
    if ! list_keys; then return; fi
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -z "$DEL_NUM" ] && return
    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then TARGET_LINE="$line"; break; fi
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"
    [ -z "$TARGET_LINE" ] && { error "无效编号"; return; }
    grep -vF "$TARGET_LINE" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    info "公钥已删除 ✓"
}

generate_key() {
    print_header "生成 SSH 密钥对"
    echo -e "  1) Ed25519 (推荐)  2) RSA 4096"
    read -rp "  请选择 [1-2]: " K_CH
    case "$K_CH" in
        1) K_TYPE="ed25519"; K_BITS="" ;;
        2) K_TYPE="rsa"; K_BITS="-b 4096" ;;
        *) return ;;
    esac
    local TMP_DIR=$(mktemp -d); local K_FILE="$TMP_DIR/id_${K_TYPE}"
    ssh-keygen -t "$K_TYPE" $K_BITS -f "$K_FILE" -N "" -q
    echo -e "\n${RED}┌─── 私钥（请立即保存！）───┐${NC}\n$(cat $K_FILE)\n${RED}└────────────────────────┘${NC}\n"
    read -rp "  是否添加公钥到本服务器？(Y/n): " ADD_C
    if [[ "$ADD_C" =~ ^[Yy]?$ ]]; then
        cat "${K_FILE}.pub" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
        info "已添加 ✓"
    fi
    rm -rf "$TMP_DIR"
}

set_login_mode() {
    print_header "登录方式设置"
    echo -e "  1) 仅密钥登录 (禁用密码)  2) 密码+密钥"
    read -rp "  选择 [1-2]: " M_CH
    backup_config
    if [ "$M_CH" = "1" ]; then
        set_config "PasswordAuthentication" "no"
        set_config "PubkeyAuthentication" "yes"
        set_config "PermitRootLogin" "prohibit-password"
    else
        set_config "PasswordAuthentication" "yes"
        set_config "PermitRootLogin" "yes"
    fi
    apply_and_restart
}

change_port() {
    print_header "修改 SSH 端口"
    local CUR_P=$(get_config "Port")
    echo -e "  当前端口：${CUR_P:-22}"
    read -rp "  新端口号: " INPUT_P
    [ -z "$INPUT_P" ] && return
    backup_config
    set_config "Port" "$INPUT_P"
    apply_and_restart
}

ssh_tools_menu() {
    while true; do
        print_header "SSH 工具集"
        echo -e "  1) 查看已有公钥  2) 添加公钥  3) 删除公钥"
        echo -e "  4) 生成密钥对    5) 登录方式  6) 修改端口"
        echo -e "  0) 返回"
        read -rp "  请选择: " CHOICE
        case "$CHOICE" in
            1) show_keys ;; 2) add_key ;; 3) delete_key ;;
            4) generate_key ;; 5) set_login_mode ;; 6) change_port ;;
            0) return ;;
        esac
        [ "$CHOICE" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  BBR 调优模块
# ══════════════════════════════════════════════════════════

bbr_print_status() {
    local BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local FQ=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    echo -e "  拥塞控制: ${BOLD}${BBR}${NC}  队列算法: ${BOLD}${FQ}${NC}"
}

bbr_apply() {
    local SYS_CONF="/etc/sysctl.d/99-vps-bbr.conf"
    cat > "$SYS_CONF" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
    sysctl -p "$SYS_CONF" &>/dev/null
    info "BBR 已开启 ✓"
}

bbr_menu() {
    while true; do
        print_header "BBR TCP 调优"
        bbr_print_status
        echo -e "\n  1) 开启 BBR (fq)  0) 返回"
        read -rp "  请选择: " CH
        case "$CH" in
            1) bbr_apply ;;
            0) return ;;
        esac
        read -rp "  按 Enter 返回..." _
    done
}

# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════

f2b_status() {
    if ! command -v fail2ban-client &>/dev/null; then echo "not_installed"
    elif svc_is_active fail2ban; then echo "running"
    else echo "stopped"; fi
}

f2b_install() {
    pkg_install fail2ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
[sshd]
enabled = true
EOF
    svc_enable fail2ban
    systemctl restart fail2ban 2>/dev/null
    info "Fail2ban 已安装 ✓"
}

fail2ban_menu() {
    while true; do
        local ST=$(f2b_status)
        print_header "Fail2ban 管理"
        echo -e "  当前状态: ${ST}"
        echo -e "  1) 安装/重启 Fail2ban  2) 查看封禁列表  0) 返回"
        read -rp "  选择: " CH
        case "$CH" in
            1) f2b_install ;;
            2) fail2ban-client status sshd 2>/dev/null ;;
            0) return ;;
        esac
        read -rp "  按 Enter 返回..." _
    done
}

# ══════════════════════════════════════════════════════════
#  Cloudflare DDNS 模块 (V3.0.8 修复重点)
# ══════════════════════════════════════════════════════════

DDNS_SCRIPT="/root/ddns.sh"
DDNS_TOKEN_FILE="/root/.cf_token"
DDNS_LOG="/var/log/ddns.log"
DDNS_ZONE_FILE="/root/.cf_zone"
DDNS_TG_FILE="/root/.cf_tg"

ddns_status() {
    if [ ! -f "$DDNS_SCRIPT" ]; then echo "not_installed"
    elif ! crontab -l 2>/dev/null | grep -q "ddns.sh"; then echo "stopped"
    else echo "running"; fi
}

ddns_install() {
    print_header "Cloudflare DDNS 配置"
    pkg_install curl; pkg_install python3
    
    read -rp "  子域名 (如 home): " D_SUB; [ -z "$D_SUB" ] && return
    read -rp "  根域名 (如 abc.com): " D_ZONE; [ -z "$D_ZONE" ] && return
    read -rp "  CF API Token: " D_TOKEN; [ -z "$D_TOKEN" ] && return
    
    local FULL_DOMAIN="${D_SUB}.${D_ZONE}"
    echo "$D_TOKEN" > "$DDNS_TOKEN_FILE"; chmod 600 "$DDNS_TOKEN_FILE"
    echo "DOMAIN=${FULL_DOMAIN}" > "$DDNS_ZONE_FILE"
    echo "ZONE=${D_ZONE}" >> "$DDNS_ZONE_FILE"

    # 生成执行脚本
    cat > "$DDNS_SCRIPT" << 'DDNS_INNER'
#!/bin/bash
# V3.0.8 修复：补全 Crontab PATH 变量
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN="__DOMAIN__"
ZONE="__ZONE__"
TOKEN_FILE="/root/.cf_token"
LOG_FILE="/var/log/ddns.log"
TG_FILE="/root/.cf_tg"

API_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
[ -z "$API_TOKEN" ] && exit 1

# 修复：更健壮的 Telegram 通知逻辑
tg_notify() {
    local MSG="$1"
    # 在函数内重新读取配置，防止 Crontab 环境变量丢失
    [ -f "$TG_FILE" ] || return 0
    local B_TOKEN=$(grep "^BOT_TOKEN=" "$TG_FILE" | cut -d= -f2-)
    local C_ID=$(grep "^CHAT_ID=" "$TG_FILE" | cut -d= -f2-)
    [ -z "$B_TOKEN" ] || [ -z "$C_ID" ] && return 0
    
    curl -s --max-time 15 \
        "https://api.telegram.org/bot${B_TOKEN}/sendMessage" \
        -d "chat_id=${C_ID}" \
        -d "text=${MSG}" \
        -d "parse_mode=HTML" > /dev/null 2>&1
}

# 获取公网 IP
CURRENT_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || curl -s https://ip.sb)
[ -z "$CURRENT_IP" ] && exit 1

# 获取 Zone ID 和 Record ID (简化逻辑用于生成)
Z_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE}" -H "Authorization: Bearer ${API_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
R_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${Z_ID}/dns_records?name=${DOMAIN}&type=A" -H "Authorization: Bearer ${API_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
OLD_IP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${Z_ID}/dns_records/${R_ID}" -H "Authorization: Bearer ${API_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)

if [ "$CURRENT_IP" != "$OLD_IP" ]; then
    # 执行更新
    RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${Z_ID}/dns_records/${R_ID}" -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${CURRENT_IP}\",\"ttl\":60,\"proxied\":false}")
    if [[ "$RESULT" == *"\"success\":true"* ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: 更新成功 ${OLD_IP} -> ${CURRENT_IP}" >> "$LOG_FILE"
        tg_notify "🌐 <b>DDNS IP 已更新</b>
域名：<code>${DOMAIN}</code>
旧IP：<code>${OLD_IP}</code>
新IP：<code>${CURRENT_IP}</code>
时间：$(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 更新失败" >> "$LOG_FILE"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: IP 未变化 ${CURRENT_IP}" >> "$LOG_FILE"
fi
DDNS_INNER

    sed -i "s/__DOMAIN__/${FULL_DOMAIN}/g" "$DDNS_SCRIPT"
    sed -i "s/__ZONE__/${D_ZONE}/g" "$DDNS_SCRIPT"
    chmod +x "$DDNS_SCRIPT"
    
    ( crontab -l 2>/dev/null | grep -v "ddns.sh"; echo "*/5 * * * * ${DDNS_SCRIPT} >> ${DDNS_LOG} 2>&1" ) | crontab -
    info "DDNS 已安装，每 5 分钟检查一次 ✓"
}

ddns_tg_config() {
    print_header "Telegram 通知配置"
    read -rp "  Bot Token: " T_TOKEN; [ -z "$T_TOKEN" ] && return
    read -rp "  Chat ID: " T_ID; [ -z "$T_ID" ] && return
    echo "BOT_TOKEN=${T_TOKEN}" > "$DDNS_TG_FILE"
    echo "CHAT_ID=${T_ID}" >> "$DDNS_TG_FILE"
    info "TG 配置已保存 ✓"
}

ddns_menu() {
    while true; do
        local ST=$(ddns_status)
        print_header "Cloudflare DDNS"
        echo -e "  状态: ${ST}"
        echo -e "  1) 安装/重新配置 DDNS  2) 配置 Telegram 通知"
        echo -e "  3) 手动立即运行一次    4) 查看日志  0) 返回"
        read -rp "  选择: " CH
        case "$CH" in
            1) ddns_install ;;
            2) ddns_tg_config ;;
            3) bash "$DDNS_SCRIPT" ;;
            4) tail -n 20 "$DDNS_LOG" 2>/dev/null ;;
            0) return ;;
        esac
        read -rp "  按 Enter 返回..." _
    done
}

# ══════════════════════════════════════════════════════════
#  主菜单与入口
# ══════════════════════════════════════════════════════════

main_menu() {
    while true; do
        local CUR_PORT=$(get_config "Port")
        safe_clear; volcano_art_banner
        box_top
        box_title "VPS 开荒脚本 V3.0.8"
        box_sep
        box_line "  1) SSH 工具集        2) Fail2ban 管理"
        box_line "  3) BBR TCP 调优      4) Cloudflare DDNS"
        box_line "  0) 退出"
        box_bot
        read -rp "  请选择: " CHOICE
        case "$CHOICE" in
            1) ssh_tools_menu ;;
            2) fail2ban_menu ;;
            3) bbr_menu ;;
            4) ddns_menu ;;
            0) exit 0 ;;
        esac
    done
}

main_menu

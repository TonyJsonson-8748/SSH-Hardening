#!/bin/bash

# ============================================================
#  VPS 开荒脚本 V3.5.9 — 银趴火山帮
#  功能：SSH管理 / Fail2ban / BBR TCP 调优
#  V3.5.9: SSH改端口/配置失败自动回滚、改端口延后删旧(防锁死)、防火墙卸载不再
#          flush全表(只删自身规则)、DDNS IPv4严格校验、服务操作统一svc_*封装、
#          默认网卡用 ip route get、Caddy 配置临时验证通过才写入
#  V3.5.8: 修复 bbr-tune.sh 独立版缺失 4 个辅助函数(ensure_conntrack_module/
#          svc_daemon_reload/svc_enable/svc_disable)，独立运行限速/场景预设不再中断
#  V3.5.7: DDNS 状态区增加「最后一次 IP 变更时间 + 新旧 IP」显示
#  V3.5.6: 新增 UDP 缓冲(QUIC/Hysteria2)、场景预设加端口范围/tw_buckets/file-max
#          防高并发端口耗尽、应用场景预设后检测代理 service LimitNOFILE
#  V3.5.5: BBR 限速改 htb 整形+fq pacing(保 BBR)、burst 随速率缩放、
#          切换预设复位残留场景键、新增 32MB 缓冲档、修 BDP 双截断
# ============================================================

# ── 解释器守卫：本脚本依赖 bash（数组 / [[ ]] / here-string 等）──
# 仅用 POSIX 语法编写，确保在 ash/dash 下也能解析并 fail-fast。
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "本脚本需要 bash 运行，当前 shell 不是 bash 且系统未安装 bash。"
    echo "请先安装 bash 后重试："
    echo "  Alpine:   apk add bash"
    echo "  OpenWrt:  opkg update && opkg install bash"
    echo "  Debian:   apt-get install -y bash"
    echo "  CentOS:   yum install -y bash"
    exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
# 优先使用 /root/.ssh/authorized_keys，兼容系统预装公钥路径
AUTH_KEYS="${HOME}/.ssh/authorized_keys"
[ "$(id -u)" = "0" ] && AUTH_KEYS="/root/.ssh/authorized_keys"

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

# 兼容 dumb 终端（OpenWrt / tmux 等不支持 clear 的环境）
safe_clear() {
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear 2>/dev/null || true
    fi
}

# 主菜单 ASCII Banner
volcano_art_banner() {
    echo -e "${RED}${BOLD}"
    cat << 'BANNER_EOF'
    ______  _______  ___    ____  ______   ____  ____  _____
   /  _/  |/  / __ \/   |  / __ \/_  __/  / __ \/ __ \/ ___/
   / // /|_/ / /_/ / /| | / /_/ / / /    / / / / /_/ /\__ \ 
 _/ // /  / / ____/ ___ |/ _, _/ / /    / /_/ / ____/___/ / 
/___/_/  /_/_/   /_/  |_/_/ |_| /_/     \____/_/    /____/  
BANNER_EOF
    echo -e "${NC}"
}

# ── 可见宽度计算（用 python3，中文=2，ASCII=1）────────────
vis_len() {
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s))
" "$1" 2>/dev/null || echo "${#1}"
}

# ── 边框常量（可见字符宽度）──────────────────────────────
BOX_W=42   # 总宽含两侧 ║

# 顶/底/分隔线
box_top() { printf "${BOLD}${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_bot() { printf "${BOLD}${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_sep() { printf "${DIM}${CYAN}"; printf '─%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }

# 居中标题行（只传纯文本，自动居中）
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

# 普通内容行：PLAIN=纯文本(算宽度)  COLORED=带色码(显示用)
# 用法: box_line "纯文本" "带色码文本"
box_line() {
    local PLAIN="$1"
    local COLORED="${2:-$1}"
    echo -e "$COLORED"
}

# 空行
box_empty() {
    echo ""
}

# ── 内层分隔线（与主框线同宽对齐，dim 青，统一替代各处 seq 1 38）──
menu_div() { printf "${DIM}${CYAN}"; printf '─%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }

# ── 段标题（❯ 前缀，统一替代 [xxx] 方括号风格）──
menu_group() { echo -e "  ${CYAN}${BOLD}❯ ${1}${NC}"; }

# ── 菜单项（统一缩进与配色）。用法: menu_item "1" "SSH 工具集" [颜色]──
menu_item() {
    local KEY="$1" LABEL="$2" COL="${3:-$GREEN}"
    echo -e "    ${COL}${BOLD}${KEY}${NC}) ${LABEL}"
}


# ── 通用编辑器（兼容 Alpine/OpenWrt 等精简系统）────────────
get_editor() {
    for ed in nano vi vim; do
        command -v "$ed" &>/dev/null && echo "$ed" && return
    done
    echo "vi"  # 最后兜底，几乎所有系统都有 vi
}

open_editor() {
    local FILE="$1"
    local ED; ED=$(get_editor)
    if ! command -v "$ED" &>/dev/null; then
        # vi 也没有，尝试安装 nano
        warn "未找到编辑器，尝试安装 nano..."
        pkg_install nano &>/dev/null || pkg_install vim &>/dev/null || true
        ED=$(get_editor)
    fi
    "$ED" "$FILE"
}

# ── 确保 sysctl 可用（Alpine 需要 procps 或 sysctl 包）────
# 加载 nf_conntrack 模块（中转/落地机需要）
ensure_conntrack_module() {
    lsmod 2>/dev/null | grep -q "^nf_conntrack" && return 0
    modprobe nf_conntrack 2>/dev/null
}

ensure_sysctl() {
    command -v sysctl &>/dev/null && return 0
    warn "sysctl 未找到，正在安装..."
    if command -v apk &>/dev/null; then
        apk add --no-cache procps 2>/dev/null || apk add --no-cache sysctl 2>/dev/null || true
    else
        pkg_install procps 2>/dev/null || true
    fi
    command -v sysctl &>/dev/null && return 0
    error "sysctl 安装失败，请手动执行：apk add procps"
    return 1
}


# iptables/ip6tables 残留规则清理（卸载防火墙时使用）
clear_iptables_residue() {
    # 安全清理：只删除本脚本可能残留的规则，绝不 flush 全表、绝不改默认策略。
    # 旧版会 iptables -F + 设 ACCEPT，会瞬间裸奔并抹掉 NFT 转发/代理/用户自有规则。
    # ufw --force reset / firewalld 卸载本身已清掉各自规则，这里无需再 flush。
    if command -v iptables &>/dev/null; then
        # 删除本脚本 SSH 放行可能残留的 INPUT ACCEPT 规则（逐条删，删到没有为止）
        local _p
        for _p in $(get_config "Port" 2>/dev/null) 22; do
            [ -n "$_p" ] || continue
            while iptables -C INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null || break
            done
        done
    fi
    info "已清理本脚本残留规则（未触碰默认策略与其它规则）"
}

# 统一标题栏
print_header() {
    safe_clear
    echo ""
    box_top
    box_title "VPS 开荒脚本 V3.5.9"
    box_title "· · 银趴火山帮 · ·"
    box_sep
    box_title "$1"
    box_bot
    echo ""
}


# ── 兼容工具函数（支持 BusyBox / Alpine）─────────────────

# 替代 grep -oP '(?:maxrate|rate) \K\S+'
# 替代 grep -oE 'initcwnd [0-9]+' | awk '{print $2}'
# 检测服务管理器并重启 SSH
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

# 检测服务管理器并重启 fail2ban
restart_fail2ban() {
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl restart fail2ban 2>/dev/null && return 0
    fi
    if command -v rc-service &>/dev/null; then
        rc-service fail2ban restart 2>/dev/null && return 0
    fi
    if command -v service &>/dev/null; then
        service fail2ban restart 2>/dev/null && return 0
    fi
    [ -x /etc/init.d/fail2ban ] && /etc/init.d/fail2ban restart 2>/dev/null
}

# 检测服务管理器并启动/停止 fail2ban
start_fail2ban() {
    # 确保 socket 目录存在（tmpfs 重启后会消失）
    mkdir -p /var/run/fail2ban 2>/dev/null
    chmod 755 /var/run/fail2ban 2>/dev/null

    # 写入 tmpfiles.d 确保重启后自动创建目录
    if command -v systemd-tmpfiles &>/dev/null; then
        echo "d /var/run/fail2ban 0755 root root -" > /etc/tmpfiles.d/fail2ban.conf 2>/dev/null
        systemd-tmpfiles --create /etc/tmpfiles.d/fail2ban.conf 2>/dev/null || true
    fi

    # 优先尝试 systemctl，失败则回退 service / rc-service
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl start fail2ban 2>/dev/null && return 0
    fi
    if command -v rc-service &>/dev/null; then
        rc-service fail2ban start 2>/dev/null && return 0
    fi
    if command -v service &>/dev/null; then
        service fail2ban start 2>/dev/null && return 0
    fi
    # 最后回退：直接调用 init.d 脚本
    [ -x /etc/init.d/fail2ban ] && /etc/init.d/fail2ban start 2>/dev/null
}
stop_fail2ban() {
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl stop fail2ban 2>/dev/null && return 0
    fi
    if command -v rc-service &>/dev/null; then
        rc-service fail2ban stop 2>/dev/null && return 0
    fi
    if command -v service &>/dev/null; then
        service fail2ban stop 2>/dev/null && return 0
    fi
    [ -x /etc/init.d/fail2ban ] && /etc/init.d/fail2ban stop 2>/dev/null
}

# ── 系统检测工具 ──────────────────────────────────────────

# 检测包管理器
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

# 通用服务启用（开机自启）
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

# 通用服务 start/stop/restart 封装（systemd / OpenRC / sysvinit）
# OpenRC 服务名常带不同后缀，systemd 用 .service；调用方传裸名即可。
# 获取默认出口网卡：ip route get 比 awk '/^default/' 更准
# （多默认路由 / 策略路由 / IPv6-only 时不易取错），失败回退旧法
default_iface() {
    local DEV
    DEV=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$DEV" ] && DEV=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$DEV" ] && DEV=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    echo "$DEV"
}

svc_start() {
    local SVC="$1"
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl start "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" start 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" start 2>/dev/null
    else
        return 1
    fi
}

svc_stop() {
    local SVC="$1"
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl stop "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" stop 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" stop 2>/dev/null
    else
        return 1
    fi
}

svc_restart() {
    local SVC="$1"
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl restart "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" restart 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" restart 2>/dev/null
    else
        return 1
    fi
}

# 通用服务 is-active 检测
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

# systemctl daemon-reload 兼容（OpenRC 不需要）
svc_daemon_reload() {
    command -v systemctl &>/dev/null && systemctl daemon-reload 2>/dev/null || true
}

# 获取 OS codename（兼容无 lsb_release 的系统）
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

# ── 权限检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ── 通用工具函数 ──────────────────────────────────────────
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
    LAST_SSHD_BACKUP="$BACKUP"   # 供 apply_and_restart 失败时回滚
    info "配置已备份：$BACKUP"
}

apply_and_restart() {
    # 失败时自动回滚到最近备份，避免把自己锁在外面
    _ssh_rollback() {
        if [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ]; then
            cp "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" 2>/dev/null
            warn "已回滚 sshd_config 到备份：$LAST_SSHD_BACKUP"
            if sshd -t 2>/dev/null && restart_ssh; then
                info "已用备份配置恢复 SSH 服务 ✓"
            else
                error "回滚后仍异常，请立即手动检查 sshd_config 与 SSH 服务！"
            fi
        else
            error "未找到可回滚的备份，请立即手动检查 SSH 配置！"
        fi
    }
    if ! sshd -t 2>/dev/null; then
        error "配置文件语法错误，自动回滚中..."
        _ssh_rollback
        return 1
    fi
    if restart_ssh; then
        info "SSH 服务已重启 ✓"
    else
        error "SSH 服务重启失败，自动回滚中..."
        _ssh_rollback
        return 1
    fi
}

list_keys() {
    if [ ! -f "$AUTH_KEYS" ] || ! grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null; then
        echo -e "  ${YELLOW}（暂无公钥）${NC}"
        return 1
    fi
    local i=1
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
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

firewall_allow_port() {
    local PORT="$1"
    local UFW_ACTIVE=false FIREWALLD_ACTIVE=false IPTABLES_ACTIVE=false

    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && UFW_ACTIVE=true
    command -v firewall-cmd &>/dev/null && svc_is_active firewalld && FIREWALLD_ACTIVE=true
    if command -v iptables &>/dev/null; then
        local RULES
        RULES=$(iptables -L INPUT --line-numbers 2>/dev/null             | grep -v "^Chain\|^num\|^$\|ACCEPT.*all.*anywhere.*anywhere" | wc -l)
        [ "$RULES" -gt 0 ] && IPTABLES_ACTIVE=true
    fi

    if [ "$UFW_ACTIVE" = false ] && [ "$FIREWALLD_ACTIVE" = false ] && [ "$IPTABLES_ACTIVE" = false ]; then
        info "未检测到活跃防火墙，跳过端口放行"
        return 0
    fi

    echo ""
    warn "检测到活跃防火墙，是否自动放行新端口 ${PORT}/tcp？"
    read -rp "  自动放行？(Y/n，默认Y): " FW_CONFIRM
    FW_CONFIRM="${FW_CONFIRM:-y}"
    if ! echo "$FW_CONFIRM" | grep -qiE '^y(es)?$'; then
        warn "已跳过，请在防火墙管理中手动添加端口 $PORT"
        return 0
    fi

    if [ "$UFW_ACTIVE" = true ]; then
        ufw allow "${PORT}"/tcp 2>/dev/null && info "ufw 已放行 ${PORT}/tcp ✓"
    fi
    if [ "$FIREWALLD_ACTIVE" = true ]; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" 2>/dev/null &&         firewall-cmd --reload 2>/dev/null &&         info "firewalld 已放行 ${PORT}/tcp ✓"
    fi
    if [ "$IPTABLES_ACTIVE" = true ]; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        [ -f /etc/iptables/rules.v4 ] && iptables-save > /etc/iptables/rules.v4
        info "iptables 已放行 ${PORT}/tcp ✓"
    fi
}

# ══════════════════════════════════════════════════════════
#  功能模块
# ══════════════════════════════════════════════════════════

show_keys() {
    print_header "查看已有公钥"
    list_keys
}

add_key() {
    print_header "添加 SSH 公钥"
    echo -e "  请粘贴公钥内容（以 ssh-ed25519 / ssh-rsa 等开头）"
    echo -e "  粘贴完成后按 ${BOLD}Enter${NC}，再按 ${BOLD}Ctrl+D${NC} 结束输入："
    echo ""
    menu_div
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)
    menu_div
    echo ""

    if [ -z "$PUBKEY_INPUT" ]; then
        warn "未输入任何内容，已取消。"
        return
    fi
    if ! echo "$PUBKEY_INPUT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
        error "公钥格式不正确，应以密钥类型开头（如 ssh-ed25519）。"
        return
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # 检查是否已存在相同公钥（取类型+主体比较，忽略备注差异）
    local KEY_BODY
    KEY_BODY=$(echo "$PUBKEY_INPUT" | awk '{print $1, $2}')
    if grep -qF "$KEY_BODY" "$AUTH_KEYS" 2>/dev/null; then
        warn "该公钥已存在，跳过添加（避免重复）"
        return
    fi

    echo "$PUBKEY_INPUT" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    local TOTAL
    TOTAL=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS")
    info "公钥已添加！当前共 $TOTAL 个公钥 ✓"
}

delete_key() {
    print_header "删除 SSH 公钥"

    if ! list_keys; then
        return
    fi

    menu_div
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"; return
    fi

    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then TARGET_LINE="$line"; break; fi
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"

    if [ -z "$TARGET_LINE" ]; then
        error "编号 $DEL_NUM 不存在。"; return
    fi

    echo ""
    warn "即将删除以下公钥："
    echo -e "  ${RED}$(echo "$TARGET_LINE" | awk '{print $1, $3}')${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 取公钥主体（类型+base64）作为匹配依据，避免尾部空格/备注差异导致删除失败
    local KEY_BODY
    KEY_BODY=$(echo "$TARGET_LINE" | awk '{print $1, $2}')
    grep -vF "$KEY_BODY" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    info "公钥已删除 ✓"
}

generate_key() {
    print_header "生成 SSH 密钥对"

    echo -e "  选择密钥类型："
    echo -e "  ${GREEN}1${NC}) Ed25519  ${YELLOW}[推荐，更安全更短]${NC}"
    echo -e "  ${GREEN}2${NC}) RSA 4096"
    echo -e "  ${GREEN}0${NC}) 返回"
    echo ""
    read -rp "  请选择 [0-2]: " KEY_TYPE_CHOICE

    case "$KEY_TYPE_CHOICE" in
        0) return ;;
        1) KEY_TYPE="ed25519"; KEY_BITS="" ;;
        2) KEY_TYPE="rsa";     KEY_BITS="-b 4096" ;;
        *) warn "无效选项，已取消。"; return ;;
    esac

    echo ""
    read -rp "  输入密钥备注（如 mypc@home，直接回车跳过）: " KEY_COMMENT
    KEY_COMMENT="${KEY_COMMENT:-ssh-key-$(date +%Y%m%d)}"

    local TMP_DIR KEY_FILE
    TMP_DIR=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/vps_tmp_$$" && echo "/tmp/vps_tmp_$$"; })
    KEY_FILE="$TMP_DIR/id_${KEY_TYPE}"

    echo ""
    info "正在生成 $KEY_TYPE 密钥对..."

    if ! ssh-keygen -t "$KEY_TYPE" $KEY_BITS -C "$KEY_COMMENT" -f "$KEY_FILE" -N "" -q 2>/dev/null; then
        error "密钥生成失败。"; rm -rf "$TMP_DIR"; return
    fi

    local PUBKEY PRIVKEY FINGER
    PUBKEY=$(cat "${KEY_FILE}.pub")
    PRIVKEY=$(cat "$KEY_FILE")
    FINGER=$(ssh-keygen -lf "${KEY_FILE}.pub" 2>/dev/null | awk '{print $2}')

    print_header "密钥生成完成 — 请复制保存"

    echo -e "  ${DIM}类型：${NC}${BOLD}$KEY_TYPE${NC}   ${DIM}备注：${NC}${YELLOW}$KEY_COMMENT${NC}"
    echo -e "  ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
    echo ""
    echo -e "  ${BOLD}${RED}┌─── 私钥（仅显示一次，请立即复制！）───┐${NC}"
    echo ""
    echo "$PRIVKEY"
    echo ""
    echo -e "  ${BOLD}${RED}└────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}┌─── 公钥（可添加到服务器）─────────────┐${NC}"
    echo ""
    echo "$PUBKEY"
    echo ""
    echo -e "  ${BOLD}${GREEN}└────────────────────────────────────────┘${NC}"
    echo ""
    menu_div
    warn "私钥请立即复制到本地保存，关闭后无法找回！"
    menu_div
    echo ""

    read -rp "  是否将公钥添加到本服务器？(Y/n，默认Y): " ADD_CONFIRM
    [ -z "${ADD_CONFIRM}" ] && ADD_CONFIRM="y"
    if echo "${ADD_CONFIRM}" | grep -qiE '^y(es)?$'; then
        mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
        local KEY_BODY
        KEY_BODY=$(echo "$PUBKEY" | awk '{print $1, $2}')
        if grep -qF "$KEY_BODY" "$AUTH_KEYS" 2>/dev/null; then
            warn "该公钥已存在于服务器，跳过添加"
        else
            echo "$PUBKEY" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
            local TOTAL
            TOTAL=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS")
            echo ""
            info "公钥已添加到服务器！当前共 $TOTAL 个公钥 ✓"
        fi
    else
        warn "已跳过，公钥未添加到服务器。"
    fi

    rm -rf "$TMP_DIR"
}

set_login_mode() {
    print_header "登录方式设置"

    local CURRENT_PWD CURRENT_PUBKEY CURRENT_ROOT
    CURRENT_PWD=$(get_config "PasswordAuthentication")
    CURRENT_PUBKEY=$(get_config "PubkeyAuthentication")
    CURRENT_ROOT=$(get_config "PermitRootLogin")

    echo -e "  ${DIM}当前配置：${NC}"
    echo -e "  PasswordAuthentication : ${BOLD}${CURRENT_PWD:-未设置}${NC}"
    echo -e "  PubkeyAuthentication   : ${BOLD}${CURRENT_PUBKEY:-未设置}${NC}"
    echo -e "  PermitRootLogin        : ${BOLD}${CURRENT_ROOT:-未设置}${NC}"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 仅密钥登录（禁用密码）    ${YELLOW}[推荐]${NC}"
    echo -e "  ${GREEN}2${NC}) 密码 + 密钥均可登录"
    echo -e "  ${GREEN}3${NC}) 仅密码登录（禁用密钥）    ${RED}[不推荐]${NC}"
    echo -e "  ${GREEN}0${NC}) 返回"
    menu_div
    echo ""
    read -rp "  请选择 [0-3]: " MODE
    echo ""

    case "$MODE" in
        1)
            local KEYCOUNT
            KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)
            if [ "$KEYCOUNT" -eq 0 ]; then
                warn "当前没有公钥！启用仅密钥登录后将无法通过密码登录！"
                read -rp "  仍要继续？(Y/n，默认Y): " FORCE
                [ -z "${FORCE}" ] && FORCE="y"
    if ! echo "${FORCE}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            fi
            backup_config
            set_config "PasswordAuthentication" "no"
            set_config "PubkeyAuthentication"   "yes"
            set_config "PermitRootLogin"        "prohibit-password"
            apply_and_restart && info "已切换：仅密钥登录 ✓"
            ;;
        2)
            backup_config
            set_config "PasswordAuthentication" "yes"
            set_config "PubkeyAuthentication"   "yes"
            set_config "PermitRootLogin"        "yes"
            apply_and_restart && info "已切换：密码 + 密钥均可登录 ✓"
            ;;
        3)
            warn "仅密码登录安全性较低，建议配合强密码使用！"
            read -rp "  确认切换？(Y/n，默认Y): " CONFIRM
            [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            backup_config
            set_config "PasswordAuthentication" "yes"
            set_config "PubkeyAuthentication"   "no"
            set_config "PermitRootLogin"        "yes"
            apply_and_restart && info "已切换：仅密码登录 ✓"
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) return ;;
    esac
}

change_port() {
    print_header "修改 SSH 端口"

    local CURRENT_PORT
    CURRENT_PORT=$(get_config "Port")
    echo -e "  当前端口：${BOLD}${CURRENT_PORT:-22}${NC}"
    echo ""
    menu_div
    read -rp "  请输入新端口号（直接回车取消）: " INPUT_PORT
    menu_div
    echo ""

    [ -z "$INPUT_PORT" ] && { warn "已取消。"; return; }

    if ! echo "$INPUT_PORT" | grep -qE '^[0-9]+$' || [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        error "无效端口号（请输入 1-65535）。"; return
    fi

    if [ "$INPUT_PORT" = "${CURRENT_PORT:-22}" ]; then
        warn "端口未变化，无需修改。"; return
    fi

    backup_config
    set_config "Port" "$INPUT_PORT"

    if ! sshd -t 2>/dev/null; then
        error "配置语法错误，自动回滚中..."
        [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ] && cp "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" 2>/dev/null && warn "已回滚配置"
        return
    fi

    local OLD_PORT="${CURRENT_PORT:-22}"
    # 先放行新端口（旧端口暂不删，避免 restart 失败/连不上时被锁外面）
    firewall_allow_port "$INPUT_PORT"

    # 应用并重启（失败会自动回滚到旧配置）
    apply_and_restart || {
        error "SSH 重启失败，已回滚。旧端口 ${OLD_PORT} 未改动，当前连接安全。"
        return
    }

    echo ""
    menu_div
    warn "新端口已生效，但【旧端口 ${OLD_PORT} 暂未关闭】——这是为防止你被锁在外面。"
    echo ""
    echo -e "  请【保持当前连接不要断开】，新开一个终端测试新端口："
    echo ""
    echo -e "     ${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    echo ""
    warn "确认新端口能登录后，再回来关闭旧端口。"
    menu_div
    echo ""
    read -rp "  新端口已测试可登录，现在关闭旧端口 ${OLD_PORT}？(y/N，默认N): " CLOSE_OLD
    [ -z "$CLOSE_OLD" ] && CLOSE_OLD="n"
    if echo "$CLOSE_OLD" | grep -qiE '^y(es)?$'; then
        if [ "$OLD_PORT" != "$INPUT_PORT" ]; then
            command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && \
                ufw delete allow "${OLD_PORT}"/tcp 2>/dev/null && info "ufw 已关闭旧端口 ${OLD_PORT}/tcp ✓"
            if command -v firewall-cmd &>/dev/null && svc_is_active firewalld; then
                firewall-cmd --permanent --remove-port="${OLD_PORT}/tcp" 2>/dev/null
                firewall-cmd --reload 2>/dev/null && info "firewalld 已关闭旧端口 ${OLD_PORT}/tcp ✓"
            fi
        fi
        info "旧端口已关闭。"
    else
        warn "旧端口 ${OLD_PORT} 保留开放。确认无误后可手动关闭，或重新进入本菜单。"
    fi
}


# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════
# 把 fail2ban 时间格式转为秒（支持 3600、1h、1d、-1 等）
f2b_to_seconds() {
    local VAL="$1"
    # 纯数字直接返回
    if echo "$VAL" | grep -qE '^-?[0-9]+$'; then
        echo "$VAL"; return
    fi
    # 解析带单位：s/m/h/d/w
    local NUM; NUM=$(echo "$VAL" | grep -oE '[0-9]+')
    local UNIT; UNIT=$(echo "$VAL" | grep -oE '[smhdw]' | tail -1)
    case "$UNIT" in
        s) echo "$NUM" ;;
        m) echo $(( NUM * 60 )) ;;
        h) echo $(( NUM * 3600 )) ;;
        d) echo $(( NUM * 86400 )) ;;
        w) echo $(( NUM * 604800 )) ;;
        *) echo "$NUM" ;;
    esac
}

# 把秒数转为可读字符串
f2b_seconds_to_human() {
    local SEC="$1"
    [ "$SEC" = "-1" ] && { echo "永久"; return; }
    [ "$SEC" -ge 86400 ] && { echo "$(( SEC / 86400 ))天"; return; }
    [ "$SEC" -ge 3600  ] && { echo "$(( SEC / 3600 ))小时"; return; }
    [ "$SEC" -ge 60    ] && { echo "$(( SEC / 60 ))分钟"; return; }
    echo "${SEC}秒"
}


# 检测 fail2ban 是否已安装并运行
# fail2ban-client ping 兼容函数（自动探测 socket 路径）
f2b_ping() {
    local SOCK
    for SOCK in /run/fail2ban/fail2ban.sock \
                /var/run/fail2ban/fail2ban.sock \
                /tmp/fail2ban.sock; do
        [ -S "$SOCK" ] && fail2ban-client -s "$SOCK" ping &>/dev/null 2>&1 && return 0
    done
    fail2ban-client ping &>/dev/null 2>&1
}

f2b_status() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "not_installed"
        return
    fi
    # 先用 fail2ban-client ping 检测实际运行状态（最可靠）
    if f2b_ping; then
        echo "running"
    elif svc_is_active fail2ban 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 安装 fail2ban
f2b_install() {
    print_header "安装 Fail2ban"
    info "正在安装 fail2ban..."
    if ! pkg_install fail2ban; then
        error "安装失败，请检查网络或手动安装：apt install fail2ban"
        return 1
    fi

    # ── 1. 确定 backend ──────────────────────────────────────
    local BACKEND="auto"

    # 检测 python3-systemd 是否可用
    if python3 -c "import systemd.journal" &>/dev/null 2>&1; then
        BACKEND="systemd"
        info "检测到 python3-systemd，使用 systemd backend ✓"
    else
        # 尝试安装 python3-systemd
        info "尝试安装 python3-systemd..."
        if pkg_install python3-systemd &>/dev/null 2>&1 \
            && python3 -c "import systemd.journal" &>/dev/null 2>&1; then
            BACKEND="systemd"
            info "python3-systemd 安装成功，使用 systemd backend ✓"
        else
            warn "python3-systemd 不可用，使用 auto backend"
            # 没有 auth.log 则安装 rsyslog 补充
            if [ ! -f /var/log/auth.log ] && [ ! -f /var/log/secure ]; then
                info "安装 rsyslog 以生成 auth.log..."
                pkg_install rsyslog &>/dev/null 2>&1
                svc_enable rsyslog
                svc_start rsyslog || true
                sleep 1
            fi
        fi
    fi

    # ── 2. 检测版本，决定是否加 allowipv6 ────────────────────
    local F2B_MAJOR
    F2B_MAJOR=$(fail2ban-client version 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
    local ALLOW_IPV6_LINE=""
    [ "${F2B_MAJOR:-0}" -ge 1 ] && ALLOW_IPV6_LINE="allowipv6 = auto"

    # ── 3. 写入 jail.local ───────────────────────────────────
    if [ ! -f /etc/fail2ban/jail.local ]; then
        local LOGPATH_LINE=""
        [ "$BACKEND" = "auto" ] && LOGPATH_LINE="logpath  = %(sshd_log)s"

        mkdir -p /etc/fail2ban
        {
            echo "[DEFAULT]"
            echo "bantime  = 3600"
            echo "findtime = 600"
            echo "maxretry = 5"
            echo "backend  = ${BACKEND}"
            [ -n "$ALLOW_IPV6_LINE" ] && echo "$ALLOW_IPV6_LINE"
            echo ""
            echo "[sshd]"
            echo "enabled  = true"
            echo "port     = ssh"
            [ -n "$LOGPATH_LINE" ] && echo "$LOGPATH_LINE"
        } > /etc/fail2ban/jail.local
        info "已创建 jail.local（backend=${BACKEND}）✓"
    fi

    # ── 4. 清理残留，准备启动 ────────────────────────────────
    # 清理旧 socket
    rm -f /run/fail2ban/fail2ban.sock \
          /var/run/fail2ban/fail2ban.sock 2>/dev/null || true

    # 清理可能残留的错误 override
    rm -f /etc/systemd/system/fail2ban.service.d/override.conf 2>/dev/null
    rmdir /etc/systemd/system/fail2ban.service.d/ 2>/dev/null || true

    # unmask + enable
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl unmask fail2ban 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable fail2ban 2>/dev/null || true
    fi

    # ── 5. 验证配置再启动 ────────────────────────────────────
    info "验证 fail2ban 配置..."
    local TEST_OUT
    TEST_OUT=$(fail2ban-server -t 2>&1)
    if echo "$TEST_OUT" | grep -qiE "^OK|test is successful"; then
        info "配置验证通过，正在启动..."
        start_fail2ban
        # 等待 socket 出现（最多 8 秒）
        local i=0
        while [ $i -lt 8 ]; do
            f2b_ping && break
            sleep 1
            i=$((i+1))
        done
        if f2b_ping; then
            info "Fail2ban 安装并启动成功 ✓"
        else
            # 最后尝试：直接前台启动后台化
            warn "标准启动未响应，尝试备用方式..."
            /usr/bin/fail2ban-server -xf start &>/dev/null &
            sleep 3
            if f2b_ping; then
                info "Fail2ban 启动成功 ✓"
            else
                error "启动失败，请手动执行："
                echo -e "  ${DIM}journalctl -u fail2ban -n 20${NC}"
                echo -e "  ${DIM}fail2ban-server -xf --logtarget=sysout start${NC}"
            fi
        fi
    else
        error "配置验证失败："
        echo "$TEST_OUT" | grep -v "^OK" | while IFS= read -r l; do
            echo -e "  ${RED}$l${NC}"
        done
        echo ""
        warn "请进入「基础参数配置」修复后再启动"
    fi
}


# ── 基础参数配置 ──────────────────────────────────────────
f2b_config_params() {
    print_header "Fail2ban 基础参数配置"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    # 读取当前值
    local CUR_BAN CUR_FIND CUR_MAX
    CUR_BAN=$(grep -E "^bantime\s*=" "$JAIL_LOCAL" 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
    CUR_FIND=$(grep -E "^findtime\s*=" "$JAIL_LOCAL" 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
    CUR_MAX=$(grep -E "^maxretry\s*=" "$JAIL_LOCAL" 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
    [ -z "$CUR_BAN"  ] && CUR_BAN="3600"
    [ -z "$CUR_FIND" ] && CUR_FIND="600"
    [ -z "$CUR_MAX"  ] && CUR_MAX="5"

    echo -e "  当前配置："
    local _BAN_S; _BAN_S=$(f2b_to_seconds "$CUR_BAN")
    local _FIND_S; _FIND_S=$(f2b_to_seconds "$CUR_FIND")
    echo -e "  封禁时长  (bantime)  : ${BOLD}${CUR_BAN}${NC}  （$(f2b_seconds_to_human "$_BAN_S")）"
    echo -e "  时间窗口  (findtime) : ${BOLD}${CUR_FIND}${NC}  （$(f2b_seconds_to_human "$_FIND_S")）"
    echo -e "  最大重试  (maxretry) : ${BOLD}${CUR_MAX}${NC} 次"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 修改封禁时长   (bantime)"
    echo -e "  ${GREEN}2${NC}) 修改时间窗口   (findtime)"
    echo -e "  ${GREEN}3${NC}) 修改最大重试次数 (maxretry)"
    echo -e "  ${GREEN}4${NC}) 修改监控端口    (port)"
    echo -e "  ${GREEN}5${NC}) 快速预设"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-5]: " CH

    case "$CH" in
        1)
            echo ""
            echo -e "  常用参考：3600=1小时  86400=1天  604800=7天  -1=永久"
            read -rp "  请输入新的 bantime（秒）: " VAL
            echo "$VAL" | grep -qE '^-?[0-9]+$' || { error "无效数值"; return; }
            f2b_set_param "bantime" "$VAL"
            ;;
        2)
            echo ""
            echo -e "  常用参考：300=5分钟  600=10分钟  3600=1小时"
            read -rp "  请输入新的 findtime（秒）: " VAL
            echo "$VAL" | grep -qE '^[0-9]+$' || { error "无效数值"; return; }
            f2b_set_param "findtime" "$VAL"
            ;;
        3)
            echo ""
            echo -e "  常用参考：3=严格  5=默认  10=宽松"
            read -rp "  请输入新的 maxretry（次）: " VAL
            echo "$VAL" | grep -qE '^[0-9]+$' || { error "无效数值"; return; }
            f2b_set_param "maxretry" "$VAL"
            ;;
        4)
            echo ""
            local CUR_SSH_PORT; CUR_SSH_PORT=$(get_config "Port"); CUR_SSH_PORT="${CUR_SSH_PORT:-22}"
            echo -e "  当前 SSH 端口：${BOLD}${CUR_SSH_PORT}${NC}"
            echo -e "  示例：ssh  或  22  或  22,2222  或  22:2222"
            echo -e "  ${DIM}提示：直接回车使用当前 SSH 端口 ${CUR_SSH_PORT}${NC}"
            echo ""
            read -rp "  请输入监控端口: " VAL
            VAL="${VAL:-$CUR_SSH_PORT}"
            f2b_set_param_jail "port" "$VAL"
            ;;
        5)
            echo ""
            echo -e "  ${GREEN}1${NC}) 严格模式  — 封禁1天   窗口10分钟  最多3次"
            echo -e "  ${GREEN}2${NC}) 标准模式  — 封禁1小时  窗口10分钟  最多5次"
            echo -e "  ${GREEN}3${NC}) 宽松模式  — 封禁30分钟 窗口5分钟   最多10次"
            echo -e "  ${GREEN}4${NC}) 永久封禁  — 封禁永久   窗口10分钟  最多3次"
            echo ""
            read -rp "  请选择预设 [1-4]: " PRESET
            case "$PRESET" in
                1) f2b_set_param "bantime" "86400";  f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "3" ;;
                2) f2b_set_param "bantime" "3600";   f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "5" ;;
                3) f2b_set_param "bantime" "1800";   f2b_set_param "findtime" "300"; f2b_set_param "maxretry" "10" ;;
                4) f2b_set_param "bantime" "-1";     f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "3" ;;
                *) warn "无效选项"; return ;;
            esac
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    echo ""
    info "重启 Fail2ban 使配置生效..."
    restart_fail2ban && info "Fail2ban 已重启 ✓" || error "重启失败"
}

# 写入参数到 jail.local [DEFAULT] 节
f2b_set_param() {
    local KEY="$1" VAL="$2"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    # 确保文件存在且有 [DEFAULT] 节
    if [ ! -f "$JAIL_LOCAL" ]; then
        echo -e "[DEFAULT]" > "$JAIL_LOCAL"
    fi
    if ! grep -q "^\[DEFAULT\]" "$JAIL_LOCAL"; then
        sed -i "1i [DEFAULT]" "$JAIL_LOCAL"
    fi

    if grep -qE "^${KEY}\s*=" "$JAIL_LOCAL"; then
        sed -i "s|^${KEY}\s*=.*|${KEY} = ${VAL}|" "$JAIL_LOCAL"
    else
        sed -i "/^\[DEFAULT\]/a ${KEY} = ${VAL}" "$JAIL_LOCAL"
    fi
    info "${KEY} 已设置为 ${VAL} ✓"
}

# 写入参数到 jail.local [sshd] 节
f2b_set_param_jail() {
    local KEY="$1" VAL="$2"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    [ -f "$JAIL_LOCAL" ] || echo -e "[DEFAULT]

[sshd]
enabled = true" > "$JAIL_LOCAL"

    if grep -q "^\[sshd\]" "$JAIL_LOCAL"; then
        # 已有 [sshd] 节：在节内找 key 并替换，没有则在 [sshd] 下追加
        if grep -A20 "^\[sshd\]" "$JAIL_LOCAL" | grep -qE "^${KEY}\s*="; then
            # 替换 [sshd] 节内的 key（简单 sed，适配大多数结构）
            awk -v k="$KEY" -v v="$VAL" '
                /^\[sshd\]/{in_sshd=1}
                /^\[/ && !/^\[sshd\]/{in_sshd=0}
                in_sshd && $0 ~ "^"k"[[:space:]]*=" {print k" = "v; next}
                {print}
            ' "$JAIL_LOCAL" > "${JAIL_LOCAL}.tmp" && mv "${JAIL_LOCAL}.tmp" "$JAIL_LOCAL"
        else
            # 在 [sshd] 后追加
            sed -i "/^\[sshd\]/a ${KEY} = ${VAL}" "$JAIL_LOCAL"
        fi
    else
        # 没有 [sshd] 节，追加
        printf '
[sshd]
enabled = true
%s = %s
' "$KEY" "$VAL" >> "$JAIL_LOCAL"
    fi
    info "[sshd] ${KEY} 已设置为 ${VAL} ✓"
}

# ── 编辑配置文件 ──────────────────────────────────────────
f2b_edit_config() {
    print_header "编辑 Fail2ban 配置文件"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"
    local JAIL_CONF="/etc/fail2ban/jail.conf"

    echo -e "  ${GREEN}1${NC}) 编辑 jail.local  ${YELLOW}（推荐，用户自定义配置）${NC}"
    echo -e "  ${GREEN}2${NC}) 查看 jail.conf    ${DIM}（系统默认配置，只读参考）${NC}"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-2]: " CH

    case "$CH" in
        1)
            if [ ! -f "$JAIL_LOCAL" ]; then
                warn "jail.local 不存在，正在创建默认模板..."
                cat > "$JAIL_LOCAL" << 'JAILEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = auto

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
JAILEOF
                info "已创建 $JAIL_LOCAL"
            fi
            echo ""
            warn "即将用 $(get_editor) 打开 $JAIL_LOCAL"
            warn "编辑完成后保存退出（vi: :wq  nano: Ctrl+O/X）"
            echo ""
            read -rp "  按 Enter 继续..." _
            open_editor "$JAIL_LOCAL"
            echo ""
            read -rp "  是否重启 Fail2ban 使配置生效？(Y/n，默认Y): " RESTART
            [ -z "$RESTART" ] && RESTART="y"
            echo "$RESTART" | grep -qiE '^y(es)?$' && restart_fail2ban && info "Fail2ban 已重启 ✓" || true
            ;;
        2)
            if [ -f "$JAIL_CONF" ]; then
                echo ""
                echo -e "  ${DIM}--- $JAIL_CONF（只读）---${NC}"
                echo ""
                LANG=C.UTF-8 LESSCHARSET=utf-8 less -R "$JAIL_CONF"
            else
                warn "$JAIL_CONF 不存在"
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 卸载 Fail2ban ─────────────────────────────────────────
f2b_uninstall() {
    print_header "卸载 Fail2ban"
    warn "即将卸载 Fail2ban，所有配置将被清除！"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    stop_fail2ban
    svc_disable fail2ban
    if pkg_remove fail2ban; then
        info "Fail2ban 已卸载 ✓"
    else
        error "卸载失败，请手动执行：apt remove fail2ban"
    fi
}

# ── Fail2ban 主菜单 ───────────────────────────────────────
fail2ban_menu() {
    while true; do
        # 获取状态
        local F2B_ST; F2B_ST=$(f2b_status)

        # 若未安装，提示安装
        if [ "$F2B_ST" = "not_installed" ]; then
            print_header "Fail2ban 管理"
            warn "Fail2ban 未安装！"
            echo ""
            echo -e "  ${DIM}Fail2ban 是一个防暴力破解工具，可自动封禁恶意 IP${NC}"
            echo ""
            menu_div
            echo -e "  ${GREEN}1${NC}) 立即安装 Fail2ban"
            echo -e "  ${RED}0${NC}) 返回主菜单"
            echo -e "  ${RED}00${NC}) 退出脚本"
            menu_div
            echo ""
            read -rp "  请选择 [0-1]: " CHOICE
            case "$CHOICE" in
                1) f2b_install; echo ""; read -rp "  按 Enter 继续..." _ ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi

        # 已安装 — 收集数据
        local F2B_COLOR BANNED_COUNT TOTAL_FAIL JAIL_NAME
        [ "$F2B_ST" = "running" ] && F2B_COLOR="$GREEN" || F2B_COLOR="$RED"

        # 自动找 SSH jail 名称（sshd / ssh）
        JAIL_NAME=$(fail2ban-client status 2>/dev/null | grep -oE 'sshd?'| head -1)
        JAIL_NAME="${JAIL_NAME:-sshd}"

        if [ "$F2B_ST" = "running" ]; then
            BANNED_COUNT=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null \
                | grep "Currently banned" | grep -oE "[0-9]+" | tail -1)
            BANNED_COUNT="${BANNED_COUNT:-0}"
        else
            BANNED_COUNT="-"; TOTAL_FAIL="-"
        fi

        safe_clear
        echo ""
        box_top
        box_title "VPS 开荒脚本 V3.5.9"
        box_title "· · 银趴火山帮 · ·"
        box_sep
        box_title "Fail2ban 管理"
        box_sep
        # 读取当前参数
        local CUR_BAN CUR_FIND CUR_MAX CUR_PORT
        CUR_BAN=$(grep -E "^bantime\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        CUR_FIND=$(grep -E "^findtime\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        CUR_MAX=$(grep -E "^maxretry\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        CUR_PORT=$(grep -E "^port\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        [ -z "$CUR_BAN" ]  && CUR_BAN="3600"
        [ -z "$CUR_FIND" ] && CUR_FIND="600"
        [ -z "$CUR_MAX" ]  && CUR_MAX="5"
        [ -z "$CUR_PORT" ] && CUR_PORT="ssh"
        local BAN_SEC; BAN_SEC=$(f2b_to_seconds "$CUR_BAN")
        local FIND_SEC; FIND_SEC=$(f2b_to_seconds "$CUR_FIND")
        local BAN_HUMAN; BAN_HUMAN=$(f2b_seconds_to_human "$BAN_SEC")
        local FIND_HUMAN; FIND_HUMAN=$(f2b_seconds_to_human "$FIND_SEC")

        box_line "  服务: ${F2B_ST}  jail: ${JAIL_NAME}"                  "  服务: ${F2B_COLOR}${BOLD}${F2B_ST}${NC}  jail: ${BOLD}${JAIL_NAME}${NC}"
        box_line "  封禁IP: ${BANNED_COUNT}  总失败: ${TOTAL_FAIL}  监控端口: ${CUR_PORT}"                  "  封禁IP: ${RED}${BOLD}${BANNED_COUNT}${NC}  总失败: ${YELLOW}${BOLD}${TOTAL_FAIL}${NC}  端口: ${BOLD}${CUR_PORT}${NC}"
        box_line "  封禁时长: ${BAN_HUMAN}  窗口: ${FIND_HUMAN}  最大重试: ${CUR_MAX}次"                  "  封禁时长: ${BOLD}${BAN_HUMAN}${NC}  窗口: ${BOLD}${FIND_HUMAN}${NC}  最大重试: ${BOLD}${CUR_MAX}${NC}次"
        box_sep
        box_line "  1) 查看封禁 IP 列表" "  ${GREEN}1${NC}) 查看封禁 IP 列表"
        box_line "  2) 手动解封 IP"      "  ${GREEN}2${NC}) 手动解封 IP"
        box_line "  3) 实时日志"         "  ${GREEN}3${NC}) 实时日志"
        box_line "  4) 基础参数配置"     "  ${GREEN}4${NC}) 基础参数配置"
        box_line "  5) 编辑配置文件"     "  ${GREEN}5${NC}) 编辑配置文件"
        box_line "  6) 卸载 Fail2ban"    "  ${YELLOW}6${NC}) 卸载 Fail2ban"
        box_line "  u) 安装/更新 Fail2ban" "  ${CYAN}u${NC}) 安装/更新 Fail2ban"
        if [ "$F2B_ST" = "running" ]; then
            box_line "  7) 停止服务"     "  ${YELLOW}7${NC}) 停止服务"
        else
            box_line "  7) 启动服务"     "  ${GREEN}7${NC}) 启动服务"
        fi
        box_line "  0) 返回主菜单"       "  ${RED}0${NC}) 返回主菜单"
        box_line "  00) 退出脚本"        "  ${RED}00${NC}) 退出脚本"
        box_bot
        echo ""
        read -rp "  请选择 [0-7/u]: " CHOICE

        case "$CHOICE" in
            1) f2b_banned_list "$JAIL_NAME" ;;
            2) f2b_unban "$JAIL_NAME" ;;
            3) f2b_logs ;;
            4) f2b_config_params ;;
            5) f2b_edit_config ;;
            6) f2b_uninstall ;;
            u|U)
                print_header "安装/更新 Fail2ban"
                info "正在更新 Fail2ban..."
                pkg_install fail2ban
                local NEW_VER; NEW_VER=$(fail2ban-client version 2>/dev/null | head -1)
                info "当前版本：${NEW_VER:-未知} ✓"
                ;;
            7)
                if [ "$F2B_ST" = "running" ]; then
                    stop_fail2ban && info "Fail2ban 已停止" || error "停止失败"
                else
                    start_fail2ban
                    sleep 2
                    if f2b_ping; then
                        info "Fail2ban 已启动 ✓"
                    else
                        error "启动失败，请检查：journalctl -u fail2ban -n 20"
                    fi
                fi
                sleep 1; continue
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CHOICE}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ── 查看封禁 IP 列表 ──────────────────────────────────────
f2b_banned_list() {
    local JAIL="${1:-sshd}"
    print_header "封禁 IP 列表 — $JAIL"

    local RAW
    RAW=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list:\s*//')

    if [ -z "$RAW" ] || [ "$RAW" = "" ]; then
        echo -e "  ${GREEN}当前没有封禁的 IP${NC}"
        return
    fi

    local i=1
    for IP in $RAW; do
        echo -e "  ${RED}[$i]${NC} $IP"
        i=$((i+1))
    done
    echo ""
    echo -e "  ${DIM}共 $((i-1)) 个封禁 IP${NC}"
}

# ── 手动解封 IP ───────────────────────────────────────────
f2b_unban() {
    local JAIL="${1:-sshd}"
    while true; do
        print_header "手动解封 IP — $JAIL"

        local RAW
        RAW=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list:\s*//')

        if [ -z "$RAW" ]; then
            echo -e "  ${GREEN}当前没有封禁的 IP${NC}"
            echo ""
            read -rp "  按 Enter 返回..." _
            return
        fi

        local i=1
        for IP in $RAW; do
            echo -e "  ${RED}[$i]${NC} $IP"
            i=$((i+1))
        done
        echo ""
        menu_div
        echo -e "  ${DIM}输入 IP 地址解封，直接回车返回上级${NC}"
        read -rp "  请输入 IP: " UNBAN_IP
        [ -z "$UNBAN_IP" ] && return

        echo ""
        if fail2ban-client set "$JAIL" unbanip "$UNBAN_IP" 2>/dev/null; then
            info "IP ${BOLD}$UNBAN_IP${NC} 已解封 ✓"
        else
            error "解封失败，请确认 IP 地址正确"
        fi
        sleep 1
    done
}

# ── 实时日志 ──────────────────────────────────────────────
f2b_logs() {
    print_header "Fail2ban 实时日志"
    echo -e "  ${DIM}显示最近 30 条，按 Ctrl+C 退出实时模式${NC}"
    menu_div
    echo ""

    local LOG_FILE="/var/log/fail2ban.log"
    if [ ! -f "$LOG_FILE" ]; then
        LOG_FILE=$(journalctl -u fail2ban --no-pager -n 1 2>/dev/null | head -1)
        # 用 journalctl
        echo -e "  ${DIM}（使用 journalctl）${NC}"
        echo ""
        journalctl -u fail2ban -n 30 --no-pager 2>/dev/null             | grep -E "Ban|Unban|Found|WARNING|ERROR"             | while IFS= read -r line; do
                if echo "$line" | grep -q "Ban"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -q "Unban"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Found"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo -e "  ${DIM}$line${NC}"
                fi
            done
        echo ""
        menu_div
        echo -e "  ${DIM}按 Enter 开启实时跟踪（Ctrl+C 退出）...${NC}"
        read -r _
        journalctl -u fail2ban -f 2>/dev/null
    else
        tail -n 30 "$LOG_FILE"             | while IFS= read -r line; do
                if echo "$line" | grep -q "Ban"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -q "Unban"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Found"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo -e "  ${DIM}$line${NC}"
                fi
            done
        echo ""
        menu_div
        echo -e "  ${DIM}按 Enter 开启实时跟踪（Ctrl+C 退出）...${NC}"
        read -r _
        tail -f "$LOG_FILE"             | while IFS= read -r line; do
                if echo "$line" | grep -q "Ban"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -q "Unban"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Found"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo -e "  $line"
                fi
            done
    fi
}


# ══════════════════════════════════════════════════════════
#  BBR TCP 调优模块
# ══════════════════════════════════════════════════════════

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"

# ── 状态显示 ──────────────────────────────────────────────
bbr_print_status() {
    local DEV; DEV=$(default_iface)
    local RATE; RATE=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oE '(maxrate|rate) [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE="未设置"
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local CWND
    CWND=$(ip route show 2>/dev/null | grep "^default" | grep -oE 'initcwnd [0-9]+' | awk '{print $2}')
    [ -z "$CWND" ] && CWND="10（默认）"

    # 读取缓冲区大小
    local RMEM_MAX WMEM_MAX RMEM_MB WMEM_MB
    RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    RMEM_MB=$(( RMEM_MAX / 1048576 ))
    WMEM_MB=$(( WMEM_MAX / 1048576 ))

    # tcp_rmem / tcp_wmem 的 max 字段
    local TCP_RMEM_MAX TCP_WMEM_MAX TCP_RMEM_MB TCP_WMEM_MB
    TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    TCP_RMEM_MB=$(( ${TCP_RMEM_MAX:-0} / 1048576 ))
    TCP_WMEM_MB=$(( ${TCP_WMEM_MAX:-0} / 1048576 ))

    echo -e "  ${CYAN}网卡${NC} ${BOLD}$DEV${NC}  ${CYAN}CC${NC} ${BOLD}$BBR${NC}  ${CYAN}cwnd${NC} ${BOLD}$CWND${NC}  ${CYAN}限速${NC} ${BOLD}$RATE${NC}"
    # 检测缓冲区是否超过物理内存一半（显示警告）
    local MEM_TOTAL_MB
    MEM_TOTAL_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
    local RMEM_COLOR WMEM_COLOR
    RMEM_COLOR="$BOLD"
    WMEM_COLOR="$BOLD"
    if [ "${MEM_TOTAL_MB:-0}" -gt 0 ]; then
        [ "$RMEM_MB" -gt $(( MEM_TOTAL_MB / 2 )) ] && RMEM_COLOR="${YELLOW}${BOLD}"
        [ "$WMEM_MB" -gt $(( MEM_TOTAL_MB / 2 )) ] && WMEM_COLOR="${YELLOW}${BOLD}"
    fi
    echo -e "  ${CYAN}缓冲${NC} rmem ${RMEM_COLOR}${RMEM_MB}MB${NC}  wmem ${WMEM_COLOR}${WMEM_MB}MB${NC}  tcp_r ${BOLD}${TCP_RMEM_MB}MB${NC}  tcp_w ${BOLD}${TCP_WMEM_MB}MB${NC}  ${DIM}物理内存 ${MEM_TOTAL_MB}MB${NC}"
}

# ── 备份 sysctl ───────────────────────────────────────────
bbr_backup_sysctl() {
    if [ -f "$SYSCTL_FILE" ]; then
        local BAK="${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SYSCTL_FILE" "$BAK"
        info "已备份至：$BAK"
    fi
}

# ── 还原 sysctl ───────────────────────────────────────────
bbr_restore_sysctl() {
    print_header "还原 TCP sysctl 配置"

    # 用 /tmp 临时文件列表替代 bash 数组（兼容 Alpine ash）
    local LIST_FILE="/tmp/vps_bbr_bak_$$"
    ls -t "${SYSCTL_FILE}.bak."* 2>/dev/null > "$LIST_FILE"

    if [ ! -s "$LIST_FILE" ]; then
        rm -f "$LIST_FILE"
        warn "未找到任何备份文件"
        return
    fi

    local i=1
    while IFS= read -r f; do
        # stat 兼容：BusyBox stat 用 -c '%y'，但格式有差异，改用 ls -l 更通用
        local FDATE
        FDATE=$(ls -l "$f" 2>/dev/null | awk '{print $6, $7}')
        echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}${FDATE}${NC}"
        i=$(( i + 1 ))
    done < "$LIST_FILE"

    local TOTAL=$(( i - 1 ))
    echo -e "  ${YELLOW}[d]${NC} 清除全部备份"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "  请选择: " CH

    case "$CH" in
        0) rm -f "$LIST_FILE"; return ;;
        00) rm -f "$LIST_FILE"; safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        d|D)
            read -rp "  确认清除全部 ${TOTAL} 个备份？(Y/n，默认Y): " C
            [ -z "$C" ] && C="y"
            if echo "$C" | grep -qiE '^y(es)?$'; then
                rm -f "${SYSCTL_FILE}.bak."*
                info "已清除全部备份 ✓"
            else
                warn "已取消"
            fi
            ;;
        *)
            # 纯数字且在范围内
            if echo "$CH" | grep -qE '^[0-9]+$' && [ "$CH" -ge 1 ] && [ "$CH" -le "$TOTAL" ]; then
                local T
                T=$(sed -n "${CH}p" "$LIST_FILE")
                cp "$T" "$SYSCTL_FILE"
                ensure_sysctl && sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
                info "已还原：$(basename "$T") ✓"
            else
                error "无效选项"
            fi
            ;;
    esac
    rm -f "$LIST_FILE"
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() {
    local CONFIG="$1"
    ensure_sysctl || return 1
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true

    # ── 切换预设时复位「旧配置写过、但新配置不再包含」的场景专有键 ──
    # 否则从中转/落地降级回普通预设后，ip_forward / conntrack 等会一直残留在内核里。
    # 仅复位本脚本场景预设管理的键，且新配置确实不含该键时才动；ip_forward 谨慎处理。
    if [ -f "$SYSCTL_FILE" ]; then
        local SCENE_KEYS="net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_timeout_established net.netfilter.nf_conntrack_tcp_timeout_time_wait net.ipv4.ip_local_port_range net.ipv4.tcp_max_tw_buckets fs.file-max"
        local k STALE=""
        for k in $SCENE_KEYS; do
            # 旧文件里有该键，但新配置里没有 → 视为需要清理的残留
            if grep -qE "^${k} *=" "$SYSCTL_FILE" 2>/dev/null && ! echo "$CONFIG" | grep -qE "^${k} *="; then
                STALE="$STALE $k"
            fi
        done
        if [ -n "$STALE" ]; then
            warn "检测到上次场景预设遗留参数，新预设不再需要："
            for k in $STALE; do echo -e "    ${DIM}${k}${NC}"; done
            # ip_forward 如被关闭可能影响 NFT/iptables 转发，单独警告
            if echo "$STALE" | grep -q 'ip_forward'; then
                warn "其中 ip_forward 复位后将关闭内核转发，若本机仍在做端口转发/中转请勿复位"
            fi
            read -rp "  是否复位这些残留参数为系统默认？(y/N，默认N): " DORST
            [ -z "$DORST" ] && DORST="n"
            if echo "$DORST" | grep -qiE '^y(es)?$'; then
                for k in $STALE; do
                    # 端口范围 / tw_buckets / file-max 复位成 0 非法或有害，给内核安全默认
                    case "$k" in
                        net.ipv4.ip_forward|net.ipv6.conf.all.forwarding) sysctl -w "${k}=0" >/dev/null 2>&1 ;;
                        net.ipv4.ip_local_port_range) sysctl -w "${k}=32768 60999" >/dev/null 2>&1 || true ;;
                        net.ipv4.tcp_max_tw_buckets)  sysctl -w "${k}=131072" >/dev/null 2>&1 || true ;;
                        fs.file-max)                  : ;;  # file-max 抬高无害，不复位（避免误伤其他服务）
                        *) sysctl -w "${k}=0" >/dev/null 2>&1 || true ;;
                    esac
                done
                info "残留场景参数已复位"
            else
                warn "保留残留参数（仍生效于当前内核，直到下次手动复位或重启）"
            fi
        fi
    fi

    echo "$CONFIG" > "$SYSCTL_FILE"

    # 逐行应用，跳过不支持的参数（Alpine 部分内核不支持 default_qdisc 等）
    local FAILED=0 SKIPPED=0
    while IFS= read -r line; do
        # 跳过注释和空行
        echo "$line" | grep -qE '^\s*#|^\s*$' && continue
        local KEY VAL
        KEY=$(echo "$line" | cut -d= -f1 | tr -d ' ')
        VAL=$(echo "$line" | cut -d= -f2- | sed 's/^ //')
        if ! sysctl -w "${KEY}=${VAL}" > /dev/null 2>&1; then
            warn "跳过不支持的参数：${KEY}"
            SKIPPED=$(( SKIPPED + 1 ))
        fi
    done < "$SYSCTL_FILE"

    if [ "$SKIPPED" -gt 0 ]; then
        warn "共跳过 ${SKIPPED} 个不支持的参数（已记录在配置文件，重启后不影响）"
    fi
    info "sysctl 配置已应用到 ${SYSCTL_FILE} ✓"
}

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_apply_tc() {
    local RATE="$1"
    local DEV; DEV=$(default_iface)
    [ -z "$DEV" ] && { error "无法确定默认出口网卡"; return 1; }

    # burst/cburst 随速率缩放（约 8ms 量级，≈ RATE KB），下限 32KB。
    # 固定 burst 会在高速率下令牌饥饿，导致跑不满设定速率。
    local BURST_KB=$RATE
    [ "$BURST_KB" -lt 32 ] && BURST_KB=32

    # 关键：用 htb 做「聚合」整形（真正硬上限），叶子挂 fq 保留 BBR pacing。
    # 旧版多队列网卡用 root tbf 会顶掉 fq、废掉 BBR pacing，且单纯 fq maxrate
    # 只能限「每流」不能限聚合。htb(整形) + fq(pacing) 才同时满足两者。
    tc qdisc del dev "$DEV" root 2>/dev/null
    if ! tc qdisc add dev "$DEV" root handle 1: htb default 10 2>/dev/null \
        || ! tc class add dev "$DEV" parent 1: classid 1:10 htb \
                rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        || ! tc qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null; then
        error "tc 规则应用失败（内核可能缺 sch_htb / sch_fq 模块）"
        tc qdisc del dev "$DEV" root 2>/dev/null
        return 1
    fi

    cat > "$SERVICE_TC" << EOF
[Unit]
Description=TC egress shaping ${RATE}Mbps (htb shape + fq pacing for BBR)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${DEV} root 2>/dev/null; /sbin/tc qdisc add dev ${DEV} root handle 1: htb default 10 && /sbin/tc class add dev ${DEV} parent 1: classid 1:10 htb rate ${RATE}mbit ceil ${RATE}mbit burst ${BURST_KB}kb cburst ${BURST_KB}kb && /sbin/tc qdisc add dev ${DEV} parent 1:10 handle 100: fq maxrate ${RATE}mbit'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    svc_daemon_reload
    svc_enable tc-fq
    rc-service tc-fq restart 2>/dev/null || systemctl restart tc-fq 2>/dev/null || true
    info "tc 限速已应用：${RATE}Mbps（htb 聚合整形 + fq pacing，burst ${BURST_KB}KB）✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
bbr_generate_config() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAPPINESS=$7 TCP_RMEM_DEFAULT=$8 PROFILE_NAME="${9:-default}"
    cat << EOF
# BBR TCP 调优配置 — 生成时间：$(date)
# 预设：${PROFILE_NAME}
# ── 内存管理 ──
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE}

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.ipv4.tcp_rmem = 32768 ${TCP_RMEM_DEFAULT} ${RMEM}
net.ipv4.tcp_wmem = 32768 ${TCP_RMEM_DEFAULT} ${WMEM}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_adv_win_scale = ${ADV_WIN}
net.ipv4.tcp_notsent_lowat = ${NOTSENT}

# ── 连接质量 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60

# ── UDP 缓冲（QUIC / Hysteria2 / TUIC 代理）──
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

    # 中转机 / 落地机 / 线路落地机 共同需要的转发与 conntrack
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            cat << EOF

# ── 转发与并发（中转/落地必备）──
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_tw_buckets = 500000
fs.file-max = 1048576
EOF
            ;;
    esac

    # 中转机额外的 conntrack 调优（大并发场景必需）
    if [ "$PROFILE_NAME" = "relay" ]; then
        cat << EOF

# ── conntrack（中转大并发必备）──
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    fi
}

# ── 确认并应用参数 ────────────────────────────────────────
# ── 检测常见代理 service 的 LimitNOFILE，偏低则提示写 drop-in ──
# fs.file-max 只是系统总上限，单进程 fd 上限由 systemd 的 LimitNOFILE 决定。
bbr_check_limitnofile() {
    command -v systemctl >/dev/null 2>&1 || return 0   # 非 systemd 跳过
    local SVCS="xray sing-box hysteria hysteria-server tuic v2ray trojan trojan-go mihomo clash"
    local svc found=0
    for svc in $SVCS; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" || continue
        found=1
        local CUR
        CUR=$(systemctl show -p LimitNOFILE --value "${svc}.service" 2>/dev/null)
        # 默认值通常为 1024 / 524288；低于 1048576 视为偏低
        if [ -n "$CUR" ] && [ "$CUR" -lt 1048576 ] 2>/dev/null; then
            echo ""
            warn "检测到代理服务 ${svc}.service 的 LimitNOFILE=${CUR} 偏低"
            echo -e "  ${DIM}fs.file-max 已抬高，但单进程 fd 上限受 systemd LimitNOFILE 限制${NC}"
            read -rp "  是否为 ${svc} 写入 LimitNOFILE=1048576 的 drop-in？(y/N，默认N): " DOLN
            [ -z "$DOLN" ] && DOLN="n"
            if echo "$DOLN" | grep -qiE '^y(es)?$'; then
                local DROPDIR="/etc/systemd/system/${svc}.service.d"
                mkdir -p "$DROPDIR" 2>/dev/null
                printf '[Service]\nLimitNOFILE=1048576\n' > "${DROPDIR}/99-nofile.conf"
                systemctl daemon-reload 2>/dev/null
                info "已写入 ${DROPDIR}/99-nofile.conf，重启 ${svc} 后生效：systemctl restart ${svc}"
            fi
        fi
    done
    [ "$found" -eq 0 ] && return 0
}

bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAP=$7 TCP_RMEM_DEFAULT=$8 \
          LABEL_MODE=$9 LABEL_BUF=${10} PROFILE_NAME="${11:-default}"

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  ${YELLOW}── 配置摘要 ──────────────────────────────${NC}"
    echo -e "  模式         : ${BOLD}$LABEL_MODE${NC}"
    echo -e "  缓冲区       : ${BOLD}${LABEL_BUF}MB${NC}  (rmem/wmem max)"
    echo -e "  tcp_rmem default : ${BOLD}$(( TCP_RMEM_DEFAULT / 1048576 ))MB${NC}"
    echo -e "  min_free_kbytes  : ${BOLD}${MIN_FREE}${NC}"
    echo -e "  tcp_mem      : ${BOLD}${TCP_MEM}${NC}"
    echo -e "  adv_win_scale: ${BOLD}${ADV_WIN}${NC}"
    echo -e "  swappiness   : ${BOLD}${SWAP}${NC}"
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    echo ""
    # 先检测 sysctl 写入权限
    if ! has_sysctl_write; then
        error "当前容器无 sysctl 写入权限，无法应用配置"
        echo -e "  ${DIM}需要宿主机开启 privileged 模式或 sysctl 白名单${NC}"
        return
    fi

    # 再检测内核是否支持 BBR
    if ! bbr_check_kernel; then
        echo ""
        read -rp "  内核不支持 BBR，仍要继续写入配置？(y/N，默认N): " FORCE
        [ -z "$FORCE" ] && FORCE="n"
        if ! echo "$FORCE" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    fi

    # 先提示备份（默认Y）
    if [ -f "$SYSCTL_FILE" ]; then
        read -rp "  备份当前 sysctl 配置？(Y/n，默认Y): " DO_BAK
        [ -z "$DO_BAK" ] && DO_BAK="y"
        echo "$DO_BAK" | grep -qiE '^y(es)?$' && bbr_backup_sysctl
        echo ""
    fi
    read -rp "  确认应用以上配置？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" "$PROFILE_NAME")
    [ "$PROFILE_NAME" = "relay" ] || [ "$PROFILE_NAME" = "landing" ] || [ "$PROFILE_NAME" = "line_landing" ] && ensure_conntrack_module
    bbr_apply_sysctl "$CONFIG"
    # 场景预设（转发机）额外检测代理 service 的 fd 上限
    case "$PROFILE_NAME" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    echo ""
    info "BBR TCP 调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6

    # 合并为单表达式避免双重整数截断：
    # 旧写法 BW/8 再 ×LAT/1000 两次取整，低带宽×低延迟会被归零（显示 BDP 0MB）
    local BDP_MB=$(( BW_MBPS * LAT_MS / 8000 ))
    local BUF_CALC=$(( BDP_MB * 3 / 2 ))

    local RMEM WMEM ADV_WIN NOTSENT TCP_RMEM_DEFAULT
    if   [ "$BUF_CALC" -le 10 ];  then RMEM=12582912;   WMEM=12582912;   ADV_WIN=2; NOTSENT=131072;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 20 ];  then RMEM=20971520;   WMEM=20971520;   ADV_WIN=2; NOTSENT=131072;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 32 ];  then RMEM=33554432;   WMEM=33554432;   ADV_WIN=2; NOTSENT=262144;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 40 ];  then RMEM=41943040;   WMEM=41943040;   ADV_WIN=3; NOTSENT=262144;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 64 ];  then RMEM=67108864;   WMEM=67108864;   ADV_WIN=3; NOTSENT=524288;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 128 ]; then RMEM=134217728;  WMEM=134217728;  ADV_WIN=3; NOTSENT=524288;  TCP_RMEM_DEFAULT=2097152
    elif [ "$BUF_CALC" -le 256 ]; then RMEM=268435456;  WMEM=268435456;  ADV_WIN=3; NOTSENT=1048576; TCP_RMEM_DEFAULT=2097152
    elif [ "$BUF_CALC" -le 512 ]; then RMEM=536870912;  WMEM=536870912;  ADV_WIN=3; NOTSENT=2097152; TCP_RMEM_DEFAULT=4194304
    else                                RMEM=1073741824; WMEM=1073741824; ADV_WIN=3; NOTSENT=2097152; TCP_RMEM_DEFAULT=4194304
    fi

    # 限制：缓冲区不超过物理内存一半
    local HALF_MEM=$(( MEM_MB * 1048576 / 2 ))
    if [ "$RMEM" -gt "$HALF_MEM" ]; then
        warn "缓冲区 $(( RMEM / 1048576 ))MB 超过物理内存 ${MEM_MB}MB 的一半，自动降级"
        RMEM=$HALF_MEM
        WMEM=$HALF_MEM
    fi

    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -le 768  ]; then MIN_FREE=32768;  SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -le 1536 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 131072"
    elif [ "$MEM_MB" -le 4096 ]; then MIN_FREE=65536;  SWAP=5;  TCP_MEM="131072 196608 393216"
    elif [ "$MEM_MB" -le 8192 ]; then MIN_FREE=131072; SWAP=5;  TCP_MEM="262144 393216 786432"
    else                               MIN_FREE=262144; SWAP=5;  TCP_MEM="524288 786432 1572864"
    fi

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  BDP 估算：${BOLD}${BDP_MB}MB${NC}  →  推荐缓冲区：${BOLD}${BUF_MB}MB${NC}"
    echo -e "  内存：${MEM_LBL}  延迟：${LAT_LBL}  带宽：${BW_LBL}"

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" \
        "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" \
        "自动计算（${MEM_LBL} / ${LAT_LBL} / ${BW_LBL}）" "$BUF_MB"
}

# ── 手动选择缓冲区模式 ────────────────────────────────────
# ── 自动模式：带宽子菜单 ─────────────────────────────────
bbr_menu_bandwidth() {
    local MEM_MB=$1 LAT_MS=$2 MEM_LBL=$3 LAT_LBL=$4
    print_header "BBR 自动配置 — 选择带宽"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}  延迟：${BOLD}${LAT_LBL}${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 100 Mbps"
    echo -e "  ${GREEN}2${NC}) 200 Mbps"
    echo -e "  ${GREEN}3${NC}) 500 Mbps"
    echo -e "  ${GREEN}4${NC}) 1 Gbps   (1024 Mbps)"
    echo -e "  ${GREEN}5${NC}) 2 Gbps   (2048 Mbps)"
    echo -e "  ${GREEN}6${NC}) 5 Gbps   (5120 Mbps)"
    echo -e "  ${GREEN}7${NC}) 10 Gbps  (10240 Mbps)"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-7]: " CH
    case "$CH" in
        1) bbr_auto_calc "$MEM_MB" "$LAT_MS" 100   "$MEM_LBL" "$LAT_LBL" "100Mbps" ;;
        2) bbr_auto_calc "$MEM_MB" "$LAT_MS" 200   "$MEM_LBL" "$LAT_LBL" "200Mbps" ;;
        3) bbr_auto_calc "$MEM_MB" "$LAT_MS" 500   "$MEM_LBL" "$LAT_LBL" "500Mbps" ;;
        4) bbr_auto_calc "$MEM_MB" "$LAT_MS" 1024  "$MEM_LBL" "$LAT_LBL" "1Gbps" ;;
        5) bbr_auto_calc "$MEM_MB" "$LAT_MS" 2048  "$MEM_LBL" "$LAT_LBL" "2Gbps" ;;
        6) bbr_auto_calc "$MEM_MB" "$LAT_MS" 5120  "$MEM_LBL" "$LAT_LBL" "5Gbps" ;;
        7) bbr_auto_calc "$MEM_MB" "$LAT_MS" 10240 "$MEM_LBL" "$LAT_LBL" "10Gbps" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：延迟子菜单 ─────────────────────────────────
bbr_menu_latency() {
    local MEM_MB=$1 MEM_LBL=$2
    print_header "BBR 自动配置 — 选择延迟"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 100ms 以内     （国内 / 亚洲近距离）"
    echo -e "  ${GREEN}2${NC}) 100ms - 200ms  （跨国，如美西→中国）"
    echo -e "  ${GREEN}3${NC}) 200ms 以上     （欧洲→中国 / 长距离）"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-3]: " CH
    case "$CH" in
        1) bbr_menu_bandwidth "$MEM_MB" 50  "$MEM_LBL" "100ms以内" ;;
        2) bbr_menu_bandwidth "$MEM_MB" 150 "$MEM_LBL" "100-200ms" ;;
        3) bbr_menu_bandwidth "$MEM_MB" 250 "$MEM_LBL" "200ms以上" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：内存子菜单 ─────────────────────────────────
bbr_menu_auto() {
    # 自动检测系统内存并标注推荐档位
    local MEM_KB; MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    local SYS_MEM_MB=$(( ${MEM_KB:-0} / 1024 ))

    print_header "BBR 自动配置 — 选择内存"
    echo -e "  系统检测内存：${BOLD}${SYS_MEM_MB}MB${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 512 MB"
    echo -e "  ${GREEN}2${NC}) 1 GB"
    echo -e "  ${GREEN}3${NC}) 2 GB"
    echo -e "  ${GREEN}4${NC}) 4 GB"
    echo -e "  ${GREEN}5${NC}) 8 GB"
    echo -e "  ${GREEN}6${NC}) 16 GB+"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-6]: " CH
    case "$CH" in
        1) bbr_menu_latency 512   "512MB" ;;
        2) bbr_menu_latency 1024  "1GB" ;;
        3) bbr_menu_latency 2048  "2GB" ;;
        4) bbr_menu_latency 4096  "4GB" ;;
        5) bbr_menu_latency 8192  "8GB" ;;
        6) bbr_menu_latency 16384 "16GB+" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 手动模式：内存子菜单 ─────────────────────────────────
bbr_menu_manual() {
    # 自动检测系统内存
    local MEM_KB; MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local MEM_MB=$(( MEM_KB / 1024 ))

    # ── 第一层：选择用途 ──
    print_header "BBR 手动配置 — 选择用途"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}"
    echo ""
    menu_div
    echo -e "  ${BOLD}请选择 VPS 用途（决定转发/conntrack/窗口参数）${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 中转机      — 双向转发/大并发（如 sing-box 中转）"
    echo -e "  ${GREEN}2${NC}) 落地机      — 跨境上行/大缓冲（落地代理出口）"
    echo -e "  ${GREEN}3${NC}) 线路落地机  — CN2/IPLC/直连用户/低延迟优先"
    echo -e "  ${GREEN}4${NC}) 通用 / 单机 — 普通 VPS（网页/SSH/服务）"
    echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-4]: " SCENE
    local PROFILE SCENE_LABEL
    case "$SCENE" in
        1) PROFILE="relay";        SCENE_LABEL="中转机" ;;
        2) PROFILE="landing";      SCENE_LABEL="落地机" ;;
        3) PROFILE="line_landing"; SCENE_LABEL="线路落地机" ;;
        4) PROFILE="default";      SCENE_LABEL="通用单机" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # ── 第二层：根据场景给出推荐档位提示 + 缓冲区选择 ──
    local RECOMMEND
    case "$PROFILE" in
        relay)
            # 中转机：中等缓冲足够，并发为主
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 4 (32MB) 或 5 (40MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB)"
            fi ;;
        landing)
            # 落地机：大缓冲吃满带宽
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 7 (128MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 8 (256MB)"
            elif [ "$MEM_MB" -le 8192 ]; then RECOMMEND="推荐 9 (512MB)"
            else                              RECOMMEND="推荐 9 (512MB) 或 10 (1024MB)"
            fi ;;
        line_landing)
            # 线路落地机：低延迟优先，缓冲不用大
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 3 (20MB) 或 4 (32MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 4 (32MB) 或 6 (64MB)"
            else                              RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            fi ;;
        default)
            if   [ "$MEM_MB" -le 768 ];  then RECOMMEND="推荐 2 (16MB) 或 3 (20MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 4 (32MB) 或 6 (64MB)"
            else                              RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            fi ;;
    esac

    print_header "BBR 手动配置 — ${SCENE_LABEL} · 选择缓冲区"
    echo -e "  场景：${BOLD}${SCENE_LABEL}${NC}    内存：${BOLD}${MEM_MB}MB${NC}"
    echo -e "  ${YELLOW}${RECOMMEND}${NC}"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 12 MB    — 低带宽 / 低延迟"
    echo -e "  ${GREEN}2${NC}) 16 MB    — 小内存保守"
    echo -e "  ${GREEN}3${NC}) 20 MB    — 中低带宽"
    echo -e "  ${GREEN}4${NC}) 32 MB    — 1G 跨境甜点区（~150ms BDP，推荐）"
    echo -e "  ${GREEN}5${NC}) 40 MB    — 中等带宽（1G）"
    echo -e "  ${GREEN}6${NC}) 64 MB    — 高带宽（1G+ 跨境）"
    echo -e "  ${GREEN}7${NC}) 128 MB   — 超高带宽（2G/高延迟）"
    echo -e "  ${GREEN}8${NC}) 256 MB   — 万兆 / 跨洋（5G/100ms）"
    echo -e "  ${GREEN}9${NC}) 512 MB   — 万兆 / 长距离（10G/100ms）"
    echo -e "  ${GREEN}10${NC}) 1024 MB — 极限（10G+/200ms+，需 8G+ 内存）"
    echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-10]: " CH

    local RMEM WMEM BUF_LBL
    case "$CH" in
        1)  RMEM=12582912;   BUF_LBL=12   ;;
        2)  RMEM=16777216;   BUF_LBL=16   ;;
        3)  RMEM=20971520;   BUF_LBL=20   ;;
        4)  RMEM=33554432;   BUF_LBL=32   ;;
        5)  RMEM=41943040;   BUF_LBL=40   ;;
        6)  RMEM=67108864;   BUF_LBL=64   ;;
        7)  RMEM=134217728;  BUF_LBL=128  ;;
        8)  RMEM=268435456;  BUF_LBL=256  ;;
        9)  RMEM=536870912;  BUF_LBL=512  ;;
        10) RMEM=1073741824; BUF_LBL=1024 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    WMEM=$RMEM

    # 缓冲区不超过物理内存一半
    local HALF_MEM=$(( MEM_MB * 1048576 / 2 ))
    if [ "$RMEM" -gt "$HALF_MEM" ]; then
        warn "缓冲区 ${BUF_LBL}MB 超过物理内存 ${MEM_MB}MB 的一半"
        read -rp "  是否继续？(y/N，默认N): " GO
        [ -z "$GO" ] && GO="n"
        echo "$GO" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    fi

    # ── 根据场景调整窗口/队列参数 ──
    local ADV_WIN NOTSENT TCP_RMEM_DEFAULT
    case "$PROFILE" in
        relay)
            # 中转机：窗口标准、NOTSENT 小（降低单连接延迟）
            ADV_WIN=2; NOTSENT=262144
            [ "$BUF_LBL" -le 64 ] && TCP_RMEM_DEFAULT=1048576 || TCP_RMEM_DEFAULT=2097152
            ;;
        landing)
            # 落地机：窗口激进、NOTSENT 大（高吞吐）
            ADV_WIN=3; NOTSENT=2097152
            [ "$BUF_LBL" -le 64 ] && TCP_RMEM_DEFAULT=1048576 \
            || { [ "$BUF_LBL" -le 256 ] && TCP_RMEM_DEFAULT=2097152 || TCP_RMEM_DEFAULT=4194304; }
            ;;
        line_landing)
            # 线路落地机：NOTSENT 极小（响应优先），adv_win=2 保证源站→落地高 BDP 接收
            ADV_WIN=2; NOTSENT=131072
            [ "$BUF_LBL" -le 64 ] && TCP_RMEM_DEFAULT=1048576 || TCP_RMEM_DEFAULT=2097152
            ;;
        default)
            # 通用：跟着缓冲区档位走
            if   [ "$BUF_LBL" -le 32 ];  then ADV_WIN=2; NOTSENT=262144;  TCP_RMEM_DEFAULT=1048576
            elif [ "$BUF_LBL" -le 64 ];  then ADV_WIN=3; NOTSENT=524288;  TCP_RMEM_DEFAULT=1048576
            elif [ "$BUF_LBL" -le 256 ]; then ADV_WIN=3; NOTSENT=1048576; TCP_RMEM_DEFAULT=2097152
            else                              ADV_WIN=3; NOTSENT=2097152; TCP_RMEM_DEFAULT=4194304
            fi ;;
    esac

    # ── 内存相关参数按物理内存匹配 ──
    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -le 768  ]; then MIN_FREE=32768;  SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -le 1536 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 131072"
    elif [ "$MEM_MB" -le 4096 ]; then MIN_FREE=65536;  SWAP=5;  TCP_MEM="131072 196608 393216"
    elif [ "$MEM_MB" -le 8192 ]; then MIN_FREE=131072; SWAP=5;  TCP_MEM="262144 393216 786432"
    else                               MIN_FREE=262144; SWAP=5;  TCP_MEM="524288 786432 1572864"
    fi
    # 中转机额外抬高 swappiness（容忍多进程）
    [ "$PROFILE" = "relay" ] && SWAP=10

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" \
        "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" \
        "${SCENE_LABEL}（内存 ${MEM_MB}MB）" "$BUF_LBL" "$PROFILE"
}

# ── tc 限速菜单 ───────────────────────────────────────────
bbr_menu_tc() {
    print_header "限速设置（tc）"

    if is_openvz; then
        echo ""
        warn "检测到当前运行于 ${BOLD}OpenVZ 容器${NC} 中"
        warn "OpenVZ 共享内核，tc 流量控制通常被宿主机限制，无法正常使用"
        echo ""
        echo -e "  ${DIM}如需限速，请联系 VPS 提供商在宿主机层面配置${NC}"
        echo ""
        read -rp "  按 Enter 返回..." _
        return
    fi

    local DEV; DEV=$(default_iface)
    local QTYPE; QTYPE=$(tc qdisc show dev "$DEV" 2>/dev/null | awk 'NR==1{print $2}')
    [ -z "$QTYPE" ] && QTYPE="未知"
    # 当前限速：优先取 htb class 的 rate，其次 fq maxrate
    local CUR; CUR=$(tc class show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$CUR" ] && CUR=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oE 'maxrate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$CUR" ] && CUR="未设置"

    echo -e "  网卡：${BOLD}${DEV}${NC}  当前 qdisc：${BOLD}${QTYPE}${NC}  当前限速：${BOLD}${CUR}${NC}"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 200 Mbps"
    echo -e "  ${GREEN}2${NC}) 500 Mbps"
    echo -e "  ${GREEN}3${NC}) 780 Mbps"
    echo -e "  ${GREEN}4${NC}) 1024 Mbps (1Gbps)"
    echo -e "  ${GREEN}5${NC}) 2048 Mbps (2Gbps)"
    echo -e "  ${GREEN}6${NC}) 自定义输入"
    echo -e "  ${YELLOW}7${NC}) 取消限速"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-7]: " CH

    local RATE=0
    case "$CH" in
        1) RATE=200 ;;
        2) RATE=500 ;;
        3) RATE=780 ;;
        4) RATE=1024 ;;
        5) RATE=2048 ;;
        6)
            read -rp "  请输入限速值（Mbps）: " RATE
            if ! echo "$RATE" | grep -qE '^[0-9]+$' || [ "$RATE" -lt 1 ]; then
                error "无效数值"; return
            fi
            ;;
        7) RATE=0 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    if [ "$RATE" -eq 0 ]; then
        # 删除 root qdisc，内核会自动恢复默认（mq/fq_codel 等），无需手动重建 mq
        tc qdisc del dev "$DEV" root 2>/dev/null
        svc_disable tc-fq
        rm -f "$SERVICE_TC"
        svc_daemon_reload
        info "已取消限速 ✓"
    else
        bbr_apply_tc "$RATE"
    fi
}

# ── initcwnd 菜单 ─────────────────────────────────────────
# 检测是否在 LXC 容器内

# 检测 OpenVZ / LXC 等受限容器
is_openvz() {
    [ -f /proc/vz/veinfo ] && return 0
    grep -qaE 'openvz|lxc' /proc/1/environ 2>/dev/null && return 0
    grep -qaE 'openvz|lxc' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

is_lxc() {
    grep -qa "lxc" /proc/1/environ 2>/dev/null     || [ -f /run/systemd/container ]     || grep -qa "container=lxc" /proc/1/environ 2>/dev/null     || { [ -f /proc/1/cgroup ] && grep -qa "lxc" /proc/1/cgroup 2>/dev/null; }
}

bbr_menu_initcwnd() {
    print_header "initcwnd 设置"

    # ── LXC 检测 ───────────────────────────────────────────
    if is_lxc; then
        echo ""
        warn "检测到当前运行于 ${BOLD}LXC 容器${NC} 中"
        warn "LXC 容器没有独立网络命名空间权限，无法执行 ip route change"
        echo ""
        echo -e "  ${DIM}initcwnd 需要在宿主机或独立网络命名空间（如 KVM/独立VPS）中设置${NC}"
        echo -e "  ${DIM}如需设置，请在宿主机执行：${NC}"
        echo -e "  ${CYAN}  ip route change default initcwnd 50 initrwnd 50${NC}"
        echo ""
        return
    fi

    local DEV GW ONLINK
    DEV=$(default_iface)
    GW=$(ip route | awk '/^default/{print $3}')
    ONLINK=$(ip route | grep "^default" | grep -q "onlink" && echo "onlink" || echo "")
    local CUR; CUR=$(ip route show | grep "^default" | grep -oE 'initcwnd [0-9]+' | awk '{print $2}')
    CUR="${CUR:-10（默认）}"

    echo -e "  网卡：${BOLD}${DEV}${NC}  网关：${BOLD}${GW}${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 10   — 默认保守"
    echo -e "  ${GREEN}2${NC}) 50   — 跨国高延迟推荐"
    echo -e "  ${GREEN}3${NC}) 100  — 激进（可能丢包）"
    echo -e "  ${GREEN}4${NC}) 自定义输入"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-4]: " CH

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=50 ;;
        3) VAL=100 ;;
        4)
            read -rp "  请输入 initcwnd 值（1-1000）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
                error "无效数值"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    ip route change default via "$GW" dev "$DEV" $ONLINK initcwnd "$VAL" initrwnd "$VAL" || {
        error "ip route change 失败"
        echo ""
        echo -e "  ${DIM}如果你在 LXC/OpenVZ 容器内，此操作会被宿主机拒绝，这是正常现象${NC}"
        return
    }

    local SERVICE_CWND="/etc/systemd/system/initcwnd.service"
    cat > "$SERVICE_CWND" << EOF
[Unit]
Description=Set TCP initcwnd
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'GW=\$(ip route | awk '"'"'/^default/{print \$3}'"'"'); DEV=\$(ip route | awk '"'"'/^default/{print \$5}'"'"'); ONLINK=\$(ip route | grep "^default" | grep -q "onlink" && echo "onlink" || echo ""); ip route change default via \$GW dev \$DEV \$ONLINK initcwnd ${VAL} initrwnd ${VAL}'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    svc_daemon_reload
    svc_enable initcwnd
    rc-service initcwnd restart 2>/dev/null || systemctl restart initcwnd 2>/dev/null || true
    info "initcwnd 已设置为 ${VAL}，重启后自动生效 ✓"
}

# ── BBR 主菜单 ────────────────────────────────────────────

# ── 一键 TCP 预设（三种场景）────────────────────────────
volcano_tcp_profile() {
    local PROFILE="${1:-balanced}"
    local RMEM WMEM TCP_MEM NOTSENT ADV_WIN MIN_FREE SWAP TCP_RMEM_DEFAULT LABEL BUF_MB
    case "$PROFILE" in
        balanced)
            # 根据实际内存动态调整 balanced 缓冲区，避免超过物理内存一半
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 512 ]; then
                RMEM=16777216; WMEM=16777216; BUF_MB=16
            elif [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=33554432; WMEM=33554432; BUF_MB=32
            else
                RMEM=67108864; WMEM=67108864; BUF_MB=64
            fi
            WMEM=$RMEM; TCP_MEM="65536 131072 262144"
            NOTSENT=262144; ADV_WIN=2; MIN_FREE=65536; SWAP=10
            TCP_RMEM_DEFAULT=1048576
            LABEL="均衡跨境  — 网页/代理/日常综合（推荐）" ;;
        latency)
            RMEM=33554432; WMEM=33554432; TCP_MEM="49152 98304 196608"
            NOTSENT=131072; ADV_WIN=1; MIN_FREE=65536; SWAP=10
            TCP_RMEM_DEFAULT=524288; BUF_MB=32
            LABEL="低延迟交互 — SSH/游戏/远程桌面/小包优先" ;;
        throughput)
            # 根据内存动态选缓冲区，万兆机器自动用大缓冲
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=67108864;   BUF_MB=64;   TCP_MEM="131072 196608 393216"; MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=134217728;  BUF_MB=128;  TCP_MEM="131072 262144 524288"; MIN_FREE=131072
            elif [ "${_MEM_MB:-0}" -lt 8192 ]; then
                RMEM=268435456;  BUF_MB=256;  TCP_MEM="262144 393216 786432"; MIN_FREE=131072
            else
                RMEM=536870912;  BUF_MB=512;  TCP_MEM="524288 786432 1572864"; MIN_FREE=262144
            fi
            WMEM=$RMEM
            NOTSENT=2097152; ADV_WIN=3; SWAP=5
            TCP_RMEM_DEFAULT=4194304
            LABEL="高吞吐传输 — 大带宽/万兆/下载上传优先" ;;
        relay)
            ensure_conntrack_module
            # 中转机：两进两出，需要均衡缓冲+低延迟+大并发
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32;   TCP_MEM="49152 98304 196608";  MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64;   TCP_MEM="65536 131072 262144"; MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128;  TCP_MEM="131072 196608 393216"; MIN_FREE=131072
            else
                RMEM=268435456; BUF_MB=256;  TCP_MEM="262144 393216 786432"; MIN_FREE=131072
            fi
            WMEM=$RMEM
            NOTSENT=262144; ADV_WIN=2; SWAP=10
            TCP_RMEM_DEFAULT=1048576
            LABEL="中转机 — 双向流量/大并发/均衡延迟与吞吐" ;;
        landing)
            ensure_conntrack_module
            # 落地机：流量主要是单向上行，跨境延迟高，需要大缓冲吃满带宽
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=67108864;   BUF_MB=64;   TCP_MEM="65536 131072 262144";   MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=134217728;  BUF_MB=128;  TCP_MEM="131072 262144 524288";  MIN_FREE=131072
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=268435456;  BUF_MB=256;  TCP_MEM="262144 393216 786432";  MIN_FREE=131072
            else
                RMEM=536870912;  BUF_MB=512;  TCP_MEM="524288 786432 1572864"; MIN_FREE=262144
            fi
            WMEM=$RMEM
            NOTSENT=2097152; ADV_WIN=3; SWAP=5
            TCP_RMEM_DEFAULT=4194304
            LABEL="落地机 — 跨境上行/大缓冲吃满带宽" ;;
        line_landing)
            ensure_conntrack_module
            # 线路落地机：直连用户/CN2/IPLC 线路，低延迟优先+中等吞吐
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32;   TCP_MEM="49152 98304 196608";  MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64;   TCP_MEM="65536 131072 262144"; MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128;  TCP_MEM="131072 262144 524288"; MIN_FREE=131072
            else
                RMEM=268435456; BUF_MB=256;  TCP_MEM="262144 393216 786432"; MIN_FREE=131072
            fi
            WMEM=$RMEM
            NOTSENT=131072; ADV_WIN=2; SWAP=5
            TCP_RMEM_DEFAULT=1048576
            LABEL="线路落地机 — CN2/IPLC/直连用户/低延迟优先" ;;
        *) error "未知预设：$PROFILE"; return 1 ;;
    esac

    echo -e "  预设：${BOLD}${LABEL}${NC}"
    echo -e "  缓冲：${BOLD}${BUF_MB}MB${NC}  拥塞控制：${BOLD}BBR + fq${NC}"
    echo ""
    bbr_backup_sysctl
    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" "$PROFILE")
    bbr_apply_sysctl "$CONFIG"
    case "$PROFILE" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    info "TCP 预设「${PROFILE}」已应用 ✓"
}

# ── 智能 TCP 调优向导 ────────────────────────────────────
bbr_smart_wizard() {
    print_header "智能 TCP 调优向导"
    local MEM_KB MEM_MB KERNEL CUR_CC
    MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    MEM_MB=$(( ${MEM_KB:-0} / 1024 ))
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")

    menu_group "当前环境"
    echo -e "  内存：${GREEN}${MEM_MB}MB${NC}  内核：${GREEN}${KERNEL}${NC}  拥塞控制：${GREEN}${CUR_CC}${NC}"
    echo ""
    menu_div
    menu_group "通用预设"
    echo -e "  ${GREEN}1${NC}) 均衡跨境    — 默认推荐，适合大多数 VPS"
    echo -e "  ${GREEN}2${NC}) 低延迟交互  — SSH/游戏/远程桌面"
    echo -e "  ${GREEN}3${NC}) 高吞吐传输  — 大带宽/下载上传优先"
    echo ""
    menu_group "场景化预设"
    echo -e "  ${GREEN}4${NC}) 中转机      — 双向转发/大并发（如 sing-box 中转）"
    echo -e "  ${GREEN}5${NC}) 落地机      — 跨境上行/大缓冲（落地代理出口）"
    echo -e "  ${GREEN}6${NC}) 线路落地机  — CN2/IPLC/直连用户/低延迟优先"
    echo ""
    echo -e "  ${GREEN}7${NC}) 自动推荐    — 根据当前内存智能选择"
    echo -e "  ${RED}0${NC}) 返回         ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-7]: " CH

    local PROFILE=""
    case "$CH" in
        1) PROFILE="balanced" ;;
        2) PROFILE="latency" ;;
        3) PROFILE="throughput" ;;
        4) PROFILE="relay" ;;
        5) PROFILE="landing" ;;
        6) PROFILE="line_landing" ;;
        7)
            if [ "$MEM_MB" -lt 768 ]; then
                PROFILE="latency"
                warn "小内存机器，推荐低延迟/轻量参数"
            elif [ "$MEM_MB" -lt 1536 ]; then
                PROFILE="balanced"
                info "1GB 左右机器，推荐均衡模式"
            else
                PROFILE="balanced"
                info "2GB+ 机器，推荐均衡；大流量场景可选高吞吐或场景化预设"
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    echo ""
    read -rp "  确认应用「${PROFILE}」？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    volcano_tcp_profile "$PROFILE"
}


# ── 检测是否有 sysctl 写入权限 ───────────────────────────
has_sysctl_write() {
    # 尝试写一个无害的参数测试权限
    sysctl -w net.ipv4.tcp_fin_timeout=10 > /dev/null 2>&1 && return 0
    return 1
}

# ── 检测内核是否支持 BBR ─────────────────────────────────
bbr_check_kernel() {
    # 1. 检测内核版本 >= 4.9
    local KVER KMAJ KMIN
    KVER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+')
    KMAJ=$(echo "$KVER" | cut -d. -f1)
    KMIN=$(echo "$KVER" | cut -d. -f2)
    if [ "${KMAJ:-0}" -lt 4 ] || { [ "${KMAJ:-0}" -eq 4 ] && [ "${KMIN:-0}" -lt 9 ]; }; then
        error "内核版本 $(uname -r) 低于 4.9，不支持 BBR"
        echo -e "  ${DIM}Alpine: apk add linux-lts 或升级内核${NC}"
        return 1
    fi

    # 2. 检测 tcp_bbr 模块是否可用
    if lsmod 2>/dev/null | grep -q "tcp_bbr"; then
        return 0  # 已加载
    fi

    # 尝试加载模块
    if modprobe tcp_bbr 2>/dev/null; then
        info "tcp_bbr 模块已加载 ✓"
        return 0
    fi

    # Alpine 上尝试安装内核模块包
    if command -v apk &>/dev/null; then
        warn "tcp_bbr 模块未加载，尝试安装内核模块..."
        local KFULL; KFULL=$(uname -r)
        apk add --no-cache "linux-lts-dev" 2>/dev/null             || apk add --no-cache "linux-virt" 2>/dev/null || true
        modprobe tcp_bbr 2>/dev/null && { info "tcp_bbr 模块已加载 ✓"; return 0; }
    fi

    # 检查 sysctl 是否已设置 bbr（有些内核内置不需要模块）
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        return 0
    fi

    error "当前内核不支持 BBR（tcp_bbr 模块未找到）"
    echo -e "  ${DIM}Alpine 解决方案：${NC}"
    echo -e "  ${DIM}  apk add linux-lts && reboot${NC}"
    echo -e "  ${DIM}或检查：/proc/sys/net/ipv4/tcp_available_congestion_control${NC}"
    return 1
}

bbr_menu() {
    # 进入时检测一次 sysctl 写入权限
    local _BBR_NO_SYSCTL=0
    if ! has_sysctl_write; then
        _BBR_NO_SYSCTL=1
    fi
    while true; do
        print_header "BBR TCP 调优"
        bbr_print_status
        if [ "$_BBR_NO_SYSCTL" -eq 1 ]; then
            echo ""
            echo -e "  ${RED}${BOLD}⚠ 当前环境无 sysctl 写入权限${NC}"
            echo -e "  ${DIM}检测为无特权容器（unprivileged container）${NC}"
            echo -e "  ${DIM}sysctl 参数由宿主机控制，无法在容器内修改${NC}"
            echo -e "  ${DIM}请联系 VPS 提供商开启 sysctl 权限，或使用 KVM/独立VPS${NC}"
        fi
        echo ""
        menu_div
        menu_div
        echo -e "  ${GREEN}1${NC}) 智能向导（推荐）"
        echo -e "  ${GREEN}2${NC}) 自动配置（内存/延迟/带宽）"
        echo -e "  ${GREEN}3${NC}) 手动选择缓冲区大小"
        menu_div
        echo -e "  ${GREEN}4${NC}) 限速设置（tc）   ${GREEN}5${NC}) initcwnd 设置"
        echo -e "  ${GREEN}6${NC}) 备份 TCP 配置    ${GREEN}7${NC}) 还原 TCP 配置"
        echo -e "  ${RED}0${NC}) 返回主菜单        ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-7]: " CH

        case "$CH" in
            1) bbr_smart_wizard ;;
            2) bbr_menu_auto ;;
            3) bbr_menu_manual ;;
            4) bbr_menu_tc ;;
            5) bbr_menu_initcwnd ;;
            6) bbr_backup_sysctl ;;
            7) bbr_restore_sysctl ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


# ══════════════════════════════════════════════════════════
#  防火墙模块
# ══════════════════════════════════════════════════════════

# ── 检测防火墙类型 ────────────────────────────────────────
# 返回: ufw / firewalld / none
fw_detect() {
    if command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    else
        echo "none"
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
            ufw allow "${SSH_PORT}"/tcp 2>/dev/null && info "SSH ${SSH_PORT} ✓"
            ufw allow 80/tcp  2>/dev/null && info "HTTP 80 ✓"
            ufw allow 443/tcp 2>/dev/null && info "HTTPS 443 ✓"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null
            firewall-cmd --permanent --add-port="80/tcp"  2>/dev/null
            firewall-cmd --permanent --add-port="443/tcp" 2>/dev/null
            firewall-cmd --reload 2>/dev/null
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
                ufw --force enable && info "ufw 已启用 ✓"
                fw_allow_common_ports "ufw"
            else
                error "安装失败，请检查网络或手动安装：apt/apk install ufw"
            fi
            ;;
        firewalld)
            if pkg_install firewalld; then
                svc_enable firewalld
                svc_start firewalld
                info "firewalld 安装并启动成功 ✓"
                fw_allow_common_ports "firewalld"
            else
                error "安装失败，请检查网络或手动安装"
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
    print_header "添加端口规则 — ufw"
    echo -e "  示例：80  或  8080/tcp  或  3000:3010/tcp"
    echo ""
    read -rp "  请输入端口（直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return; }
    read -rp "  方向 [in/out，默认 in]: " DIR
    DIR="${DIR:-in}"
    echo ""
    if ufw allow "$DIR" "$PORT" 2>/dev/null || ufw allow "$PORT" 2>/dev/null; then
        info "已放行端口 $PORT ✓"
    else
        error "添加失败，请检查端口格式"
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
        [ -z "$NUM" ] && return
        if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
            error "无效编号"; sleep 1; continue
        fi
        echo "y" | ufw delete "$NUM" 2>/dev/null && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
        sleep 1
    done
}

ufw_block_ip() {
    print_header "拉黑 IP — ufw"
    read -rp "  请输入要拉黑的 IP 或 CIDR（如 1.2.3.4 或 1.2.3.0/24）: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    ufw deny from "$IP" to any 2>/dev/null && info "已拉黑 $IP ✓" || error "操作失败"
}

ufw_allow_ip() {
    print_header "白名单 IP — ufw"
    read -rp "  请输入要放行的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    ufw allow from "$IP" to any 2>/dev/null && info "已放行 $IP ✓" || error "操作失败"
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
        [ -z "$NUM" ] && return
        echo "y" | ufw delete "$NUM" 2>/dev/null && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
        sleep 1
    done
}

ufw_quick_allow() {
    print_header "一键放行常用端口 — ufw"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT"
    echo -e "  ${GREEN}HTTP${NC}  : 80"
    echo -e "  ${GREEN}HTTPS${NC} : 443"
    echo ""
    read -rp "  确认放行？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    ufw allow "$SSH_PORT"/tcp  && info "SSH $SSH_PORT 已放行 ✓"
    ufw allow 80/tcp           && info "HTTP 80 已放行 ✓"
    ufw allow 443/tcp          && info "HTTPS 443 已放行 ✓"
}

# ── ufw 子菜单 ────────────────────────────────────────────
ufw_menu() {
    while true; do
        local STATUS; STATUS=$(fw_running "ufw")
        local ST_COLOR; [ "$STATUS" = "active" ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"

        print_header "防火墙管理 — ufw"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        echo ""
        menu_div
        if [ "$STATUS" = "active" ]; then
            echo -e "  ${YELLOW}1${NC}) 关闭防火墙"
        else
            echo -e "  ${GREEN}1${NC}) 开启防火墙"
        fi
        echo -e "  ${GREEN}2${NC}) 查看规则         ${GREEN}3${NC}) 添加端口"
        echo -e "  ${GREEN}4${NC}) 删除端口         ${GREEN}5${NC}) 拉黑IP"
        echo -e "  ${GREEN}6${NC}) 放行IP           ${GREEN}7${NC}) 删除IP规则"
        echo -e "  ${GREEN}8${NC}) 一键放行常用端口"
        echo -e "  ${CYAN}u${NC}) 安装/更新        ${YELLOW}9${NC}) 卸载 ufw"
        echo -e "  ${RED}0${NC}) 返回              ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-9/u]: " CH

        case "$CH" in
            u|U)
                print_header "安装/更新 ufw"
                info "正在更新 ufw..."
                pkg_install ufw
                local NEW_VER; NEW_VER=$(ufw version 2>/dev/null | head -1)
                info "当前版本：${NEW_VER:-未知} ✓"
                sleep 1; continue
                ;;
            1)
                if [ "$STATUS" = "active" ]; then
                    ufw --force disable && info "防火墙已关闭 ✓"
                else
                    ufw --force enable  && info "防火墙已开启 ✓"
                fi
                sleep 1; continue
                ;;
            2) ufw_show_rules ;;
            3) ufw_add_port ;;
            4) ufw_del_port ;;
            5) ufw_block_ip ;;
            6) ufw_allow_ip ;;
            7) ufw_del_ip ;;
            8) ufw_quick_allow ;;
            9)
                warn "即将卸载 ufw，所有规则将清除"
                read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
                [ -z "${CONFIRM}" ] && CONFIRM="y"
    if echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then
                    # 完整清理：禁用 → 重置规则 → 卸载 → 清残留
                    warn "即将卸载 ufw 并清理其规则（默认策略与其它规则不受影响）"
                    sleep 1
                    ufw --force disable 2>/dev/null
                    ufw --force reset 2>/dev/null
                    pkg_remove ufw
                    # 清理残留文件（防止重装时读到旧配置）
                    rm -rf /etc/ufw /lib/ufw /usr/share/ufw 2>/dev/null
                    clear_iptables_residue  # 清理 iptables 残留规则
                    info "ufw 已完整卸载 ✓（仅清理 ufw 自身规则，SSH 仍可连接）"
                    return
                else
                    warn "已取消"
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
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
    print_header "添加端口规则 — firewalld"
    echo -e "  示例：80/tcp  或  3000-3010/tcp"
    echo ""
    read -rp "  请输入端口（直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-port="$PORT" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "已放行端口 $PORT ✓" || error "添加失败，请检查格式（需含协议，如 80/tcp）"
}

fwd_del_port() {
    print_header "删除端口规则 — firewalld"
    echo -e "  当前开放端口："
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | nl | while read -r i p; do
        echo -e "  ${GREEN}[$i]${NC} $p"
    done
    echo ""
    read -rp "  请输入要删除的端口（如 80/tcp，直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --remove-port="$PORT" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "端口 $PORT 已删除 ✓" || error "删除失败"
}

fwd_block_ip() {
    print_header "拉黑 IP — firewalld"
    read -rp "  请输入要拉黑的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${IP}' reject" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "已拉黑 $IP ✓" || error "操作失败"
}

fwd_allow_ip() {
    print_header "白名单 IP — firewalld"
    read -rp "  请输入要放行的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${IP}' accept" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "已放行 $IP ✓" || error "操作失败"
}

fwd_del_ip() {
    while true; do
        print_header "删除 IP 规则 — firewalld"
        echo -e "  当前 Rich Rules："
        local RULES; RULES=$(firewall-cmd --list-rich-rules 2>/dev/null)
        if [ -z "$RULES" ]; then
            echo -e "  ${YELLOW}暂无 IP 规则${NC}"
            echo ""
            read -rp "  按 Enter 返回..." _
            return
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
        [ -z "$IP" ] && return
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' reject" 2>/dev/null
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' accept" 2>/dev/null
        firewall-cmd --reload 2>/dev/null && info "IP $IP 相关规则已删除 ✓" || error "删除失败"
        sleep 1
    done
}

fwd_quick_allow() {
    print_header "一键放行常用端口 — firewalld"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT/tcp"
    echo -e "  ${GREEN}HTTP${NC}  : 80/tcp"
    echo -e "  ${GREEN}HTTPS${NC} : 443/tcp"
    echo ""
    read -rp "  确认放行？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"  && info "SSH $SSH_PORT 已放行 ✓"
    firewall-cmd --permanent --add-port="80/tcp"           && info "HTTP 80 已放行 ✓"
    firewall-cmd --permanent --add-port="443/tcp"          && info "HTTPS 443 已放行 ✓"
    firewall-cmd --reload && info "规则已重载 ✓"
}

# ── firewalld 子菜单 ──────────────────────────────────────
fwd_menu() {
    while true; do
        local STATUS; STATUS=$(fw_running "firewalld")
        local ST_COLOR; [ "$STATUS" = "active" ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"

        print_header "防火墙管理 — firewalld"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        echo ""
        menu_div
        if [ "$STATUS" = "active" ]; then
            echo -e "  ${YELLOW}1${NC}) 关闭防火墙"
        else
            echo -e "  ${GREEN}1${NC}) 开启防火墙"
        fi
        echo -e "  ${GREEN}2${NC}) 查看当前规则"
        echo -e "  ${GREEN}3${NC}) 添加端口规则"
        echo -e "  ${GREEN}4${NC}) 删除端口规则"
        echo -e "  ${GREEN}5${NC}) 拉黑 IP（黑名单）"
        echo -e "  ${GREEN}6${NC}) 放行 IP（白名单）"
        echo -e "  ${GREEN}7${NC}) 删除 IP 规则"
        echo -e "  ${GREEN}8${NC}) 一键放行常用端口"
        echo -e "  ${YELLOW}9${NC}) 卸载 firewalld"
        echo -e "  ${RED}0${NC}) 返回"
        echo -e "  ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-9]: " CH

        case "$CH" in
            1)
                if [ "$STATUS" = "active" ]; then
                    svc_stop firewalld && info "防火墙已关闭 ✓"
                else
                    svc_start firewalld && info "防火墙已开启 ✓"
                fi
                sleep 1; continue
                ;;
            2) fwd_show_rules ;;
            3) fwd_add_port ;;
            4) fwd_del_port ;;
            5) fwd_block_ip ;;
            6) fwd_allow_ip ;;
            7) fwd_del_ip ;;
            8) fwd_quick_allow ;;
            9)
                warn "即将卸载 firewalld，所有规则将清除"
                read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
                [ -z "${CONFIRM}" ] && CONFIRM="y"
    if echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then
                    svc_stop firewalld
                    svc_disable firewalld
                    pkg_remove firewalld
                    # 清理残留配置
                    rm -rf /etc/firewalld/zones /etc/firewalld/services 2>/dev/null
                    clear_iptables_residue  # 清理 iptables 残留规则
                    info "firewalld 已完整卸载 ✓（仅清理 firewalld 自身规则）"
                    return
                else
                    warn "已取消"
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  防火墙总入口
# ══════════════════════════════════════════════════════════
firewall_menu() {
    while true; do
        local FW_TYPE; FW_TYPE=$(fw_detect)

        if [ "$FW_TYPE" = "none" ]; then
            print_header "防火墙管理"
            warn "未检测到已安装的防火墙！"
            echo ""
            menu_div
            echo -e "  请选择要安装的防火墙："
            echo -e "  ${GREEN}1${NC}) ufw       （推荐，Ubuntu/Debian 常用）"
            echo -e "  ${GREEN}2${NC}) firewalld （CentOS/Rocky/Fedora 常用）"
            echo -e "  ${RED}0${NC}) 返回主菜单"
            echo -e "  ${RED}00${NC}) 退出脚本"
            menu_div
            echo ""
            read -rp "  请选择 [0-2]: " CH
            case "$CH" in
                1) fw_install "ufw";       echo ""; read -rp "  按 Enter 继续..." _ ;;
                2) fw_install "firewalld"; echo ""; read -rp "  按 Enter 继续..." _ ;;
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

# ── SSH 工具集子菜单 ──────────────────────────────────────
ssh_tools_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)

        print_header "SSH 工具集"
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}" \
                 "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}" \
                 "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        echo ""
        menu_div
        echo -e "  ${GREEN}1${NC}) 查看已有公钥     ${GREEN}2${NC}) 添加公钥"
        echo -e "  ${GREEN}3${NC}) 删除公钥         ${GREEN}4${NC}) 生成密钥对"
        echo -e "  ${GREEN}5${NC}) 设置登录方式     ${GREEN}6${NC}) 修改 SSH 端口"
        echo -e "  ${RED}0${NC}) 返回主菜单        ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-6]: " CHOICE

        local NEED_PAUSE=1
        case "$CHOICE" in
            1) show_keys ;;
            2) add_key ;;
            3) delete_key ;;
            4) generate_key ;;
            5) set_login_mode ;;
            6) change_port ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; NEED_PAUSE=0 ;;
        esac

        [ "$NEED_PAUSE" -eq 1 ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


# ══════════════════════════════════════════════════════════
#  DNS 优化模块
# ══════════════════════════════════════════════════════════

dns_show_current() {
    echo -e "  ${BOLD}当前 DNS 地址：${NC}"
    grep "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r line; do
        local IP; IP=$(echo "$line" | awk '{print $2}')
        if echo "$IP" | grep -q ":"; then
            echo -e "    ${YELLOW}$line${NC}  ${DIM}(IPv6)${NC}"
        else
            echo -e "    ${CYAN}$line${NC}  ${DIM}(IPv4)${NC}"
        fi
    done
}

# 检测网络协议支持
dns_detect_network() {
    local HAS_V4=false HAS_V6=false
    # 检测 IPv4 全局地址
    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && HAS_V4=true
    # 检测 IPv6 全局地址
    local V6_DISABLED
    V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$V6_DISABLED" != "1" ]; then
        ip -6 addr show scope global 2>/dev/null | grep -q "inet6" && HAS_V6=true
    fi
    echo "${HAS_V4}:${HAS_V6}"
}

dns_write() {
    local V4_LIST="$1"
    local V6_LIST="$2"
    local HAS_V6="$3"  # 是否写入 v6 DNS
    local RESOLV="/etc/resolv.conf"

    chattr -i "$RESOLV" 2>/dev/null
    cp "$RESOLV" "${RESOLV}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

    local OTHER
    OTHER=$(grep -v "^nameserver" "$RESOLV" 2>/dev/null)

    {
        [ -n "$OTHER" ] && echo "$OTHER"
        for ip in $V4_LIST; do echo "nameserver $ip"; done
        # 只在有 IPv6 时写入 v6 DNS
        if [ "$HAS_V6" = "true" ] && [ -n "$V6_LIST" ]; then
            for ip in $V6_LIST; do echo "nameserver $ip"; done
        fi
    } > "$RESOLV"

    info "DNS 已更新 ✓"
    echo ""
    echo -e "  ${BOLD}更新后：${NC}"
    grep "^nameserver" "$RESOLV" | while read -r line; do
        local IP; IP=$(echo "$line" | awk '{print $2}')
        echo "$IP" | grep -q ":"             && echo -e "    ${YELLOW}$line${NC}  ${DIM}(IPv6)${NC}"             || echo -e "    ${CYAN}$line${NC}  ${DIM}(IPv4)${NC}"
    done
}

dns_menu() {
    while true; do
        print_header "DNS 优化"
        dns_show_current
        echo ""

        # 检测网络协议
        local NET_INFO; NET_INFO=$(dns_detect_network)
        local HAS_V4; HAS_V4=$(echo "$NET_INFO" | cut -d: -f1)
        local HAS_V6; HAS_V6=$(echo "$NET_INFO" | cut -d: -f2)

        # 显示当前网络状态
        local V4_LABEL V6_LABEL
        [ "$HAS_V4" = "true" ] && V4_LABEL="${GREEN}有 IPv4${NC}" || V4_LABEL="${YELLOW}无 IPv4${NC}"
        [ "$HAS_V6" = "true" ] && V6_LABEL="${GREEN}有 IPv6${NC}" || V6_LABEL="${DIM}无 IPv6${NC}"
        echo -e "  网络：$V4_LABEL  $V6_LABEL"
        [ "$HAS_V6" = "true" ] || echo -e "  ${DIM}（未检测到 IPv6，仅显示 IPv4 DNS 选项）${NC}"
        echo ""

        menu_div
        echo -e "  ${BOLD}国外 DNS：${NC}"
        if [ "$HAS_V6" = "true" ]; then
            echo -e "  ${GREEN}1${NC}) Cloudflare  v4: 1.1.1.1 / 1.0.0.1"
            echo -e "             v6: 2606:4700:4700::1111"
            echo -e "  ${GREEN}2${NC}) Google      v4: 8.8.8.8 / 8.8.4.4"
            echo -e "             v6: 2001:4860:4860::8888"
            echo -e "  ${GREEN}3${NC}) 混合推荐    CF v4 + Google v4 + 双栈 v6"
        else
            echo -e "  ${GREEN}1${NC}) Cloudflare  1.1.1.1 / 1.0.0.1"
            echo -e "  ${GREEN}2${NC}) Google      8.8.8.8 / 8.8.4.4"
            echo -e "  ${GREEN}3${NC}) 混合推荐    1.1.1.1 + 8.8.8.8"
        fi
        menu_div
        echo -e "  ${BOLD}国内 DNS：${NC}"
        if [ "$HAS_V6" = "true" ]; then
            echo -e "  ${GREEN}4${NC}) 阿里云      v4: 223.5.5.5 / 223.6.6.6"
            echo -e "             v6: 2400:3200::1"
            echo -e "  ${GREEN}5${NC}) 腾讯 DNSpod v4: 119.29.29.29 / 183.60.83.19"
            echo -e "  ${GREEN}6${NC}) 114 DNS     v4: 114.114.114.114 / 114.114.115.115"
        else
            echo -e "  ${GREEN}4${NC}) 阿里云      223.5.5.5 / 223.6.6.6"
            echo -e "  ${GREEN}5${NC}) 腾讯 DNSpod 119.29.29.29 / 183.60.83.19"
            echo -e "  ${GREEN}6${NC}) 114 DNS     114.114.114.114 / 114.114.115.115"
        fi
        menu_div
        echo -e "  ${GREEN}7${NC}) 手动编辑 DNS 配置"
        echo -e "  ${RED}0${NC}) 返回"
        echo -e "  ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-7]: " CH

        case "$CH" in
            1) dns_write "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001" "$HAS_V6" ;;
            2) dns_write "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844" "$HAS_V6" ;;
            3) dns_write "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888" "$HAS_V6" ;;
            4) dns_write "223.5.5.5 223.6.6.6" "2400:3200::1 2400:3200:baba::1" "$HAS_V6" ;;
            5) dns_write "119.29.29.29 183.60.83.19" "" "$HAS_V6" ;;
            6) dns_write "114.114.114.114 114.114.115.115" "" "$HAS_V6" ;;
            7)
                warn "即将用 $(get_editor) 编辑 /etc/resolv.conf"
                chattr -i /etc/resolv.conf 2>/dev/null
                read -rp "  按 Enter 继续..." _
                open_editor /etc/resolv.conf
                info "DNS 配置已保存"
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  换源模块
# ══════════════════════════════════════════════════════════

# 检测系统发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}:${VERSION_ID}"
    else
        echo "unknown"
    fi
}

mirror_backup() {
    local SRC_FILE="$1"
    local BAK="${SRC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SRC_FILE" "$BAK" 2>/dev/null && info "已备份原始源文件：$BAK"
}

mirror_apply_ubuntu() {
    local MIRROR="$1"
    local CODENAME; CODENAME=$(get_codename)
    mirror_backup "/etc/apt/sources.list"
    cat > /etc/apt/sources.list << EOF
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF
    info "已切换 Ubuntu 源 → $MIRROR"
    apt-get update -qq 2>/dev/null && info "apt update 完成 ✓" || warn "apt update 出现警告，请检查"
}

mirror_apply_debian() {
    local MIRROR="$1"
    local CODENAME; CODENAME=$(get_codename)
    mirror_backup "/etc/apt/sources.list"
    cat > /etc/apt/sources.list << EOF
deb ${MIRROR} ${CODENAME} main contrib non-free non-free-firmware
deb ${MIRROR} ${CODENAME}-updates main contrib non-free non-free-firmware
deb ${MIRROR} ${CODENAME}-backports main contrib non-free non-free-firmware
deb ${MIRROR}-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
    info "已切换 Debian 源 → $MIRROR"
    apt-get update -qq 2>/dev/null && info "apt update 完成 ✓" || warn "apt update 出现警告，请检查"
}

mirror_apply_centos() {
    local REGION="$1"
    if command -v dnf &>/dev/null; then
        dnf install -y epel-release &>/dev/null
        case "$REGION" in
            cn)    dnf config-manager --setopt="*.baseurl=https://mirrors.aliyun.com/centos/\$releasever" --save &>/dev/null ;;
            edu)   dnf config-manager --setopt="*.baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/\$releasever" --save &>/dev/null ;;
            *)     info "海外地区使用默认源" ;;
        esac
    fi
    info "CentOS/Rocky 源已更新 ✓"
}

mirror_menu() {
    while true; do
        local OS_INFO; OS_INFO=$(detect_os)
        local OS_ID; OS_ID=$(echo "$OS_INFO" | cut -d: -f1)
        local OS_VER; OS_VER=$(echo "$OS_INFO" | cut -d: -f2)

        print_header "系统换源"
        echo -e "  检测到系统：${BOLD}${OS_ID} ${OS_VER}${NC}"
        echo ""
        menu_div

        case "$OS_ID" in
            ubuntu)
                echo -e "  ${GREEN}1${NC}) 中国大陆【阿里云】    mirrors.aliyun.com"
                echo -e "  ${GREEN}2${NC}) 中国大陆【腾讯云】    mirrors.tencent.com"
                echo -e "  ${GREEN}3${NC}) 中国大陆【清华】      mirrors.tuna.tsinghua.edu.cn"
                echo -e "  ${GREEN}4${NC}) 中国大陆【中科大】    mirrors.ustc.edu.cn"
                echo -e "  ${GREEN}5${NC}) 海外地区【官方源】    archive.ubuntu.com"
                menu_div
                echo -e "  ${RED}0${NC}) 返回"
                echo -e "  ${RED}00${NC}) 退出脚本"
                menu_div
                echo ""
                read -rp "  请选择 [0-5]: " CH
                case "$CH" in
                    1) mirror_apply_ubuntu "https://mirrors.aliyun.com/ubuntu" ;;
                    2) mirror_apply_ubuntu "https://mirrors.tencent.com/ubuntu" ;;
                    3) mirror_apply_ubuntu "https://mirrors.tuna.tsinghua.edu.cn/ubuntu" ;;
                    4) mirror_apply_ubuntu "https://mirrors.ustc.edu.cn/ubuntu" ;;
                    5) mirror_apply_ubuntu "http://archive.ubuntu.com/ubuntu" ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            debian)
                echo -e "  ${GREEN}1${NC}) 中国大陆【阿里云】    mirrors.aliyun.com"
                echo -e "  ${GREEN}2${NC}) 中国大陆【腾讯云】    mirrors.tencent.com"
                echo -e "  ${GREEN}3${NC}) 中国大陆【清华】      mirrors.tuna.tsinghua.edu.cn"
                echo -e "  ${GREEN}4${NC}) 中国大陆【中科大】    mirrors.ustc.edu.cn"
                echo -e "  ${GREEN}5${NC}) 海外地区【官方源】    deb.debian.org"
                menu_div
                echo -e "  ${RED}0${NC}) 返回"
                echo -e "  ${RED}00${NC}) 退出脚本"
                menu_div
                echo ""
                read -rp "  请选择 [0-5]: " CH
                case "$CH" in
                    1) mirror_apply_debian "https://mirrors.aliyun.com/debian" ;;
                    2) mirror_apply_debian "https://mirrors.tencent.com/debian" ;;
                    3) mirror_apply_debian "https://mirrors.tuna.tsinghua.edu.cn/debian" ;;
                    4) mirror_apply_debian "https://mirrors.ustc.edu.cn/debian" ;;
                    5) mirror_apply_debian "http://deb.debian.org/debian" ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            centos|rocky|rhel|almalinux)
                echo -e "  ${GREEN}1${NC}) 中国大陆【阿里云】"
                echo -e "  ${GREEN}2${NC}) 中国大陆【清华】"
                echo -e "  ${GREEN}3${NC}) 海外地区【默认】"
                menu_div
                echo -e "  ${RED}0${NC}) 返回"
                echo -e "  ${RED}00${NC}) 退出脚本"
                menu_div
                echo ""
                read -rp "  请选择 [0-3]: " CH
                case "$CH" in
                    1) mirror_apply_centos "cn" ;;
                    2) mirror_apply_centos "edu" ;;
                    3) mirror_apply_centos "intl" ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            *)
                warn "暂不支持自动换源的系统：${OS_ID}"
                warn "请手动修改 /etc/apt/sources.list 或对应源文件"
                echo ""
                read -rp "  按 Enter 返回..." _
                return
                ;;
        esac

        [ "${CH:-x}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


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
}

ip_disable_v6() {
    print_header "关闭 IPv6"
    warn "关闭 IPv6 后，仅 IPv6 的服务将无法访问！"
    echo ""
    read -rp "  确认关闭？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

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
}

ip_enable_v6() {
    print_header "开启 IPv6"
    local SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"

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
        echo -e "  ${GREEN}1${NC}) 查看IPv4/IPv6状态"
        echo -e "  ${GREEN}2${NC}) 设置IPv4优先      ${GREEN}3${NC}) 关闭 IPv6"
        echo -e "  ${GREEN}4${NC}) 开启 IPv6"
        echo -e "  ${RED}0${NC}) 返回              ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-4]: " CH

        case "$CH" in
            1) ip_show_status ;;
            2) ip_prefer_v4 ;;
            3) ip_disable_v6 ;;
            4) ip_enable_v6 ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


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
    local BAK="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
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
        menu_div
        echo -e "  ${GREEN}1${NC}) 查看站点         ${GREEN}2${NC}) 添加反向代理"
        echo -e "  ${GREEN}3${NC}) 添加静态网站     ${GREEN}4${NC}) 删除站点"
        echo -e "  ${GREEN}5${NC}) SSL证书状态      ${GREEN}6${NC}) 查看日志"
        echo -e "  ${GREEN}7${NC}) 编辑Caddyfile    ${GREEN}8${NC}) 重载配置"
        if [ "$C_ST" = "running" ]; then
            echo -e "  ${YELLOW}9${NC}) 停止服务"
        else
            echo -e "  ${GREEN}9${NC}) 启动服务"
        fi
        echo -e "  ${CYAN}u${NC}) 安装/更新        ${YELLOW}d${NC}) 卸载 Caddy"
        echo -e "  ${RED}0${NC}) 返回              ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择: " CH

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
        echo -e "  ${GREEN}1${NC}) 强制同步时间"
        echo -e "  ${GREEN}2${NC}) 设置北京时区      ${GREEN}3${NC}) 一键同步+北京时区"
        echo -e "  ${GREEN}4${NC}) 设置其他时区      ${GREEN}5${NC}) 开启NTP自动同步"
        echo -e "  ${RED}0${NC}) 返回              ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-5]: " CH

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

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ── 强制同步时间 ──────────────────────────────────────────
ts_sync_time() {
    print_header "强制同步系统时间"
    echo -e "  ${DIM}尝试多种方式同步时间...${NC}"
    echo ""

    local SYNCED=false

    # 方法1：timedatectl + systemd-timesyncd
    if command -v timedatectl &>/dev/null && pidof systemd &>/dev/null; then
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

    if [ "$CAN_NTP" = "yes" ] && command -v systemctl &>/dev/null         && systemctl list-units --type=service 2>/dev/null | grep -q "systemd-timesyncd"; then
        # systemd-timesyncd 可用
        timedatectl set-ntp true 2>/dev/null
        systemctl enable systemd-timesyncd --quiet 2>/dev/null
        systemctl restart systemd-timesyncd 2>/dev/null
        info "systemd-timesyncd NTP 已开启 ✓"
    elif command -v chronyc &>/dev/null; then
        # chrony 已安装，自动探测服务名
        local CHRONY_SVC="chronyd"
        systemctl list-unit-files 2>/dev/null | grep -q "^chrony.service" && CHRONY_SVC="chrony"
        svc_enable "$CHRONY_SVC"
        systemctl start "$CHRONY_SVC" 2>/dev/null || rc-service "$CHRONY_SVC" start 2>/dev/null || true
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
            systemctl start "$CHRONY_SVC" 2>/dev/null || rc-service "$CHRONY_SVC" start 2>/dev/null || true
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


# ══════════════════════════════════════════════════════════
#  Swap 管理模块
# ══════════════════════════════════════════════════════════

# ── 显示当前 swap 状态 ────────────────────────────────────
swap_show_status() {
    echo -e "  ${BOLD}当前 Swap 状态：${NC}"
    local TOTAL USED FREE
    if swapon --show 2>/dev/null | grep -q .; then
        swapon --show --bytes 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${CYAN}${line}${NC}"
        done
        echo ""
        TOTAL=$(free -m 2>/dev/null | awk '/^Swap/{print $2}')
        USED=$(free -m 2>/dev/null  | awk '/^Swap/{print $3}')
        FREE=$(free -m 2>/dev/null  | awk '/^Swap/{print $4}')
        echo -e "  总计：${BOLD}${TOTAL}MB${NC}  已用：${BOLD}${USED}MB${NC}  空闲：${BOLD}${FREE}MB${NC}"
    else
        echo -e "  ${YELLOW}当前未设置 Swap${NC}"
    fi
    echo ""
    # swappiness
    local SWAPPINESS
    SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知")
    echo -e "  swappiness：${BOLD}${SWAPPINESS}${NC}  ${DIM}（0=不用swap，60=默认，100=积极使用）${NC}"
}

# ── 创建 swap 文件 ────────────────────────────────────────
swap_create() {
    print_header "创建 Swap"

    # 检测是否在 OpenVZ/LXC（不支持 swap file）
    local IS_VIRT=false
    if grep -qa "lxc\|openvz" /proc/1/environ 2>/dev/null \
        || [ -f /proc/vz/veinfo ] \
        || grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
        IS_VIRT=true
    fi

    # 内存信息
    local MEM_MB; MEM_MB=$(free -m | awk '/^Mem/{print $2}')
    local DISK_FREE; DISK_FREE=$(df -m / | awk 'NR==2{print $4}')

    echo -e "  物理内存：${BOLD}${MEM_MB}MB${NC}  磁盘可用：${BOLD}${DISK_FREE}MB${NC}"
    echo ""

    if [ "$IS_VIRT" = true ]; then
        warn "检测到 LXC/OpenVZ 容器，可能不支持 swap file"
        warn "如果创建失败请联系 VPS 服务商开启 swap 权限"
        echo ""
    fi

    # 推荐大小
    local REC_SIZE
    if   [ "$MEM_MB" -le 512  ]; then REC_SIZE=1024
    elif [ "$MEM_MB" -le 1024 ]; then REC_SIZE=2048
    elif [ "$MEM_MB" -le 2048 ]; then REC_SIZE=2048
    elif [ "$MEM_MB" -le 4096 ]; then REC_SIZE=4096
    else                              REC_SIZE=4096
    fi

    echo -e "  推荐大小：${GREEN}${REC_SIZE}MB${NC}（基于当前内存 ${MEM_MB}MB）"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 512MB"
    echo -e "  ${GREEN}2${NC}) 1GB   (1024MB)"
    echo -e "  ${GREEN}3${NC}) 2GB   (2048MB)  ${YELLOW}[推荐]${NC}"
    echo -e "  ${GREEN}4${NC}) 4GB   (4096MB)"
    echo -e "  ${GREEN}5${NC}) 自定义大小（MB）"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    menu_div
    echo ""
    read -rp "  请选择 [0-5]: " CH

    local SIZE_MB
    case "$CH" in
        1) SIZE_MB=512 ;;
        2) SIZE_MB=1024 ;;
        3) SIZE_MB=2048 ;;
        4) SIZE_MB=4096 ;;
        5)
            read -rp "  请输入大小（MB，如 512）: " SIZE_MB
            if ! echo "$SIZE_MB" | grep -qE '^[0-9]+$' || [ "$SIZE_MB" -lt 64 ]; then
                error "无效大小（最小 64MB）"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # 检查磁盘空间
    if [ "$SIZE_MB" -gt "$DISK_FREE" ]; then
        error "磁盘空间不足（需要 ${SIZE_MB}MB，可用 ${DISK_FREE}MB）"
        return
    fi

    local SWAP_FILE="/swapfile"
    # 如果已有 swapfile 先关闭
    if [ -f "$SWAP_FILE" ]; then
        warn "已存在 ${SWAP_FILE}，将先关闭旧 swap..."
        swapoff "$SWAP_FILE" 2>/dev/null || true
    fi

    echo ""
    info "正在创建 ${SIZE_MB}MB swap 文件..."

    # 用 fallocate 或 dd 创建文件
    if command -v fallocate &>/dev/null; then
        fallocate -l "${SIZE_MB}M" "$SWAP_FILE" 2>/dev/null || \
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SIZE_MB" status=none
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SIZE_MB" status=progress
    fi

    if [ ! -f "$SWAP_FILE" ]; then
        error "Swap 文件创建失败"; return
    fi

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" &>/dev/null
    swapon "$SWAP_FILE"

    if ! swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
        error "Swap 启用失败（容器可能不支持）"
        rm -f "$SWAP_FILE"
        return
    fi

    info "Swap 已启用 ✓"

    # 写入 /etc/fstab 持久化
    if ! grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        info "已写入 /etc/fstab，重启后自动生效 ✓"
    fi

    echo ""
    swap_show_status
}

# ── 删除 swap ─────────────────────────────────────────────
swap_delete() {
    print_header "删除 Swap"

    local SWAPS
    SWAPS=$(swapon --show --noheadings 2>/dev/null | awk '{print $1}')

    if [ -z "$SWAPS" ]; then
        warn "当前没有启用的 Swap"
        return
    fi

    echo -e "  当前 Swap："
    local i=1
    local SWAP_LIST=()
    while IFS= read -r sw; do
        local SIZE; SIZE=$(swapon --show --bytes --noheadings 2>/dev/null | grep "^$sw" | awk '{printf "%.0fMB", $3/1048576}')
        echo -e "  ${GREEN}[$i]${NC} ${BOLD}${sw}${NC}  ${SIZE}"
        SWAP_LIST+=("$sw")
        i=$((i+1))
    done <<< "$SWAPS"

    echo ""
    menu_div
    echo -e "  ${DIM}输入编号删除，直接回车取消${NC}"
    read -rp "  请输入编号: " NUM
    [ -z "$NUM" ] && { warn "已取消"; return; }

    if ! echo "$NUM" | grep -qE '^[0-9]+$' || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#SWAP_LIST[@]} ]; then
        error "无效编号"; return
    fi

    local TARGET="${SWAP_LIST[$((NUM-1))]}"
    echo ""
    warn "即将删除 Swap：${BOLD}${TARGET}${NC}"
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    swapoff "$TARGET" 2>/dev/null && info "Swap 已关闭 ✓"

    # 从 fstab 移除
    if grep -q "$TARGET" /etc/fstab 2>/dev/null; then
        grep -v "$TARGET" /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
        info "已从 /etc/fstab 移除 ✓"
    fi

    # 如果是文件则删除
    if [ -f "$TARGET" ]; then
        rm -f "$TARGET" && info "Swap 文件已删除 ✓"
    fi
}

# ── 修改 swappiness ───────────────────────────────────────
swap_set_swappiness() {
    print_header "设置 Swappiness"
    local CUR; CUR=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)

    echo -e "  当前 swappiness：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${DIM}推荐值：${NC}"
    echo -e "  ${GREEN}1${NC}) 10   — 服务器推荐（尽量用物理内存）"
    echo -e "  ${GREEN}2${NC}) 30   — 折中"
    echo -e "  ${GREEN}3${NC}) 60   — 系统默认"
    echo -e "  ${GREEN}4${NC}) 自定义（0-100）"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-4]: " CH

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=30 ;;
        3) VAL=60 ;;
        4)
            read -rp "  请输入值（0-100）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -gt 100 ]; then
                error "无效值（0-100）"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # 立即生效
    echo "$VAL" > /proc/sys/vm/swappiness 2>/dev/null

    # 持久化到 sysctl.conf
    if grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^vm.swappiness.*/vm.swappiness = ${VAL}/" /etc/sysctl.conf
    else
        echo "vm.swappiness = ${VAL}" >> /etc/sysctl.conf
    fi

    sysctl -p &>/dev/null
    info "swappiness 已设置为 ${VAL}，重启后持续生效 ✓"
}

# ── Swap 主菜单 ───────────────────────────────────────────
swap_menu() {
    while true; do
        print_header "Swap 管理"
        swap_show_status
        menu_div
        echo -e "  ${GREEN}1${NC}) 创建/更换 Swap   ${GREEN}2${NC}) 删除 Swap"
        echo -e "  ${GREEN}3${NC}) 设置 Swappiness"
        echo -e "  ${RED}0${NC}) 返回              ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-3]: " CH

        case "$CH" in
            1) swap_create ;;
            2) swap_delete ;;
            3) swap_set_swappiness ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}



# ══════════════════════════════════════════════════════════
#  脚本自我管理模块
# ══════════════════════════════════════════════════════════

SCRIPT_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh"
LOCAL_SCRIPT="/usr/local/bin/vps-tools"

# ── 安装脚本到本地（设置快捷键 v）────────────────────────
self_install() {
    print_header "安装脚本到本地"
    echo -e "  将脚本安装到 ${BOLD}${LOCAL_SCRIPT}${NC}"
    echo -e "  安装后输入 ${GREEN}v${NC} 或 ${GREEN}V${NC} 即可快速呼出"
    echo ""

    # 优先复制当前运行的脚本
    local SELF; SELF=$(readlink -f "${0}" 2>/dev/null || echo "${0}")

    if [ -f "$SELF" ] && [ "$SELF" != "$LOCAL_SCRIPT" ]; then
        cp "$SELF" "$LOCAL_SCRIPT"
    elif [ -f /tmp/ssh_hardening.sh ]; then
        cp /tmp/ssh_hardening.sh "$LOCAL_SCRIPT"
    else
        info "本地缓存不存在，从 GitHub 下载..."
        if ! curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT" 2>/dev/null; then
            error "下载失败，请检查网络"; return 1
        fi
    fi

    chmod +x "$LOCAL_SCRIPT"
    info "脚本已安装到 ${LOCAL_SCRIPT} ✓"

    # 创建系统级命令 v / V（最可靠，无需 source）
    # 检测 v/V 是否已被其他脚本占用
    for _CMD in v V; do
        local _TARGET="/usr/local/bin/${_CMD}"
        if [ -L "$_TARGET" ] && [ "$(readlink "$_TARGET")" != "$LOCAL_SCRIPT" ]; then
            warn "快捷键 ${_CMD} 已被其他脚本占用（$(readlink "$_TARGET")），跳过"
        elif [ -f "$_TARGET" ] && [ ! -L "$_TARGET" ]; then
            warn "快捷键 ${_CMD} 是独立文件（非软链接），跳过以避免覆盖"
        else
            ln -sf "$LOCAL_SCRIPT" "$_TARGET" 2>/dev/null && info "系统命令 ${_CMD} 已创建 ✓"
        fi
    done

    # 不写入 alias，只用软链接，避免前缀冲突其他命令（如 volss）
    local WROTE_ALIAS=false

    echo ""
    menu_div
    info "安装完成！新终端直接输入 ${BOLD}v${NC} 即可启动"
    echo -e "  ${DIM}软链接已创建，无需 source，新终端直接可用${NC}"
    menu_div
}

# ── 强制从 GitHub 更新脚本 ────────────────────────────────
self_update() {
    print_header "强制更新脚本"
    echo -e "  ${DIM}${SCRIPT_URL}${NC}"
    echo ""

    local TMP_FILE; TMP_FILE="/tmp/vps_update_$$.sh"

    info "正在下载最新版本..."
    if ! curl -fsSL "$SCRIPT_URL" -o "$TMP_FILE" 2>/dev/null; then
        rm -f "$TMP_FILE"
        error "下载失败，请检查网络连接"
        echo -e "  ${DIM}手动更新：curl -fsSL ${SCRIPT_URL} -o ${LOCAL_SCRIPT} && chmod +x ${LOCAL_SCRIPT}${NC}"
        return
    fi

    # 验证语法
    if ! bash -n "$TMP_FILE" 2>/dev/null; then
        rm -f "$TMP_FILE"
        error "下载的文件语法有误，已取消更新"
        return
    fi

    # 版本对比
    local NEW_VER; NEW_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$TMP_FILE" | head -1)
    local CUR_VER; CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "${LOCAL_SCRIPT}" 2>/dev/null | head -1)
    echo -e "  当前版本：${BOLD}${CUR_VER:-未知}${NC}  →  最新版本：${GREEN}${BOLD}${NEW_VER:-未知}${NC}"
    echo ""

    # 覆盖安装
    cp "$TMP_FILE" "$LOCAL_SCRIPT"
    chmod +x "$LOCAL_SCRIPT"
    cp "$TMP_FILE" /tmp/ssh_hardening.sh 2>/dev/null
    rm -f "$TMP_FILE"

    # 确保 v 命令还在
    ln -sf "$LOCAL_SCRIPT" /usr/local/bin/v 2>/dev/null
    ln -sf "$LOCAL_SCRIPT" /usr/local/bin/V 2>/dev/null

    info "更新完成 ✓"
    # 清理 DDNS 日志，保留最后 500 行（避免文件过大）
    if [ -f /var/log/ddns.log ]; then
        local _LL; _LL=$(wc -l < /var/log/ddns.log 2>/dev/null || echo 0)
        if [ "$_LL" -gt 500 ]; then
            tail -n 500 /var/log/ddns.log > /var/log/ddns.log.tmp \
                && mv /var/log/ddns.log.tmp /var/log/ddns.log
            info "DDNS 日志已清理（保留最近 500 条）✓"
        fi
    fi
    # 清理旧版写入的 alias（旧版本会写 alias v=，会拦截其他命令如 volss）
    for RC in /root/.bashrc /root/.bash_profile ~/.bashrc ~/.bash_profile ~/.zshrc; do
        [ -f "$RC" ] || continue
        if grep -q "VPS 开荒脚本快捷键" "$RC" 2>/dev/null; then
            grep -v "alias v=\|alias V=\|VPS 开荒脚本快捷键" "$RC" > "${RC}.tmp" \
                && mv "${RC}.tmp" "$RC"
            info "已清理旧版 alias（${RC}）✓"
        fi
    done
    # 清除更新提示，避免新版本启动后还显示旧提示
    rm -f /tmp/.vps_new_version 2>/dev/null
    warn "即将用新版本重启脚本..."
    sleep 1
    exec "$LOCAL_SCRIPT"
}

# ── 脚本管理菜单 ──────────────────────────────────────────
# ── 删除本地脚本和快捷键 ─────────────────────────────────
self_uninstall() {
    print_header "删除本地脚本和快捷键"
    warn "将删除以下内容："
    echo -e "  ${DIM}${LOCAL_SCRIPT}${NC}"
    echo -e "  ${DIM}/usr/local/bin/v${NC}"
    echo -e "  ${DIM}/usr/local/bin/V${NC}"
    echo -e "  ${DIM}/usr/local/bin/V${NC}"
    echo -e "  ${DIM}各 shell 配置文件中的 alias v=...${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 删除本地脚本
    rm -f "$LOCAL_SCRIPT" && info "已删除 ${LOCAL_SCRIPT} ✓"

    # 删除系统命令
    rm -f /usr/local/bin/v /usr/local/bin/V && info "已删除系统命令 v/V ✓"

    # 清理 shell 配置文件中可能残留的旧版 alias
    for RC in /root/.bashrc /root/.bash_profile ~/.bashrc ~/.bash_profile ~/.zshrc; do
        [ -f "$RC" ] || continue
        if grep -q "VPS 开荒脚本快捷键" "$RC" 2>/dev/null; then
            grep -v "alias v=\|alias V=\|VPS 开荒脚本快捷键" "$RC" > "${RC}.tmp" \
                && mv "${RC}.tmp" "$RC"
            info "已清理旧版 alias（${RC}）✓"
        fi
    done

    echo ""
    info "清理完成，快捷键 v 已移除"
    warn "当前会话仍可使用 alias，重新登录后完全生效"
    echo ""
    read -rp "  按 Enter 返回..." _
    return
}

# ── 首次运行检测是否已安装快捷键 ─────────────────────────
self_check_first_run() {
    # 已安装则跳过
    [ -f /usr/local/bin/v ] && return
    [ -f "$LOCAL_SCRIPT" ] && return

    clear
    echo ""
    box_top
    box_title "VPS 开荒脚本 V3.5.9"
    box_title "· · 银趴火山帮 · ·"
    box_sep
    box_title "首次运行检测"
    box_bot
    echo ""
    echo -e "  ${YELLOW}检测到脚本未安装到本地${NC}"
    echo -e "  安装后可随时输入 ${BOLD}v${NC} 快速启动"
    echo ""
    menu_div
    echo -e "  ${GREEN}1${NC}) 立即安装（推荐）"
    echo -e "  ${GREEN}0${NC}) 跳过，直接进入"
    menu_div
    echo ""
    read -rp "  请选择 [0-1]: " CH
    case "$CH" in
        1)
            self_install
            echo ""
            read -rp "  按 Enter 继续进入主菜单..." _
            ;;
        *) ;;
    esac
}

self_manage_menu() {
    while true; do
        print_header "脚本管理"

        local IS_INSTALLED=false
        local CUR_VER=""
        if [ -f "$LOCAL_SCRIPT" ]; then
            IS_INSTALLED=true
            CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$LOCAL_SCRIPT" | head -1)
        fi
        local HAS_CMD=false
        [ -f /usr/local/bin/v ] && HAS_CMD=true

        echo -e "  本地路径：${BOLD}${LOCAL_SCRIPT}${NC}"
        if [ "$IS_INSTALLED" = true ]; then
            echo -e "  状  态  ：${GREEN}${BOLD}已安装${NC}  版本：${BOLD}${CUR_VER:-未知}${NC}"
        else
            echo -e "  状  态  ：${YELLOW}${BOLD}未安装${NC}"
        fi
        echo -e "  快捷键 v：${BOLD}$([ "$HAS_CMD" = true ] && echo "${GREEN}已设置${NC}" || echo "${YELLOW}未设置${NC}")${NC}"
        echo ""
        menu_div
        echo -e "  ${GREEN}1${NC}) 安装脚本 + 设置快捷键 v"
        echo -e "  ${GREEN}2${NC}) 从 GitHub 更新最新版"
        echo -e "  ${YELLOW}3${NC}) 删除本地脚本和快捷键"
        echo -e "  ${RED}0${NC}) 返回              ${RED}00${NC}) 退出脚本"
        menu_div
        echo ""
        read -rp "  请选择 [0-3]: " CH

        case "$CH" in
            1) self_install ;;
            2) self_update ;;
            3) self_uninstall ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && [ "${CH}" != "3" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}




# ══════════════════════════════════════════════════════════
#  NFT 转发管理模块（端口转发 / DDNS / 访问控制）
# ══════════════════════════════════════════════════════════
NFT_CONFIG_FILE="${NFT_CONFIG_FILE:-/etc/nftables.conf}"
NFT_STATE_DIR="${NFT_STATE_DIR:-/etc/nft-port-forward}"
NFT_RULES_FILE="${NFT_RULES_FILE:-$NFT_STATE_DIR/rules.db}"
NFT_ACCESS_FILE="${NFT_ACCESS_FILE:-$NFT_STATE_DIR/access.conf}"
NFT_RENDER_VERSION="1"
NFT_TRACK_TIMEOUT="${NFT_TRACK_TIMEOUT:-30m}"
NFT_DDNS_TIMER_FILE="/etc/systemd/system/nftpf-ddns.timer"
NFT_DDNS_SERVICE_FILE="/etc/systemd/system/nftpf-ddns.service"

# ── 基础工具 ──────────────────────────────────────────────
nft_ensure_state_dir() {
    mkdir -p "$NFT_STATE_DIR"
    touch "$NFT_RULES_FILE"
    [ -f "$NFT_ACCESS_FILE" ] || echo "mode=off" > "$NFT_ACCESS_FILE"
}

nft_install() {
    command -v nft &>/dev/null && return 0
    info "正在安装 nftables..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y nftables 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache nftables 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y nftables 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y nftables 2>/dev/null
    fi
    command -v nft &>/dev/null
}


nft_uninstall() {
    print_header "卸载 nftables"
    echo -e "  ${RED}${BOLD}⚠ 警告：卸载将执行以下操作：${NC}"
    echo -e "  ${DIM}1. 清空所有 NFT 转发规则${NC}"
    echo -e "  ${DIM}2. 删除访问控制配置${NC}"
    echo -e "  ${DIM}3. 关闭 DDNS 自动刷新 timer${NC}"
    echo -e "  ${DIM}4. 停止并删除 nftables 服务${NC}"
    echo -e "  ${DIM}5. 卸载 nftables 软件包${NC}"
    echo ""
    warn "如果你的防火墙依赖 nftables（如 firewalld 后端），卸载后会失去保护！"
    read -rp "  确认卸载？(y/N，默认N): " c
    [ -z "$c" ] && c="n"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    # 1. 关闭 DDNS timer
    if command -v systemctl &>/dev/null; then
        systemctl disable --now nftpf-ddns.timer &>/dev/null || true
        systemctl disable --now nftpf-ddns.service &>/dev/null || true
    fi
    rm -f "$NFT_DDNS_TIMER_FILE" "$NFT_DDNS_SERVICE_FILE"

    # 2. 清空所有规则（先 flush 再停服务）
    if command -v nft &>/dev/null; then
        nft flush ruleset 2>/dev/null || true
    fi

    # 3. 停止服务
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl stop nftables &>/dev/null || true
        systemctl disable nftables &>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service nftables stop 2>/dev/null || true
        rc-update del nftables default 2>/dev/null || true
    fi

    # 4. 删除状态目录
    rm -rf "$NFT_STATE_DIR"

    # 5. 清空 nftables 配置（保留文件结构）
    if [ -f "$NFT_CONFIG_FILE" ]; then
        cat > "$NFT_CONFIG_FILE" <<NFTEOF
#!/usr/sbin/nft -f

flush ruleset
NFTEOF
    fi

    # 6. 卸载软件包
    info "正在卸载 nftables 软件包..."
    if command -v apt-get &>/dev/null; then
        apt-get remove -y nftables 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk del nftables 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum remove -y nftables 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf remove -y nftables 2>/dev/null
    fi

    if ! command -v systemctl &>/dev/null || ! command -v nft &>/dev/null; then
        info "nftables 卸载完成 ✓"
    else
        warn "卸载命令已执行，但 nft 命令仍存在（可能是依赖保留）"
    fi
}

nft_enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    if [ -f /etc/sysctl.conf ]; then
        grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf \
            || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf \
            || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
    fi
}

# ── IP / 端口 校验 ────────────────────────────────────────
nft_is_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    local IFS='.'
    set -- $1
    for p in "$@"; do [ "$p" -ge 0 ] && [ "$p" -le 255 ] || return 1; done
}

nft_is_ipv6() {
    [ "${1#*:}" != "$1" ] || return 1
    echo "$1" | grep -qE '^[0-9A-Fa-f:.]+$'
}

nft_is_hostname() {
    [ ${#1} -le 253 ] || return 1
    echo "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$'
}

nft_classify() {
    if nft_is_ipv4 "$1"; then echo "ipv4"
    elif nft_is_ipv6 "$1"; then echo "ipv6"
    elif nft_is_hostname "$1"; then echo "domain"
    else echo "invalid"
    fi
}

nft_check_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

nft_resolve_domain() {
    local domain="$1" family="$2" result=""
    if [ "$family" = "ipv4" ]; then
        result=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
        nft_is_ipv4 "$result" && echo "$result" && return 0
    else
        result=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1; exit}')
        nft_is_ipv6 "$result" && echo "$result" && return 0
    fi
    return 1
}

# ── 规则数据库读写 ────────────────────────────────────────
# 格式: id|family|listen_ip|lstart|lend|target_type|target_host|resolved|tstart|tend|mode
nft_next_rule_id() {
    local max=0 id
    while IFS='|' read -r id _; do
        [[ -z "$id" || "$id" = \#* ]] && continue
        [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt "$max" ] && max=$id
    done < "$NFT_RULES_FILE"
    echo $((max + 1))
}

nft_get_access_mode() {
    local m
    m=$(grep -m1 '^mode=' "$NFT_ACCESS_FILE" 2>/dev/null | cut -d= -f2)
    case "$m" in whitelist|blacklist|off) echo "$m" ;; *) echo "off" ;; esac
}

nft_access_entries_for() {
    grep "^entry=$1|" "$NFT_ACCESS_FILE" 2>/dev/null | cut -d'|' -f2-
}

nft_format_access_for() {
    local family="$1" out="" sep="" entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        out="${out}${sep}${entry}"; sep=", "
    done < <(nft_access_entries_for "$family")
    echo "$out"
}

nft_rules_has_family() {
    local family="$1" line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" = \#* ]] && continue
        case "$line" in
            *"|$family|"*) return 0 ;;
        esac
    done < "$NFT_RULES_FILE"
    return 1
}

# ── 生成 nftables 配置 ────────────────────────────────────
nft_build_dnat() {
    local family="$1" ip="$2" port="$3"
    if [ "$family" = "ipv6" ] && [ -n "$port" ]; then
        echo "[$ip]:$port"
    elif [ -n "$port" ]; then
        echo "$ip:$port"
    else
        echo "$ip"
    fi
}

nft_build_port_map() {
    local lstart="$1" lend="$2" tstart="$3"
    local lp="$lstart" rp="$tstart" first=1 out="{ "
    while [ "$lp" -le "$lend" ]; do
        [ "$first" -eq 1 ] && first=0 || out="$out, "
        out="${out}${lp} : ${rp}"
        lp=$((lp+1)); rp=$((rp+1))
    done
    echo "$out }"
}

nft_render_rule_line() {
    local id="$1" family="$2" lip="$3" ls="$4" le="$5" \
          ttype="$6" thost="$7" tip="$8" ts="$9" te="${10}" mode="${11}"
    local listen_match="" port_expr dnat map_str

    if [ -n "$lip" ]; then
        if [ "$family" = "ipv6" ]; then listen_match="ip6 daddr $lip "
        else listen_match="ip daddr $lip "; fi
    fi

    if [ "$ls" = "$le" ]; then
        port_expr="$ls"
    else
        port_expr="{ $ls-$le }"
    fi

    case "$mode" in
        single)
            dnat=$(nft_build_dnat "$family" "$tip" "$ts")
            echo "        ${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat"
            ;;
        range_1_to_1)
            dnat=$(nft_build_dnat "$family" "$tip" "")
            echo "        ${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat"
            ;;
        range_offset)
            dnat=$(nft_build_dnat "$family" "$tip" "")
            map_str=$(nft_build_port_map "$ls" "$le" "$ts")
            echo "        ${listen_match}meta l4proto {tcp, udp} th dport $port_expr dnat to $dnat : th dport map $map_str"
            ;;
    esac
}

nft_render_rules_for() {
    local family="$1" line
    while IFS='|' read -r id f lip ls le ttype thost tip ts te mode; do
        [[ -z "$id" || "$id" = \#* ]] && continue
        [ "$f" = "$family" ] || continue
        nft_render_rule_line "$id" "$f" "$lip" "$ls" "$le" "$ttype" "$thost" "$tip" "$ts" "$te" "$mode"
    done < "$NFT_RULES_FILE"
}

nft_render_access_table_for() {
    local family="$1" mode entries tf addr addr_type
    mode=$(nft_get_access_mode)
    [ "$mode" != "off" ] || return 0
    nft_rules_has_family "$family" || return 0

    entries=$(nft_format_access_for "$family")
    [ "$mode" = "blacklist" ] && [ -z "$entries" ] && return 0

    if [ "$family" = "ipv6" ]; then
        tf="ip6"; addr="ip6"; addr_type="ipv6_addr"
    else
        tf="ip"; addr="ip"; addr_type="ipv4_addr"
    fi

    echo "table $tf nftpf_access {"
    if [ -n "$entries" ]; then
        cat <<EOF
    set sources {
        type $addr_type
        flags interval
        elements = { $entries }
    }
EOF
    fi
    echo "    chain prerouting {"
    echo "        type filter hook prerouting priority -101; policy accept;"
    echo "        # NFTPF_ACCESS_MODE=$mode"

    # 为每条规则生成访问控制匹配
    local id f lip ls le ttype thost tip ts te md match
    while IFS='|' read -r id f lip ls le ttype thost tip ts te md; do
        [[ -z "$id" || "$id" = \#* ]] && continue
        [ "$f" = "$family" ] || continue
        # 构造匹配（不带 dnat 的版本）
        if [ -n "$lip" ]; then
            if [ "$f" = "ipv6" ]; then match="ip6 daddr $lip "
            else match="ip daddr $lip "; fi
        else
            match=""
        fi
        if [ "$ls" = "$le" ]; then
            match="${match}meta l4proto {tcp, udp} th dport $ls"
        else
            match="${match}meta l4proto {tcp, udp} th dport { $ls-$le }"
        fi
        if [ "$mode" = "whitelist" ]; then
            if [ -n "$entries" ]; then
                echo "        $match $addr saddr != @sources drop"
            else
                echo "        $match drop"
            fi
        else
            echo "        $match $addr saddr @sources drop"
        fi
    done < "$NFT_RULES_FILE"
    echo "    }"
    echo "}"
    echo ""
}

nft_generate_config() {
    cat <<EOF
#!/usr/sbin/nft -f
# NFTPF_RENDER_VERSION=$NFT_RENDER_VERSION

flush ruleset

EOF
    nft_render_access_table_for "ipv4"
    nft_render_access_table_for "ipv6"

    cat <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF
    nft_render_rules_for "ipv4"
    cat <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ct status dnat masquerade
    }
}

table ip6 nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF
    nft_render_rules_for "ipv6"
    cat <<EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ct status dnat masquerade
    }
}
EOF
}

nft_write_and_apply() {
    local tmp
    tmp=$(mktemp) || return 1
    nft_generate_config > "$tmp"

    if ! nft -c -f "$tmp" 2>&1; then
        rm -f "$tmp"
        error "nftables 配置语法校验失败"
        return 1
    fi

    [ -f "$NFT_CONFIG_FILE" ] && cp "$NFT_CONFIG_FILE" "${NFT_CONFIG_FILE}.bak.last"
    mv "$tmp" "$NFT_CONFIG_FILE"
    chmod +x "$NFT_CONFIG_FILE"

    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl enable nftables &>/dev/null || true
        systemctl restart nftables &>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-update add nftables default 2>/dev/null || true
        rc-service nftables restart &>/dev/null || nft -f "$NFT_CONFIG_FILE"
    else
        nft -f "$NFT_CONFIG_FILE"
    fi
    info "nftables 配置已应用 ✓"
}

# ── 规则展示 ──────────────────────────────────────────────
nft_display_host() {
    nft_is_ipv6 "$1" && echo "[$1]" || echo "$1"
}

nft_rule_summary() {
    local id="$1" family="$2" lip="$3" ls="$4" le="$5" \
          ttype="$6" thost="$7" tip="$8" ts="$9" te="${10}" mode="${11}"
    local listen_disp target_disp mode_text note=""

    [ -z "$lip" ] && lip="$([ "$family" = "ipv6" ] && echo "::" || echo "0.0.0.0")"
    if [ "$ls" = "$le" ]; then
        listen_disp="$(nft_display_host "$lip"):$ls"
    else
        listen_disp="$(nft_display_host "$lip"):${ls}-${le}"
    fi

    [ "$ttype" = "domain" ] && note=" (${tip})"
    if [ "$ts" = "$te" ]; then
        target_disp="$(nft_display_host "$thost"):${ts}${note}"
    else
        target_disp="$(nft_display_host "$thost"):${ts}-${te}${note}"
    fi

    case "$mode" in
        single) mode_text="单端口" ;;
        range_1_to_1) mode_text="端口段1:1" ;;
        range_offset) mode_text="端口段偏移" ;;
    esac

    echo "[${id}] [${family}] [${mode_text}] ${listen_disp} → ${target_disp}"
}

nft_list_rules() {
    local count=0 line
    while IFS='|' read -r id f lip ls le ttype thost tip ts te mode; do
        [[ -z "$id" || "$id" = \#* ]] && continue
        nft_rule_summary "$id" "$f" "$lip" "$ls" "$le" "$ttype" "$thost" "$tip" "$ts" "$te" "$mode"
        count=$((count + 1))
    done < "$NFT_RULES_FILE"
    [ "$count" -gt 0 ]
}

nft_find_rule() {
    local target_id="$1" line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" = \#* ]] && continue
        local id="${line%%|*}"
        if [ "$id" = "$target_id" ]; then
            NFT_FOUND_RULE="$line"
            return 0
        fi
    done < "$NFT_RULES_FILE"
    return 1
}

# ── 添加规则 ──────────────────────────────────────────────
nft_choose_family() {
    local lip="$1" thost="$2" choice="$3"
    if [ -n "$lip" ]; then
        echo "$(nft_classify "$lip")"
        return
    fi
    case "$choice" in
        4|ipv4) echo "ipv4"; return ;;
        6|ipv6) echo "ipv6"; return ;;
    esac
    local k; k=$(nft_classify "$thost")
    case "$k" in
        ipv4|ipv6) echo "$k" ;;
        domain)
            if nft_resolve_domain "$thost" ipv4 >/dev/null 2>&1; then echo "ipv4"
            elif nft_resolve_domain "$thost" ipv6 >/dev/null 2>&1; then echo "ipv6"
            else echo "invalid"; fi
            ;;
        *) echo "invalid" ;;
    esac
}

nft_add_rule() {
    local mode="$1"
    local lip ls le thost ts te family resolved_ip
    print_header "添加端口转发规则（${mode}）"

    read -rp "  监听 IP（留空=所有，IPv6 输入 ::）: " lip
    [ "$lip" = "0.0.0.0" ] || [ "$lip" = "::" ] && lip=""

    if [ "$mode" = "single" ]; then
        read -rp "  监听端口: " ls
        nft_check_port "$ls" || { error "端口无效"; return; }
        le="$ls"
    else
        read -rp "  监听起始端口: " ls
        read -rp "  监听结束端口: " le
        nft_check_port "$ls" || { error "起始端口无效"; return; }
        nft_check_port "$le" || { error "结束端口无效"; return; }
        [ "$ls" -le "$le" ] || { error "起始端口不能大于结束端口"; return; }
    fi

    read -rp "  目标 IP / 域名: " thost
    [ -z "$thost" ] && { warn "已取消"; return; }
    [ "$(nft_classify "$thost")" != "invalid" ] || { error "目标地址格式无效"; return; }

    if [ "$mode" = "single" ]; then
        read -rp "  目标端口（留空=同监听端口）: " ts
        [ -z "$ts" ] && ts="$ls"
        nft_check_port "$ts" || { error "目标端口无效"; return; }
        te="$ts"
        local rule_mode="single"
    else
        echo ""
        echo -e "  ${GREEN}1${NC}) 1:1 映射（目标端口段=监听端口段）"
        echo -e "  ${GREEN}2${NC}) 端口段偏移（目标段从指定起始端口开始）"
        read -rp "  选择映射模式 [1/2]，默认 1: " mc
        [ -z "$mc" ] && mc=1
        local count=$((le - ls + 1))
        if [ "$mc" = "2" ]; then
            read -rp "  目标起始端口: " ts
            nft_check_port "$ts" || { error "目标端口无效"; return; }
            te=$((ts + count - 1))
            [ "$te" -le 65535 ] || { error "目标结束端口超过 65535"; return; }
            local rule_mode="range_offset"
        else
            ts="$ls"; te="$le"
            local rule_mode="range_1_to_1"
        fi
    fi

    # 协议族判定
    family=$(nft_choose_family "$lip" "$thost" "auto")
    [ "$family" = "invalid" ] && { error "无法确定协议族"; return; }

    # 目标地址解析
    local ttype="ip"
    if [ "$(nft_classify "$thost")" = "domain" ]; then
        ttype="domain"
        resolved_ip=$(nft_resolve_domain "$thost" "$family") || { error "域名解析失败"; return; }
    else
        resolved_ip="$thost"
    fi

    local id; id=$(nft_next_rule_id)
    local record="${id}|${family}|${lip}|${ls}|${le}|${ttype}|${thost}|${resolved_ip}|${ts}|${te}|${rule_mode}"

    echo ""
    info "即将添加："
    nft_rule_summary "$id" "$family" "$lip" "$ls" "$le" "$ttype" "$thost" "$resolved_ip" "$ts" "$te" "$rule_mode"
    echo ""
    read -rp "  确认添加？(Y/n，默认Y): " c
    [ -z "$c" ] && c="y"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    echo "$record" >> "$NFT_RULES_FILE"
    nft_write_and_apply || {
        # 回滚
        sed -i "/^${id}|/d" "$NFT_RULES_FILE"
        return 1
    }
}

# ── 删除规则 ──────────────────────────────────────────────
nft_edit_rule() {
    print_header "修改转发规则"
    if ! nft_list_rules; then
        warn "暂无规则"
        return
    fi
    echo ""
    read -rp "  请输入要修改的规则 ID（0 取消）: " id
    [ "$id" = "0" ] || [ -z "$id" ] && { warn "已取消"; return; }
    nft_find_rule "$id" || { error "未找到该规则"; return; }

    # 解析当前字段
    IFS='|' read -r OLD_ID OLD_F OLD_LIP OLD_LS OLD_LE OLD_TTYPE OLD_THOST OLD_TIP OLD_TS OLD_TE OLD_MODE <<< "$NFT_FOUND_RULE"

    echo ""
    info "当前规则："
    nft_rule_summary "$OLD_ID" "$OLD_F" "$OLD_LIP" "$OLD_LS" "$OLD_LE" "$OLD_TTYPE" "$OLD_THOST" "$OLD_TIP" "$OLD_TS" "$OLD_TE" "$OLD_MODE"
    echo ""
    echo -e "  ${DIM}直接回车 = 保留原值${NC}"
    echo ""

    # ── 监听 IP ──
    local lip_display="${OLD_LIP:-所有}"
    read -rp "  监听 IP [${lip_display}]: " new_lip
    [ -z "$new_lip" ] && new_lip="$OLD_LIP"
    [ "$new_lip" = "0.0.0.0" ] || [ "$new_lip" = "::" ] && new_lip=""

    # ── 监听端口 ──
    local new_ls new_le
    if [ "$OLD_MODE" = "single" ]; then
        read -rp "  监听端口 [${OLD_LS}]: " new_ls
        [ -z "$new_ls" ] && new_ls="$OLD_LS"
        nft_check_port "$new_ls" || { error "端口无效"; return; }
        new_le="$new_ls"
    else
        read -rp "  监听起始端口 [${OLD_LS}]: " new_ls
        [ -z "$new_ls" ] && new_ls="$OLD_LS"
        read -rp "  监听结束端口 [${OLD_LE}]: " new_le
        [ -z "$new_le" ] && new_le="$OLD_LE"
        nft_check_port "$new_ls" || { error "起始端口无效"; return; }
        nft_check_port "$new_le" || { error "结束端口无效"; return; }
        [ "$new_ls" -le "$new_le" ] || { error "起始端口不能大于结束端口"; return; }
    fi

    # ── 目标主机 ──
    read -rp "  目标 IP/域名 [${OLD_THOST}]: " new_thost
    [ -z "$new_thost" ] && new_thost="$OLD_THOST"
    [ "$(nft_classify "$new_thost")" != "invalid" ] || { error "目标地址格式无效"; return; }

    # ── 目标端口 ──
    local new_ts new_te new_mode
    if [ "$OLD_MODE" = "single" ]; then
        read -rp "  目标端口 [${OLD_TS}]: " new_ts
        [ -z "$new_ts" ] && new_ts="$OLD_TS"
        nft_check_port "$new_ts" || { error "目标端口无效"; return; }
        new_te="$new_ts"
        new_mode="single"
    else
        # 端口段：保留原模式或允许切换
        echo ""
        local cur_mode_label
        case "$OLD_MODE" in
            range_1_to_1) cur_mode_label="1:1 映射" ;;
            range_offset) cur_mode_label="端口段偏移" ;;
        esac
        echo -e "  当前映射模式：${BOLD}${cur_mode_label}${NC}"
        echo -e "  ${GREEN}1${NC}) 1:1 映射（目标段=监听段）"
        echo -e "  ${GREEN}2${NC}) 端口段偏移"
        local default_mc=1
        [ "$OLD_MODE" = "range_offset" ] && default_mc=2
        read -rp "  选择映射模式 [1/2]，默认 ${default_mc}: " mc
        [ -z "$mc" ] && mc=$default_mc

        local count=$((new_le - new_ls + 1))
        if [ "$mc" = "2" ]; then
            read -rp "  目标起始端口 [${OLD_TS}]: " new_ts
            [ -z "$new_ts" ] && new_ts="$OLD_TS"
            nft_check_port "$new_ts" || { error "目标端口无效"; return; }
            new_te=$((new_ts + count - 1))
            [ "$new_te" -le 65535 ] || { error "目标结束端口超过 65535"; return; }
            new_mode="range_offset"
        else
            new_ts="$new_ls"; new_te="$new_le"
            new_mode="range_1_to_1"
        fi
    fi

    # ── 协议族判定（监听 IP 变化可能改变 family）──
    local new_family
    new_family=$(nft_choose_family "$new_lip" "$new_thost" "$OLD_F")
    [ "$new_family" = "invalid" ] && { error "无法确定协议族"; return; }

    # ── 目标解析 ──
    local new_ttype new_tip
    if [ "$(nft_classify "$new_thost")" = "domain" ]; then
        new_ttype="domain"
        new_tip=$(nft_resolve_domain "$new_thost" "$new_family") || { error "域名解析失败"; return; }
    else
        new_ttype="ip"
        new_tip="$new_thost"
    fi

    local new_record="${OLD_ID}|${new_family}|${new_lip}|${new_ls}|${new_le}|${new_ttype}|${new_thost}|${new_tip}|${new_ts}|${new_te}|${new_mode}"

    echo ""
    info "修改后："
    nft_rule_summary "$OLD_ID" "$new_family" "$new_lip" "$new_ls" "$new_le" "$new_ttype" "$new_thost" "$new_tip" "$new_ts" "$new_te" "$new_mode"
    echo ""
    read -rp "  确认应用？(Y/n，默认Y): " c
    [ -z "$c" ] && c="y"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    # 备份原规则用于回滚
    local backup_line="$NFT_FOUND_RULE"
    # 删除旧规则
    sed -i "/^${OLD_ID}|/d" "$NFT_RULES_FILE"
    # 写入新规则
    echo "$new_record" >> "$NFT_RULES_FILE"

    if ! nft_write_and_apply; then
        # 回滚
        sed -i "/^${OLD_ID}|/d" "$NFT_RULES_FILE"
        echo "$backup_line" >> "$NFT_RULES_FILE"
        nft_write_and_apply
        error "应用失败，已回滚到原规则"
        return 1
    fi
    info "规则已修改 ✓"
}

nft_delete_rule() {
    print_header "删除端口转发规则"
    if ! nft_list_rules; then
        warn "暂无规则"
        return
    fi
    echo ""
    read -rp "  请输入要删除的规则 ID（0 取消）: " id
    [ "$id" = "0" ] || [ -z "$id" ] && { warn "已取消"; return; }
    nft_find_rule "$id" || { error "未找到该规则"; return; }

    echo ""
    info "即将删除："
    local fields; IFS='|' read -ra fields <<< "$NFT_FOUND_RULE"
    nft_rule_summary "${fields[@]}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " c
    [ -z "$c" ] && c="y"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    sed -i "/^${id}|/d" "$NFT_RULES_FILE"
    nft_write_and_apply
}

# ── 清空所有规则 ──────────────────────────────────────────
nft_clear_all_rules() {
    warn "将清空所有 NFT 转发规则！"
    read -rp "  确认清空？(y/N，默认N): " c
    [ -z "$c" ] && c="n"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    : > "$NFT_RULES_FILE"
    nft_write_and_apply
}

# ── DDNS 刷新 ─────────────────────────────────────────────
nft_refresh_ddns() {
    local tmp; tmp=$(mktemp) || return 1
    local changed=0 domain_count=0 line
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" = \#* ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        IFS='|' read -r id f lip ls le ttype thost tip ts te mode <<< "$line"
        if [ "$ttype" = "domain" ]; then
            domain_count=$((domain_count + 1))
            local new_ip
            if new_ip=$(nft_resolve_domain "$thost" "$f"); then
                if [ "$new_ip" != "$tip" ]; then
                    info "[$id] ${thost}: ${tip} → ${new_ip}"
                    tip="$new_ip"
                    changed=$((changed + 1))
                fi
            else
                warn "[$id] ${thost} 解析失败，保留旧值 ${tip}"
            fi
        fi
        echo "${id}|${f}|${lip}|${ls}|${le}|${ttype}|${thost}|${tip}|${ts}|${te}|${mode}" >> "$tmp"
    done < "$NFT_RULES_FILE"

    if [ "$domain_count" -eq 0 ]; then
        warn "没有配置 DDNS 域名目标"
        rm -f "$tmp"
        return 0
    fi
    if [ "$changed" -eq 0 ]; then
        info "DDNS 检查完成，无变化"
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$NFT_RULES_FILE"
    nft_write_and_apply
}

# ── DDNS 自动刷新 timer ──────────────────────────────────
nft_ddns_timer_status() {
    if command -v systemctl &>/dev/null && systemctl is-active --quiet nftpf-ddns.timer 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

nft_ddns_timer_enable() {
    print_header "启用 DDNS 自动刷新"
    if ! command -v systemctl &>/dev/null; then
        error "需要 systemd 才能启用自动刷新"
        return 1
    fi
    read -rp "  刷新间隔（10s-24h，默认 5m）: " interval
    [ -z "$interval" ] && interval="5m"

    cat > "$NFT_DDNS_SERVICE_FILE" <<EOF
[Unit]
Description=NFT Port Forward DDNS refresh
After=network-online.target

[Service]
Type=oneshot
ExecStart=$LOCAL_SCRIPT --nft-refresh-ddns
EOF

    cat > "$NFT_DDNS_TIMER_FILE" <<EOF
[Unit]
Description=NFT Port Forward DDNS auto refresh

[Timer]
OnBootSec=${interval}
OnUnitActiveSec=${interval}
AccuracySec=1s
Unit=nftpf-ddns.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now nftpf-ddns.timer &>/dev/null && info "DDNS 自动刷新已启用（每 ${interval}）✓" \
        || error "启用失败"
}

nft_ddns_timer_disable() {
    if command -v systemctl &>/dev/null; then
        systemctl disable --now nftpf-ddns.timer &>/dev/null || true
    fi
    rm -f "$NFT_DDNS_TIMER_FILE" "$NFT_DDNS_SERVICE_FILE"
    command -v systemctl &>/dev/null && systemctl daemon-reload
    info "DDNS 自动刷新已关闭"
}

# ── 访问控制 ──────────────────────────────────────────────
nft_validate_access_entry() {
    local entry="$1" base prefix=""
    if [[ "$entry" = */* ]]; then
        base="${entry%%/*}"
        prefix="${entry##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    else
        base="$entry"
    fi
    local family; family=$(nft_classify "$base")
    case "$family" in
        ipv4)
            [ -z "$prefix" ] || [ "$prefix" -ge 0 -a "$prefix" -le 32 ] || return 1
            NFT_AC_FAMILY="ipv4"
            ;;
        ipv6)
            [ -z "$prefix" ] || [ "$prefix" -ge 0 -a "$prefix" -le 128 ] || return 1
            NFT_AC_FAMILY="ipv6"
            ;;
        *) return 1 ;;
    esac
}

nft_set_access_mode() {
    local mode="$1" entries_raw="$2"
    local tmp; tmp=$(mktemp) || return 1
    echo "mode=$mode" > "$tmp"

    local entry count=0
    for entry in $(echo "$entries_raw" | tr ',' ' '); do
        [ -n "$entry" ] || continue
        if ! nft_validate_access_entry "$entry"; then
            error "无效的 IP/CIDR：$entry"
            rm -f "$tmp"
            return 1
        fi
        grep -qxF "entry=$NFT_AC_FAMILY|$entry" "$tmp" || {
            echo "entry=$NFT_AC_FAMILY|$entry" >> "$tmp"
            count=$((count + 1))
        }
    done

    if [ "$mode" != "off" ] && [ "$count" -eq 0 ]; then
        error "启用白/黑名单需要至少一个 IP/CIDR"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$NFT_ACCESS_FILE"
    nft_write_and_apply
}

nft_access_menu() {
    while true; do
        local mode count v4 v6
        mode=$(nft_get_access_mode)
        if [ -f "$NFT_ACCESS_FILE" ]; then
            count=$(grep -c '^entry=' "$NFT_ACCESS_FILE" 2>/dev/null)
            count=${count:-0}
        else
            count=0
        fi
        v4=$(nft_format_access_for "ipv4")
        v6=$(nft_format_access_for "ipv6")

        local mode_label mode_color
        case "$mode" in
            whitelist) mode_label="白名单"; mode_color="$GREEN" ;;
            blacklist) mode_label="黑名单"; mode_color="$YELLOW" ;;
            *) mode_label="关闭"; mode_color="$DIM" ;;
        esac

        print_header "访问控制（白名单 / 黑名单）"
        echo -e "  当前模式: ${mode_color}${BOLD}${mode_label}${NC}    名单数: ${BOLD}${count}${NC}"
        [ -n "$v4" ] && echo -e "  IPv4: ${BOLD}${v4}${NC}"
        [ -n "$v6" ] && echo -e "  IPv6: ${BOLD}${v6}${NC}"
        menu_div
        echo -e "  ${DIM}白名单：只允许名单内 IP 访问转发端口${NC}"
        echo -e "  ${DIM}黑名单：拒绝名单内 IP 访问转发端口${NC}"
        echo -e "  ${DIM}仅影响 NFT 转发端口，不影响 SSH 等其他服务${NC}"
        menu_div
        echo -e "  ${GREEN}1${NC}) 启用白名单    ${GREEN}2${NC}) 启用黑名单"
        echo -e "  ${YELLOW}3${NC}) 关闭访问控制"
        echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
        echo ""
        read -rp "  请选择: " ch

        case "$ch" in
            1)
                # 白名单警告：自动检测当前 SSH 来源
                local ssh_from
                ssh_from=$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')
                if [ -n "$ssh_from" ]; then
                    echo ""
                    echo -e "  ${YELLOW}当前 SSH 来源：${BOLD}${ssh_from}${NC}"
                    echo -e "  ${DIM}建议加入白名单避免自我封锁${NC}"
                fi
                echo ""
                echo -e "  ${DIM}多个用空格或逗号分隔，例如：1.2.3.4 5.6.7.0/24${NC}"
                read -rp "  白名单 IP/CIDR: " entries
                [ -z "$entries" ] && { warn "已取消"; sleep 1; continue; }
                if [ -n "$ssh_from" ] && ! echo "$entries" | grep -qF "$ssh_from"; then
                    read -rp "  自动添加 ${ssh_from}？(Y/n，默认Y): " a
                    [ -z "$a" ] && a="y"
                    echo "$a" | grep -qiE '^y(es)?$' && entries="$entries $ssh_from"
                fi
                nft_set_access_mode whitelist "$entries"
                ;;
            2)
                echo ""
                read -rp "  黑名单 IP/CIDR: " entries
                [ -z "$entries" ] && { warn "已取消"; sleep 1; continue; }
                nft_set_access_mode blacklist "$entries"
                ;;
            3)
                nft_set_access_mode off ""
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        echo ""
        read -rp "  按 Enter 继续..." _
    done
}


# ── iptables 本地端口转发（轻量，不依赖 nftables）─────────
IPTPF_RULES_FILE="${IPTPF_RULES_FILE:-/etc/iptables-local-fwd.conf}"

iptpf_ensure_file() {
    [ -f "$IPTPF_RULES_FILE" ] || touch "$IPTPF_RULES_FILE"
}

iptpf_check_iptables() {
    command -v iptables &>/dev/null && return 0
    info "正在安装 iptables..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y iptables iptables-persistent 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache iptables 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y iptables-services 2>/dev/null
    fi
    command -v iptables &>/dev/null
}

iptpf_persist() {
    # 持久化保存当前 iptables 规则
    if [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    elif [ -f /etc/sysconfig/iptables ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
    # rc.local 兜底（无 systemd 时）
    if [ -f /etc/rc.local ] && ! grep -q "iptables-local-fwd" /etc/rc.local; then
        # 不重复写入
        :
    fi
}

iptpf_apply_rule() {
    local src_port="$1" dst_port="$2" proto="$3"
    # PREROUTING：来自外部的流量
    iptables -t nat -A PREROUTING -p "$proto" --dport "$src_port" -j REDIRECT --to-port "$dst_port" 2>/dev/null
    # OUTPUT：本机自己访问也走转发
    iptables -t nat -A OUTPUT -p "$proto" -o lo --dport "$src_port" -j REDIRECT --to-port "$dst_port" 2>/dev/null
}

iptpf_remove_rule() {
    local src_port="$1" dst_port="$2" proto="$3"
    iptables -t nat -D PREROUTING -p "$proto" --dport "$src_port" -j REDIRECT --to-port "$dst_port" 2>/dev/null
    iptables -t nat -D OUTPUT -p "$proto" -o lo --dport "$src_port" -j REDIRECT --to-port "$dst_port" 2>/dev/null
}

iptpf_list() {
    iptpf_ensure_file
    if [ ! -s "$IPTPF_RULES_FILE" ]; then
        warn "暂无本地端口转发规则"
        return 1
    fi
    echo -e "  ${DIM}格式: [编号] 源端口 → 目标端口 (协议)${NC}"
    local i=1
    while IFS='|' read -r src dst proto; do
        [ -z "$src" ] && continue
        echo -e "  ${GREEN}[$i]${NC} ${BOLD}${src}${NC} → ${BOLD}${dst}${NC}  (${proto})"
        i=$((i + 1))
    done < "$IPTPF_RULES_FILE"
}

iptpf_add() {
    print_header "添加本地端口转发"
    echo -e "  ${DIM}将访问本机 A 端口的流量转发到本机 B 端口${NC}"
    echo -e "  ${DIM}用途：端口跳转、绕过端口限制、本机端口聚合${NC}"
    echo ""

    iptpf_check_iptables || { error "iptables 不可用"; return; }

    read -rp "  源端口（外部访问的端口）: " src
    nft_check_port "$src" || { error "端口无效"; return; }

    read -rp "  目标端口（本机实际服务端口）: " dst
    nft_check_port "$dst" || { error "端口无效"; return; }

    [ "$src" = "$dst" ] && { error "源端口和目标端口不能相同"; return; }

    echo ""
    echo -e "  ${GREEN}1${NC}) TCP"
    echo -e "  ${GREEN}2${NC}) UDP"
    echo -e "  ${GREEN}3${NC}) TCP + UDP"
    read -rp "  协议 [1/2/3]，默认 3: " pc
    [ -z "$pc" ] && pc=3

    case "$pc" in
        1) protos="tcp" ;;
        2) protos="udp" ;;
        3) protos="tcp udp" ;;
        *) error "无效选项"; return ;;
    esac

    # 检查重复
    for p in $protos; do
        if grep -qE "^${src}\|${dst}\|${p}$" "$IPTPF_RULES_FILE" 2>/dev/null; then
            warn "规则已存在: ${src} → ${dst} (${p})"
            continue
        fi
        iptpf_apply_rule "$src" "$dst" "$p"
        echo "${src}|${dst}|${p}" >> "$IPTPF_RULES_FILE"
        info "已添加: ${src} → ${dst} (${p}) ✓"
    done

    iptpf_persist
}

iptpf_delete() {
    print_header "删除本地端口转发"
    if ! iptpf_list; then
        return
    fi
    echo ""
    read -rp "  请输入要删除的规则编号（0 取消）: " id
    [ "$id" = "0" ] || [ -z "$id" ] && { warn "已取消"; return; }
    if ! echo "$id" | grep -qE '^[0-9]+$'; then
        error "无效编号"
        return
    fi

    local target_line; target_line=$(sed -n "${id}p" "$IPTPF_RULES_FILE")
    [ -z "$target_line" ] && { error "未找到该规则"; return; }

    IFS='|' read -r src dst proto <<< "$target_line"

    echo ""
    info "即将删除: ${src} → ${dst} (${proto})"
    read -rp "  确认删除？(Y/n，默认Y): " c
    [ -z "$c" ] && c="y"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    iptpf_remove_rule "$src" "$dst" "$proto"
    sed -i "${id}d" "$IPTPF_RULES_FILE"
    iptpf_persist
    info "已删除 ✓"
}

iptpf_clear_all() {
    warn "将清空所有本地端口转发规则"
    read -rp "  确认？(y/N，默认N): " c
    [ -z "$c" ] && c="n"
    echo "$c" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    iptpf_ensure_file
    while IFS='|' read -r src dst proto; do
        [ -z "$src" ] && continue
        iptpf_remove_rule "$src" "$dst" "$proto"
    done < "$IPTPF_RULES_FILE"
    : > "$IPTPF_RULES_FILE"
    iptpf_persist
    info "已清空所有本地端口转发规则 ✓"
}

iptpf_menu() {
    iptpf_ensure_file
    while true; do
        local count
        count=$(grep -c '^' "$IPTPF_RULES_FILE" 2>/dev/null)
        count=${count:-0}

        print_header "iptables 本地端口转发"
        echo -e "  ${DIM}本机 A 端口 → 本机 B 端口（不涉及外网目标）${NC}"
        echo -e "  ${DIM}用途：端口跳转、绕过端口限制、端口别名${NC}"
        echo ""
        echo -e "  当前规则数：${BOLD}${count}${NC}"

        if [ "$count" -gt 0 ]; then
            menu_div
            iptpf_list
        fi

        menu_div
        echo -e "  ${GREEN}1${NC}) 添加本地端口转发"
        echo -e "  ${YELLOW}2${NC}) 删除指定规则"
        echo -e "  ${YELLOW}3${NC}) 清空所有规则"
        echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
        echo ""
        read -rp "  请选择: " ch

        case "$ch" in
            1) iptpf_add ;;
            2) iptpf_delete ;;
            3) iptpf_clear_all ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

# ── NFT 主菜单 ────────────────────────────────────────────
nft_menu() {
    nft_ensure_state_dir

    while true; do
        local rule_count
        if [ -f "$NFT_RULES_FILE" ]; then
            rule_count=$(grep -c '^[0-9]' "$NFT_RULES_FILE" 2>/dev/null)
            rule_count=${rule_count:-0}
        else
            rule_count=0
        fi
        local access_mode; access_mode=$(nft_get_access_mode)
        local timer_st; timer_st=$(nft_ddns_timer_status)

        print_header "NFT 转发管理（端口转发 / DDNS / 访问控制）"

        # 状态栏
        if command -v nft &>/dev/null; then
            echo -e "  nftables : ${GREEN}已安装${NC}    规则数: ${BOLD}${rule_count}${NC}"
        else
            echo -e "  nftables : ${RED}未安装${NC}"
        fi

        case "$access_mode" in
            whitelist) echo -e "  访问控制 : ${GREEN}${BOLD}白名单${NC}" ;;
            blacklist) echo -e "  访问控制 : ${YELLOW}${BOLD}黑名单${NC}" ;;
            *) echo -e "  访问控制 : ${DIM}关闭${NC}" ;;
        esac
        case "$timer_st" in
            active)  echo -e "  DDNS 定时刷新 : ${GREEN}${BOLD}运行中${NC}" ;;
            *)       echo -e "  DDNS 定时刷新 : ${DIM}未启用${NC}" ;;
        esac

        # 显示规则列表（不超过 10 条）
        if [ "$rule_count" -gt 0 ]; then
            menu_div
            echo -e "  ${DIM}当前规则：${NC}"
            local shown=0
            while IFS='|' read -r id f lip ls le ttype thost tip ts te mode; do
                [[ -z "$id" || "$id" = \#* ]] && continue
                [ "$shown" -ge 10 ] && { echo -e "  ${DIM}（更多规则请用「查看所有规则」）${NC}"; break; }
                echo "  $(nft_rule_summary "$id" "$f" "$lip" "$ls" "$le" "$ttype" "$thost" "$tip" "$ts" "$te" "$mode")"
                shown=$((shown + 1))
            done < "$NFT_RULES_FILE"
        fi

        menu_div
        if command -v nft &>/dev/null; then
            echo -e "  ${GREEN}1${NC}) 添加单端口转发     ${GREEN}2${NC}) 添加端口段转发"
            echo -e "  ${GREEN}3${NC}) 查看所有规则       ${GREEN}e${NC}) 修改规则"
            echo -e "  ${YELLOW}4${NC}) 删除规则           ${YELLOW}5${NC}) 清空所有规则"
            menu_div
            echo -e "  ${GREEN}6${NC}) 立即刷新 DDNS"
            if [ "$timer_st" = "active" ]; then
                echo -e "  ${YELLOW}7${NC}) 关闭 DDNS 自动刷新"
            else
                echo -e "  ${GREEN}7${NC}) 启用 DDNS 自动刷新"
            fi
            echo -e "  ${GREEN}8${NC}) 访问控制（白/黑名单）"
            echo -e "  ${GREEN}l${NC}) iptables 本地端口转发"
            menu_div
            echo -e "  ${YELLOW}9${NC}) 卸载 nftables"
        else
            echo -e "  ${YELLOW}未检测到 nftables，请先安装：${NC}"
            echo -e "  ${GREEN}i${NC}) 安装 nftables"
            echo -e "  ${GREEN}l${NC}) iptables 本地端口转发（无需 nftables）"
            menu_div
        fi
        echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
        echo ""
        read -rp "  请选择: " ch

        if ! command -v nft &>/dev/null; then
            case "$ch" in
                i|I)
                    nft_install && info "nftables 安装完成 ✓" || error "nftables 安装失败"
                    ;;
                l|L) iptpf_menu ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "请先安装 nftables（按 i）"; sleep 1; continue ;;
            esac
        else
            case "$ch" in
                1|2)
                    nft_enable_ip_forward
                    if [ "$ch" = "1" ]; then nft_add_rule single
                    else nft_add_rule range; fi
                    ;;
                3)
                    print_header "所有 NFT 转发规则"
                    nft_list_rules || warn "暂无规则"
                    ;;
                e|E) nft_edit_rule ;;
                4) nft_delete_rule ;;
                5) nft_clear_all_rules ;;
                6) nft_refresh_ddns ;;
                7)
                    [ "$timer_st" = "active" ] && nft_ddns_timer_disable || nft_ddns_timer_enable
                    ;;
                8) nft_access_menu ;;
                9) nft_uninstall ;;
                l|L) iptpf_menu ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1; continue ;;
            esac
        fi
        echo ""
        read -rp "  按 Enter 继续..." _
    done
}


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
LOG_FILE="/var/log/ddns.log"

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
    echo -e "  ${GREEN}1${NC}) 配置 Telegram 通知"
    echo -e "  ${GREEN}2${NC}) 发送测试消息"
    [ -f "$DDNS_TG_FILE" ] && echo -e "  ${YELLOW}3${NC}) 关闭 Telegram 通知"
    echo -e "  ${RED}0${NC}) 返回"
    echo ""
    read -rp "  请选择: " CH

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
        echo -e "  ${GREEN}1${NC}) 实时跟踪（Ctrl+C 返回）"
        echo -e "  ${GREEN}2${NC}) 查看完整日志（UTF-8）"
        echo -e "  ${RED}0${NC}) 返回"
        echo ""
        read -rp "  请选择: " CH
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
            echo -e "  ${GREEN}1${NC}) 开始安装配置 DDNS"
            echo -e "  ${RED}0${NC}) 返回  ${RED}00${NC}) 退出脚本"
        else
            echo -e "  ${GREEN}1${NC}) 手动立即更新     ${GREEN}2${NC}) 查看日志"
            echo -e "  ${GREEN}3${NC}) 修改配置         ${GREEN}6${NC}) Telegram 通知"
            if [ "$D_ST" = "running" ]; then
                echo -e "  ${YELLOW}4${NC}) 暂停自动更新     ${YELLOW}5${NC}) 卸载 DDNS"
            elif [ "$D_ST" = "no_cron" ]; then
                echo -e "  ${GREEN}4${NC}) 安装 cron 并恢复  ${YELLOW}5${NC}) 卸载 DDNS"
            else
                echo -e "  ${GREEN}4${NC}) 恢复自动更新     ${YELLOW}5${NC}) 卸载 DDNS"
            fi
            echo -e "  ${RED}0${NC}) 返回  ${RED}00${NC}) 退出脚本"
        fi
        menu_div
        echo ""
        read -rp "  请选择: " CH

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
            echo ""; read -rp "  按 Enter 返回..." _
        fi
    done
}

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
        box_title "VPS 开荒脚本 V3.5.9"
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
        menu_item "m" "脚本管理 ${DIM}（安装 / 更新 / 卸载）${NC}"
        echo ""
        menu_item "0" "退出" "$RED"
        box_bot
        echo ""
        read -rp "  请选择功能 [0-9/n/t/s/m]: " CHOICE

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
            m|M) self_manage_menu ;;
            0) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
        continue
    done
}

# CLI 处理：systemd timer 调用 DDNS 刷新（非交互）
if [ "${1:-}" = "--nft-refresh-ddns" ]; then
    nft_refresh_ddns
    exit $?
fi

self_check_first_run
# 后台检测新版本（不阻塞主菜单）
self_check_update &
main_menu

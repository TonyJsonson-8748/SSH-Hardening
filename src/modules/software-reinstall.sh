# ══════════════════════════════════════════════════════════
#  常用软件与系统重装
# ══════════════════════════════════════════════════════════

software_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v opkg >/dev/null 2>&1; then echo opkg
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown
    fi
}

software_group_packages() {
    local PM="$1" GROUP="$2"
    case "$PM:$GROUP" in
        apt:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        apt:network) echo "iproute2 dnsutils mtr-tiny traceroute tcpdump netcat-openbsd socat nmap" ;;
        apt:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        apt:develop) echo "build-essential python3 python3-pip" ;;
        dnf:base|yum:base) echo "curl wget git jq unzip zip tar nano vim-enhanced tmux screen ca-certificates" ;;
        dnf:network|yum:network) echo "iproute bind-utils mtr traceroute tcpdump nmap-ncat socat nmap" ;;
        dnf:monitor|yum:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        dnf:develop|yum:develop) echo "gcc gcc-c++ make python3 python3-pip" ;;
        apk:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        apk:network) echo "iproute2 bind-tools mtr traceroute tcpdump netcat-openbsd socat nmap" ;;
        apk:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        apk:develop) echo "build-base python3 py3-pip" ;;
        opkg:base) echo "curl wget-ssl git git-http jq unzip zip tar nano-full vim-fuller tmux screen ca-bundle" ;;
        opkg:network) echo "ip-full bind-dig mtr traceroute tcpdump netcat socat nmap" ;;
        opkg:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        opkg:develop) echo "python3 python3-pip make gcc" ;;
        pacman:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        pacman:network) echo "iproute2 bind mtr traceroute tcpdump openbsd-netcat socat nmap" ;;
        pacman:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        pacman:develop) echo "base-devel python python-pip" ;;
    esac
}

software_refresh_index() {
    case "$1" in
        apt) apt-get update -qq ;;
        dnf) dnf makecache -q ;;
        yum) yum makecache -q ;;
        apk) apk update ;;
        opkg) opkg update ;;
        pacman) pacman -Sy --noconfirm ;;
        *) return 1 ;;
    esac
}

software_install_one() {
    local PM="$1" PKG="$2"
    case "$PM" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" ;;
        dnf) dnf install -y "$PKG" ;;
        yum) yum install -y "$PKG" ;;
        apk) apk add --no-cache "$PKG" ;;
        opkg) opkg install "$PKG" ;;
        pacman) pacman -S --noconfirm --needed "$PKG" ;;
        *) return 1 ;;
    esac
}

software_install_packages() {
    local PM="$1" PACKAGES="$2" PKG OK=0 FAILED=0 FAILED_LIST=""
    info "正在刷新软件包索引..."
    software_refresh_index "$PM" || warn "软件包索引刷新失败，将继续尝试安装"
    for PKG in $PACKAGES; do
        echo -e "  ${CYAN}›${NC} 安装 ${BOLD}$PKG${NC}"
        if software_install_one "$PM" "$PKG" >/dev/null 2>&1; then
            OK=$((OK+1))
        else
            FAILED=$((FAILED+1)); FAILED_LIST="${FAILED_LIST} ${PKG}"
        fi
    done
    echo ""; menu_div
    info "安装完成：成功 $OK 个，失败 $FAILED 个"
    [ "$FAILED" -gt 0 ] && warn "未安装：${FAILED_LIST# }"
    audit_action "安装常用软件：成功 $OK，失败 $FAILED" SUCCESS
}

common_software_menu() {
    while true; do
        print_header "安装常用软件"
        local PM; PM=$(software_package_manager)
        echo -e "  包管理器：${BOLD}$PM${NC}"
        ui_hint "可多选，例如 1 2 3；重复软件会自动去重"
        echo ""; menu_div
        menu_item "1" "基础工具  ${DIM}curl / wget / git / jq / tmux / 编辑器${NC}"
        menu_item "2" "网络诊断  ${DIM}mtr / tcpdump / socat / nmap / DNS${NC}"
        menu_item "3" "系统监控  ${DIM}htop / iftop / iotop / sysstat / ncdu${NC}"
        menu_item "4" "开发环境  ${DIM}编译工具 / Python / pip${NC}"
        menu_item "5" "全部推荐软件"
        menu_item "6" "安装自定义软件包"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择分类 [0-6，可多选]: ')" CHOICES
        [ "$CHOICES" = "0" ] && return
        [ "$PM" != "unknown" ] || { error "未识别到支持的包管理器"; ui_pause; return; }

        local PACKAGES="" CH GROUP PKG
        CHOICES=${CHOICES//,/ }
        for CH in $CHOICES; do
            case "$CH" in
                1) GROUP="base" ;;
                2) GROUP="network" ;;
                3) GROUP="monitor" ;;
                4) GROUP="develop" ;;
                5) GROUP="base network monitor develop" ;;
                6)
                    read -rp "$(ui_prompt '输入软件包名称: ')" PKG
                    if ! echo "$PKG" | grep -qE '^[A-Za-z0-9.+_-]+$'; then error "软件包名称格式无效"; continue; fi
                    PACKAGES="$PACKAGES $PKG"; continue ;;
                *) warn "忽略无效分类：$CH"; continue ;;
            esac
            local G
            for G in $GROUP; do
                for PKG in $(software_group_packages "$PM" "$G"); do
                    case " $PACKAGES " in *" $PKG "*) ;; *) PACKAGES="$PACKAGES $PKG" ;; esac
                done
            done
        done
        PACKAGES=${PACKAGES# }
        [ -n "$PACKAGES" ] || { warn "没有选择可安装的软件"; sleep 1; continue; }
        echo ""; echo -e "  ${BOLD}准备安装：${NC}"
        echo "$PACKAGES" | fold -s -w "$((BOX_W-4))" | sed 's/^/  /'
        confirm_change_preview "安装常用软件" "包管理器：$PM" "软件包数量：$(echo "$PACKAGES" | wc -w | tr -d ' ')" || { warn "已取消"; continue; }
        software_install_packages "$PM" "$PACKAGES"
        ui_pause
    done
}

reinstall_is_container() {
    local VIRT=""
    command -v systemd-detect-virt >/dev/null 2>&1 && VIRT=$(systemd-detect-virt 2>/dev/null || true)
    case "$VIRT" in lxc|lxc-libvirt|openvz|docker|podman|container-other) return 0 ;; esac
    grep -qaE 'lxc|openvz|docker|kubepods|containerd' /proc/1/cgroup /proc/1/environ 2>/dev/null
}

reinstall_download_engine() {
    local DEST="$1"
    local URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    info "正在从官方仓库下载重装工具..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 10 "$URL" -o "$DEST"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$DEST" "$URL"
    else
        error "需要先安装 curl 或 wget"
        return 1
    fi
    bash -n "$DEST" 2>/dev/null || { rm -f "$DEST"; error "下载脚本语法校验失败"; return 1; }
    chmod 700 "$DEST"
    local HASH; HASH=$(file_sha256 "$DEST" 2>/dev/null || echo "无法计算")
    info "下载完成，SHA256：$HASH"
}

reinstall_collect_auth_args() {
    REINSTALL_AUTH_ARGS=()
    local SSH_PORT KEY PASSWORD PASSWORD2
    SSH_PORT=$(get_config Port); SSH_PORT=${SSH_PORT:-22}
    KEY=$(grep -m1 -E '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa) ' "$AUTH_KEYS" 2>/dev/null || true)
    echo -e "  新系统 SSH 端口：${BOLD}$SSH_PORT${NC}"
    if [ -n "$KEY" ]; then
        info "检测到 SSH 公钥，新系统将继续使用该公钥"
        REINSTALL_AUTH_ARGS=(--ssh-port "$SSH_PORT" --ssh-key "$KEY")
        return 0
    fi
    warn "未检测到 SSH 公钥，需要为新系统设置 root 密码"
    read -rp "$(ui_prompt '输入新系统 root 密码（明文显示）: ')" PASSWORD
    read -rp "$(ui_prompt '再次输入密码: ')" PASSWORD2
    [ -n "$PASSWORD" ] && [ "$PASSWORD" = "$PASSWORD2" ] || { error "两次密码不一致或为空"; return 1; }
    REINSTALL_AUTH_ARGS=(--ssh-port "$SSH_PORT" --password "$PASSWORD")
}

reinstall_run_target() {
    local TARGET_LABEL="$1"; shift
    local SCRIPT="/root/reinstall.sh" ROOT_SOURCE ROOT_DISK VIRT ACTION="${1:-}" SSH_PORT
    if reinstall_is_container; then
        error "检测到容器环境，官方重装工具不支持 OpenVZ/LXC/Docker"
        return 1
    fi
    ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || df / | awk 'END {print $1}')
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null | head -1)
    VIRT=$(systemd-detect-virt 2>/dev/null || echo "未知")
    print_header "系统重装最终确认"
    echo -e "  目标系统：${RED}${BOLD}$TARGET_LABEL${NC}"
    echo -e "  当前根分区：${BOLD}${ROOT_SOURCE:-未知}${NC}"
    echo -e "  系统磁盘：${BOLD}${ROOT_DISK:-自动识别}${NC}"
    echo -e "  虚拟化：${BOLD}${VIRT:-物理机}${NC}"
    echo ""
    error "继续操作将清空整块系统盘，现有系统和所有数据不可恢复"
    warn "请先确认商家控制台/VNC可用，并已在异地保存必要备份"
    echo ""
    read -rp "$(ui_prompt '输入 ERASE-ALL-DATA 确认: ')" CONFIRM
    [ "$CONFIRM" = "ERASE-ALL-DATA" ] || { warn "确认词不匹配，已取消"; return; }
    if [ "$ACTION" = "dd" ]; then
        SSH_PORT=$(get_config Port); SSH_PORT=${SSH_PORT:-22}
        REINSTALL_AUTH_ARGS=(--ssh-port "$SSH_PORT")
        warn "RAW 镜像保留镜像自身账户凭据，本脚本不会注入 SSH 公钥或 root 密码"
    else
        reinstall_collect_auth_args || return 1
    fi
    reinstall_download_engine "$SCRIPT" || return 1
    audit_action "启动系统重装：$TARGET_LABEL" DANGER
    echo ""; warn "即将交由第三方重装工具执行，请认真阅读其后续输出"
    sleep 2
    bash "$SCRIPT" "$@" "${REINSTALL_AUTH_ARGS[@]}"
}

system_reinstall_menu() {
    while true; do
        print_header "一键 DD / 系统重装"
        error "此功能会清空整块系统盘，仅适用于 KVM、VMware、Hyper-V 或独立服务器"
        ui_hint "使用 bin456789/reinstall 官方工具；OpenVZ/LXC 将被拒绝"
        echo ""; menu_div
        menu_pair "1" "Debian 12" "2" "Debian 13"
        menu_pair "3" "Ubuntu 22.04" "4" "Ubuntu 24.04"
        menu_pair "5" "Alpine 3.20" "6" "Alpine 3.22"
        menu_item "7" "Rocky Linux 9"
        menu_item "8" "DD 自定义 RAW 镜像" "$YELLOW"
        menu_item "9" "仅下载 / 更新重装工具"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择目标系统 [0-9]: ')" CH
        case "$CH" in
            1) reinstall_run_target "Debian 12" debian 12 ;;
            2) reinstall_run_target "Debian 13" debian 13 ;;
            3) reinstall_run_target "Ubuntu 22.04" ubuntu 22.04 ;;
            4) reinstall_run_target "Ubuntu 24.04" ubuntu 24.04 ;;
            5) reinstall_run_target "Alpine 3.20" alpine 3.20 ;;
            6) reinstall_run_target "Alpine 3.22" alpine 3.22 ;;
            7) reinstall_run_target "Rocky Linux 9" rocky 9 ;;
            8)
                local IMG
                read -rp "$(ui_prompt '输入 RAW/VHD 镜像直链: ')" IMG
                echo "$IMG" | grep -qE '^https?://[^[:space:]]+$' || { error "镜像链接格式无效"; ui_pause; continue; }
                reinstall_run_target "自定义 RAW 镜像" dd --img "$IMG"
                ;;
            9) reinstall_download_engine /root/reinstall.sh ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}

software_reinstall_menu() {
    while true; do
        print_header "软件与系统重装"
        menu_item "1" "安装常用软件"
        menu_item "2" "一键 DD / 系统重装" "$RED"
        menu_item "0" "返回主菜单" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择功能 [0-2]: ')" CH
        case "$CH" in
            1) common_software_menu ;;
            2) system_reinstall_menu ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

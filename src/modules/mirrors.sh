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
    local BAK
    BAK="${SRC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
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

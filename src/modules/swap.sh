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

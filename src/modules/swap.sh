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
    menu_pair "1" "512 MB" "2" "1 GB"
    menu_pair "3" "2 GB · 推荐" "4" "4 GB"
    menu_item "5" "自定义大小"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择大小 [0-5]: ')" CH

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

    local SWAP_FILE NEW_SWAP OLD_SWAP
    SWAP_FILE="${SWAP_FILE:-/swapfile}"
    NEW_SWAP="${SWAP_FILE}.vps-tools.$$"
    OLD_SWAP="${SWAP_FILE}.vps-tools.bak.$$"

    echo ""
    info "正在创建 ${SIZE_MB}MB swap 文件..."

    # 用 fallocate 或 dd 创建文件
    if command -v fallocate &>/dev/null; then
        fallocate -l "${SIZE_MB}M" "$NEW_SWAP" 2>/dev/null || \
            dd if=/dev/zero of="$NEW_SWAP" bs=1M count="$SIZE_MB" status=none
    else
        dd if=/dev/zero of="$NEW_SWAP" bs=1M count="$SIZE_MB" status=progress
    fi

    if [ ! -f "$NEW_SWAP" ]; then
        error "Swap 文件创建失败"; return
    fi

    chmod 600 "$NEW_SWAP" || { rm -f "$NEW_SWAP"; return 1; }
    mkswap "$NEW_SWAP" &>/dev/null || { rm -f "$NEW_SWAP"; error "Swap 格式化失败"; return 1; }

    if swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -qxF "$SWAP_FILE"; then
        warn "已存在 ${SWAP_FILE}，正在安全替换..."
        swapoff "$SWAP_FILE" 2>/dev/null || { rm -f "$NEW_SWAP"; error "旧 Swap 无法关闭，已取消替换"; return 1; }
    fi
    if [ -f "$SWAP_FILE" ]; then
        mv "$SWAP_FILE" "$OLD_SWAP" || { rm -f "$NEW_SWAP"; error "旧 Swap 文件备份失败"; return 1; }
    fi
    if ! mv "$NEW_SWAP" "$SWAP_FILE" || ! swapon "$SWAP_FILE" 2>/dev/null; then
        rm -f "$SWAP_FILE" "$NEW_SWAP"
        if [ -f "$OLD_SWAP" ]; then
            mv "$OLD_SWAP" "$SWAP_FILE"
            swapon "$SWAP_FILE" 2>/dev/null || true
        fi
        error "Swap 启用失败，已恢复旧文件"
        return 1
    fi
    rm -f "$OLD_SWAP"

    info "Swap 已启用 ✓"

    # 写入 /etc/fstab 持久化
    if ! awk -v target="$SWAP_FILE" '$1 == target {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab || { error "无法写入 /etc/fstab，Swap 仅当前启动有效"; return 1; }
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

    if ! swapoff "$TARGET" 2>/dev/null; then
        error "Swap 无法关闭，未修改 fstab，也未删除文件"
        return 1
    fi
    info "Swap 已关闭 ✓"

    # 从 fstab 移除
    if awk -v target="$TARGET" '$1 == target {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        awk -v target="$TARGET" '$1 != target {print}' /etc/fstab > /etc/fstab.tmp \
            && mv /etc/fstab.tmp /etc/fstab || { error "更新 /etc/fstab 失败"; swapon "$TARGET" 2>/dev/null || true; return 1; }
        info "已从 /etc/fstab 移除 ✓"
    fi

    # 如果是文件则删除
    if [ -f "$TARGET" ]; then
        rm -f "$TARGET" && info "Swap 文件已删除 ✓"
    fi
}

# ── 修改 swappiness ───────────────────────────────────────
swap_swappiness_runtime_write() {
    local PROC_FILE="$1" VALUE="$2"
    printf '%s\n' "$VALUE" > "$PROC_FILE" 2>/dev/null
}

swap_swappiness_restore_state() {
    local PROC_FILE="$1" OLD_RUNTIME="$2" SYSCTL_FILE="$3" BACKUP="$4" EXISTED="$5"
    local RESTORE_TMP="" RESTORE_RC=0
    if [ "$EXISTED" = yes ]; then
        if [ -z "$BACKUP" ] || [ ! -f "$BACKUP" ]; then
            RESTORE_RC=1
        else
            RESTORE_TMP=$(mktemp "${SYSCTL_FILE}.vps-tools-restore.XXXXXX") || RESTORE_RC=1
            if [ "$RESTORE_RC" -eq 0 ]; then
                if ! cp -p -- "$BACKUP" "$RESTORE_TMP" \
                    || ! mv -f -- "$RESTORE_TMP" "$SYSCTL_FILE"; then
                    RESTORE_RC=1
                    rm -f -- "$RESTORE_TMP" 2>/dev/null || true
                fi
            fi
        fi
    else
        rm -f -- "$SYSCTL_FILE" 2>/dev/null || RESTORE_RC=1
    fi
    if ! [[ "$OLD_RUNTIME" =~ ^[0-9]+$ ]] \
        || ! swap_swappiness_runtime_write "$PROC_FILE" "$OLD_RUNTIME"; then
        RESTORE_RC=1
    fi
    return "$RESTORE_RC"
}

swap_swappiness_handle_failure() {
    local REASON="$1" PROC_FILE="$2" OLD_RUNTIME="$3"
    local SYSCTL_FILE="$4" BACKUP="$5" EXISTED="$6"
    if swap_swappiness_restore_state "$PROC_FILE" "$OLD_RUNTIME" \
        "$SYSCTL_FILE" "$BACKUP" "$EXISTED"; then
        rm -f -- "$BACKUP" 2>/dev/null || true
        error "$REASON，已恢复原设置"
        return 1
    fi
    error "$REASON，且自动回滚不完整"
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        warn "原配置备份已保留，请人工恢复：$BACKUP"
    else
        warn "原配置备份不可用，请立即人工核对：$SYSCTL_FILE"
    fi
    warn "请同时核对当前运行值：$PROC_FILE"
    return 2
}

swap_apply_swappiness() {
    local VAL="$1"
    local PROC_FILE="${SWAPPINESS_PROC_FILE:-/proc/sys/vm/swappiness}"
    local SYSCTL_FILE="${SWAPPINESS_SYSCTL_FILE:-/etc/sysctl.conf}"
    local SYSCTL_DIR CANDIDATE BACKUP="" EXISTED=no OLD_RUNTIME ACTUAL CONFIG_INPUT=/dev/null
    local FAILURE_RC

    [[ "$VAL" =~ ^[0-9]+$ ]] && [ "$VAL" -le 100 ] || {
        error "无效值（0-100）"
        return 1
    }
    VAL=$((10#$VAL))
    [ -f "$PROC_FILE" ] && [ ! -L "$PROC_FILE" ] || {
        error "swappiness 运行参数不可用：$PROC_FILE"
        return 1
    }
    if [ -e "$SYSCTL_FILE" ] || [ -L "$SYSCTL_FILE" ]; then
        [ -f "$SYSCTL_FILE" ] && [ ! -L "$SYSCTL_FILE" ] || {
            error "sysctl 配置不是安全的普通文件：$SYSCTL_FILE"
            return 1
        }
        EXISTED=yes
    fi
    SYSCTL_DIR=$(dirname "$SYSCTL_FILE")
    [ -d "$SYSCTL_DIR" ] || {
        error "sysctl 配置目录不存在：$SYSCTL_DIR"
        return 1
    }
    OLD_RUNTIME=$(cat "$PROC_FILE" 2>/dev/null)
    [[ "$OLD_RUNTIME" =~ ^[0-9]+$ ]] || {
        error "无法读取当前 swappiness"
        return 1
    }

    CANDIDATE=$(mktemp "${SYSCTL_FILE}.vps-tools.XXXXXX") || {
        error "无法创建 sysctl 候选文件"
        return 1
    }
    if [ "$EXISTED" = yes ]; then
        CONFIG_INPUT="$SYSCTL_FILE"
        BACKUP=$(mktemp "${SYSCTL_FILE}.vps-tools-backup.XXXXXX") || {
            rm -f "$CANDIDATE"
            error "无法创建 sysctl 备份"
            return 1
        }
        if ! cp -p -- "$SYSCTL_FILE" "$BACKUP" \
            || ! cp -p -- "$SYSCTL_FILE" "$CANDIDATE"; then
            rm -f "$CANDIDATE" "$BACKUP"
            error "无法备份 sysctl 配置"
            return 1
        fi
    else
        chmod 644 "$CANDIDATE" 2>/dev/null || true
    fi

    if ! awk -v value="$VAL" '
        /^[[:space:]]*vm[.]swappiness[[:space:]]*=/ {
            if (!written) print "vm.swappiness = " value
            written=1
            next
        }
        { print }
        END {
            if (!written) print "vm.swappiness = " value
        }
    ' "$CONFIG_INPUT" > "$CANDIDATE"; then
        rm -f "$CANDIDATE" "$BACKUP"
        error "无法生成 sysctl 候选配置"
        return 1
    fi

    if ! swap_swappiness_runtime_write "$PROC_FILE" "$VAL"; then
        rm -f -- "$CANDIDATE"
        FAILURE_RC=1
        swap_swappiness_handle_failure "无法修改当前 swappiness" \
            "$PROC_FILE" "$OLD_RUNTIME" "$SYSCTL_FILE" "$BACKUP" "$EXISTED" \
            || FAILURE_RC=$?
        return "$FAILURE_RC"
    fi
    if ! mv -f -- "$CANDIDATE" "$SYSCTL_FILE"; then
        rm -f -- "$CANDIDATE" 2>/dev/null || true
        FAILURE_RC=1
        swap_swappiness_handle_failure "无法写入 sysctl 配置" \
            "$PROC_FILE" "$OLD_RUNTIME" "$SYSCTL_FILE" "$BACKUP" "$EXISTED" \
            || FAILURE_RC=$?
        return "$FAILURE_RC"
    fi
    ACTUAL=$(cat "$PROC_FILE" 2>/dev/null)
    ACTUAL=${ACTUAL//[[:space:]]/}
    if [ "$ACTUAL" != "$VAL" ]; then
        FAILURE_RC=1
        swap_swappiness_handle_failure \
            "swappiness 写后验证失败（期望 $VAL，实际 ${ACTUAL:-未知}）" \
            "$PROC_FILE" "$OLD_RUNTIME" "$SYSCTL_FILE" "$BACKUP" "$EXISTED" \
            || FAILURE_RC=$?
        return "$FAILURE_RC"
    fi
    if [ -n "$BACKUP" ] && ! rm -f -- "$BACKUP"; then
        warn "swappiness 已生效，但临时备份清理失败：$BACKUP"
    fi
}

swap_set_swappiness() {
    print_header "设置 Swappiness"
    local PROC_FILE="${SWAPPINESS_PROC_FILE:-/proc/sys/vm/swappiness}"
    local CUR; CUR=$(cat "$PROC_FILE" 2>/dev/null || echo 60)

    echo -e "  当前 swappiness：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${DIM}推荐值：${NC}"
    menu_item "1" "10 · 服务器推荐"
    menu_item "2" "30 · 折中"
    menu_item "3" "60 · 系统默认"
    menu_item "4" "自定义 0-100"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择 Swappiness [0-4]: ')" CH

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

    local APPLY_RC=0
    swap_apply_swappiness "$VAL" || APPLY_RC=$?
    [ "$APPLY_RC" -eq 0 ] || return "$APPLY_RC"
    info "swappiness 已设置为 ${VAL}，重启后持续生效 ✓"
}

# ── Swap 主菜单 ───────────────────────────────────────────
swap_menu() {
    while true; do
        print_header "Swap 管理"
        swap_show_status
        menu_div
        menu_pair "1" "创建 / 更换 Swap" "2" "删除 Swap"
        menu_item "3" "设置 Swappiness"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" CH

        case "$CH" in
            1) swap_create ;;
            2) swap_delete ;;
            3) swap_set_swappiness ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

# ══════════════════════════════════════════════════════════
#  BBR TCP 调优模块
# ══════════════════════════════════════════════════════════

# 单流 BDP 缓冲推导和 policer 拐点扫描思路参考了 tcpfit v0.5.6：
# https://github.com/Kylin010/tcpfit/tree/67c0bdfb35dd98e86982600298237b6ecc08ebe4
# (MIT, Copyright (c) 2026 Kylin010)
# 本模块保留自身的 sysctl 事务回滚、qdisc 所有权检查和多 init 持久化。
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SERVICE_TC_INIT="/etc/init.d/tc-fq"
TC_HELPER="/usr/local/libexec/vps-tools-tc-fq"
TC_STATE_FILE="/var/lib/vps-tools/tc-fq.state"
TC_BACKUP_DIR="/var/lib/vps-tools/tc-backups"
SERVICE_CWND="/etc/systemd/system/initcwnd.service"
SERVICE_CWND_INIT="/etc/init.d/initcwnd"
CWND_HELPER="/usr/local/libexec/vps-tools-initcwnd"
CWND_STATE_FILE="/var/lib/vps-tools/initcwnd.state"
SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"
BBR_BASELINE_FILE="/var/lib/vps-tools/bbr-sysctl-baseline.conf"

bbr_default_ipv6_iface() {
    local DEV
    DEV=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$DEV" ] || DEV=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || DEV=""
    printf '%s\n' "$DEV"
}

bbr_scene_keys() {
    local IPV6_IFACE
    IPV6_IFACE=$(bbr_default_ipv6_iface)
    printf '%s\n' \
        net.ipv4.ip_forward \
        net.ipv6.conf.all.forwarding \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.netfilter.nf_conntrack_max \
        net.netfilter.nf_conntrack_tcp_timeout_established \
        net.netfilter.nf_conntrack_tcp_timeout_time_wait \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_max_tw_buckets \
        net.ipv6.conf.default.accept_ra \
        fs.file-max
    [ -n "$IPV6_IFACE" ] && printf 'net.ipv6.conf.%s.accept_ra\n' "$IPV6_IFACE"
    return 0
}

bbr_retired_keys() {
    printf '%s\n' \
        vm.min_free_kbytes \
        net.ipv4.tcp_mem \
        net.ipv4.tcp_adv_win_scale \
        net.ipv4.tcp_fastopen_blackhole_timeout_sec \
        net.ipv4.tcp_ecn \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_fin_timeout \
        net.ipv4.tcp_keepalive_time
}

# 这些键只在部分配置模式中管理。模式切换后若新配置不再包含，
# 必须恢复首次调优前基线，避免运行值一直残留到重启。
bbr_conditional_keys() {
    printf '%s\n' \
        net.core.rmem_default \
        net.core.wmem_default \
        net.ipv4.tcp_window_scaling \
        net.ipv4.tcp_moderate_rcvbuf \
        net.ipv4.tcp_notsent_lowat
}

bbr_managed_keys() {
    printf '%s\n' \
        vm.swappiness \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.rmem_default \
        net.core.wmem_default \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat \
        net.ipv4.tcp_window_scaling \
        net.ipv4.tcp_moderate_rcvbuf \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.udp_rmem_min \
        net.ipv4.udp_wmem_min
    bbr_scene_keys
}

bbr_runtime_snapshot() {
    local DEST="$1" EXTRA_CONFIG="${2:-}" DIR TMP KEY VALUE CAPTURED=0
    DIR=$(dirname "$DEST")
    mkdir -p "$DIR" 2>/dev/null || return 1
    TMP=$(mktemp "${DEST}.tmp.XXXXXX") || return 1
    {
        echo "# VPS TOOLS BBR sysctl runtime snapshot"
        echo "# captured: $(date '+%Y-%m-%d %H:%M:%S')"
        while IFS= read -r KEY; do
            [ -n "$KEY" ] || continue
            if VALUE=$(sysctl -n "$KEY" 2>/dev/null); then
                printf '%s = %s\n' "$KEY" "$VALUE"
                CAPTURED=$(( CAPTURED + 1 ))
            fi
        done < <({ bbr_managed_keys; bbr_config_keys "$EXTRA_CONFIG"; } | awk '!seen[$0]++')
    } > "$TMP"
    if [ "$CAPTURED" -eq 0 ]; then
        rm -f "$TMP"
        return 1
    fi
    chmod 600 "$TMP" 2>/dev/null || true
    mv "$TMP" "$DEST" || { rm -f "$TMP"; return 1; }
}

bbr_ensure_baseline() {
    if [ ! -s "$BBR_BASELINE_FILE" ]; then
        bbr_runtime_snapshot "$BBR_BASELINE_FILE" || {
            error "无法保存 BBR 应用前运行参数基线"
            return 1
        }
        return 0
    fi

    local TMP KEY VALUE ADDED=0
    TMP=$(mktemp "${BBR_BASELINE_FILE}.tmp.XXXXXX") || return 1
    cp "$BBR_BASELINE_FILE" "$TMP" || { rm -f "$TMP"; return 1; }
    while IFS= read -r KEY; do
        [ -n "$KEY" ] || continue
        if ! bbr_baseline_value "$KEY" >/dev/null 2>&1 && VALUE=$(sysctl -n "$KEY" 2>/dev/null); then
            printf '%s = %s\n' "$KEY" "$VALUE" >> "$TMP"
            ADDED=$(( ADDED + 1 ))
        fi
    done < <(bbr_managed_keys)
    if [ "$ADDED" -eq 0 ]; then
        rm -f "$TMP"
        return 0
    fi
    chmod 600 "$TMP" && mv "$TMP" "$BBR_BASELINE_FILE" || {
        rm -f "$TMP"
        error "无法保存 BBR 应用前运行参数基线"
        return 1
    }
}

bbr_baseline_value() {
    local KEY="$1"
    [ -f "$BBR_BASELINE_FILE" ] || return 1
    awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$BBR_BASELINE_FILE"
}

bbr_restore_baseline_key() {
    local KEY="$1" VALUE
    VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null || true)
    [ -n "$VALUE" ] || { warn "基线中没有 ${KEY}，保持当前运行值"; return 1; }
    sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || {
        warn "无法恢复基线参数：${KEY}"
        return 1
    }
}

bbr_restore_runtime_snapshot() {
    local SNAPSHOT="$1" KEY VALUE FAILED=0
    [ -f "$SNAPSHOT" ] || return 1
    while IFS='=' read -r KEY VALUE; do
        KEY=$(printf '%s' "$KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        VALUE=$(printf '%s' "$VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$KEY" in ""|\#*) continue ;; esac
        sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || FAILED=1
    done < "$SNAPSHOT"
    return "$FAILED"
}

bbr_config_has_key() {
    local CONFIG="$1" KEY="$2"
    printf '%s\n' "$CONFIG" | awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs == key) found=1
        }
        END { exit !found }
    '
}

bbr_config_value() {
    local CONFIG="$1" KEY="$2"
    printf '%s\n' "$CONFIG" | awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    '
}

bbr_config_keys() {
    printf '%s\n' "$1" | awk -F= '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs ~ /^[[:alnum:]_.-]+$/) print lhs
        }
    '
}

bbr_config_dynamic_scene_keys() {
    bbr_config_keys "$1" | awk '/^net\.ipv6\.conf\..+\.accept_ra$/ { print }'
}

# ── 状态显示 ──────────────────────────────────────────────
bbr_print_status() {
    local DEV TC_BIN RATE
    DEV=$(default_iface)
    TC_BIN=$(command -v tc 2>/dev/null || true)
    RATE="未设置"
    [ -z "$TC_BIN" ] || RATE=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local CWND
    CWND=$(ip -4 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
    [ -n "$CWND" ] || CWND=$(ip -6 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
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
    # 检测缓冲区是否超过物理内存四分之一（显示警告）
    local MEM_TOTAL_MB
    MEM_TOTAL_MB=$(bbr_physical_memory_mb)
    local RMEM_COLOR WMEM_COLOR
    RMEM_COLOR="$BOLD"
    WMEM_COLOR="$BOLD"
    if [ "${MEM_TOTAL_MB:-0}" -gt 0 ]; then
        [ "$RMEM_MB" -gt $(( MEM_TOTAL_MB / 4 )) ] && RMEM_COLOR="${YELLOW}${BOLD}"
        [ "$WMEM_MB" -gt $(( MEM_TOTAL_MB / 4 )) ] && WMEM_COLOR="${YELLOW}${BOLD}"
    fi
    echo -e "  ${CYAN}缓冲${NC} rmem ${RMEM_COLOR}${RMEM_MB}MB${NC}  wmem ${WMEM_COLOR}${WMEM_MB}MB${NC}  tcp_r ${BOLD}${TCP_RMEM_MB}MB${NC}  tcp_w ${BOLD}${TCP_WMEM_MB}MB${NC}  ${DIM}物理内存 ${MEM_TOTAL_MB}MB${NC}"
}

# ── 备份 sysctl ───────────────────────────────────────────
bbr_backup_sysctl() {
    local BAK CURRENT_CONFIG=""
    BAK="${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    [ -e "$BAK" ] && BAK="${BAK}.$$"
    [ ! -f "$SYSCTL_FILE" ] || CURRENT_CONFIG=$(cat "$SYSCTL_FILE")
    if bbr_runtime_snapshot "$BAK" "$CURRENT_CONFIG"; then
        info "已备份当前运行参数至：$BAK"
    else
        error "BBR 运行参数备份失败"
        return 1
    fi
}

# ── 还原 sysctl ───────────────────────────────────────────
bbr_restore_sysctl() {
    print_header "还原 TCP sysctl 配置"

    local LIST_FILE
    LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/vps_bbr_bak.XXXXXX") || { error "无法创建备份列表"; return 1; }
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
    read -rp "$(ui_prompt '选择备份编号: ')" CH

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
                local T CONFIG
                T=$(sed -n "${CH}p" "$LIST_FILE")
                CONFIG=$(cat "$T")
                if bbr_apply_sysctl "$CONFIG" baseline; then
                    info "已还原运行参数：$(basename "$T") ✓"
                else
                    error "还原未完全成功，请查看上方失败参数"
                fi
            else
                error "无效选项"
            fi
            ;;
    esac
    rm -f "$LIST_FILE"
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() {
    local CONFIG="$1" STALE_MODE="${2:-ask}" TX_SNAPSHOT SNAPSHOT_CONFIG="$1"
    ensure_sysctl || return 1
    bbr_ensure_baseline || return 1
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || return 1
    TX_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/vps-bbr-transaction.XXXXXX") || {
        error "无法创建 BBR 回滚快照"
        return 1
    }
    [ ! -f "$SYSCTL_FILE" ] || SNAPSHOT_CONFIG="${SNAPSHOT_CONFIG}"$'\n'"$(cat "$SYSCTL_FILE")"
    if ! bbr_runtime_snapshot "$TX_SNAPSHOT" "$SNAPSHOT_CONFIG"; then
        rm -f "$TX_SNAPSHOT"
        error "无法保存 BBR 应用前快照"
        return 1
    fi

    # 新版本不再管理这些高风险或已废弃参数；升级时立即恢复首次基线。
    if [ -f "$SYSCTL_FILE" ]; then
        local RETIRED_STALE="" RETIRED_FAILED=0 k
        for k in $(bbr_retired_keys); do
            if bbr_config_has_key "$(cat "$SYSCTL_FILE")" "$k" && ! bbr_config_has_key "$CONFIG" "$k"; then
                RETIRED_STALE="$RETIRED_STALE $k"
            fi
        done
        if [ -n "$RETIRED_STALE" ]; then
            info "正在恢复旧版激进参数到首次调优前基线"
            for k in $RETIRED_STALE; do
                bbr_restore_baseline_key "$k" || RETIRED_FAILED=1
            done
            if [ "$RETIRED_FAILED" -ne 0 ]; then
                warn "部分旧参数缺少基线，当前值将保留到重启；新配置不会再持久化这些参数"
            fi
        fi
    fi

    # 不同调优模式会管理不同的缓冲起始值。离开某个模式时精确回基线，
    # 不把“上一次的值”当成新模式的隐式配置。
    if [ -f "$SYSCTL_FILE" ]; then
        local CONDITIONAL_STALE="" CONDITIONAL_FAILED=0
        for k in $(bbr_conditional_keys); do
            if bbr_config_has_key "$(cat "$SYSCTL_FILE")" "$k" && ! bbr_config_has_key "$CONFIG" "$k"; then
                CONDITIONAL_STALE="$CONDITIONAL_STALE $k"
            fi
        done
        if [ -n "$CONDITIONAL_STALE" ]; then
            info "正在恢复上一调优模式的条件参数"
            for k in $CONDITIONAL_STALE; do
                bbr_restore_baseline_key "$k" || CONDITIONAL_FAILED=1
            done
            if [ "$CONDITIONAL_FAILED" -ne 0 ]; then
                warn "部分条件参数缺少基线，当前值将保留到重启"
            fi
        fi
    fi

    # ── 切换预设时复位「旧配置写过、但新配置不再包含」的场景专有键 ──
    # 否则从中转/落地降级回普通预设后，ip_forward / conntrack 等会一直残留在内核里。
    # 仅复位本脚本场景预设管理的键，且新配置确实不含该键时才动；ip_forward 谨慎处理。
    if [ -f "$SYSCTL_FILE" ]; then
        local SCENE_KEYS
        SCENE_KEYS=$({ bbr_scene_keys; bbr_config_dynamic_scene_keys "$(cat "$SYSCTL_FILE")"; } | awk '!seen[$0]++')
        local k STALE=""
        for k in $SCENE_KEYS; do
            # 旧文件里有该键，但新配置里没有 → 视为需要清理的残留
            if bbr_config_has_key "$(cat "$SYSCTL_FILE")" "$k" && ! bbr_config_has_key "$CONFIG" "$k"; then
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
            local DORST="n"
            if [ "$STALE_MODE" = baseline ]; then
                DORST="y"
            else
                read -rp "  是否恢复这些残留参数到首次调优前基线？(y/N，默认N): " DORST
                [ -z "$DORST" ] && DORST="n"
            fi
            if echo "$DORST" | grep -qiE '^y(es)?$'; then
                local RESTORE_FAILED=0
                for k in $STALE; do
                    bbr_restore_baseline_key "$k" || RESTORE_FAILED=1
                done
                if [ "$RESTORE_FAILED" -eq 0 ]; then
                    info "残留场景参数已恢复到首次调优前基线"
                else
                    warn "部分残留参数缺少基线或恢复失败，已保持原值"
                fi
            else
                warn "保留残留参数（仍生效于当前内核）"
            fi
        fi
    fi

    # 逐行应用并生成持久化文件；不支持的参数写成注释，避免重启时 sysctl 报错。
    local SKIPPED=0 CORE_FAILED=0 TMP_FILE
    TMP_FILE=$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX") || {
        rm -f "$TX_SNAPSHOT"
        error "无法创建 sysctl 临时配置"
        return 1
    }
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^[[:space:]]*#|^[[:space:]]*$'; then
            echo "$line" >> "$TMP_FILE"
            continue
        fi
        local KEY VAL
        KEY=$(printf '%s' "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        VAL=$(printf '%s' "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if sysctl -w "${KEY}=${VAL}" > /dev/null 2>&1; then
            echo "$line" >> "$TMP_FILE"
        else
            warn "跳过不支持的参数：${KEY}"
            echo "# skipped unsupported: $line" >> "$TMP_FILE"
            SKIPPED=$(( SKIPPED + 1 ))
            case "$KEY" in
                net.core.default_qdisc|net.ipv4.tcp_congestion_control) CORE_FAILED=1 ;;
            esac
        fi
    done <<< "$CONFIG"

    if [ "$CORE_FAILED" -eq 0 ]; then
        local EXPECTED_CC EXPECTED_QDISC ACTIVE_CC ACTIVE_QDISC
        EXPECTED_CC=$(bbr_config_value "$CONFIG" net.ipv4.tcp_congestion_control 2>/dev/null || true)
        EXPECTED_QDISC=$(bbr_config_value "$CONFIG" net.core.default_qdisc 2>/dev/null || true)
        if [ -n "$EXPECTED_CC" ]; then
            ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
            [ "$ACTIVE_CC" = "$EXPECTED_CC" ] || CORE_FAILED=1
        fi
        if [ -n "$EXPECTED_QDISC" ]; then
            ACTIVE_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
            [ "$ACTIVE_QDISC" = "$EXPECTED_QDISC" ] || CORE_FAILED=1
        fi
        if [ "$CORE_FAILED" -ne 0 ]; then
            error "BBR 核心参数写入后回读不一致：cc=${ACTIVE_CC:-未校验}/${EXPECTED_CC:-未设置} qdisc=${ACTIVE_QDISC:-未校验}/${EXPECTED_QDISC:-未设置}"
        fi
    fi

    if [ "$CORE_FAILED" -eq 1 ]; then
        rm -f "$TMP_FILE"
        bbr_restore_runtime_snapshot "$TX_SNAPSHOT" || warn "部分运行参数自动回滚失败"
        rm -f "$TX_SNAPSHOT"
        error "BBR 核心参数未能完整启用，已回滚本次参数修改"
        return 1
    fi
    if ! mv "$TMP_FILE" "$SYSCTL_FILE"; then
        rm -f "$TMP_FILE"
        bbr_restore_runtime_snapshot "$TX_SNAPSHOT" || warn "部分运行参数自动回滚失败"
        rm -f "$TX_SNAPSHOT"
        error "无法更新 ${SYSCTL_FILE}，已回滚本次参数修改"
        return 1
    fi
    rm -f "$TX_SNAPSHOT"

    if [ "$SKIPPED" -gt 0 ]; then
        warn "共跳过 ${SKIPPED} 个不支持的参数（已在配置文件中注释，重启后不报错）"
    fi
    [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved || true
    info "sysctl 配置已应用到 ${SYSCTL_FILE} ✓"
    return 0
}

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_tc_qdisc_type() {
    awk 'NR==1 { print $2 }' <<< "$1"
}

bbr_tc_qdisc_handle() {
    awk 'NR==1 { print $3 }' <<< "$1"
}

bbr_tc_root_line() {
    awk '
        $1 == "qdisc" {
            for (i = 4; i <= NF; i++) {
                if ($i == "root") { print; exit }
            }
        }
    ' <<< "$1"
}

bbr_tc_qdisc_safe_to_replace() {
    case "$1" in
        ""|mq|fq|fq_codel|noqueue|pfifo_fast) return 0 ;;
        *) return 1 ;;
    esac
}

bbr_tc_current_rate() {
    local DEV="$1" TC_BIN="$2" RATE
    RATE=$("$TC_BIN" class show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null | grep -oE 'maxrate [^ ]+' | head -1 | awk '{print $2}')
    printf '%s\n' "$RATE"
}

bbr_tc_saved_values() {
    local DEV RATE BURST_KB FORCE
    DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    RATE=$(bbr_state_value "$TC_STATE_FILE" RATE 2>/dev/null || true)
    BURST_KB=$(bbr_state_value "$TC_STATE_FILE" BURST_KB 2>/dev/null || true)
    FORCE=$(bbr_state_value "$TC_STATE_FILE" FORCE 2>/dev/null || true)
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    echo "$RATE" | grep -qE '^[0-9]+$' || return 1
    echo "$BURST_KB" | grep -qE '^[0-9]+$' || return 1
    [ "$RATE" -gt 0 ] && [ "$BURST_KB" -gt 0 ] || return 1
    case "$FORCE" in 0|1) : ;; *) FORCE=0 ;; esac
    printf '%s %s %s %s\n' "$DEV" "$RATE" "$BURST_KB" "$FORCE"
}

bbr_tc_saved_rate_display() {
    local CURRENT_DEV="$1" SAVED_VALUES SAVED_DEV SAVED_RATE
    SAVED_VALUES=$(bbr_tc_saved_values) || return 1
    SAVED_DEV=${SAVED_VALUES%% *}
    SAVED_RATE=${SAVED_VALUES#* }
    SAVED_RATE=${SAVED_RATE%% *}
    if [ "$SAVED_DEV" = "$CURRENT_DEV" ]; then
        printf '%sMbit（已保存，未生效）\n' "$SAVED_RATE"
    else
        printf '%sMbit（保存于 %s，当前未生效）\n' "$SAVED_RATE" "$SAVED_DEV"
    fi
}

bbr_tc_rate_display() {
    local DEV="$1" TC_BIN="$2" RATE QDISCS LINE TYPE SAVED_RATE
    RATE=$(bbr_tc_current_rate "$DEV" "$TC_BIN")
    if [ -z "$RATE" ]; then
        SAVED_RATE=$(bbr_tc_saved_rate_display "$DEV" 2>/dev/null || true)
        [ -z "$SAVED_RATE" ] && echo "未设置" || echo "$SAVED_RATE"
        return
    fi
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$LINE")
    if ! bbr_tc_is_owned "$DEV" "$TC_BIN" \
        && ! bbr_tc_is_legacy_owned "$DEV" "$TC_BIN" \
        && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        printf '%s（外部 %s）\n' "$RATE" "${TYPE:-未知}"
    else
        printf '%s\n' "$RATE"
    fi
}

bbr_tc_snapshot_foreign() {
    local DEV="$1" TC_BIN="$2" TMP SNAPSHOT STAMP
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    mkdir -p "$TC_BACKUP_DIR" 2>/dev/null || return 1
    chmod 700 "$TC_BACKUP_DIR" 2>/dev/null || true
    STAMP=$(date '+%Y%m%d_%H%M%S')
    SNAPSHOT="$TC_BACKUP_DIR/${DEV}_${STAMP}_$$.txt"
    TMP="${SNAPSHOT}.tmp"
    {
        printf 'VPS TOOLS foreign tc snapshot\n'
        printf 'Captured: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'Device: %s\n\n' "$DEV"
        printf '[qdisc]\n'
        "$TC_BIN" qdisc show dev "$DEV" 2>&1 || true
        printf '\n[class]\n'
        "$TC_BIN" class show dev "$DEV" 2>&1 || true
        printf '\n[filter]\n'
        "$TC_BIN" filter show dev "$DEV" 2>&1 || true
        printf '\n[qdisc-json]\n'
        "$TC_BIN" -j qdisc show dev "$DEV" 2>&1 || true
        printf '\n[class-json]\n'
        "$TC_BIN" -j class show dev "$DEV" 2>&1 || true
        printf '\n[filter-json]\n'
        "$TC_BIN" -j filter show dev "$DEV" 2>&1 || true
    } > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 600 "$TMP" && mv "$TMP" "$SNAPSHOT" || { rm -f "$TMP"; return 1; }
    printf '%s\n' "$SNAPSHOT"
}

bbr_tc_force_confirm() {
    local DEV="$1" RATE="$2" TC_BIN="$3" QDISCS CLASSES FILTERS CONFIRM
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    FILTERS=$("$TC_BIN" filter show dev "$DEV" 2>/dev/null || true)
    echo ""
    menu_div
    warn "强制接管会删除 ${DEV} 的全部 root qdisc、子 class 和 filter"
    warn "现有 QoS 无法通用自动恢复；重启后本工具仍会覆盖外部 qdisc"
    echo -e "  ${DIM}目标限速：${RATE} Mbps${NC}"
    echo -e "  ${DIM}当前 qdisc：${NC}"
    printf '%s\n' "$QDISCS" | sed 's/^/    /'
    [ -z "$CLASSES" ] || { echo -e "  ${DIM}当前 class：${NC}"; printf '%s\n' "$CLASSES" | sed 's/^/    /'; }
    [ -z "$FILTERS" ] || { echo -e "  ${DIM}当前 filter：${NC}"; printf '%s\n' "$FILTERS" | sed 's/^/    /'; }
    menu_div
    echo ""
    read -rp "  输入 FORCE ${DEV} 确认强制覆盖: " CONFIRM
    if [ "$CONFIRM" != "FORCE ${DEV}" ]; then
        warn "确认词不匹配，已取消强制覆盖"
        return 1
    fi
    return 0
}

bbr_tc_remove_confirm() {
    local DEV="$1" TC_BIN="$2" QDISCS CLASSES FILTERS CONFIRM
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    FILTERS=$("$TC_BIN" filter show dev "$DEV" 2>/dev/null || true)
    echo ""
    menu_div
    warn "检测到 ${DEV} 仍有非本工具管理的 root qdisc"
    warn "删除会清除该 root qdisc 的全部子 class 和 filter；clsact 不受影响"
    echo -e "  ${DIM}当前 qdisc：${NC}"
    printf '%s\n' "$QDISCS" | sed 's/^/    /'
    [ -z "$CLASSES" ] || { echo -e "  ${DIM}当前 class：${NC}"; printf '%s\n' "$CLASSES" | sed 's/^/    /'; }
    [ -z "$FILTERS" ] || { echo -e "  ${DIM}当前 filter：${NC}"; printf '%s\n' "$FILTERS" | sed 's/^/    /'; }
    menu_div
    echo ""
    read -rp "  输入 DELETE ${DEV} 确认删除外部限速: " CONFIRM
    if [ "$CONFIRM" != "DELETE ${DEV}" ]; then
        warn "确认词不匹配，外部 qdisc 已保留"
        return 1
    fi
    return 0
}

bbr_state_value() {
    local FILE="$1" KEY="$2"
    [ -f "$FILE" ] || return 1
    awk -F= -v key="$KEY" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$FILE"
}

bbr_tc_topology_matches() {
    local DEV="$1" TC_BIN="$2" QDISCS CLASSES
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null) || return 1
    printf '%s\n' "$QDISCS" | awk '
        $1 == "qdisc" && $2 == "htb" && $3 == "1:" {
            for (i = 4; i <= NF; i++) if ($i == "root") root = 1
        }
        $1 == "qdisc" && $2 == "fq" && $3 == "100:" {
            for (i = 4; i < NF; i++) if ($i == "parent" && $(i + 1) == "1:10") leaf = 1
        }
        END { exit !(root && leaf) }
    ' || return 1
    printf '%s\n' "$CLASSES" | awk '
        $1 == "class" && $2 == "htb" && $3 == "1:10" { found = 1 }
        END { exit !found }
    '
}

bbr_tc_managed_artifact() {
    if [ -f "$SERVICE_TC" ] && grep -qE \
        '^Description=(VPS TOOLS TC egress shaping|TC egress shaping .+htb shape \+ fq pacing for BBR)' \
        "$SERVICE_TC" 2>/dev/null; then
        return 0
    fi
    if [ -f "$TC_HELPER" ] && grep -qF 'STATE=/var/lib/vps-tools/tc-fq.state' "$TC_HELPER" 2>/dev/null; then
        return 0
    fi
    [ -f "$SERVICE_TC_INIT" ] \
        && grep -qE 'VPS TOOLS network tuning|vps-tools-tc-fq' "$SERVICE_TC_INIT" 2>/dev/null
}

bbr_tc_is_owned() {
    local DEV="$1" TC_BIN="$2" STATE_DEV
    STATE_DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    [ "$STATE_DEV" = "$DEV" ] || return 1
    bbr_tc_topology_matches "$DEV" "$TC_BIN"
}

bbr_tc_is_legacy_owned() {
    local DEV="$1" TC_BIN="$2"
    bbr_tc_managed_artifact || return 1
    bbr_tc_topology_matches "$DEV" "$TC_BIN"
}

bbr_tc_restore_owned() {
    if [ -x "$TC_HELPER" ] && "$TC_HELPER" apply >/dev/null 2>&1; then
        return 0
    fi
    if systemd_available && [ -f "$SERVICE_TC" ]; then
        systemctl restart tc-fq >/dev/null 2>&1 && return 0
    elif command -v rc-service >/dev/null 2>&1 && [ -f "$SERVICE_TC_INIT" ]; then
        rc-service tc-fq restart >/dev/null 2>&1 && return 0
    elif command -v service >/dev/null 2>&1 && [ -f "$SERVICE_TC_INIT" ]; then
        service tc-fq restart >/dev/null 2>&1 && return 0
    fi
    return 1
}

bbr_tc_persistence_current() {
    [ -x "$TC_HELPER" ] \
        && grep -qxF '# VPS_TOOLS_TC_HELPER_VERSION=2' "$TC_HELPER" 2>/dev/null
}

bbr_tc_reconcile_saved() {
    local CURRENT_DEV SAVED_VALUES SAVED_REST SAVED_DEV SAVED_RATE SAVED_BURST SAVED_FORCE TC_BIN
    [ "${VPS_TOOLS_TEST_MODE:-0}" != 1 ] || return 2
    [ "${BBR_TUNE_TEST_MODE:-0}" != 1 ] || return 2
    SAVED_VALUES=$(bbr_tc_saved_values) || return 2
    SAVED_DEV=${SAVED_VALUES%% *}
    SAVED_REST=${SAVED_VALUES#* }
    SAVED_RATE=${SAVED_REST%% *}
    SAVED_REST=${SAVED_REST#* }
    SAVED_BURST=${SAVED_REST%% *}
    SAVED_FORCE=${SAVED_REST##* }
    CURRENT_DEV=$(default_iface)
    if [ "$SAVED_DEV" != "$CURRENT_DEV" ]; then
        warn "已保存 ${SAVED_DEV} 的 ${SAVED_RATE}Mbps 限速，但当前默认网卡为 ${CURRENT_DEV:-未知}，未自动迁移"
        return 1
    fi
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$TC_BIN" ] || { warn "已保存 ${SAVED_RATE}Mbps 限速，但 tc 命令不可用"; return 1; }
    if bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
        bbr_tc_persistence_current && return 0
        if bbr_tc_write_persistence "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$SAVED_FORCE" \
            && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
            info "检测到旧版 tc 持久化配置，已自动升级 ✓"
            return 0
        fi
        warn "tc 限速当前有效，但持久化配置升级失败"
        return 1
    fi
    if bbr_tc_persistence_current \
        && bbr_tc_restore_owned \
        && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
        info "检测到已保存的 ${SAVED_RATE}Mbps 限速未生效，已自动恢复 ✓"
        return 0
    fi
    if bbr_tc_apply_runtime "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$TC_BIN" "$SAVED_FORCE"; then
        if bbr_tc_write_persistence "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$SAVED_FORCE" \
            && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
            info "检测到已保存的 ${SAVED_RATE}Mbps 限速未生效，已自动恢复并升级持久化配置 ✓"
            return 0
        fi
        warn "tc 限速已恢复运行，但持久化配置更新失败"
        return 1
    fi
    warn "已保存 ${SAVED_RATE}Mbps 限速，但自动恢复失败"
    echo -e "  ${DIM}可检查：${TC_HELPER} apply && tc -s qdisc show dev ${SAVED_DEV}${NC}"
    return 1
}

bbr_tc_apply_runtime() {
    local DEV="$1" RATE="$2" BURST_KB="$3" TC_BIN="$4" FORCE="${5:-0}"
    local QDISCS LINE TYPE WAS_OWNED=0 FORCED_FOREIGN=0 SNAPSHOT="" ROOT_ACTION=add
    if ! QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null); then
        error "无法读取 ${DEV} 的当前 tc 配置，已拒绝修改"
        return 1
    fi
    LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$LINE")
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        WAS_OWNED=1
    elif bbr_tc_is_legacy_owned "$DEV" "$TC_BIN"; then
        WAS_OWNED=1
        info "识别到旧版 VPS Tools tc 限速规则，将自动迁移"
    fi
    if [ "$WAS_OWNED" -eq 0 ] && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        if [ "$FORCE" != 1 ]; then
            error "检测到非本工具管理的 root qdisc：${TYPE:-未知}，需要强制确认"
            echo -e "  ${DIM}默认不会覆盖；确认后可由本工具强制接管${NC}"
            return 2
        fi
        SNAPSHOT=$(bbr_tc_snapshot_foreign "$DEV" "$TC_BIN") || {
            error "无法保存现有 tc 诊断快照，已拒绝强制覆盖"
            return 1
        }
        FORCED_FOREIGN=1
        warn "已保存现有 tc 诊断快照：${SNAPSHOT}"
    fi

    if [ -n "$LINE" ]; then
        if [ "$WAS_OWNED" -eq 0 ] && [ "$FORCED_FOREIGN" -eq 0 ]; then
            # mq/noqueue 等内核默认 qdisc 不能可靠 del，replace 可原子接管 root。
            ROOT_ACTION=replace
        elif ! "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null; then
            error "无法删除 ${DEV} 的现有 root qdisc"
            return 1
        fi
    fi

    if ! "$TC_BIN" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 2>/dev/null; then
        error "无法在 ${DEV} 安装 HTB root qdisc（内核可能缺 sch_htb 模块）"
        if [ "$WAS_OWNED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "旧 tc 限速规则自动恢复失败"
        elif [ "$FORCED_FOREIGN" -eq 1 ]; then
            warn "外部 qdisc 已删除且无法通用自动恢复，请按原管理工具重建"
            warn "删除前诊断快照：${SNAPSHOT}"
        fi
        return 1
    fi
    if ! "$TC_BIN" class add dev "$DEV" parent 1: classid 1:10 htb \
                rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        || ! "$TC_BIN" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null; then
        error "tc 规则应用失败（内核可能缺 sch_htb / sch_fq 模块）"
        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || true
        if [ "$WAS_OWNED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "旧 tc 限速规则自动恢复失败"
        elif [ "$FORCED_FOREIGN" -eq 1 ]; then
            warn "外部 qdisc 已删除且无法通用自动恢复，请按原管理工具重建"
            warn "删除前诊断快照：${SNAPSHOT}"
        fi
        return 1
    fi
    [ "$FORCED_FOREIGN" -eq 0 ] || warn "已强制接管 ${DEV} 的 root qdisc"
    return 0
}

bbr_tc_write_persistence() {
    local DEV="$1" RATE="$2" BURST_KB="$3" FORCE="${4:-0}" TMP
    mkdir -p "$(dirname "$TC_HELPER")" "$(dirname "$TC_STATE_FILE")" 2>/dev/null || {
        error "无法创建 tc 持久化目录"
        return 1
    }
    TMP=$(mktemp "${TC_STATE_FILE}.tmp.XXXXXX") || return 1
    printf 'DEV=%s\nRATE=%s\nBURST_KB=%s\nFORCE=%s\n' "$DEV" "$RATE" "$BURST_KB" "$FORCE" > "$TMP" || {
        rm -f "$TMP"
        return 1
    }
    chmod 600 "$TMP" && mv "$TMP" "$TC_STATE_FILE" || { rm -f "$TMP"; return 1; }

    TMP=$(mktemp "${TC_HELPER}.tmp.XXXXXX") || return 1
    cat > "$TMP" << 'TC_HELPER_EOF'
#!/bin/sh
# VPS_TOOLS_TC_HELPER_VERSION=2
STATE=/var/lib/vps-tools/tc-fq.state
state_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE"; }
DEV=$(state_value DEV)
RATE=$(state_value RATE)
BURST_KB=$(state_value BURST_KB)
FORCE=$(state_value FORCE)
[ "$FORCE" = 1 ] || FORCE=0
TC=$(command -v tc 2>/dev/null || echo /sbin/tc)
[ -n "$DEV" ] && echo "$RATE" | grep -qE '^[0-9]+$' && echo "$BURST_KB" | grep -qE '^[0-9]+$' || exit 1
QDISCS=$("$TC" qdisc show dev "$DEV" 2>/dev/null)
CLASSES=$("$TC" class show dev "$DEV" 2>/dev/null)
LINE=$(printf '%s\n' "$QDISCS" | awk '$1 == "qdisc" { for (i=4; i<=NF; i++) if ($i == "root") { print; exit } }')
TYPE=$(printf '%s\n' "$LINE" | awk 'NR==1 { print $2 }')
OWNED=0
if printf '%s\n' "$QDISCS" | awk '
    $1 == "qdisc" && $2 == "htb" && $3 == "1:" { for (i=4; i<=NF; i++) if ($i == "root") root=1 }
    $1 == "qdisc" && $2 == "fq" && $3 == "100:" { for (i=4; i<NF; i++) if ($i == "parent" && $(i+1) == "1:10") leaf=1 }
    END { exit !(root && leaf) }
' && printf '%s\n' "$CLASSES" | awk '$1 == "class" && $2 == "htb" && $3 == "1:10" { found=1 } END { exit !found }'; then
    OWNED=1
fi
if [ "${1:-apply}" = remove ]; then
    [ "$OWNED" -eq 0 ] || "$TC" qdisc del dev "$DEV" root
    exit $?
fi
if [ "${1:-apply}" = status ]; then
    [ "$OWNED" -eq 1 ]
    exit $?
fi
ROOT_ACTION=add
case "$TYPE" in
    ""|mq|fq|fq_codel|noqueue|pfifo_fast) ROOT_ACTION=replace ;;
    htb) [ "$OWNED" -eq 1 ] || [ "$FORCE" -eq 1 ] || exit 1 ;;
    *) [ "$FORCE" -eq 1 ] || exit 1 ;;
esac
if [ "$OWNED" -eq 1 ] || { [ -n "$LINE" ] && [ "$ROOT_ACTION" != replace ]; }; then
    "$TC" qdisc del dev "$DEV" root 2>/dev/null || exit 1
fi
"$TC" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 && \
"$TC" class add dev "$DEV" parent 1: classid 1:10 htb rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" && \
"$TC" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit"
TC_HELPER_EOF
    chmod 700 "$TMP" && mv "$TMP" "$TC_HELPER" || { rm -f "$TMP"; return 1; }

    if systemd_available; then
        TMP=$(mktemp "${SERVICE_TC}.tmp.XXXXXX") || return 1
        cat > "$TMP" << EOF
[Unit]
Description=VPS TOOLS TC egress shaping
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${TC_HELPER} apply
ExecStop=${TC_HELPER} remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        mv "$TMP" "$SERVICE_TC" || { rm -f "$TMP"; return 1; }
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable tc-fq --quiet >/dev/null 2>&1 \
            && systemctl restart tc-fq >/dev/null 2>&1 || {
                error "tc 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" openrc || return 1
        rc-update add tc-fq default >/dev/null 2>&1 \
            && rc-service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" sysv || return 1
        update-rc.d tc-fq defaults >/dev/null 2>&1 \
            && service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 SysV 持久化失败"
                return 1
            }
    else
        error "tc 已立即生效，但未检测到支持的服务管理器，无法设置开机恢复"
        return 1
    fi
}

bbr_write_init_script() {
    local DEST="$1" HELPER="$2" MODE="$3" TMP
    TMP=$(mktemp "${DEST}.tmp.XXXXXX") || return 1
    if [ "$MODE" = openrc ]; then
        cat > "$TMP" << EOF
#!/sbin/openrc-run
description="VPS TOOLS network tuning"
depend() { need net; }
start() { ebegin "Applying VPS TOOLS network tuning"; ${HELPER} apply; eend \$?; }
stop() { ebegin "Stopping VPS TOOLS network tuning"; ${HELPER} remove; eend \$?; }
status() { ${HELPER} status; }
EOF
    else
        cat > "$TMP" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $(basename "$DEST")
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: VPS TOOLS network tuning
### END INIT INFO
case "\${1:-start}" in
    start|restart) ${HELPER} apply ;;
    stop) ${HELPER} remove ;;
    status) ${HELPER} status ;;
    *) echo "Usage: \$0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
EOF
    fi
    chmod 755 "$TMP" && mv "$TMP" "$DEST" || { rm -f "$TMP"; return 1; }
}

bbr_apply_tc() {
    local RATE="$1" FORCE="${2:-0}" APPLY_RC
    local DEV; DEV=$(default_iface)
    [ -z "$DEV" ] && { error "无法确定默认出口网卡"; return 1; }
    local TC_BIN
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$TC_BIN" ] || { error "tc 命令不可用，请先安装 iproute2"; return 1; }

    # burst/cburst 随速率缩放（约 8ms 量级，≈ RATE KB），下限 32KB。
    # 固定 burst 会在高速率下令牌饥饿，导致跑不满设定速率。
    local BURST_KB=$RATE
    [ "$BURST_KB" -lt 32 ] && BURST_KB=32

    bbr_tc_apply_runtime "$DEV" "$RATE" "$BURST_KB" "$TC_BIN" "$FORCE"
    APPLY_RC=$?
    [ "$APPLY_RC" -eq 0 ] || return "$APPLY_RC"
    bbr_tc_write_persistence "$DEV" "$RATE" "$BURST_KB" "$FORCE" || {
        error "tc 已立即生效，但持久化配置未完成"
        return 1
    }
    info "tc 限速已应用：${RATE}Mbps（htb 聚合整形 + fq pacing，burst ${BURST_KB}KB）✓"
    return 0
}

bbr_remove_tc() {
    local FORCE="${1:-0}" TC_BIN DEV FAILED=0 FOREIGN=0 QDISCS LINE TYPE SNAPSHOT=""
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    [ -n "$DEV" ] || DEV=$(default_iface)
    if [ -x "$TC_BIN" ] && [ -n "$DEV" ]; then
        if bbr_tc_is_owned "$DEV" "$TC_BIN" || bbr_tc_is_legacy_owned "$DEV" "$TC_BIN"; then
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || FAILED=1
        else
            QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
            LINE=$(bbr_tc_root_line "$QDISCS")
            TYPE=$(bbr_tc_qdisc_type "$LINE")
            if [ -n "$LINE" ] && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
                if [ "$FORCE" = 1 ]; then
                    SNAPSHOT=$(bbr_tc_snapshot_foreign "$DEV" "$TC_BIN") || FAILED=1
                    if [ "$FAILED" -eq 0 ]; then
                        warn "已保存外部 tc 诊断快照：${SNAPSHOT}"
                        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || FAILED=1
                    fi
                else
                    FOREIGN=1
                fi
            fi
        fi
    fi

    if systemd_available; then
        systemctl disable --now tc-fq >/dev/null 2>&1 || true
        rm -f "$SERVICE_TC"
        systemctl daemon-reload >/dev/null 2>&1 || FAILED=1
    elif command -v rc-update >/dev/null 2>&1; then
        rc-service tc-fq stop >/dev/null 2>&1 || true
        rc-update del tc-fq default >/dev/null 2>&1 || true
    elif command -v update-rc.d >/dev/null 2>&1; then
        service tc-fq stop >/dev/null 2>&1 || true
        update-rc.d -f tc-fq remove >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_TC_INIT" "$TC_HELPER" "$TC_STATE_FILE"
    if [ "$FAILED" -ne 0 ]; then
        error "取消 tc 限速时发生错误"
        return 1
    fi
    if [ "$FOREIGN" -eq 1 ]; then
        warn "本工具的 tc 持久化已取消，但外部 root qdisc ${TYPE:-未知} 仍在生效"
        return 2
    fi
    [ "$FORCE" != 1 ] || info "外部 root qdisc 已删除 ✓"
    info "已取消本工具管理的 tc 限速 ✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
# ── 单流 iperf3 / policer 拐点扫描 ─────────────────────
# 扫描只允许临时替换内核默认 qdisc 或本工具自己的 HTB；第三方 QoS 一律拒绝。
BBR_SWEEP_QSAVE_IFACE=""
BBR_SWEEP_QSAVE_KIND=""
BBR_SWEEP_QSAVE_LEAF_KIND=""
BBR_SWEEP_QSAVE_TC=""
BBR_SWEEP_QSAVE_OWNED=0
BBR_SWEEP_IPERF_PID=""
BBR_IPERF_RESULT=""
BBR_SWEEP_LAST_OK=""
BBR_SWEEP_BROKE_AT=""
BBR_SWEEP_BASE_LOSS=""
BBR_SWEEP_PEER_SLOW=0
BBR_SWEEP_POINT_GOODPUT=""
BBR_SWEEP_POINT_LOSS=""
BBR_SWEEP_RECOMMEND=""
BBR_SWEEP_KNEE=""
BBR_SWEEP_TRAFFIC_RX0=""
BBR_SWEEP_TRAFFIC_TX0=""

bbr_tc_root_kind() {
    local DEV="$1" TC_BIN="$2" QDISCS LINE
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    LINE=$(bbr_tc_root_line "$QDISCS")
    bbr_tc_qdisc_type "$LINE"
}

bbr_tc_mq_leaf_kind() {
    local DEV="$1" TC_BIN="$2" QDISCS HANDLE MAJOR KINDS COUNT
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    HANDLE=$(printf '%s\n' "$QDISCS" | awk '
        $1 == "qdisc" && $2 == "mq" {
            for (i=1; i<=NF; i++) if ($i == "root") { print $3; exit }
        }
    ')
    MAJOR=${HANDLE%:}
    [ -n "$MAJOR" ] || return 1
    KINDS=$(printf '%s\n' "$QDISCS" | awk -v major="$MAJOR" '
        $1 == "qdisc" && $0 ~ / parent / {
            for (i=1; i<=NF; i++) if ($i == "parent") {
                parent=$(i+1)
                if ((major == "0" && (parent ~ /^:/ || index(parent, "0:") == 1)) ||
                    (major != "0" && index(parent, major ":") == 1)) {
                    if (!seen[$2]++) print $2
                }
                break
            }
        }
    ')
    COUNT=$(printf '%s\n' "$KINDS" | awk 'NF { count++ } END { print count+0 }')
    [ "$COUNT" -le 1 ] || return 2
    printf '%s\n' "$KINDS"
}

bbr_tc_set_mq_leaves() {
    local DEV="$1" KIND="$2" TC_BIN="$3" QDISCS HANDLE MAJOR PARENTS PARENT
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    HANDLE=$(printf '%s\n' "$QDISCS" | awk '
        $1 == "qdisc" && $2 == "mq" {
            for (i=1; i<=NF; i++) if ($i == "root") { print $3; exit }
        }
    ')
    MAJOR=${HANDLE%:}
    if [ -z "$MAJOR" ] || [ "$MAJOR" = 0 ]; then
        "$TC_BIN" qdisc replace dev "$DEV" root handle 1: mq 2>/dev/null || return 1
        QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
        HANDLE=$(printf '%s\n' "$QDISCS" | awk '
            $1 == "qdisc" && $2 == "mq" {
                for (i=1; i<=NF; i++) if ($i == "root") { print $3; exit }
            }
        ')
        MAJOR=${HANDLE%:}
    fi
    [ -n "$MAJOR" ] || return 1
    PARENTS=$(printf '%s\n' "$QDISCS" | awk -v major="$MAJOR" '
        $1 == "qdisc" && $0 ~ / parent / {
            for (i=1; i<=NF; i++) if ($i == "parent") {
                parent=$(i+1)
                if ((major == "0" && (parent ~ /^:/ || index(parent, "0:") == 1)) ||
                    (major != "0" && index(parent, major ":") == 1)) print parent
                break
            }
        }
    ')
    [ -n "$PARENTS" ] || return 1
    for PARENT in $PARENTS; do
        "$TC_BIN" qdisc replace dev "$DEV" parent "$PARENT" "$KIND" 2>/dev/null || return 1
    done
}

bbr_tc_remove_root_for_sweep() {
    local DEV="$1" TC_BIN="$2" KIND
    KIND=$(bbr_tc_root_kind "$DEV" "$TC_BIN" 2>/dev/null || true)
    case "$KIND" in
        ""|noqueue) return 0 ;;
        htb)
            bbr_tc_topology_matches "$DEV" "$TC_BIN" || return 1
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null
            ;;
        mq)
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null && return 0
            "$TC_BIN" qdisc replace dev "$DEV" root handle 1: mq 2>/dev/null || return 1
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null
            ;;
        fq|fq_codel|pfifo_fast)
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

bbr_sweep_qdisc_save() {
    local DEV="$1" TC_BIN="$2" QDISCS LINE KIND HANDLE FILTERS LEAF_KIND="" MQ_RC
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || {
        error "无法读取 ${DEV} 的 qdisc，已取消扫描"
        return 1
    }
    LINE=$(bbr_tc_root_line "$QDISCS")
    KIND=$(bbr_tc_qdisc_type "$LINE")
    HANDLE=$(bbr_tc_qdisc_handle "$LINE")
    BBR_SWEEP_QSAVE_OWNED=0
    if bbr_tc_is_owned "$DEV" "$TC_BIN" || bbr_tc_is_legacy_owned "$DEV" "$TC_BIN"; then
        if [ ! -x "$TC_HELPER" ] && [ ! -f "$SERVICE_TC" ] && [ ! -f "$SERVICE_TC_INIT" ]; then
            error "检测到本工具的 HTB，但缺少可用的持久化恢复器"
            return 1
        fi
        BBR_SWEEP_QSAVE_OWNED=1
    elif ! bbr_tc_qdisc_safe_to_replace "$KIND"; then
        error "检测到第三方 root qdisc：${KIND:-未知}，拐点扫描不会覆盖它"
        return 2
    fi
    case "$KIND" in
        mq|fq|fq_codel|pfifo_fast)
            if [ "$BBR_SWEEP_QSAVE_OWNED" -eq 0 ] && [ -n "$HANDLE" ] && [ "$HANDLE" != "0:" ]; then
                error "检测到非默认 handle ${HANDLE} 的 ${KIND} qdisc，拐点扫描不会覆盖它"
                return 2
            fi
            ;;
    esac

    FILTERS=$("$TC_BIN" filter show dev "$DEV" root 2>/dev/null || true)
    if [ "$BBR_SWEEP_QSAVE_OWNED" -eq 0 ] && [ -n "$FILTERS" ]; then
        error "${DEV} 的 root qdisc 挂有外部 filter，已拒绝临时替换"
        return 2
    fi
    if [ "$KIND" = mq ]; then
        MQ_RC=0
        LEAF_KIND=$(bbr_tc_mq_leaf_kind "$DEV" "$TC_BIN") || MQ_RC=$?
        case "$MQ_RC" in
            0) : ;;
            2) error "${DEV} 的 mq 使用混合叶子 qdisc，无法安全还原"; return 2 ;;
            *) error "无法识别 ${DEV} 的 mq 叶子 qdisc"; return 1 ;;
        esac
        case "$LEAF_KIND" in
            ""|fq|fq_codel|pfifo_fast) : ;;
            *) error "检测到第三方 mq 叶子 qdisc：${LEAF_KIND}"; return 2 ;;
        esac
    fi

    BBR_SWEEP_QSAVE_IFACE="$DEV"
    BBR_SWEEP_QSAVE_KIND="$KIND"
    BBR_SWEEP_QSAVE_LEAF_KIND="$LEAF_KIND"
    BBR_SWEEP_QSAVE_TC="$TC_BIN"
    return 0
}

bbr_sweep_qdisc_restore() {
    local DEV="$BBR_SWEEP_QSAVE_IFACE" TC_BIN="$BBR_SWEEP_QSAVE_TC" CURRENT_KIND
    [ -n "$DEV" ] && [ -n "$TC_BIN" ] || return 0
    if [ "$BBR_SWEEP_QSAVE_OWNED" -eq 1 ]; then
        bbr_tc_remove_root_for_sweep "$DEV" "$TC_BIN" 2>/dev/null || true
        bbr_tc_restore_owned || return 1
        BBR_SWEEP_QSAVE_IFACE=""
        return 0
    fi

    CURRENT_KIND=$(bbr_tc_root_kind "$DEV" "$TC_BIN" 2>/dev/null || true)
    case "$BBR_SWEEP_QSAVE_KIND" in
        mq)
            if [ "$CURRENT_KIND" != mq ]; then
                bbr_tc_remove_root_for_sweep "$DEV" "$TC_BIN" 2>/dev/null || true
                CURRENT_KIND=$(bbr_tc_root_kind "$DEV" "$TC_BIN" 2>/dev/null || true)
                [ "$CURRENT_KIND" = mq ] \
                    || "$TC_BIN" qdisc add dev "$DEV" root mq 2>/dev/null \
                    || return 1
            fi
            [ -z "$BBR_SWEEP_QSAVE_LEAF_KIND" ] \
                || bbr_tc_set_mq_leaves "$DEV" "$BBR_SWEEP_QSAVE_LEAF_KIND" "$TC_BIN" \
                || return 1
            ;;
        ""|noqueue)
            bbr_tc_remove_root_for_sweep "$DEV" "$TC_BIN" 2>/dev/null || true
            ;;
        fq|fq_codel|pfifo_fast)
            bbr_tc_remove_root_for_sweep "$DEV" "$TC_BIN" 2>/dev/null || true
            "$TC_BIN" qdisc replace dev "$DEV" root "$BBR_SWEEP_QSAVE_KIND" 2>/dev/null || return 1
            ;;
        *) return 1 ;;
    esac
    BBR_SWEEP_QSAVE_IFACE=""
    return 0
}

bbr_sweep_set_fq() {
    local DEV="$1" TC_BIN="$2" KIND
    KIND=$(bbr_tc_root_kind "$DEV" "$TC_BIN" 2>/dev/null || true)
    case "$KIND" in
        mq) bbr_tc_set_mq_leaves "$DEV" fq "$TC_BIN" ;;
        fq) return 0 ;;
        htb)
            bbr_tc_topology_matches "$DEV" "$TC_BIN" || return 1
            bbr_tc_remove_root_for_sweep "$DEV" "$TC_BIN" || return 1
            KIND=$(bbr_tc_root_kind "$DEV" "$TC_BIN" 2>/dev/null || true)
            if [ "$KIND" = mq ]; then
                bbr_tc_set_mq_leaves "$DEV" fq "$TC_BIN"
            else
                "$TC_BIN" qdisc replace dev "$DEV" root fq 2>/dev/null
            fi
            ;;
        ""|noqueue|fq_codel|pfifo_fast)
            "$TC_BIN" qdisc replace dev "$DEV" root fq 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

bbr_sweep_apply_shaper() {
    local DEV="$1" RATE="$2" TC_BIN="$3" QDISCS LINE KIND ROOT_ACTION=add BURST_KB
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    LINE=$(bbr_tc_root_line "$QDISCS")
    KIND=$(bbr_tc_qdisc_type "$LINE")
    if [ -n "$LINE" ]; then
        case "$KIND" in
            htb)
                bbr_tc_topology_matches "$DEV" "$TC_BIN" || return 1
                "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || return 1
                ;;
            mq|fq|fq_codel|noqueue|pfifo_fast) ROOT_ACTION=replace ;;
            *) return 1 ;;
        esac
    fi
    BURST_KB=$RATE
    [ "$BURST_KB" -ge 32 ] || BURST_KB=32
    "$TC_BIN" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 2>/dev/null \
        && "$TC_BIN" class add dev "$DEV" parent 1: classid 1:10 htb \
            rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        && "$TC_BIN" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null
}

bbr_parse_iperf_output() {
    local RAW="$1" SENDER_LINE RECEIVER_LINE SENDER RETRANS RECEIVER=""
    SENDER_LINE=$(printf '%s\n' "$RAW" | awk '/[[:space:]]sender[[:space:]]*$/ { line=$0 } END { print line }')
    [ -n "$SENDER_LINE" ] || return 1
    RECEIVER_LINE=$(printf '%s\n' "$RAW" | awk '/[[:space:]]receiver[[:space:]]*$/ { line=$0 } END { print line }')
    SENDER=$(printf '%s\n' "$SENDER_LINE" | awk '{ print $(NF-3) }')
    RETRANS=$(printf '%s\n' "$SENDER_LINE" | awk '{ print $(NF-1) }')
    [ -z "$RECEIVER_LINE" ] || RECEIVER=$(printf '%s\n' "$RECEIVER_LINE" | awk '{ print $(NF-2) }')
    printf '%s\n' "$SENDER" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
    printf '%s\n' "$RETRANS" | grep -qE '^[0-9]+$' || return 1
    if [ -n "$RECEIVER" ]; then
        printf '%s\n' "$RECEIVER" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
        printf '%s %s %s\n' "$SENDER" "$RETRANS" "$RECEIVER"
    else
        printf '%s %s\n' "$SENDER" "$RETRANS"
    fi
}

bbr_iperf_single() {
    local PEER="$1" PORT="$2" DURATION="$3" FAMILY="$4" TMP RAW RC=0 PARSED
    local -a TIMEOUT_ARGS
    TMP=$(mktemp "${TMPDIR:-/tmp}/vps-bbr-iperf.XXXXXX") || return 1
    TIMEOUT_ARGS=(timeout)
    timeout --foreground 1 true >/dev/null 2>&1 && TIMEOUT_ARGS+=(--foreground)
    LC_ALL=C "${TIMEOUT_ARGS[@]}" "$(( DURATION + 20 ))" \
        iperf3 "$FAMILY" -c "$PEER" -p "$PORT" -t "$DURATION" -P 1 -f m > "$TMP" 2>&1 &
    BBR_SWEEP_IPERF_PID=$!
    if wait "$BBR_SWEEP_IPERF_PID"; then
        RC=0
    else
        RC=$?
    fi
    BBR_SWEEP_IPERF_PID=""
    RAW=$(cat "$TMP")
    rm -f "$TMP"
    [ "${BBR_SWEEP_VERBOSE:-0}" != 1 ] || printf '%s\n' "$RAW" | sed 's/^/      | /' >&2
    [ "$RC" -eq 0 ] || return 1
    PARSED=$(bbr_parse_iperf_output "$RAW") || return 1
    BBR_IPERF_RESULT="$PARSED"
    return 0
}

bbr_sweep_measure_rate() {
    local DEV="$1" TC_BIN="$2" PEER="$3" PORT="$4" FAMILY="$5" DURATION="$6" RATE="$7" LABEL="${8:-$7}"
    local RESULT SENDER RETRANS RECEIVER GOODPUT LOSS
    bbr_sweep_apply_shaper "$DEV" "$RATE" "$TC_BIN" || return 1
    bbr_iperf_single "$PEER" "$PORT" "$DURATION" "$FAMILY" || return 1
    RESULT="$BBR_IPERF_RESULT"
    SENDER=$(printf '%s\n' "$RESULT" | awk '{ print $1 }')
    RETRANS=$(printf '%s\n' "$RESULT" | awk '{ print $2 }')
    RECEIVER=$(printf '%s\n' "$RESULT" | awk '{ print $3 }')
    GOODPUT="${RECEIVER:-$SENDER}"
    LOSS=$(bbr_loss_pct "$RETRANS" "$SENDER" "$DURATION")
    BBR_SWEEP_POINT_GOODPUT="$GOODPUT"
    BBR_SWEEP_POINT_LOSS="$LOSS"
    printf '  %-12s %12s %9s %9s\n' "$LABEL" "$GOODPUT" "$RETRANS" "${LOSS}%"
}

bbr_sweep_scan_range() {
    local DEV="$1" TC_BIN="$2" PEER="$3" PORT="$4" FAMILY="$5" DURATION="$6"
    local LO="$7" HI="$8" STEP="$9" THRESHOLD="${10:-0.1}" RATE LAST_RATE=0
    local HITS SAMPLE CLEAN_GOODPUT="" CLEAN_LOSS=""
    RATE=$LO
    while [ "$RATE" -le "$HI" ]; do
        bbr_sweep_measure_rate "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" "$DURATION" "$RATE" || return 1
        LAST_RATE=$RATE
        if [ -z "$BBR_SWEEP_BASE_LOSS" ] && awk -v loss="$BBR_SWEEP_POINT_LOSS" -v threshold="$THRESHOLD" \
            'BEGIN { exit !(loss <= threshold) }'; then
            BBR_SWEEP_BASE_LOSS="$BBR_SWEEP_POINT_LOSS"
        fi

        if bbr_loss_is_spike "$BBR_SWEEP_POINT_LOSS" "$BBR_SWEEP_BASE_LOSS" "$THRESHOLD"; then
            HITS=1
            CLEAN_GOODPUT=""
            CLEAN_LOSS=""
            for SAMPLE in 2 3; do
                sleep 3
                bbr_sweep_measure_rate "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" "$DURATION" \
                    "$RATE" "${RATE} (#${SAMPLE})" || continue
                if bbr_loss_is_spike "$BBR_SWEEP_POINT_LOSS" "$BBR_SWEEP_BASE_LOSS" "$THRESHOLD"; then
                    HITS=$(( HITS + 1 ))
                else
                    CLEAN_GOODPUT="$BBR_SWEEP_POINT_GOODPUT"
                    CLEAN_LOSS="$BBR_SWEEP_POINT_LOSS"
                    [ -n "$BBR_SWEEP_BASE_LOSS" ] || BBR_SWEEP_BASE_LOSS="$CLEAN_LOSS"
                fi
            done
            if [ "$HITS" -ge 2 ]; then
                BBR_SWEEP_BROKE_AT=$RATE
                return 0
            fi
            if [ -n "$CLEAN_GOODPUT" ]; then
                BBR_SWEEP_POINT_GOODPUT="$CLEAN_GOODPUT"
                BBR_SWEEP_POINT_LOSS="$CLEAN_LOSS"
            else
                return 1
            fi
        fi

        if awk -v goodput="$BBR_SWEEP_POINT_GOODPUT" -v rate="$RATE" -v loss="$BBR_SWEEP_POINT_LOSS" \
            -v threshold="$THRESHOLD" 'BEGIN { exit !(goodput < rate * 0.65 && loss <= threshold) }'; then
            BBR_SWEEP_PEER_SLOW=$(( BBR_SWEEP_PEER_SLOW + 1 ))
            [ "$BBR_SWEEP_PEER_SLOW" -lt 2 ] || return 2
        else
            BBR_SWEEP_PEER_SLOW=0
        fi
        BBR_SWEEP_LAST_OK=$RATE
        RATE=$(( RATE + STEP ))
    done
    if [ "$LAST_RATE" -ne "$HI" ] && [ -z "$BBR_SWEEP_BROKE_AT" ]; then
        bbr_sweep_scan_range "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" "$DURATION" \
            "$HI" "$HI" 1 "$THRESHOLD"
    fi
}

bbr_sweep_traffic_mark() {
    local DEV="$1"
    BBR_SWEEP_TRAFFIC_RX0=$(cat "/sys/class/net/${DEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    BBR_SWEEP_TRAFFIC_TX0=$(cat "/sys/class/net/${DEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
}

bbr_sweep_traffic_report() {
    local DEV="$1" RX TX DRX DTX
    [ -n "$BBR_SWEEP_TRAFFIC_TX0" ] || return 0
    RX=$(cat "/sys/class/net/${DEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    TX=$(cat "/sys/class/net/${DEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
    DRX=$(( RX - BBR_SWEEP_TRAFFIC_RX0 ))
    DTX=$(( TX - BBR_SWEEP_TRAFFIC_TX0 ))
    [ "$DRX" -ge 0 ] || DRX=0
    [ "$DTX" -ge 0 ] || DTX=0
    awk -v rx="$DRX" -v tx="$DTX" 'BEGIN {
        printf "  本次测试流量：上行 %.2f GiB / 下行 %.2f GiB / 合计 %.2f GiB\n",
            tx/1073741824, rx/1073741824, (tx+rx)/1073741824
    }'
}

bbr_sweep_estimate_gb() {
    local NOMINAL="$1"
    awk -v bw="$NOMINAL" 'BEGIN { printf "%.1f", bw * 10 * 16 / 8 / 1024 }'
}

bbr_sweep_abort() {
    [ -z "$BBR_SWEEP_IPERF_PID" ] || kill -TERM "$BBR_SWEEP_IPERF_PID" 2>/dev/null || true
    bbr_sweep_qdisc_restore >/dev/null 2>&1 || true
    trap - INT TERM HUP
    echo ""
    warn "拐点扫描已中断，qdisc 已尝试恢复"
    exit 130
}

bbr_run_policer_sweep() {
    local PEER="$1" PORT="$2" NOMINAL="$3" FAMILY="${4:--4}" CAP=2500 DURATION=10
    local DEV TC_BIN BASE_RATE RESULT SENDER RETRANS RECEIVER GOODPUT LOSS
    local BEST_RESULT BEST_GOODPUT SAMPLE RANGE LO HI STEP SCAN_RC=0
    local KNOWN_BROKE CONTROL ATTEMPTS FINE COARSE_BROKE MARGIN FINAL SAVE_RC

    BBR_SWEEP_RECOMMEND=""
    BBR_SWEEP_KNEE=""
    bbr_positive_int "$PORT" 1 65535 || { error "iperf3 端口必须为 1-65535"; return 1; }
    bbr_positive_int "$NOMINAL" 1 100000 || { error "套餐带宽必须为正整数"; return 1; }
    case "$FAMILY" in -4|-6) : ;; *) error "无效协议族"; return 1 ;; esac
    printf '%s\n' "$PEER" | grep -qE '^[[:alnum:]_.:-]+$' || { error "无效的 iperf3 对端"; return 1; }
    case "$PEER" in -*) error "无效的 iperf3 对端"; return 1 ;; esac
    command -v iperf3 >/dev/null 2>&1 || { error "未安装 iperf3"; return 1; }
    command -v timeout >/dev/null 2>&1 || { error "缺少 timeout 命令，无法限制测速进程"; return 1; }
    [ "$NOMINAL" -le "$CAP" ] || {
        warn "${NOMINAL}Mbps 超过自动扫描上限 ${CAP}Mbps，为避免误限速已跳过"
        return 3
    }
    if is_openvz; then
        error "受限容器中无法安全替换 qdisc"
        return 1
    fi
    DEV=$(default_iface)
    [ -n "$DEV" ] || { error "无法确定默认出口网卡"; return 1; }
    TC_BIN=$(command -v tc 2>/dev/null || true)
    [ -n "$TC_BIN" ] || { error "tc 命令不可用"; return 1; }
    SAVE_RC=0
    bbr_sweep_qdisc_save "$DEV" "$TC_BIN" || SAVE_RC=$?
    [ "$SAVE_RC" -eq 0 ] || return "$SAVE_RC"
    bbr_sweep_traffic_mark "$DEV"
    trap 'bbr_sweep_abort' INT TERM HUP

    echo ""
    info "先以套餐带宽 40% 检查对端与路径底噪"
    BASE_RATE=$(( NOMINAL * 40 / 100 ))
    [ "$BASE_RATE" -ge 1 ] || BASE_RATE=1
    printf '  %-12s %12s %9s %9s\n' "速率/Mbps" "送达/Mbps" "重传" "估算丢包"
    if ! bbr_sweep_measure_rate "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" 8 "$BASE_RATE" "${BASE_RATE} (baseline)"; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        error "路径基线测试失败，请检查对端是否可达或占线"
        return 2
    fi
    BBR_SWEEP_BASE_LOSS="$BBR_SWEEP_POINT_LOSS"
    if awk -v goodput="$BBR_SWEEP_POINT_GOODPUT" -v rate="$BASE_RATE" -v loss="$BBR_SWEEP_BASE_LOSS" \
        'BEGIN { exit !(goodput < rate * 0.65 && loss <= 0.5) }'; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        warn "对端在低速基线 ${BASE_RATE}Mbps 下仅送达 ${BBR_SWEEP_POINT_GOODPUT}Mbps，对端能力不足"
        return 2
    fi
    if awk -v loss="$BBR_SWEEP_BASE_LOSS" 'BEGIN { exit !(loss > 0.5) }'; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        warn "低速基线已有 ${BBR_SWEEP_BASE_LOSS}% 丢包，无法把路径损失与端口 policer 分开"
        return 2
    fi

    info "不限速单流探测（${DURATION}s）"
    bbr_sweep_set_fq "$DEV" "$TC_BIN" || {
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || true
        error "无法临时启用 fq"
        return 1
    }
    sleep 3
    if ! bbr_iperf_single "$PEER" "$PORT" "$DURATION" "$FAMILY"; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        error "不限速探测失败"
        return 2
    fi
    BEST_RESULT="$BBR_IPERF_RESULT"
    RECEIVER=$(printf '%s\n' "$BEST_RESULT" | awk '{ print $3 }')
    SENDER=$(printf '%s\n' "$BEST_RESULT" | awk '{ print $1 }')
    BEST_GOODPUT="${RECEIVER:-$SENDER}"
    if awk -v goodput="$BEST_GOODPUT" -v nominal="$NOMINAL" 'BEGIN { exit !(goodput < nominal * 0.7) }'; then
        warn "单流仅达 ${BEST_GOODPUT}Mbps，低于套餐带宽的 70%；再取两次中的最佳完整样本"
        for SAMPLE in 2 3; do
            sleep 3
            bbr_iperf_single "$PEER" "$PORT" "$DURATION" "$FAMILY" || continue
            RESULT="$BBR_IPERF_RESULT"
            RECEIVER=$(printf '%s\n' "$RESULT" | awk '{ print $3 }')
            SENDER=$(printf '%s\n' "$RESULT" | awk '{ print $1 }')
            GOODPUT="${RECEIVER:-$SENDER}"
            if awk -v current="$GOODPUT" -v best="$BEST_GOODPUT" 'BEGIN { exit !(current > best) }'; then
                BEST_RESULT="$RESULT"
                BEST_GOODPUT="$GOODPUT"
            fi
        done
    fi
    SENDER=$(printf '%s\n' "$BEST_RESULT" | awk '{ print $1 }')
    RETRANS=$(printf '%s\n' "$BEST_RESULT" | awk '{ print $2 }')
    RECEIVER=$(printf '%s\n' "$BEST_RESULT" | awk '{ print $3 }')
    GOODPUT="${RECEIVER:-$SENDER}"
    LOSS=$(bbr_loss_pct "$RETRANS" "$SENDER" "$DURATION")
    printf '  %-12s %12s %9s %9s\n' "none" "$GOODPUT" "$RETRANS" "${LOSS}%"

    if awk -v goodput="$GOODPUT" -v cap="$CAP" 'BEGIN { exit !(goodput > cap) }'; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        info "不限速单流已送达 ${GOODPUT}Mbps，超过安全扫描上限 ${CAP}Mbps，不添加硬限速"
        bbr_sweep_traffic_report "$DEV"
        return 3
    fi

    if ! bbr_loss_is_spike "$LOSS" "$BBR_SWEEP_BASE_LOSS" 0.1; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        info "不限速时未出现相对于底噪的重传跳变，不建议添加 HTB 硬限速"
        bbr_sweep_traffic_report "$DEV"
        return 3
    fi

    RANGE=$(bbr_sweep_range "$GOODPUT" "$LOSS" "$CAP")
    LO=$(printf '%s\n' "$RANGE" | awk '{ print $1 }')
    HI=$(printf '%s\n' "$RANGE" | awk '{ print $2 }')
    STEP=$(printf '%s\n' "$RANGE" | awk '{ print $3 }')
    info "检测到可疑 policer，将从 ${LO} 扫到 ${HI}Mbps，粗步长 ${STEP}Mbps"
    warn "扫描仅针对 VPS 近端出口上限，不能代表中美国际线路质量"
    sleep 10

    BBR_SWEEP_LAST_OK=""
    BBR_SWEEP_BROKE_AT=""
    BBR_SWEEP_PEER_SLOW=0
    printf '  %-12s %12s %9s %9s\n' "速率/Mbps" "送达/Mbps" "重传" "估算丢包"
    bbr_sweep_scan_range "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" "$DURATION" \
        "$LO" "$HI" "$STEP" 0.1 || SCAN_RC=$?
    if [ "$SCAN_RC" -eq 2 ]; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        warn "对端速度连续明显低于测试档位，已停止以避免误限速"
        return 2
    elif [ "$SCAN_RC" -ne 0 ]; then
        trap - INT TERM HUP
        bbr_sweep_qdisc_restore || warn "qdisc 自动恢复失败"
        error "扫描中的 iperf3 或 tc 测试失败"
        return 2
    fi

    if [ -z "$BBR_SWEEP_LAST_OK" ] && [ -n "$BBR_SWEEP_BROKE_AT" ]; then
        KNOWN_BROKE=$BBR_SWEEP_BROKE_AT
        ATTEMPTS=0
        while [ "$ATTEMPTS" -lt 3 ] && [ -z "$BBR_SWEEP_LAST_OK" ]; do
            ATTEMPTS=$(( ATTEMPTS + 1 ))
            CONTROL=$(( KNOWN_BROKE * 3 / 4 ))
            [ "$CONTROL" -ge 1 ] || CONTROL=1
            BBR_SWEEP_BROKE_AT=""
            info "首档已跳变，向下检查控制点 ${CONTROL}Mbps"
            bbr_sweep_scan_range "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" "$DURATION" \
                "$CONTROL" "$CONTROL" 1 0.1 || break
            if [ -n "$BBR_SWEEP_LAST_OK" ]; then
                BBR_SWEEP_BROKE_AT=$KNOWN_BROKE
            elif [ -n "$BBR_SWEEP_BROKE_AT" ]; then
                KNOWN_BROKE=$CONTROL
            fi
        done
    fi

    if [ -n "$BBR_SWEEP_LAST_OK" ] && [ -n "$BBR_SWEEP_BROKE_AT" ] \
        && [ $(( BBR_SWEEP_BROKE_AT - BBR_SWEEP_LAST_OK )) -gt 1 ]; then
        COARSE_BROKE=$BBR_SWEEP_BROKE_AT
        FINE=$(( STEP / 4 ))
        [ "$FINE" -ge 1 ] || FINE=1
        BBR_SWEEP_BROKE_AT=""
        info "拐点在 ${BBR_SWEEP_LAST_OK}-${COARSE_BROKE}Mbps 之间，以 ${FINE}Mbps 细扫"
        if [ $(( BBR_SWEEP_LAST_OK + FINE )) -le $(( COARSE_BROKE - FINE )) ]; then
            bbr_sweep_scan_range "$DEV" "$TC_BIN" "$PEER" "$PORT" "$FAMILY" "$DURATION" \
                $(( BBR_SWEEP_LAST_OK + FINE )) $(( COARSE_BROKE - FINE )) "$FINE" 0.1 || true
        fi
        [ -n "$BBR_SWEEP_BROKE_AT" ] || BBR_SWEEP_BROKE_AT=$COARSE_BROKE
    fi

    trap - INT TERM HUP
    bbr_sweep_qdisc_restore || {
        error "扫描完成，但无法恢复原 qdisc；请立即检查 tc qdisc"
        return 1
    }
    bbr_sweep_traffic_report "$DEV"
    [ -n "$BBR_SWEEP_LAST_OK" ] || {
        warn "未找到干净档位，不会给出自动限速值"
        return 2
    }
    [ -n "$BBR_SWEEP_BROKE_AT" ] || {
        warn "扫到 ${HI}Mbps 仍未找到稳定跳变，不会把上界误当成拐点"
        return 3
    }
    MARGIN=$(bbr_sweep_margin_mbps "$NOMINAL")
    FINAL=$(( BBR_SWEEP_LAST_OK - MARGIN ))
    [ "$FINAL" -ge 1 ] || FINAL=$BBR_SWEEP_LAST_OK
    BBR_SWEEP_KNEE=$BBR_SWEEP_LAST_OK
    BBR_SWEEP_RECOMMEND=$FINAL
    info "最高干净档 ${BBR_SWEEP_KNEE}Mbps，退 ${MARGIN}Mbps 安全余量，建议 ${FINAL}Mbps"
    return 0
}

bbr_physical_memory_mb() {
    local MEM_KB
    MEM_KB=$(awk '/MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
    case "$MEM_KB" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo $(( MEM_KB / 1024 )) ;;
    esac
}

bbr_effective_memory_mb() {
    local REQUESTED_MB="$1" ACTUAL_MB="${2:-}"
    [ -n "$ACTUAL_MB" ] || ACTUAL_MB=$(bbr_physical_memory_mb)
    case "$REQUESTED_MB" in ''|*[!0-9]*) return 1 ;; esac
    case "$ACTUAL_MB" in ''|*[!0-9]*) ACTUAL_MB=0 ;; esac
    if [ "$ACTUAL_MB" -gt 0 ] && [ "$REQUESTED_MB" -gt "$ACTUAL_MB" ]; then
        echo "$ACTUAL_MB"
    else
        echo "$REQUESTED_MB"
    fi
}

bbr_buffer_cap_bytes() {
    local MEM_MB="$1"
    case "$MEM_MB" in ''|*[!0-9]*) return 1 ;; esac
    [ "$MEM_MB" -gt 0 ] || return 1
    echo $(( MEM_MB * 1048576 / 4 ))
}

bbr_conntrack_max_for_memory() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -lt 1024 ]; then
        echo 131072
    elif [ "$MEM_MB" -lt 2048 ]; then
        echo 262144
    elif [ "$MEM_MB" -lt 4096 ]; then
        echo 524288
    else
        echo 1048576
    fi
}

# ── 单线程自适应参数推导 ───────────────────────
bbr_positive_int() {
    local VALUE="$1" MIN="$2" MAX="$3"
    case "$VALUE" in ''|*[!0-9]*) return 1 ;; esac
    [ "$VALUE" -ge "$MIN" ] 2>/dev/null && [ "$VALUE" -le "$MAX" ] 2>/dev/null
}

# BDP(字节) = 带宽(Mbps) × RTT(ms) × 125。
bbr_bdp_bytes() {
    awk -v bw="$1" -v rtt="$2" 'BEGIN { printf "%.0f", bw * rtt * 125 }'
}

# 上限使用连续公式 2×BDP+2MiB，避免旧版固定档位在边界突跳。
# 单 socket 最多使用物理内存约 1/32，并设 4MiB 下限和 256MiB 绝对上限。
bbr_single_buffer_max_bytes() {
    local BDP_BYTES="$1" MEM_MB="$2"
    awk -v b="$BDP_BYTES" -v m="$MEM_MB" 'BEGIN {
        value = b * 2 + 2097152
        cap = m * 32768
        if (cap > 268435456) cap = 268435456
        if (value > cap) value = cap
        if (value < 4194304) value = 4194304
        printf "%.0f", value
    }'
}

# 单流模式用 BDP 作为 TCP 自动扩展的起点，但限制在 1-8MiB，
# 避免偶发多连接时按每连接过度预留内存。
bbr_single_buffer_default_bytes() {
    local BDP_BYTES="$1"
    awk -v b="$BDP_BYTES" 'BEGIN {
        value = b
        if (value < 1048576) value = 1048576
        if (value > 8388608) value = 8388608
        printf "%.0f", value
    }'
}

bbr_single_buffer_reason() {
    local BDP_BYTES="$1" MEM_MB="$2" VALUE="$3"
    awk -v b="$BDP_BYTES" -v m="$MEM_MB" -v v="$VALUE" 'BEGIN {
        target = b * 2 + 2097152
        cap = m * 32768
        if (cap > 268435456) cap = 268435456
        if (v <= 4194304 && target < 4194304) { print "4MiB 保底"; exit }
        if (v >= cap && target > cap) { print "受物理内存 1/32 限制"; exit }
        print "2×BDP + 2MiB 余量"
    }'
}

bbr_bytes_to_mib() {
    awk -v value="$1" 'BEGIN { printf "%.2f", value / 1048576 }'
}

bbr_sweep_margin_mbps() {
    local BW="$1"
    if [ "$BW" -le 30 ] 2>/dev/null; then
        echo 1
    elif [ "$BW" -le 60 ] 2>/dev/null; then
        echo 2
    elif [ "$BW" -le 100 ] 2>/dev/null; then
        echo 5
    elif [ "$BW" -le 300 ] 2>/dev/null; then
        echo 10
    elif [ "$BW" -le 600 ] 2>/dev/null; then
        echo 15
    elif [ "$BW" -le 1000 ] 2>/dev/null; then
        echo 25
    else
        echo 40
    fi
}

# 输出“下限 上限 粗扫步长”。拐点在打穿 policer 后的实际送达量之上。
bbr_sweep_range() {
    local GOODPUT="$1" LOSS_PCT="$2" CAP="${3:-2500}"
    awk -v gp="$GOODPUT" -v loss="$LOSS_PCT" -v cap="$CAP" 'BEGIN {
        lo = int(gp * 0.95)
        if (lo < 1) lo = 1
        factor = 1.25 + loss / 100 * 2
        if (factor > 2.5) factor = 2.5
        hi = int(gp * factor)
        if (hi > cap) hi = cap
        if (hi <= lo) hi = lo + 2
        step = int((hi - lo) / 10 + 0.5)
        if (step < 1) step = 1
        printf "%d %d %d\n", lo, hi, step
    }'
}

# 重传率估算：重传数 / 以 1448 字节 MSS 估算的发送包数。
bbr_loss_pct() {
    local RETRANS="$1" SENDER_MBPS="$2" DURATION="$3"
    awk -v retrans="$RETRANS" -v mbps="$SENDER_MBPS" -v duration="$DURATION" 'BEGIN {
        packets = mbps * 1000000 * duration / 8 / 1448
        if (packets < 1) packets = 1
        printf "%.4f", retrans * 100 / packets
    }'
}

# 既超过 0.1% 绝对门限，又明显高于稳定底噪，才判为拐点。
bbr_loss_is_spike() {
    local LOSS="$1" BASELINE="${2:-0}" THRESHOLD="${3:-0.1}"
    awk -v loss="$LOSS" -v base="$BASELINE" -v threshold="$THRESHOLD" 'BEGIN {
        need = threshold
        if (base > 0 && base * 5 > need) need = base * 5
        if (need > 1) need = 1
        exit !(loss > need)
    }'
}

bbr_generate_single_stream_config() {
    local BUF_MAX="$1" BUF_DEFAULT="$2" SWAPPINESS="$3" BW_MBPS="$4" RTT_MS="$5"
    cat << EOF
# BBR 跨境单线程自适应配置 — 生成时间：$(date)
# 推导条件：${BW_MBPS}Mbps / RTT ${RTT_MS}ms
# 缓冲上限：2×BDP+2MiB，再受物理内存 1/32 与 256MiB 限制
# ── 内存管理 ──
vm.swappiness = ${SWAPPINESS}

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 单流缓冲 ──
net.core.rmem_max = ${BUF_MAX}
net.core.wmem_max = ${BUF_MAX}
net.core.rmem_default = ${BUF_DEFAULT}
net.core.wmem_default = ${BUF_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${BUF_DEFAULT} ${BUF_MAX}
net.ipv4.tcp_wmem = 4096 ${BUF_DEFAULT} ${BUF_MAX}
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# ── 连接质量 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# ── UDP 保守下限（QUIC / Hysteria2 / TUIC）──
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
}

bbr_generate_config() {
    local RMEM=$1 WMEM=$2 NOTSENT=$3 SWAPPINESS=$4 \
          PROFILE_NAME="${5:-default}" ENABLE_FORWARD="${6:-0}"
    cat << EOF
# BBR TCP 调优配置 — 生成时间：$(date)
# 预设：${PROFILE_NAME}
# ── 内存管理 ──
vm.swappiness = ${SWAPPINESS}

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.ipv4.tcp_rmem = 4096 131072 ${RMEM}
net.ipv4.tcp_wmem = 4096 16384 ${WMEM}
net.ipv4.tcp_notsent_lowat = ${NOTSENT}

# ── 连接质量 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# ── UDP 缓冲（QUIC / Hysteria2 / TUIC 代理）──
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

    # 场景预设的并发参数不依赖内核转发，用户态代理同样受益。
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            cat << EOF

# ── 代理并发 ──
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_tw_buckets = 500000
fs.file-max = 1048576
EOF
            ;;
    esac

    if [ "$ENABLE_FORWARD" = 1 ]; then
        local IPV6_IFACE
        IPV6_IFACE=$(bbr_default_ipv6_iface)
        cat << EOF

# ── 内核路由 / NAT ──
net.ipv6.conf.default.accept_ra = 2
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
        if [ -n "$IPV6_IFACE" ]; then
            cat << EOF
net.ipv6.conf.${IPV6_IFACE}.accept_ra = 2
EOF
        fi
    fi

    if [ "$ENABLE_FORWARD" = 1 ] && [ "$PROFILE_NAME" = "relay" ]; then
        local MEM_MB CONNTRACK_MAX
        MEM_MB=$(bbr_physical_memory_mb)
        CONNTRACK_MAX=$(bbr_conntrack_max_for_memory "$MEM_MB")
        cat << EOF

# ── conntrack（按物理内存分档）──
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    fi
}

# ── 确认并应用参数 ────────────────────────────────────────
bbr_preflight() {
    ensure_sysctl || return 1
    if ! has_sysctl_write; then
        error "当前容器无 sysctl 写入权限，无法应用配置"
        echo -e "  ${DIM}需要宿主机开启 privileged 模式或 sysctl 白名单${NC}"
        return 1
    fi
    bbr_check_kernel || return 1
}

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

bbr_kernel_forwarding_confirm() {
    local ANSWER
    read -rp "  是否启用内核 IPv4/IPv6 转发？仅路由或 NAT 需要 (y/N，默认N): " ANSWER
    [ -z "$ANSWER" ] && ANSWER="n"
    echo "$ANSWER" | grep -qiE '^y(es)?$'
}

bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 NOTSENT=$3 SWAP=$4 \
          LABEL_MODE=$5 LABEL_BUF=$6 PROFILE_NAME="${7:-default}" ENABLE_FORWARD=0

    bbr_preflight || return 1
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            echo ""
            bbr_kernel_forwarding_confirm && ENABLE_FORWARD=1
            ;;
    esac

    echo ""
    echo -e "  ${YELLOW}── 配置摘要 ──────────────────────────────${NC}"
    echo -e "  模式         : ${BOLD}$LABEL_MODE${NC}"
    echo -e "  缓冲区       : ${BOLD}${LABEL_BUF}MB${NC}  (rmem/wmem max)"
    echo -e "  TCP min/default  : ${BOLD}接收 4KB/128KB · 发送 4KB/16KB${NC}"
    echo -e "  全局 TCP 内存    : ${BOLD}由内核自动管理${NC}"
    echo -e "  swappiness   : ${BOLD}${SWAP}${NC}"
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            [ "$ENABLE_FORWARD" = 1 ] \
                && echo -e "  内核转发     : ${BOLD}启用${NC}" \
                || echo -e "  内核转发     : ${BOLD}不修改${NC}"
            ;;
    esac
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    echo ""

    # 先提示备份（默认Y）
    if [ -f "$SYSCTL_FILE" ]; then
        read -rp "  备份当前 sysctl 配置？(Y/n，默认Y): " DO_BAK
        [ -z "$DO_BAK" ] && DO_BAK="y"
        if echo "$DO_BAK" | grep -qiE '^y(es)?$' && ! bbr_backup_sysctl; then
            error "无法安全备份，已取消应用"
            return 1
        fi
        echo ""
    fi
    read -rp "  确认应用以上配置？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" "$PROFILE_NAME" "$ENABLE_FORWARD")
    [ "$ENABLE_FORWARD" != 1 ] \
        || ensure_conntrack_module \
        || warn "无法预加载 nf_conntrack，将按内核实际支持情况应用"
    bbr_apply_sysctl "$CONFIG" || {
        error "BBR TCP 调优配置应用失败"
        return 1
    }
    # 场景预设（转发机）额外检测代理 service 的 fd 上限
    case "$PROFILE_NAME" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    echo ""
    info "BBR TCP 调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
    return 0
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_single_stream_apply() {
    local BW_MBPS="$1" RTT_MS="$2" MEM_MB BDP_BYTES BUF_MAX BUF_DEFAULT
    local SWAP=5 BUF_MAX_MIB BUF_DEFAULT_MIB BDP_MIB REASON CONFIG
    bbr_positive_int "$BW_MBPS" 1 100000 || { error "带宽必须为 1-100000 Mbps"; return 1; }
    bbr_positive_int "$RTT_MS" 1 2000 || { error "RTT 必须为 1-2000 ms"; return 1; }
    bbr_preflight || return 1

    MEM_MB=$(bbr_physical_memory_mb)
    if [ "$MEM_MB" -le 0 ] 2>/dev/null; then
        warn "无法读取物理内存，按 512MB 保守计算"
        MEM_MB=512
    fi
    BDP_BYTES=$(bbr_bdp_bytes "$BW_MBPS" "$RTT_MS")
    BUF_MAX=$(bbr_single_buffer_max_bytes "$BDP_BYTES" "$MEM_MB")
    BUF_DEFAULT=$(bbr_single_buffer_default_bytes "$BDP_BYTES")
    [ "$BUF_DEFAULT" -le "$BUF_MAX" ] || BUF_DEFAULT=$BUF_MAX
    [ "$MEM_MB" -gt 1536 ] || SWAP=10
    BDP_MIB=$(bbr_bytes_to_mib "$BDP_BYTES")
    BUF_MAX_MIB=$(bbr_bytes_to_mib "$BUF_MAX")
    BUF_DEFAULT_MIB=$(bbr_bytes_to_mib "$BUF_DEFAULT")
    REASON=$(bbr_single_buffer_reason "$BDP_BYTES" "$MEM_MB" "$BUF_MAX")

    echo ""
    echo -e "  ${YELLOW}── 跨境单线程配置摘要 ──────────────${NC}"
    echo -e "  推导条件     : ${BOLD}${BW_MBPS}Mbps / RTT ${RTT_MS}ms / ${MEM_MB}MB RAM${NC}"
    echo -e "  BDP          : ${BOLD}${BDP_MIB}MiB${NC}"
    echo -e "  socket 上限  : ${BOLD}${BUF_MAX_MIB}MiB${NC}  (${REASON})"
    echo -e "  socket 起点  : ${BOLD}${BUF_DEFAULT_MIB}MiB${NC}  (BDP，限制在 1-8MiB)"
    echo -e "  拥塞/队列    : ${BOLD}BBR + fq${NC}"
    echo -e "  全局 TCP 内存: ${BOLD}由内核管理${NC}  (不写 tcp_mem)"
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    warn "该模式针对少量大流/单线程；若是数百并发代理连接，应用手动中转预设"
    echo ""

    if [ -f "$SYSCTL_FILE" ]; then
        local DO_BAK
        read -rp "  备份当前 sysctl 运行值？(Y/n，默认Y): " DO_BAK
        [ -n "$DO_BAK" ] || DO_BAK=y
        if echo "$DO_BAK" | grep -qiE '^y(es)?$' && ! bbr_backup_sysctl; then
            error "无法安全备份，已取消应用"
            return 1
        fi
    fi
    local CONFIRM
    read -rp "  确认应用自适应单线程配置？(Y/n，默认Y): " CONFIRM
    [ -n "$CONFIRM" ] || CONFIRM=y
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return 2; }

    CONFIG=$(bbr_generate_single_stream_config "$BUF_MAX" "$BUF_DEFAULT" "$SWAP" "$BW_MBPS" "$RTT_MS")
    bbr_apply_sysctl "$CONFIG" || {
        error "跨境单线程配置应用失败"
        return 1
    }
    info "自适应单线程 BBR 参数已应用 ✓"
    return 0
}

bbr_bdp_mb() {
    awk -v bw="$1" -v lat="$2" 'BEGIN { printf "%.2f", bw * lat / 8000 }'
}

bbr_buffer_target_mb() {
    local BW_MBPS="$1" LAT_MS="$2"
    printf '%s\n' $(( (BW_MBPS * LAT_MS * 3 + 15999) / 16000 ))
}

bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6
    local ACTUAL_MEM_MB EFFECTIVE_MEM_MB
    ACTUAL_MEM_MB=$(bbr_physical_memory_mb)
    EFFECTIVE_MEM_MB=$(bbr_effective_memory_mb "$MEM_MB" "$ACTUAL_MEM_MB") || return 1
    if [ "$EFFECTIVE_MEM_MB" -lt "$MEM_MB" ]; then
        warn "所选内存 ${MEM_MB}MB 超过实际内存 ${ACTUAL_MEM_MB}MB，按实际内存计算"
        MEM_LBL="${MEM_LBL}，按实际 ${ACTUAL_MEM_MB}MB"
    fi
    MEM_MB=$EFFECTIVE_MEM_MB

    local BDP_MB BUF_CALC
    BDP_MB=$(bbr_bdp_mb "$BW_MBPS" "$LAT_MS")
    BUF_CALC=$(bbr_buffer_target_mb "$BW_MBPS" "$LAT_MS")

    local RMEM WMEM NOTSENT
    if   [ "$BUF_CALC" -le 10 ];  then RMEM=12582912;   NOTSENT=131072
    elif [ "$BUF_CALC" -le 20 ];  then RMEM=20971520;   NOTSENT=131072
    elif [ "$BUF_CALC" -le 32 ];  then RMEM=33554432;   NOTSENT=262144
    elif [ "$BUF_CALC" -le 40 ];  then RMEM=41943040;   NOTSENT=262144
    elif [ "$BUF_CALC" -le 64 ];  then RMEM=67108864;   NOTSENT=524288
    elif [ "$BUF_CALC" -le 128 ]; then RMEM=134217728;  NOTSENT=524288
    elif [ "$BUF_CALC" -le 256 ]; then RMEM=268435456;  NOTSENT=1048576
    elif [ "$BUF_CALC" -le 512 ]; then RMEM=536870912;  NOTSENT=2097152
    else                                RMEM=1073741824; NOTSENT=2097152
    fi
    WMEM=$RMEM

    local BUFFER_CAP
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "缓冲区 $(( RMEM / 1048576 ))MB 超过实际内存 ${MEM_MB}MB 的 25%，自动降级"
        RMEM=$BUFFER_CAP
        WMEM=$BUFFER_CAP
    fi

    local SWAP=5
    [ "$MEM_MB" -le 1536 ] && SWAP=10

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  BDP 估算：${BOLD}${BDP_MB}MB${NC}  →  推荐缓冲区：${BOLD}${BUF_MB}MB${NC}"
    echo -e "  内存：${MEM_LBL}  延迟：${LAT_LBL}  带宽：${BW_LBL}"

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" \
        "自动计算（${MEM_LBL} / ${LAT_LBL} / ${BW_LBL}）" "$BUF_MB"
}

# ── 手动选择缓冲区模式 ────────────────────────────────────
# ── 自动模式：带宽子菜单 ─────────────────────────────────
bbr_menu_bandwidth() {
    local MEM_MB=$1 LAT_MS=$2 MEM_LBL=$3 LAT_LBL=$4
    print_header "BBR 自动配置 — 选择带宽"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}  延迟：${BOLD}${LAT_LBL}${NC}"
    echo ""
    menu_pair "1" "100 Mbps" "2" "200 Mbps"
    menu_pair "3" "500 Mbps" "4" "1 Gbps"
    menu_pair "5" "2 Gbps" "6" "5 Gbps"
    menu_item "7" "10 Gbps"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择带宽 [0-7]: ')" CH
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
    menu_item "1" "100ms 以内  ${DIM}国内 / 亚洲${NC}"
    menu_item "2" "100-200ms  ${DIM}跨国线路${NC}"
    menu_item "3" "200ms 以上  ${DIM}跨洲长距离${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择延迟 [0-3]: ')" CH
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
    local SYS_MEM_MB
    SYS_MEM_MB=$(bbr_physical_memory_mb)

    print_header "BBR 自动配置 — 选择内存"
    echo -e "  系统检测内存：${BOLD}${SYS_MEM_MB}MB${NC}"
    echo ""
    menu_pair "1" "512 MB" "2" "1 GB"
    menu_pair "3" "2 GB" "4" "4 GB"
    menu_pair "5" "8 GB" "6" "16 GB+"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择内存 [0-6]: ')" CH
    local SELECTED_MB SELECTED_LABEL EFFECTIVE_MB
    case "$CH" in
        1) SELECTED_MB=512;   SELECTED_LABEL="512MB" ;;
        2) SELECTED_MB=1024;  SELECTED_LABEL="1GB" ;;
        3) SELECTED_MB=2048;  SELECTED_LABEL="2GB" ;;
        4) SELECTED_MB=4096;  SELECTED_LABEL="4GB" ;;
        5) SELECTED_MB=8192;  SELECTED_LABEL="8GB" ;;
        6) SELECTED_MB=16384; SELECTED_LABEL="16GB+" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    EFFECTIVE_MB=$(bbr_effective_memory_mb "$SELECTED_MB" "$SYS_MEM_MB") || return 1
    if [ "$EFFECTIVE_MB" -lt "$SELECTED_MB" ]; then
        warn "所选内存 ${SELECTED_LABEL} 超过实际内存 ${SYS_MEM_MB}MB，后续按实际内存计算"
        SELECTED_LABEL="${SELECTED_LABEL}（实际 ${SYS_MEM_MB}MB）"
    fi
    bbr_menu_latency "$EFFECTIVE_MB" "$SELECTED_LABEL"
}

# ── 手动模式：内存子菜单 ─────────────────────────────────
bbr_menu_manual() {
    # 自动检测系统内存
    local MEM_MB
    MEM_MB=$(bbr_physical_memory_mb)
    [ "$MEM_MB" -gt 0 ] || { error "无法读取物理内存"; return 1; }

    # ── 第一层：选择用途 ──
    print_header "BBR 手动配置 — 选择用途"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}"
    echo ""
    menu_div
    echo -e "  ${BOLD}请选择 VPS 用途（决定并发与队列参数）${NC}"
    echo ""
    menu_item "1" "中转机  ${DIM}双向转发 / 大并发${NC}"
    menu_item "2" "落地机  ${DIM}跨境上行 / 大缓冲${NC}"
    menu_item "3" "线路落地机  ${DIM}低延迟优先${NC}"
    menu_item "4" "通用单机  ${DIM}网页 / SSH / 服务${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择用途 [0-4]: ')" SCENE
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
    menu_pair "1" "12 MB · 低带宽" "2" "16 MB · 小内存"
    menu_pair "3" "20 MB · 中低带宽" "4" "32 MB · 跨境推荐"
    menu_pair "5" "40 MB · 1G" "6" "64 MB · 1G+"
    menu_pair "7" "128 MB · 2G" "8" "256 MB · 5G"
    menu_pair "9" "512 MB · 10G" "10" "1024 MB · 极限"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择缓冲区 [0-10]: ')" CH

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

    local BUFFER_CAP
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "缓冲区 ${BUF_LBL}MB 超过物理内存 ${MEM_MB}MB 的 25%，高并发时可能造成内存压力"
        read -rp "  是否继续？(y/N，默认N): " GO
        [ -z "$GO" ] && GO="n"
        echo "$GO" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    fi

    # ── 根据场景调整待发送队列 ──
    local NOTSENT
    case "$PROFILE" in
        relay)
            # 中转机：NOTSENT 小（降低单连接延迟）
            NOTSENT=262144
            ;;
        landing)
            # 落地机：NOTSENT 大（高吞吐）
            NOTSENT=2097152
            ;;
        line_landing)
            # 线路落地机：NOTSENT 极小（响应优先）
            NOTSENT=131072
            ;;
        default)
            # 通用：跟着缓冲区档位走
            if   [ "$BUF_LBL" -le 32 ];  then NOTSENT=262144
            elif [ "$BUF_LBL" -le 64 ];  then NOTSENT=524288
            elif [ "$BUF_LBL" -le 256 ]; then NOTSENT=1048576
            else                              NOTSENT=2097152
            fi ;;
    esac

    local SWAP=5
    [ "$MEM_MB" -le 1536 ] && SWAP=10
    # 中转机额外抬高 swappiness（容忍多进程）
    [ "$PROFILE" = "relay" ] && SWAP=10

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" \
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
        ui_pause
        return
    fi

    local DEV QDISCS ROOT_LINE
    DEV=$(default_iface)
    QDISCS=$(tc qdisc show dev "$DEV" 2>/dev/null || true)
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    local QTYPE; QTYPE=$(bbr_tc_qdisc_type "$ROOT_LINE")
    [ -z "$QTYPE" ] && QTYPE="未知"
    local CUR; CUR=$(bbr_tc_rate_display "$DEV" "$(command -v tc 2>/dev/null || echo /sbin/tc)")

    echo -e "  网卡：${BOLD}${DEV}${NC}  当前 qdisc：${BOLD}${QTYPE}${NC}  当前限速：${BOLD}${CUR}${NC}"
    echo ""
    menu_div
    menu_pair "1" "200 Mbps" "2" "500 Mbps"
    menu_pair "3" "780 Mbps" "4" "1 Gbps"
    menu_pair "5" "2 Gbps" "6" "自定义输入"
    menu_item "7" "取消限速" "$YELLOW"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择限速 [0-7]: ')" CH

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
        local REMOVE_RC TC_BIN
        bbr_remove_tc
        REMOVE_RC=$?
        if [ "$REMOVE_RC" -eq 2 ]; then
            TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
            bbr_tc_remove_confirm "$DEV" "$TC_BIN" || return
            bbr_remove_tc 1
        elif [ "$REMOVE_RC" -ne 0 ]; then
            return "$REMOVE_RC"
        fi
    else
        local APPLY_RC TC_BIN
        bbr_apply_tc "$RATE"
        APPLY_RC=$?
        if [ "$APPLY_RC" -eq 2 ]; then
            TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
            bbr_tc_force_confirm "$DEV" "$RATE" "$TC_BIN" || return
            bbr_apply_tc "$RATE" 1
        elif [ "$APPLY_RC" -ne 0 ]; then
            return "$APPLY_RC"
        fi
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

bbr_default_route_info() {
    local ROUTE
    ROUTE=$(ip -4 route show default 2>/dev/null | head -1)
    if [ -n "$ROUTE" ]; then
        printf '4|%s\n' "$ROUTE"
        return 0
    fi
    ROUTE=$(ip -6 route show default 2>/dev/null | head -1)
    [ -n "$ROUTE" ] || return 1
    printf '6|%s\n' "$ROUTE"
}

bbr_route_token() {
    local ROUTE="$1" TOKEN="$2"
    awk -v token="$TOKEN" '{ for (i=1; i<=NF; i++) if ($i == token) { print $(i+1); exit } }' <<< "$ROUTE"
}

bbr_route_strip_cwnd() {
    awk '
        {
            out=""
            for (i=1; i<=NF; i++) {
                if ($i == "initcwnd" || $i == "initrwnd") { i++; continue }
                out = out (out == "" ? "" : " ") $i
            }
            print out
        }
    ' <<< "$1"
}

bbr_apply_initcwnd_route() {
    local FAMILY="$1" ROUTE="$2" VAL="$3" BASE_ROUTE
    local -a ROUTE_ARGS
    BASE_ROUTE=$(bbr_route_strip_cwnd "$ROUTE")
    read -r -a ROUTE_ARGS <<< "$BASE_ROUTE"
    [ "${ROUTE_ARGS[0]:-}" = default ] || return 1
    ip "-${FAMILY}" route replace "${ROUTE_ARGS[@]}" initcwnd "$VAL" initrwnd "$VAL"
}

bbr_cwnd_write_persistence() {
    local FAMILY="$1" ROUTE="$2" VAL="$3" TMP
    [ -n "$ROUTE" ] || return 1
    mkdir -p "$(dirname "$CWND_HELPER")" "$(dirname "$CWND_STATE_FILE")" 2>/dev/null || return 1
    TMP=$(mktemp "${CWND_STATE_FILE}.tmp.XXXXXX") || return 1
    printf 'FAMILY=%s\nVALUE=%s\n' "$FAMILY" "$VAL" > "$TMP" || {
        rm -f "$TMP"
        return 1
    }
    chmod 600 "$TMP" && mv "$TMP" "$CWND_STATE_FILE" || { rm -f "$TMP"; return 1; }

    TMP=$(mktemp "${CWND_HELPER}.tmp.XXXXXX") || return 1
    cat > "$TMP" << 'CWND_HELPER_EOF'
#!/bin/sh
STATE=/var/lib/vps-tools/initcwnd.state
state_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE"; }
FAMILY=$(state_value FAMILY)
VALUE=$(state_value VALUE)
case "$FAMILY" in 4|6) : ;; *) exit 1 ;; esac
echo "$VALUE" | grep -qE '^[0-9]+$' || exit 1
case "${1:-apply}" in
    remove) exit 0 ;;
    status) ip "-${FAMILY}" route show default 2>/dev/null | grep -q "initcwnd ${VALUE}"; exit $? ;;
esac
ROUTE=$(ip "-${FAMILY}" route show default 2>/dev/null | head -1 | awk '
    {
        out=""
        for (i=1; i<=NF; i++) {
            if ($i == "initcwnd" || $i == "initrwnd") { i++; continue }
            out = out (out == "" ? "" : " ") $i
        }
        print out
    }
')
[ -n "$ROUTE" ] || exit 1
# ROUTE comes from iproute2 and is split back into individual route arguments.
# shellcheck disable=SC2086
set -- $ROUTE
[ "${1:-}" = default ] || exit 1
ip "-${FAMILY}" route replace "$@" initcwnd "$VALUE" initrwnd "$VALUE"
CWND_HELPER_EOF
    chmod 700 "$TMP" && mv "$TMP" "$CWND_HELPER" || { rm -f "$TMP"; return 1; }

    if systemd_available; then
        TMP=$(mktemp "${SERVICE_CWND}.tmp.XXXXXX") || return 1
        cat > "$TMP" << EOF
[Unit]
Description=VPS TOOLS TCP initcwnd
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${CWND_HELPER} apply
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        mv "$TMP" "$SERVICE_CWND" || { rm -f "$TMP"; return 1; }
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable initcwnd --quiet >/dev/null 2>&1 \
            && systemctl restart initcwnd >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" openrc || return 1
        rc-update add initcwnd default >/dev/null 2>&1 \
            && rc-service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" sysv || return 1
        update-rc.d initcwnd defaults >/dev/null 2>&1 \
            && service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 SysV 持久化失败"
                return 1
            }
    else
        error "initcwnd 已立即生效，但未检测到支持的服务管理器，无法设置开机恢复"
        return 1
    fi
}

bbr_set_initcwnd_value() {
    local VAL="$1" ROUTE_INFO FAMILY ROUTE DEV
    bbr_positive_int "$VAL" 1 1000 || { error "initcwnd 必须为 1-1000"; return 1; }
    if is_lxc; then
        warn "LXC/OpenVZ 通常无权修改默认路由，已跳过 initcwnd"
        return 2
    fi
    ROUTE_INFO=$(bbr_default_route_info) || {
        error "未找到 IPv4 或 IPv6 默认路由"
        return 1
    }
    FAMILY=${ROUTE_INFO%%|*}
    ROUTE=${ROUTE_INFO#*|}
    DEV=$(bbr_route_token "$ROUTE" dev)
    [ -n "$DEV" ] || { error "默认路由缺少出口网卡"; return 1; }
    bbr_apply_initcwnd_route "$FAMILY" "$ROUTE" "$VAL" || {
        error "ip route 设置 initcwnd 失败"
        return 1
    }
    bbr_cwnd_write_persistence "$FAMILY" "$ROUTE" "$VAL" || {
        error "initcwnd 已立即生效，但持久化配置未完成"
        return 1
    }
    info "initcwnd/initrwnd 已设为 ${VAL}，重启后自动恢复 ✓"
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

    local ROUTE_INFO FAMILY ROUTE DEV GW
    ROUTE_INFO=$(bbr_default_route_info) || {
        error "未找到 IPv4 或 IPv6 默认路由"
        return 1
    }
    FAMILY=${ROUTE_INFO%%|*}
    ROUTE=${ROUTE_INFO#*|}
    DEV=$(bbr_route_token "$ROUTE" dev)
    GW=$(bbr_route_token "$ROUTE" via)
    [ -n "$DEV" ] || { error "默认路由缺少出口网卡"; return 1; }
    local CUR; CUR=$(bbr_route_token "$ROUTE" initcwnd)
    CUR="${CUR:-10（默认）}"

    echo -e "  协议：${BOLD}IPv${FAMILY}${NC}  网卡：${BOLD}${DEV}${NC}  网关：${BOLD}${GW:-直连}${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    echo ""
    menu_div
    menu_item "1" "10 · 默认保守"
    menu_item "2" "32 · 跨境单流推荐"
    menu_item "3" "50 · 较激进"
    menu_item "4" "100 · 高风险，可能丢包" "$YELLOW"
    menu_item "5" "自定义输入"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择 initcwnd [0-5]: ')" CH

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=32 ;;
        3) VAL=50 ;;
        4) VAL=100 ;;
        5)
            read -rp "  请输入 initcwnd 值（1-1000）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
                error "无效数值"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    bbr_set_initcwnd_value "$VAL"
}

# ── BBR 主菜单 ────────────────────────────────────────────

# ── 一键 TCP 预设（三种场景）────────────────────────────
volcano_tcp_profile() {
    local PROFILE="${1:-balanced}"
    local RMEM WMEM NOTSENT SWAP LABEL BUF_MB MEM_MB BUFFER_CAP
    MEM_MB=$(bbr_physical_memory_mb)
    if [ "$MEM_MB" -le 0 ]; then
        warn "无法读取物理内存，按 512MB 保守计算"
        MEM_MB=512
    fi
    case "$PROFILE" in
        balanced)
            if [ "$MEM_MB" -lt 512 ]; then
                RMEM=16777216; BUF_MB=16
            elif [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432; BUF_MB=32
            else
                RMEM=67108864; BUF_MB=64
            fi
            NOTSENT=262144; SWAP=10
            LABEL="均衡跨境  — 网页/代理/日常综合（推荐）" ;;
        latency)
            RMEM=33554432; NOTSENT=131072; SWAP=10; BUF_MB=32
            LABEL="低延迟交互 — SSH/游戏/远程桌面/小包优先" ;;
        throughput)
            # 根据内存动态选缓冲区，万兆机器自动用大缓冲
            if [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;   BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728;  BUF_MB=128
            elif [ "$MEM_MB" -lt 8192 ]; then
                RMEM=268435456;  BUF_MB=256
            else
                RMEM=536870912;  BUF_MB=512
            fi
            NOTSENT=2097152; SWAP=5
            LABEL="高吞吐传输 — 大带宽/万兆/下载上传优先" ;;
        relay)
            # 中转机：两进两出，需要均衡缓冲+低延迟+大并发
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128
            else
                RMEM=268435456; BUF_MB=256
            fi
            NOTSENT=262144; SWAP=10
            LABEL="中转机 — 双向流量/大并发/均衡延迟与吞吐" ;;
        landing)
            # 落地机：流量主要是单向上行，跨境延迟高，需要大缓冲吃满带宽
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=67108864;   BUF_MB=64
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=134217728;  BUF_MB=128
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=268435456;  BUF_MB=256
            else
                RMEM=536870912;  BUF_MB=512
            fi
            NOTSENT=2097152; SWAP=5
            LABEL="落地机 — 跨境上行/大缓冲吃满带宽" ;;
        line_landing)
            # 线路落地机：直连用户/CN2/IPLC 线路，低延迟优先+中等吞吐
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128
            else
                RMEM=268435456; BUF_MB=256
            fi
            NOTSENT=131072; SWAP=5
            LABEL="线路落地机 — CN2/IPLC/直连用户/低延迟优先" ;;
        *) error "未知预设：$PROFILE"; return 1 ;;
    esac

    WMEM=$RMEM
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "预设缓冲区 ${BUF_MB}MB 超过实际内存 ${MEM_MB}MB 的 25%，已自动降级"
        RMEM=$BUFFER_CAP
        WMEM=$BUFFER_CAP
        BUF_MB=$(( RMEM / 1048576 ))
    fi

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" "$LABEL" "$BUF_MB" "$PROFILE"
}

# ── 智能 TCP 调优向导 ────────────────────────────────────
bbr_recommend_profile() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -lt 768 ]; then
        echo latency
    elif [ "$MEM_MB" -lt 4096 ]; then
        echo balanced
    else
        echo throughput
    fi
}

bbr_smart_wizard() {
    print_header "跨境单线程 BBR 自适应向导"
    local MEM_MB KERNEL CUR_CC BW_MBPS RTT_MS APPLY_RC ANSWER
    local PEER PORT FAMILY FAMILY_CH ESTIMATE INSTALL_IPERF SWEEP_RC
    MEM_MB=$(bbr_physical_memory_mb)
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")

    menu_group "当前环境"
    echo -e "  内存：${GREEN}${MEM_MB}MB${NC}  内核：${GREEN}${KERNEL}${NC}  拥塞控制：${GREEN}${CUR_CC}${NC}"
    echo ""
    menu_div
    echo -e "  ${BOLD}目标：美国 VPS ↔ 远端用户的 TCP 单连接吞吐${NC}"
    echo -e "  ${DIM}缓冲按 2×BDP+2MiB 连续推导，不再按固定内存档位套参数${NC}"
    echo -e "  ${DIM}可选使用近端 iperf3 对端实测端口 policer 拐点${NC}"
    menu_div
    echo ""
    read -rp "  请输入 VPS 套餐带宽（Mbps，输入 0 返回）: " BW_MBPS
    [ "$BW_MBPS" != 0 ] || return
    bbr_positive_int "$BW_MBPS" 1 100000 || { error "带宽必须为 1-100000 的整数"; return 1; }
    read -rp "  请输入 VPS 到目标用户的 RTT（ms，默认180）: " RTT_MS
    [ -n "$RTT_MS" ] || RTT_MS=180
    bbr_positive_int "$RTT_MS" 1 2000 || { error "RTT 必须为 1-2000 的整数"; return 1; }

    APPLY_RC=0
    bbr_single_stream_apply "$BW_MBPS" "$RTT_MS" || APPLY_RC=$?
    [ "$APPLY_RC" -eq 0 ] || return "$APPLY_RC"

    if [ "$BW_MBPS" -gt 100 ]; then
        echo ""
        read -rp "  将 initcwnd/initrwnd 设为 32 以加快新单流起步？(Y/n，默认Y): " ANSWER
        [ -n "$ANSWER" ] || ANSWER=y
        if echo "$ANSWER" | grep -qiE '^y(es)?$'; then
            bbr_set_initcwnd_value 32 || warn "initcwnd 未完成，基础 BBR 配置仍已生效"
        fi
    else
        info "带宽不高于 100Mbps，不主动增大 initcwnd"
    fi

    echo ""
    menu_div
    echo -e "  ${BOLD}可选：实测 VPS 端口 policer 拐点${NC}"
    echo -e "  ${DIM}对端应与 VPS 地理上接近，且速度高于本机；不要用中国客户端作对端${NC}"
    echo -e "  ${DIM}留空即跳过，不影响已应用的 BBR/缓冲配置${NC}"
    read -rp "  iperf3 对端主机名或 IP（留空跳过）: " PEER
    if [ -z "$PEER" ]; then
        info "已跳过拐点扫描；当前保持纯 fq，不新增硬限速"
        return 0
    fi
    read -rp "  iperf3 端口（默认5201）: " PORT
    [ -n "$PORT" ] || PORT=5201
    bbr_positive_int "$PORT" 1 65535 || { error "端口必须为 1-65535"; return 1; }
    read -rp "  协议族 4=IPv4 / 6=IPv6（默认4）: " FAMILY_CH
    [ -n "$FAMILY_CH" ] || FAMILY_CH=4
    case "$FAMILY_CH" in
        4) FAMILY=-4 ;;
        6) FAMILY=-6 ;;
        *) error "协议族只能选 4 或 6"; return 1 ;;
    esac

    if ! command -v iperf3 >/dev/null 2>&1; then
        read -rp "  未安装 iperf3，现在安装？(Y/n，默认Y): " INSTALL_IPERF
        [ -n "$INSTALL_IPERF" ] || INSTALL_IPERF=y
        if ! echo "$INSTALL_IPERF" | grep -qiE '^y(es)?$'; then
            warn "已跳过拐点扫描"
            return 0
        fi
        DEBIAN_FRONTEND=noninteractive pkg_install iperf3 || {
            error "iperf3 安装失败"
            return 1
        }
    fi
    ESTIMATE=$(bbr_sweep_estimate_gb "$BW_MBPS")
    warn "拐点扫描约需 5-15 分钟；按最多 16 个样本估算，上限约 ${ESTIMATE}GiB 流量"
    read -rp "  输入 SWEEP 确认执行带流量消耗的扫描: " ANSWER
    [ "$ANSWER" = SWEEP ] || { warn "已跳过拐点扫描"; return 0; }

    SWEEP_RC=0
    bbr_run_policer_sweep "$PEER" "$PORT" "$BW_MBPS" "$FAMILY" || SWEEP_RC=$?
    if [ "$SWEEP_RC" -eq 0 ] && [ -n "$BBR_SWEEP_RECOMMEND" ]; then
        read -rp "  按建议值 ${BBR_SWEEP_RECOMMEND}Mbps 应用 HTB + fq 持久限速？(Y/n，默认Y): " ANSWER
        [ -n "$ANSWER" ] || ANSWER=y
        if echo "$ANSWER" | grep -qiE '^y(es)?$'; then
            bbr_apply_tc "$BBR_SWEEP_RECOMMEND" || {
                error "拐点已找到，但建议限速未能应用"
                return 1
            }
        else
            info "仅保留测量结果，未修改持久限速"
        fi
    elif [ "$SWEEP_RC" -eq 3 ]; then
        info "本次没有得到可靠拐点，不会新增限速"
    else
        warn "拐点扫描未完成，但已应用的 BBR/缓冲配置不受影响"
    fi
}


# ── 检测是否有 sysctl 写入权限 ───────────────────────────
has_sysctl_write() {
    local CUR
    CUR=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null) || return 1
    [ -n "$CUR" ] || return 1
    # 写回原值来测试权限，避免探测动作改变系统 TCP 参数。
    sysctl -w "net.ipv4.tcp_fin_timeout=${CUR}" > /dev/null 2>&1 && return 0
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

    # Alpine 上安装/切换内核包通常需要重启，交给用户确认后再动系统包。
    if command -v apk &>/dev/null; then
        warn "tcp_bbr 模块未加载。Alpine 可能需要安装/切换内核包并重启。"
        read -rp "  尝试安装 linux-lts 或 linux-virt？(y/N，默认N): " APK_KERNEL
        [ -z "$APK_KERNEL" ] && APK_KERNEL="n"
        if echo "$APK_KERNEL" | grep -qiE '^y(es)?$'; then
            apk add --no-cache linux-lts 2>/dev/null || apk add --no-cache linux-virt 2>/dev/null || true
            modprobe tcp_bbr 2>/dev/null && { info "tcp_bbr 模块已加载 ✓"; return 0; }
            warn "内核包安装后通常需要 reboot 才会生效"
        fi
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

bbr_diagnose() {
    print_header "BBR 诊断"
    local DEV TC_BIN KERNEL CC AVAIL QDISC RATE SYSCTL_WRITABLE SERVICE_STATE
    DEV=$(default_iface)
    TC_BIN=$(command -v tc 2>/dev/null || true)
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    RATE="未设置"

    if [ -n "$DEV" ] && [ -n "$TC_BIN" ]; then
        RATE=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
    fi

    SYSCTL_WRITABLE="否"
    has_sysctl_write && SYSCTL_WRITABLE="是"

    SERVICE_STATE="未安装"
    if systemd_available && [ -f "$SERVICE_TC" ]; then
        SERVICE_STATE=$(systemctl is-enabled tc-fq 2>/dev/null || echo "已安装未启用")
    elif [ -f "$SERVICE_TC_INIT" ]; then
        if command -v rc-service >/dev/null 2>&1 && rc-service tc-fq status >/dev/null 2>&1; then
            SERVICE_STATE="已启用"
        else
            SERVICE_STATE="已安装未运行"
        fi
    fi

    echo -e "  内核版本: ${BOLD}${KERNEL}${NC}"
    echo -e "  默认网卡: ${BOLD}${DEV:-未知}${NC}"
    echo -e "  tc 命令: ${BOLD}${TC_BIN:-未安装}${NC}"
    echo -e "  拥塞算法: ${BOLD}${CC}${NC}"
    echo -e "  可用算法: ${BOLD}${AVAIL}${NC}"
    echo -e "  默认队列: ${BOLD}${QDISC}${NC}"
    echo -e "  tc 限速: ${BOLD}${RATE}${NC}"
    echo -e "  tc-fq 服务: ${BOLD}${SERVICE_STATE}${NC}"
    echo -e "  sysctl 可写: ${BOLD}${SYSCTL_WRITABLE}${NC}"

    [ "$CC" = "bbr" ] || warn "当前未启用 BBR 拥塞算法"
    echo "$AVAIL" | grep -qw bbr || warn "可用拥塞算法里没有 bbr，可能需要升级/切换内核"
    [ "$QDISC" = "fq" ] || warn "默认队列不是 fq，BBR pacing 可能不完整"
    if [ -f "$SYSCTL_FILE" ] && grep -q '^# skipped unsupported:' "$SYSCTL_FILE"; then
        warn "检测到不支持的 sysctl 参数已被注释："
        grep '^# skipped unsupported:' "$SYSCTL_FILE" | sed 's/^/    /'
    fi
}

bbr_menu() {
    # 进入时检测一次 sysctl 写入权限
    local _BBR_NO_SYSCTL=0
    if ! ensure_sysctl || ! has_sysctl_write; then
        _BBR_NO_SYSCTL=1
    fi
    [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved || true
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
        menu_group "调优"
        menu_item "1" "智能向导  ${DIM}推荐${NC}"
        menu_pair "2" "自动配置" "3" "手动配置"
        menu_pair "4" "限速设置" "5" "initcwnd 设置"
        echo ""
        menu_group "维护"
        menu_pair "6" "备份 TCP 配置" "7" "还原 TCP 配置"
        menu_item "8" "BBR 诊断"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-8]: ')" CH

        case "$CH" in
            1) bbr_smart_wizard ;;
            2) bbr_menu_auto ;;
            3) bbr_menu_manual ;;
            4) bbr_menu_tc ;;
            5) bbr_menu_initcwnd ;;
            6) bbr_backup_sysctl ;;
            7) bbr_restore_sysctl ;;
            8) bbr_diagnose ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

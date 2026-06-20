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
    local id f lip ls le ttype thost tip ts te _md match
    while IFS='|' read -r id f lip ls le ttype thost tip ts te _md; do
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
        if ! systemctl restart nftables &>/dev/null; then
            nft -f "$NFT_CONFIG_FILE" &>/dev/null || {
                error "nftables 配置应用失败"
                return 1
            }
        fi
    elif command -v rc-service &>/dev/null; then
        rc-update add nftables default 2>/dev/null || true
        rc-service nftables restart &>/dev/null || nft -f "$NFT_CONFIG_FILE" &>/dev/null || {
            error "nftables 配置应用失败"
            return 1
        }
    else
        nft -f "$NFT_CONFIG_FILE" &>/dev/null || {
            error "nftables 配置应用失败"
            return 1
        }
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
        menu_item "1" "1:1 映射  ${DIM}目标端口段等于监听端口段${NC}"
        menu_item "2" "端口段偏移  ${DIM}指定目标起始端口${NC}"
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
        menu_item "1" "1:1 映射"
        menu_item "2" "端口段偏移"
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
            [ -z "$prefix" ] || { [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]; } || return 1
            NFT_AC_FAMILY="ipv4"
            ;;
        ipv6)
            [ -z "$prefix" ] || { [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ]; } || return 1
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
        menu_pair "1" "启用白名单" "2" "启用黑名单"
        menu_item "3" "关闭访问控制" "$YELLOW"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择模式: ')" ch

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
        ui_continue
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
    menu_pair "1" "TCP" "2" "UDP"
    menu_item "3" "TCP + UDP"
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
        menu_item "1" "添加本地端口转发"
        menu_pair "2" "删除指定规则" "3" "清空所有规则" "$YELLOW" "$YELLOW"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择操作: ')" ch

        case "$ch" in
            1) iptpf_add ;;
            2) iptpf_delete ;;
            3) iptpf_clear_all ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        echo ""
        ui_continue
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
            menu_pair "1" "添加单端口转发" "2" "添加端口段转发"
            menu_pair "3" "查看所有规则" "e" "修改规则"
            menu_pair "4" "删除规则" "5" "清空所有规则" "$YELLOW" "$YELLOW"
            echo ""
            menu_group "动态解析与访问"
            menu_item "6" "立即刷新 DDNS"
            if [ "$timer_st" = "active" ]; then
                menu_item "7" "关闭 DDNS 自动刷新" "$YELLOW"
            else
                menu_item "7" "启用 DDNS 自动刷新"
            fi
            menu_pair "8" "访问控制" "l" "iptables 本地转发"
            menu_item "9" "卸载 nftables" "$YELLOW"
        else
            echo -e "  ${YELLOW}未检测到 nftables，请先安装：${NC}"
            menu_item "i" "安装 nftables"
            menu_item "l" "iptables 本地端口转发"
            menu_div
        fi
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择操作: ')" ch

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
        ui_continue
    done
}

# ══════════════════════════════════════════════════════════
#  网卡管理（Netplan / NetworkManager / ifupdown / ifcfg）
# ══════════════════════════════════════════════════════════

network_iface_name_valid() {
    local iface="${1:-}"
    [ -n "$iface" ] && [ "${#iface}" -le 15 ] \
        && [[ "$iface" =~ ^[A-Za-z0-9_-]+$ ]] \
        && [ "$iface" != lo ]
}

network_iface_valid() {
    network_iface_name_valid "$1" && [ -d "/sys/class/net/$1" ]
}

network_ipv4_valid() {
    local ip="${1:-}" part
    local parts=()
    IFS=. read -r -a parts <<< "$ip"
    [ "${#parts[@]}" -eq 4 ] || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]+$ ]] && [ "${#part}" -le 3 ] \
            && [ "$((10#$part))" -le 255 ] || return 1
        [ "${#part}" -eq 1 ] || [ "${part#0}" = "$part" ] || return 1
    done
}

network_mask_to_prefix() {
    local mask="${1:-}" octet value prefix=0 partial=no
    local parts=()
    IFS=. read -r -a parts <<< "$mask"
    [ "${#parts[@]}" -eq 4 ] || return 1
    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && [ "${#octet}" -le 3 ] || return 1
        value=$((10#$octet))
        if [ "$partial" = yes ] && [ "$value" -ne 0 ]; then
            return 1
        fi
        case "$value" in
            255) prefix=$((prefix + 8)) ;;
            254) prefix=$((prefix + 7)); partial=yes ;;
            252) prefix=$((prefix + 6)); partial=yes ;;
            248) prefix=$((prefix + 5)); partial=yes ;;
            240) prefix=$((prefix + 4)); partial=yes ;;
            224) prefix=$((prefix + 3)); partial=yes ;;
            192) prefix=$((prefix + 2)); partial=yes ;;
            128) prefix=$((prefix + 1)); partial=yes ;;
            0) partial=yes ;;
            *) return 1 ;;
        esac
    done
    [ "$prefix" -ge 1 ] && printf '%s\n' "$prefix"
}

network_prefix_to_mask() {
    local prefix="${1:-}" bits value output="" index
    [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 1 ] \
        && [ "$prefix" -le 32 ] || return 1
    prefix=$((10#$prefix))
    for index in 1 2 3 4; do
        if [ "$prefix" -ge 8 ]; then
            value=255
            prefix=$((prefix - 8))
        elif [ "$prefix" -gt 0 ]; then
            bits=$prefix
            value=$((256 - (1 << (8 - bits))))
            prefix=0
        else
            value=0
        fi
        output+="${output:+.}${value}"
    done
    printf '%s\n' "$output"
}

network_ipv4_to_int() {
    local ip="$1" a b c d
    network_ipv4_valid "$ip" || return 1
    IFS=. read -r a b c d <<< "$ip"
    printf '%s\n' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
}

network_gateway_is_onlink() {
    local ip="$1" gateway="$2" prefix="$3" ip_num gateway_num mask
    ip_num=$(network_ipv4_to_int "$ip") || return 1
    gateway_num=$(network_ipv4_to_int "$gateway") || return 1
    if [ "$prefix" -eq 32 ]; then
        return 1
    fi
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    [ $((ip_num & mask)) -eq $((gateway_num & mask)) ]
}

network_interfaces() {
    local path iface
    for path in /sys/class/net/*; do
        [ -d "$path" ] || continue
        iface=${path##*/}
        [ "$iface" = lo ] || printf '%s\n' "$iface"
    done
}

network_nm_connection_uuid() {
    local iface="$1" uuid candidate
    command -v nmcli >/dev/null 2>&1 || return 1
    uuid=$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null | head -1)
    case "$uuid" in ""|--|*[!A-Fa-f0-9-]*) uuid="" ;; esac
    if [ -z "$uuid" ]; then
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            [ "$(nmcli -g connection.interface-name connection show uuid "$candidate" 2>/dev/null)" = "$iface" ] \
                && { uuid="$candidate"; break; }
        done < <(nmcli -g UUID connection show 2>/dev/null)
    fi
    [ -n "$uuid" ] && printf '%s\n' "$uuid"
}

network_backend_detect() {
    local iface="$1" netplan_iface="" has_netplan=no
    if command -v netplan >/dev/null 2>&1; then
        find /etc/netplan -maxdepth 1 -type f \
            \( -name '*.yaml' -o -name '*.yml' \) -print -quit 2>/dev/null \
            | grep -q . && has_netplan=yes
        netplan_iface=$(netplan get "ethernets.${iface}" 2>/dev/null || true)
    fi
    if command -v netplan >/dev/null 2>&1 \
        && [ "$has_netplan" = yes ] && [ -n "$netplan_iface" ]; then
        echo netplan
    elif command -v nmcli >/dev/null 2>&1 \
        && [ "$(LC_ALL=C nmcli -g GENERAL.NM-MANAGED device show "$iface" 2>/dev/null)" = yes ]; then
        echo networkmanager
    elif command -v networkctl >/dev/null 2>&1 \
        && svc_is_active systemd-networkd \
        && LC_ALL=C networkctl status --no-pager "$iface" 2>/dev/null \
            | grep -Eq 'Network File:[[:space:]]+/'; then
        echo networkd
    elif { [ -f /etc/network/interfaces ] || command -v ifquery >/dev/null 2>&1; } \
        && { grep -RqsE "^[[:space:]]*iface[[:space:]]+${iface}[[:space:]]+inet[[:space:]]" \
                /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null \
            || [ -e "/sys/class/net/$iface/device" ]; }; then
        echo ifupdown
    elif [ -f "/etc/sysconfig/network-scripts/ifcfg-${iface}" ] \
        || { [ -d /etc/sysconfig/network-scripts ] \
            && [ -e "/sys/class/net/$iface/device" ]; }; then
        echo ifcfg
    elif [ "$has_netplan" = yes ] && [ -e "/sys/class/net/$iface/device" ]; then
        echo netplan
    else
        return 1
    fi
}

network_backend_label() {
    case "$1" in
        netplan) echo "Netplan" ;;
        networkmanager) echo "NetworkManager" ;;
        networkd) echo "systemd-networkd" ;;
        ifupdown) echo "ifupdown" ;;
        ifcfg) echo "RHEL/CentOS ifcfg" ;;
        *) echo "未知" ;;
    esac
}

network_current_ipv4_cidr() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null \
        | awk '{print $4; exit}'
}

network_current_gateway() {
    ip -4 route show default dev "$1" 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}'
}

network_current_dns() {
    local iface="$1" value
    if command -v nmcli >/dev/null 2>&1; then
        while IFS= read -r value; do
            [ -n "$value" ] && [ "$value" != -- ] && printf '%s\n' "$value"
        done < <(nmcli -g IP4.DNS device show "$iface" 2>/dev/null)
    fi
    if ! command -v nmcli >/dev/null 2>&1 \
        || ! nmcli -g IP4.DNS device show "$iface" 2>/dev/null | grep -q '[0-9]'; then
        awk '$1 == "nameserver" && $2 ~ /^[0-9]+\./ {print $2}' \
            /etc/resolv.conf 2>/dev/null
    fi
}

network_show_interfaces() {
    local iface backend state mac cidr gateway dns
    print_header "网卡状态"
    while IFS= read -r iface; do
        backend=$(network_backend_detect "$iface" 2>/dev/null || echo 未识别)
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)
        mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
        cidr=$(network_current_ipv4_cidr "$iface")
        gateway=$(network_current_gateway "$iface")
        dns=$(network_current_dns "$iface" | paste -sd ',' -)
        echo -e "  ${BOLD}${iface}${NC}  ${DIM}$(network_backend_label "$backend") · $state${NC}"
        echo -e "    IPv4：${cidr:-未配置}"
        echo -e "    网关：${gateway:-未配置}"
        echo -e "    DNS ：${dns:-未检测到}"
        [ -z "$mac" ] || echo -e "    MAC ：$mac"
        echo ""
    done < <(network_interfaces)
}

network_select_interface() {
    local interfaces=() iface index=0 choice
    while IFS= read -r iface; do interfaces+=("$iface"); done < <(network_interfaces)
    [ "${#interfaces[@]}" -gt 0 ] || { error "未检测到可配置的网卡"; return 1; }
    echo ""
    menu_div
    for iface in "${interfaces[@]}"; do
        index=$((index + 1))
        printf '  %2d) %-16s  %-18s  %s\n' "$index" "$iface" \
            "$(network_current_ipv4_cidr "$iface")" \
            "$(network_backend_label "$(network_backend_detect "$iface" 2>/dev/null || true)")"
    done
    menu_item "0" "返回上级" "$RED"
    menu_div
    read -rp "$(ui_prompt "选择网卡 [0-${#interfaces[@]}]: ")" choice
    [ "$choice" = 0 ] && return 2
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] \
        && [ "$choice" -le "${#interfaces[@]}" ] \
        || { warn "无效网卡编号"; return 1; }
    NETWORK_SELECTED_IFACE=${interfaces[$((choice - 1))]}
}

network_write_atomic() {
    local target="$1" mode="${2:-600}" tmp
    mkdir -p "$(dirname "$target")" || return 1
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

network_netplan_write_static() {
    local iface="$1" ip_addr="$2" prefix="$3" gateway="$4" dns1="$5" dns2="$6"
    local origin="99-vps-tools-${iface}" dns_list onlink=false
    [ -z "$dns2" ] && dns_list="\"$dns1\"" || dns_list="\"$dns1\", \"$dns2\""
    network_gateway_is_onlink "$ip_addr" "$gateway" "$prefix" || onlink=true
    # Replacing our origin file avoids Netplan merging the previous route list
    # when the same interface is edited again (for example /24 -> /32).
    rm -f -- "/etc/netplan/${origin}.yaml"
    # netplan set writes an origin-aware override. This matters because plain
    # later YAML files concatenate address/route sequences instead of replacing
    # the earlier cloud-init or installer values.
    netplan set --origin-hint="$origin" \
        "ethernets.${iface}={dhcp4: false, addresses: [\"${ip_addr}/${prefix}\"], gateway4: null, routes: [{to: default, via: \"${gateway}\", on-link: ${onlink}}], nameservers: {addresses: [${dns_list}]}}" \
        >/dev/null 2>&1
}

network_netplan_write_dhcp() {
    local iface="$1" origin
    origin="99-vps-tools-${iface}"
    rm -f -- "/etc/netplan/${origin}.yaml"
    netplan set --origin-hint="$origin" \
        "ethernets.${iface}={dhcp4: true, addresses: null, gateway4: null, routes: null, nameservers: null, dhcp4-overrides: {use-dns: true, use-routes: true}}" \
        >/dev/null 2>&1
}

network_networkd_write_static() {
    local iface="$1" ip_addr="$2" prefix="$3" gateway="$4" dns1="$5" dns2="$6"
    local target="/etc/systemd/network/00-vps-tools-${iface}.network" onlink=no
    network_gateway_is_onlink "$ip_addr" "$gateway" "$prefix" || onlink=yes
    {
        printf '%s\n' '# Managed by VPS Tools. Use the network interface menu to edit.'
        printf '%s\n' '[Match]' "Name=$iface" '' '[Network]' \
            "Address=${ip_addr}/${prefix}" 'DHCP=ipv6' 'IPv6AcceptRA=yes' "DNS=$dns1"
        [ -z "$dns2" ] || printf '%s\n' "DNS=$dns2"
        printf '%s\n' '' '[Route]' 'Destination=0.0.0.0/0' "Gateway=$gateway"
        [ "$onlink" = no ] || printf '%s\n' 'GatewayOnLink=yes'
    } | network_write_atomic "$target" 600
}

network_networkd_write_dhcp() {
    local iface="$1" target="/etc/systemd/network/00-vps-tools-${iface}.network"
    {
        printf '%s\n' '# Managed by VPS Tools. Use the network interface menu to edit.'
        printf '%s\n' '[Match]' "Name=$iface" '' '[Network]' 'DHCP=yes' 'IPv6AcceptRA=yes'
    } | network_write_atomic "$target" 600
}

network_ifupdown_strip_ipv4() {
    local iface="$1" file tmp
    while IFS= read -r -d '' file; do
        [ "$file" = "/etc/network/interfaces.d/90-vps-tools-${iface}.cfg" ] && continue
        grep -Eq "^[[:space:]]*iface[[:space:]]+${iface}[[:space:]]+inet[[:space:]]" "$file" 2>/dev/null \
            || continue
        tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
        awk -v iface="$iface" '
            function emit_activation(    i, out) {
                out=$1
                for (i=2; i<=NF; i++) if ($i != iface) out=out " " $i
                if (out != $1) print out
            }
            skipping && /^[ \t]/ {next}
            skipping {skipping=0}
            ($1 == "auto" || $1 == "allow-hotplug") {
                for (i=2; i<=NF; i++) if ($i == iface) {emit_activation(); next}
            }
            $1 == "iface" && $2 == iface && $3 == "inet" {skipping=1; next}
            {print}
        ' "$file" > "$tmp" && chmod --reference="$file" "$tmp" 2>/dev/null \
            && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    done < <(find /etc/network/interfaces /etc/network/interfaces.d \
        -maxdepth 1 -type f -print0 2>/dev/null)
}

network_ifupdown_ensure_source() {
    local file=/etc/network/interfaces tmp
    mkdir -p /etc/network/interfaces.d || return 1
    [ -f "$file" ] || printf '%s\n' 'auto lo' 'iface lo inet loopback' > "$file"
    grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d/' "$file" \
        && return 0
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    { cat "$file"; printf '\nsource /etc/network/interfaces.d/*\n'; } > "$tmp" \
        && chmod --reference="$file" "$tmp" 2>/dev/null \
        && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

network_ifupdown_write_static() {
    local iface="$1" ip_addr="$2" prefix="$3" gateway="$4" dns1="$5" dns2="$6"
    local mask target="/etc/network/interfaces.d/90-vps-tools-${iface}.cfg"
    mask=$(network_prefix_to_mask "$prefix") || return 1
    network_ifupdown_strip_ipv4 "$iface" && network_ifupdown_ensure_source || return 1
    {
        printf '%s\n' '# Managed by VPS Tools. Use the network interface menu to edit.'
        printf 'auto %s\niface %s inet static\n' "$iface" "$iface"
        printf '    address %s\n    netmask %s\n' "$ip_addr" "$mask"
        if network_gateway_is_onlink "$ip_addr" "$gateway" "$prefix"; then
            printf '    up ip route replace default via %s dev %s\n' "$gateway" "$iface"
        else
            printf '    up ip route replace default via %s dev %s onlink\n' "$gateway" "$iface"
        fi
        printf '    down ip route del default via %s dev %s 2>/dev/null || true\n' "$gateway" "$iface"
        printf '    dns-nameservers %s%s\n' "$dns1" "${dns2:+ $dns2}"
    } | network_write_atomic "$target" 600
}

network_ifupdown_write_dhcp() {
    local iface="$1" target="/etc/network/interfaces.d/90-vps-tools-${iface}.cfg"
    network_ifupdown_strip_ipv4 "$iface" && network_ifupdown_ensure_source || return 1
    {
        printf '%s\n' '# Managed by VPS Tools. Use the network interface menu to edit.'
        printf 'auto %s\niface %s inet dhcp\n' "$iface" "$iface"
    } | network_write_atomic "$target" 600
}

network_ifcfg_write() {
    local iface="$1" mode="$2" ip_addr="${3:-}" prefix="${4:-}" gateway="${5:-}"
    local dns1="${6:-}" dns2="${7:-}" target="/etc/sysconfig/network-scripts/ifcfg-${iface}" tmp
    mkdir -p /etc/sysconfig/network-scripts || return 1
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if [ -f "$target" ]; then
        grep -Ev '^(TYPE|DEVICE|NAME|ONBOOT|BOOTPROTO|IPADDR|PREFIX|NETMASK|GATEWAY|GATEWAYDEV|DNS1|DNS2|PEERDNS|DEFROUTE)=' \
            "$target" > "$tmp" || true
    fi
    {
        cat "$tmp"
        printf '%s\n' 'TYPE=Ethernet' "DEVICE=$iface" "NAME=$iface" 'ONBOOT=yes' 'DEFROUTE=yes'
        if [ "$mode" = static ]; then
            printf '%s\n' 'BOOTPROTO=none' "IPADDR=$ip_addr" "PREFIX=$prefix" 'PEERDNS=no' "DNS1=$dns1"
            network_gateway_is_onlink "$ip_addr" "$gateway" "$prefix" \
                && printf '%s\n' "GATEWAY=$gateway"
            [ -z "$dns2" ] || printf '%s\n' "DNS2=$dns2"
        else
            printf '%s\n' 'BOOTPROTO=dhcp' 'PEERDNS=yes'
        fi
    } | network_write_atomic "$target" 600 || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    if [ "$mode" = static ] && ! network_gateway_is_onlink "$ip_addr" "$gateway" "$prefix"; then
        network_ifcfg_route_managed "$iface" "default via $gateway dev $iface onlink"
    else
        network_ifcfg_route_managed "$iface" ""
    fi
}

network_ifcfg_route_managed() {
    local iface="$1" route_line="$2" target="/etc/sysconfig/network-scripts/route-${iface}" tmp
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if [ -f "$target" ]; then
        awk '
            $0 == "# BEGIN VPS-TOOLS MANAGED DEFAULT ROUTE" {skip=1; next}
            $0 == "# END VPS-TOOLS MANAGED DEFAULT ROUTE" {skip=0; next}
            !skip {print}
        ' "$target" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    if [ -n "$route_line" ]; then
        printf '%s\n%s\n%s\n' '# BEGIN VPS-TOOLS MANAGED DEFAULT ROUTE' \
            "$route_line" '# END VPS-TOOLS MANAGED DEFAULT ROUTE' >> "$tmp" || {
                rm -f -- "$tmp"
                return 1
            }
    fi
    if [ -s "$tmp" ]; then
        chmod 600 "$tmp" && mv -f -- "$tmp" "$target"
    else
        rm -f -- "$tmp" "$target"
    fi
}

network_nm_prepare_connection() {
    local iface="$1" uuid
    uuid=$(network_nm_connection_uuid "$iface" 2>/dev/null || true)
    if [ -z "$uuid" ]; then
        nmcli connection add type ethernet ifname "$iface" \
            con-name "vps-tools-$iface" >/dev/null 2>&1 || return 1
        uuid=$(network_nm_connection_uuid "$iface" 2>/dev/null || true)
        [ -n "$uuid" ] || uuid=$(nmcli -g UUID connection show "vps-tools-$iface" 2>/dev/null | head -1)
    fi
    [ -n "$uuid" ] || return 1
    NETWORK_ACTIVE_NM_UUID="$uuid"
}

network_nm_write_static() {
    local iface="$1" ip_addr="$2" prefix="$3" gateway="$4" dns1="$5" dns2="$6"
    local dns="$dns1${dns2:+,$dns2}" route=""
    network_nm_prepare_connection "$iface" || return 1
    if network_gateway_is_onlink "$ip_addr" "$gateway" "$prefix"; then
        nmcli connection modify uuid "$NETWORK_ACTIVE_NM_UUID" \
            connection.interface-name "$iface" connection.autoconnect yes \
            ipv4.method manual ipv4.addresses "${ip_addr}/${prefix}" \
            ipv4.gateway "$gateway" ipv4.routes '' ipv4.dns "$dns" \
            ipv4.ignore-auto-dns yes ipv4.never-default no >/dev/null 2>&1
    else
        route="${gateway}/32,0.0.0.0/0 ${gateway} onlink=true"
        nmcli connection modify uuid "$NETWORK_ACTIVE_NM_UUID" \
            connection.interface-name "$iface" connection.autoconnect yes \
            ipv4.method manual ipv4.addresses "${ip_addr}/${prefix}" \
            ipv4.gateway '' ipv4.routes "$route" ipv4.dns "$dns" \
            ipv4.ignore-auto-dns yes ipv4.never-default no >/dev/null 2>&1
    fi
}

network_nm_write_dhcp() {
    local iface="$1"
    network_nm_prepare_connection "$iface" || return 1
    nmcli connection modify uuid "$NETWORK_ACTIVE_NM_UUID" \
        connection.interface-name "$iface" connection.autoconnect yes \
        ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.routes '' ipv4.dns '' \
        ipv4.ignore-auto-dns no ipv4.never-default no >/dev/null 2>&1
}

network_backend_validate() {
    case "$1" in
        netplan) netplan generate >/dev/null 2>&1 ;;
        networkmanager) nmcli connection show uuid "$NETWORK_ACTIVE_NM_UUID" >/dev/null 2>&1 ;;
        networkd) grep -q '^\[Network\]$' "/etc/systemd/network/00-vps-tools-$2.network" ;;
        ifupdown)
            if command -v ifquery >/dev/null 2>&1; then
                ifquery "$2" >/dev/null 2>&1
            else
                return 0
            fi
            ;;
        ifcfg) grep -q '^DEVICE=' "/etc/sysconfig/network-scripts/ifcfg-$2" ;;
        *) return 1 ;;
    esac
}

network_backend_apply() {
    local backend="$1" iface="$2"
    case "$backend" in
        netplan) netplan apply >/dev/null 2>&1 ;;
        networkmanager)
            nmcli connection reload >/dev/null 2>&1 \
                && nmcli connection up uuid "$NETWORK_ACTIVE_NM_UUID" \
                    ifname "$iface" >/dev/null 2>&1
            ;;
        networkd)
            networkctl reload >/dev/null 2>&1 \
                && { networkctl reconfigure "$iface" >/dev/null 2>&1 \
                    || svc_restart systemd-networkd; }
            ;;
        ifupdown)
            ifdown --force "$iface" >/dev/null 2>&1 || true
            ifup "$iface" >/dev/null 2>&1
            ;;
        ifcfg)
            if command -v nmcli >/dev/null 2>&1; then
                nmcli connection reload >/dev/null 2>&1 \
                    && { nmcli connection up "$iface" ifname "$iface" >/dev/null 2>&1 \
                        || nmcli device connect "$iface" >/dev/null 2>&1; }
            elif command -v ifup >/dev/null 2>&1; then
                ifdown "$iface" >/dev/null 2>&1 || true
                ifup "$iface" >/dev/null 2>&1
            else
                svc_restart network
            fi
            ;;
        *) return 1 ;;
    esac
}

network_static_configure() {
    local iface backend current_cidr current_ip current_prefix current_mask
    local current_gateway dns_values=() default_dns1 default_dns2
    local ip_addr mask prefix gateway dns1 dns2
    print_header "新增 / 修改静态 IPv4"
    network_select_interface
    case "$?" in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    iface="$NETWORK_SELECTED_IFACE"
    network_iface_valid "$iface" || { error "网卡名称无效"; return 1; }
    backend=$(network_backend_detect "$iface" 2>/dev/null || true)
    [ -n "$backend" ] || { error "无法识别 $iface 的网络配置后端"; return 1; }
    current_cidr=$(network_current_ipv4_cidr "$iface")
    current_ip=${current_cidr%/*}; [ "$current_ip" = "$current_cidr" ] && current_ip=""
    current_prefix=${current_cidr#*/}; [ "$current_prefix" = "$current_cidr" ] && current_prefix=""
    [ -z "$current_prefix" ] || current_mask=$(network_prefix_to_mask "$current_prefix")
    current_gateway=$(network_current_gateway "$iface")
    while IFS= read -r dns1; do [ -n "$dns1" ] && dns_values+=("$dns1"); done \
        < <(network_current_dns "$iface")
    default_dns1=${dns_values[0]:-1.1.1.1}
    default_dns2=${dns_values[1]:-8.8.8.8}

    echo -e "  配置后端：${BOLD}$(network_backend_label "$backend")${NC}"
    read -rp "$(ui_prompt "IPv4 地址${current_ip:+ [${current_ip}]}: ")" ip_addr
    ip_addr=${ip_addr:-$current_ip}
    network_ipv4_valid "$ip_addr" || { error "IPv4 地址格式无效"; return 1; }
    read -rp "$(ui_prompt "子网掩码或前缀${current_mask:+ [${current_mask}]}: ")" mask
    mask=${mask:-$current_mask}
    if [[ "$mask" =~ ^/?[0-9]+$ ]]; then
        prefix=${mask#/}
        [ "$prefix" -ge 1 ] 2>/dev/null && [ "$prefix" -le 32 ] 2>/dev/null \
            || { error "CIDR 前缀必须是 1-32"; return 1; }
        prefix=$((10#$prefix))
        mask=$(network_prefix_to_mask "$prefix")
    else
        prefix=$(network_mask_to_prefix "$mask") \
            || { error "子网掩码无效或不连续"; return 1; }
    fi
    read -rp "$(ui_prompt "默认网关${current_gateway:+ [${current_gateway}]}: ")" gateway
    gateway=${gateway:-$current_gateway}
    network_ipv4_valid "$gateway" || { error "默认网关格式无效"; return 1; }
    [ "$gateway" != "$ip_addr" ] || { error "默认网关不能与网卡 IP 相同"; return 1; }
    read -rp "$(ui_prompt "主 DNS [${default_dns1}]: ")" dns1
    dns1=${dns1:-$default_dns1}
    network_ipv4_valid "$dns1" || { error "主 DNS 格式无效"; return 1; }
    read -rp "$(ui_prompt "备用 DNS [${default_dns2}]（输入 - 表示不设置）: ")" dns2
    dns2=${dns2:-$default_dns2}; [ "$dns2" = - ] && dns2=""
    [ -z "$dns2" ] || network_ipv4_valid "$dns2" \
        || { error "备用 DNS 格式无效"; return 1; }

    confirm_change_preview "配置 $iface 静态 IPv4" \
        "后端：$(network_backend_label "$backend")" "地址：${ip_addr}/${prefix}（${mask}）" \
        "网关：$gateway" "DNS：$dns1${dns2:+、$dns2}" \
        "应用后必须从新终端确认连接，否则 180 秒后自动恢复" || { warn "已取消"; return 0; }

    NETWORK_ROLLBACK_BACKEND="$backend"
    NETWORK_ROLLBACK_IFACE="$iface"
    NETWORK_ROLLBACK_NM_UUID=""
    [ "$backend" != networkmanager ] \
        || NETWORK_ROLLBACK_NM_UUID=$(network_nm_connection_uuid "$iface" 2>/dev/null || true)
    safety_arm network_interface || return 1
    case "$backend" in
        netplan) network_netplan_write_static "$iface" "$ip_addr" "$prefix" "$gateway" "$dns1" "$dns2" ;;
        networkmanager) network_nm_write_static "$iface" "$ip_addr" "$prefix" "$gateway" "$dns1" "$dns2" ;;
        networkd) network_networkd_write_static "$iface" "$ip_addr" "$prefix" "$gateway" "$dns1" "$dns2" ;;
        ifupdown) network_ifupdown_write_static "$iface" "$ip_addr" "$prefix" "$gateway" "$dns1" "$dns2" ;;
        ifcfg) network_ifcfg_write "$iface" static "$ip_addr" "$prefix" "$gateway" "$dns1" "$dns2" ;;
    esac || { error "写入网卡配置失败；自动回滚仍在计时"; return 1; }
    network_backend_validate "$backend" "$iface" \
        || { error "网卡配置校验失败；自动回滚仍在计时"; return 1; }
    network_backend_apply "$backend" "$iface" \
        || { error "应用网卡配置失败；请保持旧会话，自动回滚仍在计时"; return 1; }
    sleep 1
    ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
        | awk '{print $4}' | grep -qxF "${ip_addr}/${prefix}" \
        || { error "未检测到预期地址 ${ip_addr}/${prefix}；自动回滚仍在计时"; return 1; }
    info "$iface 的静态 IPv4 已应用"
    audit_action "配置网卡 $iface ${ip_addr}/${prefix}" SUCCESS
    safety_confirm
}

network_dhcp_configure() {
    local iface backend
    print_header "设置 IPv4 DHCP"
    network_select_interface
    case "$?" in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    iface="$NETWORK_SELECTED_IFACE"
    backend=$(network_backend_detect "$iface" 2>/dev/null || true)
    [ -n "$backend" ] || { error "无法识别 $iface 的网络配置后端"; return 1; }
    confirm_change_preview "设置 $iface 使用 DHCP" \
        "后端：$(network_backend_label "$backend")" "IPv4 地址、网关和 DNS 将由 DHCP 获取" \
        "应用后必须从新终端确认连接，否则 180 秒后自动恢复" || { warn "已取消"; return 0; }
    NETWORK_ROLLBACK_BACKEND="$backend"
    NETWORK_ROLLBACK_IFACE="$iface"
    NETWORK_ROLLBACK_NM_UUID=""
    [ "$backend" != networkmanager ] \
        || NETWORK_ROLLBACK_NM_UUID=$(network_nm_connection_uuid "$iface" 2>/dev/null || true)
    safety_arm network_interface || return 1
    case "$backend" in
        netplan) network_netplan_write_dhcp "$iface" ;;
        networkmanager) network_nm_write_dhcp "$iface" ;;
        networkd) network_networkd_write_dhcp "$iface" ;;
        ifupdown) network_ifupdown_write_dhcp "$iface" ;;
        ifcfg) network_ifcfg_write "$iface" dhcp ;;
    esac || { error "写入 DHCP 配置失败；自动回滚仍在计时"; return 1; }
    network_backend_validate "$backend" "$iface" \
        || { error "DHCP 配置校验失败；自动回滚仍在计时"; return 1; }
    network_backend_apply "$backend" "$iface" \
        || { error "应用 DHCP 配置失败；请保持旧会话，自动回滚仍在计时"; return 1; }
    sleep 2
    [ -n "$(network_current_ipv4_cidr "$iface")" ] \
        || { error "DHCP 尚未取得 IPv4 地址；自动回滚仍在计时"; return 1; }
    info "$iface 已切换为 DHCP"
    audit_action "网卡 $iface 切换 DHCP" SUCCESS
    safety_confirm
}

network_interface_menu() {
    while true; do
        print_header "网卡管理"
        menu_item "1" "查看网卡、IP、网关与 DNS"
        menu_item "2" "新增 / 修改静态 IPv4" "$YELLOW"
        menu_item "3" "设置 IPv4 DHCP" "$CYAN"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        ui_hint "支持 Netplan、NetworkManager、systemd-networkd、ifupdown 与 CentOS/RHEL ifcfg"
        ui_hint "远程修改网卡有断联风险，请始终保留当前 SSH 会话并另开终端验证"
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" choice
        case "$choice" in
            1) network_show_interfaces ;;
            2) network_static_configure ;;
            3) network_dhcp_configure ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}

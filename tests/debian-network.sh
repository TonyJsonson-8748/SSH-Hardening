#!/usr/bin/env bash
set -euo pipefail

debian_network_error() {
    local exit_code=$? line="$1" command="$2" os_label="Debian"
    [ ! -r /etc/os-release ] || os_label=$(bash -c '. /etc/os-release; printf "%s %s" "$NAME" "$VERSION_ID"')
    command=${command//'%'/'%25'}
    command=${command//$'\r'/'%0D'}
    command=${command//$'\n'/'%0A'}
    printf '::error title=%s network simulation::line %s failed: %s (exit %s)\n' \
        "$os_label" "$line" "$command" "$exit_code"
    exit "$exit_code"
}
trap 'debian_network_error "$LINENO" "$BASH_COMMAND"' ERR

[ -e /.dockerenv ] || { echo "This test must run in a disposable container." >&2; exit 1; }
. /etc/os-release
[ "$ID" = debian ] || { echo "This test requires Debian." >&2; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/src/modules/network.sh"

IFACE=eth0
MANAGED="/etc/network/interfaces.d/90-vps-tools-${IFACE}.cfg"

network_ifupdown_write_static "$IFACE" 203.0.113.10 32 192.0.2.1 1.1.1.1 8.8.8.8
ifquery "$IFACE" >/dev/null
grep -qx '    address 203.0.113.10' "$MANAGED"
grep -qx '    netmask 255.255.255.255' "$MANAGED"
grep -qx '    up ip route replace default via 192.0.2.1 dev eth0 onlink' "$MANAGED"
grep -qx '    dns-nameservers 1.1.1.1 8.8.8.8' "$MANAGED"

# Exercise the no-resolvconf/no-resolved fallback without replacing the
# container's own resolver file.
NETWORK_RESOLV_CONF=/tmp/vps-tools-resolv.conf
printf '%s\n' 'search example.test' 'nameserver 9.9.9.9' > "$NETWORK_RESOLV_CONF"
network_dns_has_managed_resolver() { return 1; }
network_dns_finalize_static ifupdown "$IFACE" 1.1.1.1 8.8.8.8
grep -qx 'search example.test' "$NETWORK_RESOLV_CONF"
grep -qx 'nameserver 1.1.1.1' "$NETWORK_RESOLV_CONF"
grep -qx 'nameserver 8.8.8.8' "$NETWORK_RESOLV_CONF"
! grep -q '9.9.9.9' "$NETWORK_RESOLV_CONF"

network_ifupdown_write_dhcp "$IFACE"
ifquery "$IFACE" >/dev/null
grep -qx 'iface eth0 inet dhcp' "$MANAGED"

network_networkd_write_static "$IFACE" 203.0.113.10 32 192.0.2.1 1.1.1.1 8.8.8.8
NETWORKD="/etc/systemd/network/00-vps-tools-${IFACE}.network"
grep -qx 'Address=203.0.113.10/32' "$NETWORKD"
grep -qx 'Gateway=192.0.2.1' "$NETWORKD"
grep -qx 'GatewayOnLink=yes' "$NETWORKD"
grep -qx 'DNS=1.1.1.1' "$NETWORKD"
grep -qx 'DNS=8.8.8.8' "$NETWORKD"
network_networkd_write_dhcp "$IFACE"
grep -qx 'DHCP=yes' "$NETWORKD"

# If NetworkManager is present, validate and activate the off-subnet /32
# profile with the distribution's own nmcli/libnm version.
if command -v nmcli >/dev/null 2>&1; then
    mkdir -p /run/dbus
    rm -f /run/dbus/pid /run/dbus/messagebus.pid /run/dbus/system_bus_socket
    dbus-daemon --system --fork
    NetworkManager --no-daemon >/tmp/vps-tools-networkmanager.log 2>&1 &
    NM_PID=$!
    cleanup_nm() {
        kill "$NM_PID" 2>/dev/null || true
        ip link del vptest0 2>/dev/null || true
    }
    trap cleanup_nm EXIT
    for _ in 1 2 3 4 5; do
        nmcli general status >/dev/null 2>&1 && break
        sleep 1
    done
    nmcli general status >/dev/null 2>&1
    nmcli connection delete vps-tools-vptest0 >/dev/null 2>&1 || true
    nmcli connection add type dummy ifname vptest0 con-name vps-tools-vptest0 \
        >/dev/null
    network_nm_write_static vptest0 203.0.113.10 32 192.0.2.1 1.1.1.1 ''
    network_backend_apply networkmanager vptest0
    ip -4 -o addr show dev vptest0 | grep -q '203.0.113.10/32'
    ip -4 route show dev vptest0 | grep -q '^default via 192.0.2.1 '
    ip -4 route show dev vptest0 | grep -q '^192.0.2.1 .* scope link '
    cleanup_nm
    trap - EXIT
fi

echo "Debian network simulation passed on $PRETTY_NAME."

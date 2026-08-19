#!/usr/bin/env bash
set -euo pipefail

centos_network_error() {
    local exit_code=$? line="$1" command="$2"
    command=${command//'%'/'%25'}
    command=${command//$'\r'/'%0D'}
    command=${command//$'\n'/'%0A'}
    printf '::error title=CentOS 7 network simulation::line %s failed: %s (exit %s)\n' \
        "$line" "$command" "$exit_code"
    exit "$exit_code"
}
trap 'centos_network_error "$LINENO" "$BASH_COMMAND"' ERR

[ -e /.dockerenv ] || { echo "This test must run in a disposable container." >&2; exit 1; }
grep -q 'release 7\.' /etc/centos-release \
    || { echo "This test requires CentOS 7." >&2; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/src/modules/network.sh"

IFACE=eth0
IFCFG="/etc/sysconfig/network-scripts/ifcfg-${IFACE}"
ROUTE="/etc/sysconfig/network-scripts/route-${IFACE}"

network_ifcfg_write "$IFACE" static 192.0.2.10 24 192.0.2.1 1.1.1.1 8.8.8.8
grep -qx 'IPADDR=192.0.2.10' "$IFCFG"
grep -qx 'PREFIX=24' "$IFCFG"
grep -qx 'GATEWAY=192.0.2.1' "$IFCFG"
grep -qx 'DNS1=1.1.1.1' "$IFCFG"
grep -qx 'DNS2=8.8.8.8' "$IFCFG"

network_ifcfg_write "$IFACE" static 203.0.113.10 32 192.0.2.1 1.1.1.1 ''
grep -qx 'IPADDR=203.0.113.10' "$IFCFG"
grep -qx 'PREFIX=32' "$IFCFG"
! grep -q '^GATEWAY=' "$IFCFG"
grep -qx 'default via 192.0.2.1 dev eth0 onlink' "$ROUTE"

# When NetworkManager is installed, validate the exact profile syntax against
# CentOS 7's own NM 1.18 parser and daemon.
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
    NM_ROUTES=$(nmcli -g ipv4.routes connection show uuid "$NETWORK_ACTIVE_NM_UUID")
    NM_GATEWAY=$(nmcli -g ipv4.gateway connection show uuid "$NETWORK_ACTIVE_NM_UUID")
    [[ "$NM_ROUTES" = *'192.0.2.1/32'* ]]
    [[ "$NM_GATEWAY" = '192.0.2.1' ]]
    [[ "$NM_ROUTES" != *'onlink=true'* ]]
    [[ "$NM_ROUTES" != *'0.0.0.0/0'* ]]
    network_backend_apply networkmanager vptest0
    ip -4 -o addr show dev vptest0 | grep -q '203.0.113.10/32'
    ip -4 route show dev vptest0 | grep -q '^default via 192.0.2.1 '
    ip -4 route show dev vptest0 | grep -q '^192.0.2.1 .* scope link '
    cleanup_nm
    trap - EXIT
fi

echo "CentOS 7 network simulation passed."

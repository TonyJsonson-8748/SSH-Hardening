#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/src/modules/network.sh"

network_iface_name_valid eth0
network_iface_name_valid enp1s0
! network_iface_name_valid lo
! network_iface_name_valid 'eth0;reboot'

network_ipv4_valid 192.0.2.10
network_ipv4_valid 255.255.255.255
! network_ipv4_valid 256.1.1.1
! network_ipv4_valid 1.2.3
! network_ipv4_valid 192.168.001.1

[[ "$(network_mask_to_prefix 255.255.255.0)" = 24 ]]
[[ "$(network_mask_to_prefix 255.255.255.255)" = 32 ]]
! network_mask_to_prefix 255.0.255.0 >/dev/null 2>&1
[[ "$(network_prefix_to_mask 24)" = 255.255.255.0 ]]
[[ "$(network_prefix_to_mask 32)" = 255.255.255.255 ]]

network_gateway_is_onlink 192.0.2.10 192.0.2.1 24
! network_gateway_is_onlink 192.0.2.10 198.51.100.1 24
! network_gateway_is_onlink 192.0.2.10 192.0.2.1 32

# CentOS 7 ships NetworkManager 1.18, which rejects onlink=true route
# attributes or a /0 entry in ipv4.routes.  A direct gateway host route plus
# ipv4.gateway is accepted by both that release and current versions.
network_nm_prepare_connection() { NETWORK_ACTIVE_NM_UUID=test-uuid; }
nmcli() { NETWORK_TEST_NMCLI_ARGS="$*"; }
network_nm_write_static eth0 203.0.113.10 32 192.0.2.1 1.1.1.1 ''
[[ "$NETWORK_TEST_NMCLI_ARGS" = *'ipv4.gateway 192.0.2.1 ipv4.routes 192.0.2.1/32'* ]]
[[ "$NETWORK_TEST_NMCLI_ARGS" != *'onlink=true'* ]]
[[ "$NETWORK_TEST_NMCLI_ARGS" != *'0.0.0.0/0'* ]]

# Minimal Debian servers may use ifupdown/networkd without a resolver manager.
# In that case the selected DNS servers must be written to resolv.conf while
# preserving unrelated search/options directives.
NETWORK_RESOLV_CONF=$(mktemp)
printf '%s\n' 'search example.test' 'nameserver 9.9.9.9' 'options timeout:2' \
    > "$NETWORK_RESOLV_CONF"
network_dns_has_managed_resolver() { return 1; }
network_dns_finalize_static ifupdown eth0 1.1.1.1 8.8.8.8
grep -qx 'search example.test' "$NETWORK_RESOLV_CONF"
grep -qx 'options timeout:2' "$NETWORK_RESOLV_CONF"
grep -qx 'nameserver 1.1.1.1' "$NETWORK_RESOLV_CONF"
grep -qx 'nameserver 8.8.8.8' "$NETWORK_RESOLV_CONF"
! grep -q '9.9.9.9' "$NETWORK_RESOLV_CONF"
rm -f -- "$NETWORK_RESOLV_CONF"
unset NETWORK_RESOLV_CONF

# Keep Netplan writers safe for the main script's set -u mode without touching
# the test host's /etc/netplan hierarchy.
rm() { :; }
netplan() { :; }
network_netplan_write_dhcp eth0

echo "Network basic checks passed."

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

# Keep Netplan writers safe for the main script's set -u mode without touching
# the test host's /etc/netplan hierarchy.
rm() { :; }
netplan() { :; }
network_netplan_write_dhcp eth0

echo "Network basic checks passed."

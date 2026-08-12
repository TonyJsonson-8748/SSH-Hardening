#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT/src/modules/network.sh"

IFACE=eth0
ORIGIN="/etc/netplan/99-vps-tools-${IFACE}.yaml"

rm -f "$ORIGIN"

# Common Ubuntu VPS layout: one static IPv4, an on-subnet gateway and two DNS
# servers.  Validate the merged hierarchy with the image's own Netplan parser.
network_netplan_write_static "$IFACE" 192.0.2.10 24 192.0.2.1 1.1.1.1 8.8.8.8
netplan generate
STATIC_CFG=$(netplan get "ethernets.${IFACE}")
grep -q '192.0.2.10/24' <<< "$STATIC_CFG"
grep -q '192.0.2.1' <<< "$STATIC_CFG"
grep -q '1.1.1.1' <<< "$STATIC_CFG"
grep -q '8.8.8.8' <<< "$STATIC_CFG"
grep -Eq 'dhcp4:[[:space:]]*false' <<< "$STATIC_CFG"

# Many VPS providers use a /32 address with an off-subnet gateway.  Netplan
# must retain the on-link route flag or the generated route is unusable.
network_netplan_write_static "$IFACE" 203.0.113.10 32 192.0.2.1 1.1.1.1 ''
netplan generate
HOST_ROUTE_CFG=$(netplan get "ethernets.${IFACE}")
grep -q '203.0.113.10/32' <<< "$HOST_ROUTE_CFG"
grep -Eq 'on-link:[[:space:]]*true' <<< "$HOST_ROUTE_CFG"

# Switching back to DHCP must remove the managed static address, route and DNS.
network_netplan_write_dhcp "$IFACE"
netplan generate
DHCP_CFG=$(netplan get "ethernets.${IFACE}")
grep -Eq 'dhcp4:[[:space:]]*true' <<< "$DHCP_CFG"
! grep -q '203.0.113.10/32' <<< "$DHCP_CFG"
! grep -q '192.0.2.1' <<< "$DHCP_CFG"
! grep -q '1.1.1.1' <<< "$DHCP_CFG"

echo "Ubuntu Netplan simulation passed on $(. /etc/os-release; printf '%s %s' "$NAME" "$VERSION_ID")."

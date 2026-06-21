#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"

for fn in main_menu ssh_tools_menu fail2ban_menu bbr_menu firewall_menu dns_menu \
    ip_config_menu caddy_menu nft_menu ddns_menu system_toolbox_menu \
    resource_health_check system_update_manager config_backup_create self_update docker_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in docker_install docker_status docker_select_container docker_upgrade_container docker_container_action docker_inspect_label docker_download_file docker_compose_basename docker_compose_fetch_and_deploy; do
    declare -F "$fn" >/dev/null || { echo "Missing Docker function: $fn" >&2; exit 1; }
done

for fn in common_software_menu system_reinstall_menu software_reinstall_menu software_group_packages; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in config_export_archive config_import_archive config_transfer_menu rollback_center_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing toolbox function: $fn" >&2; exit 1; }
done

[[ "$(software_group_packages apt base)" = *curl* ]] || { echo "APT base package mapping is incomplete" >&2; exit 1; }
[[ "$(software_group_packages apk network)" = *mtr* ]] || { echo "APK network package mapping is incomplete" >&2; exit 1; }

OS=$(detect_os)
[ -n "$OS" ] || { echo "OS detection returned empty" >&2; exit 1; }

COLUMNS=44; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 1 ] || { echo "Narrow terminal did not enable compact layout" >&2; exit 1; }
COLUMNS=72; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 0 ] || { echo "Wide terminal did not enable two-column layout" >&2; exit 1; }

echo "Smoke test passed on $OS."

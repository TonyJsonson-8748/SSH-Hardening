#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"

for fn in systemd_available show_cli_help main_menu ssh_tools_menu fail2ban_menu bbr_menu firewall_menu dns_menu \
    ip_config_menu caddy_menu nft_menu ddns_menu ddns_install ddns_run_now ddns_view_logs ddns_status system_toolbox_menu \
    resource_health_check system_update_manager config_backup_create self_update docker_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in docker_install docker_status docker_select_container docker_upgrade_container docker_container_action docker_inspect_label docker_download_file docker_compose_basename docker_compose_fetch_and_deploy; do
    declare -F "$fn" >/dev/null || { echo "Missing Docker function: $fn" >&2; exit 1; }
done

for fn in self_offline_bundle_create self_offline_bundle_install self_update self_manifest_value monitor_alert_check monitor_alert_config_menu monitor_alert_home_menu monitor_alert_daily_report monitor_alert_host_label monitor_time_normalize monitor_date_normalize monitor_int_normalize monitor_traffic_reset_day_valid monitor_traffic_totals monitor_traffic_usage_triplet monitor_traffic_usage_text monitor_traffic_set_cycle_usage_split_gb monitor_alert_service_state monitor_alert_any_service_state monitor_alert_ssh_state monitor_alert_test_snapshot monitor_alert_notify config_health_check diagnostic_bundle_create; do
    declare -F "$fn" >/dev/null || { echo "Missing new function: $fn" >&2; exit 1; }
done

for fn in common_software_menu system_reinstall_menu software_reinstall_menu software_group_packages; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in config_export_archive config_import_archive config_transfer_menu rollback_center_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing toolbox function: $fn" >&2; exit 1; }
done

[[ "$(software_group_packages apt base)" = *curl* ]] || { echo "APT base package mapping is incomplete" >&2; exit 1; }
[[ "$(software_group_packages apk network)" = *mtr* ]] || { echo "APK network package mapping is incomplete" >&2; exit 1; }
CLI_HELP=$(show_cli_help)
[[ "$CLI_HELP" = *"--ssh-menu"* ]] || { echo "CLI help missing SSH entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--docker-menu"* ]] || { echo "CLI help missing Docker entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--monitor-home"* ]] || { echo "CLI help missing monitor entry" >&2; exit 1; }
monitor_alert_service_state() { case "$1" in ssh) echo stopped ;; sshd) echo running ;; *) echo unknown ;; esac; }
[[ "$(monitor_alert_ssh_state)" = "running" ]] || { echo "SSH service alias check failed" >&2; exit 1; }
[[ "$(monitor_int_normalize 1.24682e+11)" = "124682000000" ]] || { echo "Scientific notation normalization failed" >&2; exit 1; }
monitor_traffic_reset_day_valid 31 || { echo "Reset day 31 should be valid" >&2; exit 1; }
! monitor_traffic_reset_day_valid 32 || { echo "Reset day 32 should be invalid" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-02-15)" = "2026-01-31" ]] || { echo "Previous short-month reset calculation failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-02-28)" = "2026-01-31" ]] || { echo "Short-month reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-03-01)" = "2026-03-01" ]] || { echo "Short-month rollover reset failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2028-02-29)" = "2028-01-31" ]] || { echo "Leap-year short-month reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2028-03-01)" = "2028-03-01" ]] || { echo "Leap-year rollover reset failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-04-30)" = "2026-03-31" ]] || { echo "April reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-05-01)" = "2026-05-01" ]] || { echo "April rollover reset failed" >&2; exit 1; }
monitor_traffic_totals() { echo "107374182400 214748364800 322122547200"; }
monitor_alert_save_cfg() { :; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_set_cycle_usage_split_gb
MON_TRAFFIC_RESET_DAY=1
monitor_traffic_set_cycle_usage_split_gb 10 20
MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:?}
MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:?}
[[ "$(monitor_traffic_usage_triplet cycle)" = "10737418240 21474836480 32212254720" ]] || { echo "Split traffic calibration failed" >&2; exit 1; }
monitor_traffic_set_cycle_usage_split_gb 1000 1000
[[ "$(monitor_traffic_usage_triplet cycle)" = "1073741824000 1073741824000 2147483648000" ]] || { echo "Large split traffic calibration failed" >&2; exit 1; }
MANIFEST="$TMP/manifest.json"
cat > "$MANIFEST" <<'EOF'
{"name":"SSH-Hardening","version":"V3.9.18","sha256":"abc123"}
EOF
[[ "$(self_manifest_value "$MANIFEST" version)" = "V3.9.18" ]] || { echo "Manifest parsing failed" >&2; exit 1; }

OS=$(detect_os)
[ -n "$OS" ] || { echo "OS detection returned empty" >&2; exit 1; }

COLUMNS=44; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 1 ] || { echo "Narrow terminal did not enable compact layout" >&2; exit 1; }
COLUMNS=72; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 0 ] || { echo "Wide terminal did not enable two-column layout" >&2; exit 1; }

echo "Smoke test passed on $OS."

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"

for fn in systemd_available show_cli_help main_menu ssh_tools_menu fail2ban_menu bbr_menu firewall_menu dns_menu \
    ip_config_menu caddy_menu nft_menu ddns_menu ddns_install ddns_install_cloudflare ddns_install_huawei ddns_run_now ddns_view_logs ddns_status \
    ddns_provider ddns_provider_label ddns_sed_escape ddns_domain_dot \
    ddns_interval_normalize ddns_interval_min ddns_cron_expr ddns_cron_without_managed ddns_prompt_interval \
    ddns_cfg_enable_a ddns_cfg_enable_aaaa ddns_cfg_domain4 ddns_cfg_domain6 ddns_primary_domain ddns_mode_label ddns_build_domain \
    ddns_latest_log_line ddns_latest_change_log_line ddns_line_time ddns_line_result_ip ddns_newer_line ddns_change_matches_status ddns_record_status_line ddns_record_change_line ddns_print_record_summary \
    system_toolbox_menu \
    resource_health_check system_update_manager system_hostname_apply config_backup_create self_update docker_menu change_port; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

BANNER_WIDE=$(COLUMNS=80 NO_COLOR=1 volcano_art_banner)
[[ "$BANNER_WIDE" = *'██╗███╗'* && "$BANNER_WIDE" = *'███████╗'* ]] || { echo "Wide IMPART OPS banner is missing" >&2; exit 1; }
BANNER_COMPACT=$(COLUMNS=60 NO_COLOR=1 volcano_art_banner)
[[ "$BANNER_COMPACT" = *'██╗███╗'* && "$BANNER_COMPACT" = *'██████╗ ██████╗ ███████╗'* ]] || { echo "Compact IMPART OPS banner is missing" >&2; exit 1; }
[[ "$(COLUMNS=40 NO_COLOR=1 volcano_art_banner)" = *'IMPART OPS'* ]] || { echo "Narrow IMPART OPS banner fallback is missing" >&2; exit 1; }

for fn in bbr_preflight bbr_runtime_snapshot bbr_ensure_baseline bbr_restore_runtime_snapshot bbr_baseline_value bbr_config_has_key \
    bbr_apply_sysctl bbr_generate_config bbr_bdp_mb bbr_buffer_target_mb bbr_recommend_profile \
    bbr_tc_qdisc_safe_to_replace bbr_tc_topology_matches bbr_tc_managed_artifact bbr_tc_is_legacy_owned \
    bbr_tc_apply_runtime bbr_default_route_info bbr_route_token \
    bbr_route_strip_cwnd bbr_apply_initcwnd_route volcano_tcp_profile; do
    declare -F "$fn" >/dev/null || { echo "Missing BBR function: $fn" >&2; exit 1; }
done

BBR_BASELINE_FILE="$TMP/bbr-baseline.conf"
cat > "$BBR_BASELINE_FILE" <<'EOF'
netXipv4Xip_forward = 9
net.ipv4.ip_forward = 1
net.core.somaxconn = 4096
EOF
[[ "$(bbr_baseline_value net.ipv4.ip_forward)" = "1" ]] || { echo "BBR baseline key matching was not exact" >&2; exit 1; }
[[ "$(bbr_config_dynamic_scene_keys 'net.ipv6.conf.eth9.accept_ra = 2')" = net.ipv6.conf.eth9.accept_ra ]] || { echo "BBR old IPv6 interface cleanup key was not detected" >&2; exit 1; }
BBR_RESTORE_LOG="$TMP/bbr-restore.log"
# shellcheck disable=SC2329 # test stub used indirectly by bbr_restore_baseline_key
sysctl() {
    [ "${1:-}" = -w ] && printf '%s\n' "$2" >> "$BBR_RESTORE_LOG"
}
bbr_restore_baseline_key net.core.somaxconn
grep -qx 'net.core.somaxconn=4096' "$BBR_RESTORE_LOG" || { echo "BBR baseline restore used the wrong value" >&2; exit 1; }
unset -f sysctl

(
    BBR_BASELINE_FILE="$TMP/bbr-growing-baseline.conf"
    printf 'net.ipv4.ip_forward = 0\n' > "$BBR_BASELINE_FILE"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_ensure_baseline
    bbr_managed_keys() { printf '%s\n' net.ipv4.ip_forward net.ipv6.conf.eth0.accept_ra; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_ensure_baseline
    sysctl() {
        [ "${1:-}" = -n ] && [ "${2:-}" = net.ipv6.conf.eth0.accept_ra ] && echo 1
    }
    bbr_ensure_baseline
    [[ "$(bbr_baseline_value net.ipv4.ip_forward)" = 0 ]] || { echo "BBR baseline overwrote an existing value" >&2; exit 1; }
    [[ "$(bbr_baseline_value net.ipv6.conf.eth0.accept_ra)" = 1 ]] || { echo "BBR baseline did not capture a newly managed interface" >&2; exit 1; }
)

(
    SYSCTL_FILE="$TMP/bbr-sysctl.conf"
    BBR_BASELINE_FILE="$TMP/bbr-transaction-baseline.conf"
    printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FILE"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    ensure_sysctl() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    bbr_ensure_baseline() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    bbr_runtime_snapshot() {
        printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$1"
    }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    sysctl() {
        case "${2:-}" in net.ipv4.tcp_congestion_control=bbr) return 1 ;; *) return 0 ;; esac
    }
    CONFIG=$(printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr')
    if bbr_apply_sysctl "$CONFIG" baseline >/dev/null 2>&1; then
        echo "BBR core sysctl failure returned success" >&2
        exit 1
    fi
    grep -qx 'net.ipv4.tcp_congestion_control = cubic' "$SYSCTL_FILE" || {
        echo "BBR failed apply replaced the previous persistent config" >&2
        exit 1
    }
)

(
    PREFLIGHT_CALLED=0
    BACKUP_CALLED=0
    # shellcheck disable=SC2329 # test stub used indirectly by volcano_tcp_profile
    bbr_preflight() { PREFLIGHT_CALLED=1; return 1; }
    # shellcheck disable=SC2329 # must stay uncalled when preflight fails
    bbr_backup_sysctl() { BACKUP_CALLED=1; }
    if volcano_tcp_profile balanced >/dev/null 2>&1; then
        echo "BBR smart profile ignored a failed preflight" >&2
        exit 1
    fi
    [ "$PREFLIGHT_CALLED" -eq 1 ] || { echo "BBR smart profile skipped preflight" >&2; exit 1; }
    [ "$BACKUP_CALLED" -eq 0 ] || { echo "BBR smart profile changed state after failed preflight" >&2; exit 1; }
)

(
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_generate_config
    bbr_default_ipv6_iface() { echo eth0; }
    CONFIG=$(bbr_generate_config 12582912 12582912 '32768 49152 98304' 131072 2 32768 10 1048576 relay)
    grep -qx 'net.ipv6.conf.eth0.accept_ra = 2' <<< "$CONFIG" || { echo "BBR forwarding profile missing IPv6 accept_ra=2" >&2; exit 1; }
)

bbr_tc_qdisc_safe_to_replace fq || { echo "BBR rejected a safe default qdisc" >&2; exit 1; }
! bbr_tc_qdisc_safe_to_replace cake || { echo "BBR would overwrite a foreign CAKE qdisc" >&2; exit 1; }
(
    TC_STATE_FILE="$TMP/legacy-tc-no-state"
    SERVICE_TC="$TMP/legacy-tc-fq.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact
    SERVICE_TC_INIT="$TMP/legacy-tc-fq.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_tc_restore_owned
    TC_HELPER="$TMP/legacy-tc-helper"
    TC_TEST_LOG="$TMP/legacy-tc.log"
    export TC_TEST_LOG
    cat > "$SERVICE_TC" <<'EOF'
[Unit]
Description=TC egress shaping 1024Mbps (htb shape + fq pacing for BBR)
EOF
    FAKE_TC="$TMP/fake-legacy-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    cat <<'OUT'
qdisc htb 1: root refcnt 3 r2q 10 default 0x10 direct_packets_stat 0 direct_qlen 1000
qdisc fq 100: parent 1:10 limit 10000p flow_limit 100p buckets 1024 maxrate 1024Mbit
OUT
elif [ "$1 $2" = "class show" ]; then
    echo 'class htb 1:10 root rate 1024Mbit ceil 1024Mbit burst 1024Kb cburst 1024Kb'
else
    printf '%s\n' "$*" >> "$TC_TEST_LOG"
fi
EOF
    chmod +x "$FAKE_TC"
    bbr_tc_is_legacy_owned eth0 "$FAKE_TC" || { echo "BBR did not recognize its legacy tc topology" >&2; exit 1; }
    bbr_tc_apply_runtime eth0 780 780 "$FAKE_TC" >/dev/null || { echo "BBR refused to migrate its legacy tc topology" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" || { echo "BBR legacy tc migration did not replace the root qdisc" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 parent 1:10 handle 100: fq maxrate 780mbit' "$TC_TEST_LOG" \
        || { echo "BBR legacy tc migration did not apply the requested rate" >&2; exit 1; }
    rm -f "$SERVICE_TC"
    ! bbr_tc_is_legacy_owned eth0 "$FAKE_TC" || { echo "BBR claimed legacy tc topology without a managed artifact" >&2; exit 1; }
    cat > "$SERVICE_TC" <<'EOF'
[Unit]
Description=TC egress shaping 1024Mbps (htb shape + fq pacing for BBR)
EOF
    TC_BIN_DIR="$TMP/legacy-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cp "$FAKE_TC" "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"
    # shellcheck disable=SC2329 # test stubs consumed indirectly by bbr_remove_tc
    default_iface() { echo eth0; }
    # shellcheck disable=SC2329 # keep the removal test away from the host service manager
    systemd_available() { return 1; }
    # shellcheck disable=SC2329 # test stubs consumed through command -v
    rc-update() { return 0; }
    # shellcheck disable=SC2329 # test stub consumed indirectly by bbr_remove_tc
    rc-service() { return 0; }
    : > "$TC_TEST_LOG"
    bbr_remove_tc >/dev/null || { echo "BBR refused to remove its legacy tc topology" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" || { echo "BBR legacy tc removal left the root qdisc active" >&2; exit 1; }
)
(
    # shellcheck disable=SC2034 # consumed by bbr_tc_is_owned
    TC_STATE_FILE="$TMP/no-tc-state"
    TC_TEST_LOG="$TMP/tc-test.log"
    export TC_TEST_LOG
    FAKE_TC="$TMP/fake-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    echo 'qdisc cake 8001: root refcnt 2 bandwidth 100Mbit'
    exit 0
fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
EOF
    chmod +x "$FAKE_TC"
    if bbr_tc_apply_runtime eth0 100 100 "$FAKE_TC" >/dev/null 2>&1; then
        echo "BBR accepted a foreign root qdisc" >&2
        exit 1
    fi
    [ ! -s "$TC_TEST_LOG" ] || { echo "BBR modified a foreign root qdisc" >&2; exit 1; }
)
[[ "$(bbr_route_token 'default dev eth0 proto static metric 100' dev)" = eth0 ]] || { echo "BBR direct default route device parsing failed" >&2; exit 1; }
[[ -z "$(bbr_route_token 'default dev eth0 proto static metric 100' via)" ]] || { echo "BBR direct default route invented a gateway" >&2; exit 1; }
[[ "$(bbr_route_strip_cwnd 'default via 192.0.2.1 dev eth0 metric 100 initcwnd 50 initrwnd 50')" = 'default via 192.0.2.1 dev eth0 metric 100' ]] || { echo "BBR initcwnd route cleanup failed" >&2; exit 1; }
(
    ROUTE_CALL="$TMP/bbr-route-call"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_initcwnd_route
    ip() { printf '%s\n' "$*" > "$ROUTE_CALL"; }
    bbr_apply_initcwnd_route 4 'default dev eth0 proto static metric 100' 50
    grep -qx -- '-4 route replace default dev eth0 proto static metric 100 initcwnd 50 initrwnd 50' "$ROUTE_CALL" || {
        echo "BBR direct route initcwnd application was malformed" >&2
        exit 1
    }
)
[[ "$(bbr_bdp_mb 100 50)" != "0.00" ]] || { echo "BBR BDP estimate was truncated to zero" >&2; exit 1; }
[[ "$(bbr_buffer_target_mb 100 50)" = "1" ]] || { echo "BBR BDP buffer target rounding failed" >&2; exit 1; }
[[ "$(bbr_recommend_profile 4095)" = balanced ]] || { echo "BBR sub-4GB recommendation changed unexpectedly" >&2; exit 1; }
[[ "$(bbr_recommend_profile 4096)" = throughput ]] || { echo "BBR 4GB recommendation does not match documentation" >&2; exit 1; }

BBR_TC_HELPER_TEST="$TMP/tc-helper.sh"
BBR_CWND_HELPER_TEST="$TMP/cwnd-helper.sh"
awk 'p && /^TC_HELPER_EOF$/{exit} /<< '\''TC_HELPER_EOF'\''/{p=1; next} p{print}' "$ROOT/src/modules/bbr.sh" > "$BBR_TC_HELPER_TEST"
awk 'p && /^CWND_HELPER_EOF$/{exit} /<< '\''CWND_HELPER_EOF'\''/{p=1; next} p{print}' "$ROOT/src/modules/bbr.sh" > "$BBR_CWND_HELPER_TEST"
sh -n "$BBR_TC_HELPER_TEST" || { echo "Generated tc helper has syntax errors" >&2; exit 1; }
sh -n "$BBR_CWND_HELPER_TEST" || { echo "Generated initcwnd helper has syntax errors" >&2; exit 1; }

for fn in docker_install docker_status docker_select_container docker_upgrade_container docker_container_action docker_inspect_label docker_download_file docker_compose_basename docker_compose_fetch_and_deploy; do
    declare -F "$fn" >/dev/null || { echo "Missing Docker function: $fn" >&2; exit 1; }
done

for fn in self_install self_script_valid self_resolve_script_source self_fetch_script self_shortcut_owned self_install_shortcut self_remove_shortcut self_offline_bundle_create self_offline_bundle_install self_update self_manifest_value self_remote_main_sha monitor_alert_check monitor_alert_config_menu monitor_alert_home_menu monitor_alert_daily_report monitor_alert_host_label monitor_alert_host_label_html monitor_alert_html_escape monitor_alert_set_host_label monitor_time_normalize monitor_date_normalize monitor_int_normalize monitor_positive_number_valid monitor_positive_int_valid monitor_percent_valid monitor_renew_notice_days_valid monitor_traffic_interfaces monitor_traffic_reset_day_valid monitor_traffic_totals monitor_traffic_delta_bytes monitor_traffic_reconcile_counters monitor_traffic_usage_triplet monitor_traffic_usage_text monitor_traffic_set_cycle_usage_split_gb monitor_alert_service_state monitor_alert_any_service_state monitor_alert_ssh_state monitor_alert_test_snapshot monitor_alert_resource_snapshot monitor_alert_traffic_snapshot monitor_alert_renew_snapshot monitor_alert_renew_mark_paid monitor_alert_renew_reset_state monitor_alert_notify monitor_alert_telegram_send monitor_alert_history_add monitor_alert_history_view monitor_alert_cooldown_seconds monitor_alert_time_to_minutes monitor_alert_in_silence monitor_alert_metrics monitor_alert_metrics_sample monitor_alert_trend_line monitor_alert_trend_summary monitor_alert_level_label monitor_alert_level_icon monitor_alert_level_rank monitor_alert_worst_level monitor_alert_daily_cron_expr monitor_alert_cron_command monitor_alert_cron_without_managed monitor_alert_acquire_lock monitor_alert_install_cron monitor_alert_remove_cron monitor_alert_cron_status monitor_alert_next_daily_time monitor_alert_configured_without_cron monitor_alert_service_menu monitor_alert_notify_menu monitor_alert_resource_menu monitor_alert_traffic_menu monitor_alert_daily_menu monitor_alert_renew_menu monitor_alert_advanced_menu monitor_alert_quick_setup_menu config_health_check diagnostic_bundle_create; do
    declare -F "$fn" >/dev/null || { echo "Missing new function: $fn" >&2; exit 1; }
done

for fn in common_software_menu system_reinstall_menu software_reinstall_menu software_group_packages; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in config_export_archive config_import_archive config_transfer_menu rollback_center_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing toolbox function: $fn" >&2; exit 1; }
done

for fn in stun_ports_normalize stun_host_valid stun_udp_explanation stun_nat_explanation stun_mapping_explanation stun_filtering_explanation stun_confidence_explanation stun_recommendation stun_probe_engine stun_render_results stun_probe_execute stun_nat_quick stun_nat_custom stun_nat_menu; do
    declare -F "$fn" >/dev/null || { echo "Missing STUN function: $fn" >&2; exit 1; }
done
[[ "$(stun_ports_normalize '3478, 19302;3478 443')" = "3478,19302,443" ]] || { echo "STUN port normalization failed" >&2; exit 1; }
! stun_ports_normalize '0,3478' >/dev/null 2>&1 || { echo "STUN accepted port zero" >&2; exit 1; }
! stun_ports_normalize '3478,65536' >/dev/null 2>&1 || { echo "STUN accepted an out-of-range port" >&2; exit 1; }
! stun_ports_normalize '1,2,3,4,5,6,7,8,9,10,11,12,13' >/dev/null 2>&1 || { echo "STUN accepted more than 12 ports" >&2; exit 1; }
stun_host_valid stun.nextcloud.com || { echo "STUN rejected a valid hostname" >&2; exit 1; }
! stun_host_valid 'bad host;id' || { echo "STUN accepted an unsafe hostname" >&2; exit 1; }
! stun_host_valid 'bad..example.com' || { echo "STUN accepted an empty hostname label" >&2; exit 1; }
[[ "$(stun_probe_engine selftest - -)" = $'SELFTEST\tok' ]] || { echo "STUN protocol self-test failed" >&2; exit 1; }
! grep -Fq 'stun.sipgate.net' "$ROOT/src/modules/stun.sh" || { echo "STUN still uses the retired Sipgate endpoint" >&2; exit 1; }
grep -Fq '("stun.nextcloud.com", 443)' "$ROOT/src/modules/stun.sh" || { echo "STUN quick endpoints missing Nextcloud UDP/443" >&2; exit 1; }
grep -Fq '("stun.nextcloud.com", 3478)' "$ROOT/src/modules/stun.sh" || { echo "STUN quick endpoints missing Nextcloud UDP/3478" >&2; exit 1; }
[[ "$(stun_udp_explanation 5 5)" = *"全部节点响应"* ]] || { echo "STUN complete UDP explanation failed" >&2; exit 1; }
[[ "$(stun_udp_explanation 3 5)" = *"3/5 节点响应"* ]] || { echo "STUN partial UDP explanation failed" >&2; exit 1; }
[[ "$(stun_udp_explanation 0 5)" = *"无节点响应"* ]] || { echo "STUN unavailable UDP explanation failed" >&2; exit 1; }
for NAT_RESULT in open_internet public_udp_firewall full_cone restricted_cone port_restricted symmetric nat_unknown udp_unavailable unknown; do
    [ -n "$(stun_nat_explanation "$NAT_RESULT")" ] || { echo "STUN NAT explanation missing for $NAT_RESULT" >&2; exit 1; }
    [ -n "$(stun_recommendation "$NAT_RESULT")" ] || { echo "STUN recommendation missing for $NAT_RESULT" >&2; exit 1; }
done
for MAPPING_RESULT in eim adm apdm endpoint_dependent unknown; do
    [ -n "$(stun_mapping_explanation "$MAPPING_RESULT")" ] || { echo "STUN mapping explanation missing for $MAPPING_RESULT" >&2; exit 1; }
done
for FILTERING_RESULT in eif adf apdf unknown; do
    [ -n "$(stun_filtering_explanation "$FILTERING_RESULT")" ] || { echo "STUN filtering explanation missing for $FILTERING_RESULT" >&2; exit 1; }
done
for CONFIDENCE_RESULT in high medium low; do
    [ -n "$(stun_confidence_explanation "$CONFIDENCE_RESULT")" ] || { echo "STUN confidence explanation missing for $CONFIDENCE_RESULT" >&2; exit 1; }
done
STUN_RENDERED=$(stun_render_results $'SUMMARY\t10.0.0.2\t12345\t198.51.100.2:54321\tapdm\tapdf\tsymmetric\thigh\t5\t5')
[[ "$STUN_RENDERED" = *"结果解释"* && "$STUN_RENDERED" = *"UDP 打洞和 P2P 直连较困难"* ]] || { echo "STUN rendered result explanations are missing" >&2; exit 1; }

[[ "$(software_group_packages apt base)" = *curl* ]] || { echo "APT base package mapping is incomplete" >&2; exit 1; }
[[ "$(software_group_packages apk network)" = *mtr* ]] || { echo "APK network package mapping is incomplete" >&2; exit 1; }
CLI_HELP=$(show_cli_help)
[[ "$CLI_HELP" = *"--ssh-menu"* ]] || { echo "CLI help missing SSH entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--docker-menu"* ]] || { echo "CLI help missing Docker entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--monitor-home"* ]] || { echo "CLI help missing monitor entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--hostname-menu"* ]] || { echo "CLI help missing hostname entry" >&2; exit 1; }
[[ "$CLI_HELP" = *"--stun-test"* ]] || { echo "CLI help missing STUN entry" >&2; exit 1; }
DDNS_ZONE_FILE="$TMP/cf_zone"
cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=home.example.com
MODE=dual
EOF
ddns_cfg_enable_a || { echo "Legacy DDNS IPv4 enable detection failed" >&2; exit 1; }
ddns_cfg_enable_aaaa || { echo "Legacy DDNS IPv6 enable detection failed" >&2; exit 1; }
[[ "$(ddns_cfg_domain4)" = "home.example.com" ]] || { echo "Legacy DDNS IPv4 domain failed" >&2; exit 1; }
[[ "$(ddns_cfg_domain6)" = "home.example.com" ]] || { echo "Legacy DDNS IPv6 domain failed" >&2; exit 1; }
[[ "$(ddns_mode_label)" = "IPv4 + IPv6（同域名）" ]] || { echo "Legacy DDNS mode label failed" >&2; exit 1; }
[[ "$(ddns_provider)" = "cloudflare" ]] || { echo "Legacy DDNS provider fallback failed" >&2; exit 1; }
[[ "$(ddns_interval_min)" = "5" ]] || { echo "Legacy DDNS interval fallback failed" >&2; exit 1; }
[[ "$(ddns_interval_normalize 1)" = "1" ]] || { echo "DDNS interval 1 should be valid" >&2; exit 1; }
[[ "$(ddns_interval_normalize 2)" = "2" ]] || { echo "DDNS interval 2 should be valid" >&2; exit 1; }
[[ "$(ddns_interval_normalize 5)" = "5" ]] || { echo "DDNS interval 5 should be valid" >&2; exit 1; }
[[ "$(ddns_interval_normalize 0)" = "5" ]] || { echo "DDNS interval 0 should fall back to 5" >&2; exit 1; }
[[ "$(ddns_interval_normalize 60)" = "5" ]] || { echo "DDNS interval 60 should fall back to 5" >&2; exit 1; }
[[ "$(ddns_cron_expr 1)" = "* * * * *" ]] || { echo "DDNS interval 1 cron expression failed" >&2; exit 1; }
[[ "$(ddns_cron_expr 2)" = "*/2 * * * *" ]] || { echo "DDNS interval 2 cron expression failed" >&2; exit 1; }
[[ "$(ddns_cron_expr 5)" = "*/5 * * * *" ]] || { echo "DDNS interval 5 cron expression failed" >&2; exit 1; }
DDNS_CRON_SAMPLE=$(printf '%s\n' \
    '*/5 * * * * /root/ddns.sh >> /var/log/ddns.log 2>&1' \
    '*/5 * * * * /opt/another-ddns.sh >> /var/log/another-ddns.log 2>&1')
DDNS_CRON_FILTERED=$(printf '%s\n' "$DDNS_CRON_SAMPLE" | ddns_cron_without_managed)
[[ "$DDNS_CRON_FILTERED" != *'/root/ddns.sh'* ]] || { echo "Managed DDNS cron entry was not removed" >&2; exit 1; }
[[ "$DDNS_CRON_FILTERED" = *'/opt/another-ddns.sh'* ]] || { echo "Unrelated DDNS cron entry was removed" >&2; exit 1; }
cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=v6.example.com
MODE=dual
ENABLE_A=true
ENABLE_AAAA=true
INTERVAL_MIN=2
EOF
[[ "$(ddns_primary_domain)" = "v4.example.com" ]] || { echo "DDNS primary domain failed" >&2; exit 1; }
[[ "$(ddns_mode_label)" = "IPv4 + IPv6（分别设置）" ]] || { echo "Split DDNS mode label failed" >&2; exit 1; }
[[ "$(ddns_interval_min)" = "2" ]] || { echo "Configured DDNS interval failed" >&2; exit 1; }
[[ "$(ddns_build_domain @ example.com)" = "example.com" ]] || { echo "DDNS root domain build failed" >&2; exit 1; }
[[ "$(ddns_build_domain v6.example.com example.com)" = "v6.example.com" ]] || { echo "DDNS full domain build failed" >&2; exit 1; }
[[ "$(ddns_domain_dot example.com)" = "example.com." ]] || { echo "DDNS trailing-dot helper failed" >&2; exit 1; }
cat > "$DDNS_ZONE_FILE" <<'EOF'
PROVIDER=huawei
DOMAIN=home.example.com
DOMAIN4=home.example.com
ZONE=example.com
MODE=ipv4
ENABLE_A=true
ENABLE_AAAA=false
ENDPOINT=https://dns.myhuaweicloud.com
EOF
[[ "$(ddns_provider)" = "huawei" ]] || { echo "Huawei DDNS provider detection failed" >&2; exit 1; }
[[ "$(ddns_provider_label)" = "华为云 DNS" ]] || { echo "Huawei DDNS provider label failed" >&2; exit 1; }
ddns_cfg_enable_a || { echo "Huawei DDNS IPv4 enable failed" >&2; exit 1; }
! ddns_cfg_enable_aaaa || { echo "Huawei DDNS IPv6 should be disabled" >&2; exit 1; }
grep -Fq 'read -rp "  Cloudflare API Token（输入可见）: " DDNS_TOKEN' "$ROOT/src/modules/ddns.sh" || { echo "Cloudflare API Token input must remain visible" >&2; exit 1; }
grep -q "SDK-HMAC-SHA256" "$ROOT/src/modules/ddns.sh" || { echo "Huawei DDNS signer missing" >&2; exit 1; }
! grep -q "LC_TIME" "$ROOT/src/modules/ddns.sh" || { echo "DDNS menu must not use LC_TIME locale variable" >&2; exit 1; }
CLOUDFLARE_DDNS_TEMPLATE="$TMP/cloudflare-ddns-template.sh"
awk "BEGIN{p=0} /cat > \"\\\$DDNS_SCRIPT\" << 'DDNS_INNER'/{p=1; next} /^DDNS_INNER$/{if(p){exit}} p{print}" "$ROOT/src/modules/ddns.sh" > "$CLOUDFLARE_DDNS_TEMPLATE"
bash -n "$CLOUDFLARE_DDNS_TEMPLATE" || { echo "Cloudflare DDNS generated template has syntax errors" >&2; exit 1; }
grep -Fq 'LOCK_DIR="/run/vps-tools-ddns.lock"' "$CLOUDFLARE_DDNS_TEMPLATE" || { echo "Cloudflare DDNS concurrency lock missing" >&2; exit 1; }
grep -Fq 'record_ip_file()' "$CLOUDFLARE_DDNS_TEMPLATE" || { echo "Cloudflare DDNS successful IP state missing" >&2; exit 1; }
CF_SYNC_LINE=$(grep -nF 'if [ "$NEW_IP" = "$VERIFY_IP" ]; then' "$CLOUDFLARE_DDNS_TEMPLATE" | head -1 | cut -d: -f1)
CF_SKIP_LINE=$(grep -nF 'if [ -z "$VERIFY_IP" ] || [ "$VERIFY_IP" != "$OLD_IP" ]; then' "$CLOUDFLARE_DDNS_TEMPLATE" | head -1 | cut -d: -f1)
[[ -n "$CF_SYNC_LINE" && -n "$CF_SKIP_LINE" && "$CF_SYNC_LINE" -lt "$CF_SKIP_LINE" ]] || { echo "Cloudflare DDNS synchronized second-check branch is unreachable" >&2; exit 1; }
CF_STATE_HELPERS="$TMP/cloudflare-state-helpers.sh"
awk 'p && /^write_record_change\(\)/{exit} /^record_status_file\(\)/{p=1} p{print}' "$CLOUDFLARE_DDNS_TEMPLATE" > "$CF_STATE_HELPERS"
# shellcheck source=/dev/null
source "$CF_STATE_HELPERS"
STATE_DIR="$TMP/generated-ddns-state"
mkdir -p "$STATE_DIR"
write_record_status A home.example.com unchanged 1.1.1.1 2.2.2.2
[[ "$(previous_record_ip A home.example.com)" = "2.2.2.2" ]] || { echo "DDNS legacy successful IP migration failed" >&2; exit 1; }
write_record_ip A home.example.com 2.2.2.2
write_record_status A home.example.com fetch_failed "" ""
[[ "$(previous_record_ip A home.example.com)" = "2.2.2.2" ]] || { echo "DDNS failure overwrote the last successful IP" >&2; exit 1; }
HUAWEI_DDNS_TEMPLATE="$TMP/huawei-ddns-template.sh"
awk "BEGIN{p=0} /cat > \"\\\$DDNS_SCRIPT\" << 'DDNS_HUAWEI_INNER'/{p=1; next} /^DDNS_HUAWEI_INNER$/{if(p){exit}} p{print}" "$ROOT/src/modules/ddns.sh" > "$HUAWEI_DDNS_TEMPLATE"
bash -n "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS generated template has syntax errors" >&2; exit 1; }
grep -Fq 'JSON_INPUT=$(cat)' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS JSON parser must preserve piped API responses" >&2; exit 1; }
grep -Fq 'fetch_ip6_local' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS IPv6 local fallback missing" >&2; exit 1; }
grep -Fq 'LOCK_DIR="/run/vps-tools-ddns.lock"' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS concurrency lock missing" >&2; exit 1; }
grep -Fq 'record_ip_file()' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS successful IP state missing" >&2; exit 1; }
awk 'p && /^except Exception:/{exit} /^except urllib\.error\.HTTPError/{p=1} p{print}' "$HUAWEI_DDNS_TEMPLATE" | grep -Fq 'sys.exit(1)' || { echo "Huawei DDNS HTTP errors must fail API calls" >&2; exit 1; }
FETCH_IP6_LOCAL="$TMP/fetch-ip6-local.sh"
awk 'p{print} /^fetch_ip6_local\(\) \{/{p=1; print; next} p && /^}$/{exit}' "$HUAWEI_DDNS_TEMPLATE" > "$FETCH_IP6_LOCAL"
# shellcheck source=/dev/null
source "$FETCH_IP6_LOCAL"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
cat <<'IPADDR'
2: eth0    inet6 2404:c804:2331:ad01:be24:11ff:fe45:5e90/64 scope global dynamic mngtmpaddr \       valid_lft 1041sec preferred_lft 1041sec
2: eth0    inet6 2001:db8::100/64 scope global temporary dynamic \       valid_lft 1041sec preferred_lft 1041sec
IPADDR
EOF
chmod +x "$TMP/bin/ip"
[[ "$(PATH="$TMP/bin:$PATH" fetch_ip6_local)" = "2404:c804:2331:ad01:be24:11ff:fe45:5e90" ]] || { echo "DDNS IPv6 local fallback picked the wrong address" >&2; exit 1; }
DDNS_SAMPLE_LOG="$TMP/ddns.log"
DDNS_STATE_DIR="$TMP/ddns-state"
mkdir -p "$DDNS_STATE_DIR"
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:00:02] OK: AAAA v6jp99.289599.xyz 更新成功 2001:db8::1 → 2001:db8::2
[2026-07-02 23:05:01] OK: A jp99.289599.xyz 未变化 2.2.2.2
[2026-07-02 23:05:02] OK: AAAA v6jp99.289599.xyz 未变化 2001:db8::2
EOF
[[ "$(ddns_latest_log_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 未变化 2.2.2.2"* ]] || { echo "DDNS IPv4 latest log lookup failed" >&2; exit 1; }
[[ "$(ddns_latest_log_line AAAA v6jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"AAAA v6jp99.289599.xyz 未变化 2001:db8::2"* ]] || { echo "DDNS IPv6 latest log lookup failed" >&2; exit 1; }
[[ "$(ddns_latest_change_log_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 1.1.1.1"* ]] || { echo "DDNS IPv4 change log lookup failed" >&2; exit 1; }
[[ "$(ddns_latest_change_log_line AAAA v6jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"AAAA v6jp99.289599.xyz 更新成功 2001:db8::1"* ]] || { echo "DDNS IPv6 change log lookup failed" >&2; exit 1; }
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 1.1.1.1"* ]] || { echo "DDNS current change lookup failed" >&2; exit 1; }
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:06:01] OK: A jp99.289599.xyz IP变化 2.2.2.2 → 3.3.3.3（DNS已同步）
[2026-07-02 23:07:01] OK: A jp99.289599.xyz 未变化 3.3.3.3
EOF
[[ "$(ddns_latest_change_log_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz IP变化 2.2.2.2 → 3.3.3.3"* ]] || { echo "DDNS synced IP change log lookup failed" >&2; exit 1; }
cat > "$DDNS_STATE_DIR/.cf_last_change_A" <<'EOF'
2026-07-02 23:00:01|A|1.1.1.1|2.2.2.2|jp99.289599.xyz
EOF
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:10:01] OK: A jp99.289599.xyz 未变化 3.3.3.3
EOF
! ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG" >/dev/null || { echo "DDNS stale change should be hidden when current IP differs" >&2; exit 1; }
cat > "$DDNS_SAMPLE_LOG" <<'EOF'
[2026-07-02 23:00:01] OK: A jp99.289599.xyz 更新成功 1.1.1.1 → 2.2.2.2
[2026-07-02 23:10:01] OK: A jp99.289599.xyz 更新成功 2.2.2.2 → 3.3.3.3
[2026-07-02 23:11:01] OK: A jp99.289599.xyz 未变化 3.3.3.3
EOF
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 2.2.2.2 → 3.3.3.3"* ]] || { echo "DDNS newer log change should beat stale state file" >&2; exit 1; }
cat > "$DDNS_STATE_DIR/.cf_last_status_A" <<'EOF'
2026-07-02 23:20:01|A|jp99.289599.xyz|unchanged|4.4.4.4|4.4.4.4
EOF
cat > "$DDNS_STATE_DIR/.cf_last_change_A" <<'EOF'
2026-07-02 23:19:01|A|3.3.3.3|4.4.4.4|jp99.289599.xyz
EOF
[[ "$(ddns_record_status_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 未变化 4.4.4.4"* ]] || { echo "DDNS newer state status should beat old log status" >&2; exit 1; }
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz 更新成功 3.3.3.3 → 4.4.4.4"* ]] || { echo "DDNS current state change should be shown" >&2; exit 1; }
cat > "$DDNS_STATE_DIR/.cf_last_change_A" <<'EOF'
2026-07-02 23:21:01|A|4.4.4.4|5.5.5.5|jp99.289599.xyz|synced
EOF
cat > "$DDNS_STATE_DIR/.cf_last_status_A" <<'EOF'
2026-07-02 23:22:01|A|jp99.289599.xyz|unchanged|5.5.5.5|5.5.5.5
EOF
[[ "$(ddns_record_change_line A jp99.289599.xyz "$DDNS_SAMPLE_LOG")" = *"A jp99.289599.xyz IP变化 4.4.4.4 → 5.5.5.5"* ]] || { echo "DDNS synced state change should be shown" >&2; exit 1; }
grep -q "新端口已测试可登录吗" "$ROOT/src/modules/ssh.sh" || { echo "SSH new port confirmation prompt missing" >&2; exit 1; }
grep -q "自动回滚已取消" "$ROOT/src/modules/ssh.sh" || { echo "SSH rollback cancellation message missing" >&2; exit 1; }
grep -q "关闭旧端口防火墙规则" "$ROOT/src/modules/ssh.sh" || { echo "SSH old firewall rule prompt missing" >&2; exit 1; }
system_hostname_valid GreenCloud.HK6666 || { echo "Hostname validation rejected valid dotted name" >&2; exit 1; }
! system_hostname_valid "-bad-name" || { echo "Hostname validation accepted bad leading hyphen" >&2; exit 1; }
[[ "$(monitor_alert_html_escape 'Ali&HKG<ECS>')" = "Ali&amp;HKG&lt;ECS&gt;" ]] || { echo "HTML escape failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_alert_host_label
MON_HOST_LABEL='Ali&HKG<ECS>'
[[ "$(monitor_alert_host_label)" = "Ali&HKG<ECS>" ]] || { echo "Raw host label changed unexpectedly" >&2; exit 1; }
[[ "$(monitor_alert_host_label_html)" = "Ali&amp;HKG&lt;ECS&gt;" ]] || { echo "Escaped host label failed" >&2; exit 1; }
(
    MONITOR_CFG="$TMP/monitor.cfg"
    PWNED="$TMP/monitor-config-executed"
    monitor_alert_cfg() { echo "$MONITOR_CFG"; }
    # shellcheck disable=SC2034 # consumed by monitor_alert_check
    monitor_alert_load_cfg() { MON_ENABLED=no; }
    {
        echo "ENABLED=no"
        echo "HOST_LABEL=\$(touch '$PWNED')"
    } > "$MONITOR_CFG"
    monitor_alert_check
    [ ! -e "$PWNED" ] || { echo "Monitor config was executed as shell" >&2; exit 1; }
)
SSHD_SAMPLE="$TMP/sshd_config"
cat > "$SSHD_SAMPLE" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes

Match User deploy
    PasswordAuthentication yes
EOF
set_config_file "$SSHD_SAMPLE" "PasswordAuthentication" "no"
FIRST_DIRECTIVE=$(grep -m1 -E '^(Include|PasswordAuthentication|Match)' "$SSHD_SAMPLE")
[[ "$FIRST_DIRECTIVE" = "PasswordAuthentication no" ]] || { echo "Managed SSH settings must precede Include and Match blocks" >&2; exit 1; }
(
    NFT_RULES_FILE="$TMP/nft-rules.db"
    NFT_ACCESS_FILE="$TMP/nft-access.conf"
    : > "$NFT_RULES_FILE"
    echo "mode=off" > "$NFT_ACCESS_FILE"
    NFT_CONFIG=$(nft_generate_config)
    [[ "$NFT_CONFIG" != *"flush ruleset"* ]] || { echo "NFT config must not flush the host ruleset" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *"table ip nftpf_nat"* ]] || { echo "NFT IPv4 table name should be script-scoped" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *"table ip6 nftpf_nat"* ]] || { echo "NFT IPv6 table name should be script-scoped" >&2; exit 1; }

(
    NFT_TEST="$TMP/nft-transaction"
    mkdir -p "$NFT_TEST/state"
    NFT_CONFIG_FILE="$NFT_TEST/nftables.conf"
    NFT_MANAGED_FILE="$NFT_TEST/vps-tools.nft"
    NFT_STATE_DIR="$NFT_TEST/state"
    NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
    NFT_ACCESS_FILE="$NFT_STATE_DIR/access.conf"
    : > "$NFT_RULES_FILE"
    printf 'mode=off\n' > "$NFT_ACCESS_FILE"
    printf '#!/usr/sbin/nft -f\ntable inet user_firewall {}\n' > "$NFT_CONFIG_FILE"
    systemd_available() { return 1; }
    nft() {
        [ "${1:-}" = list ] && return 1
        return 0
    }
    nft_write_and_apply >/dev/null
    grep -q 'table inet user_firewall' "$NFT_CONFIG_FILE" || { echo "NFT update replaced user config" >&2; exit 1; }
    grep -Fq "$NFT_INCLUDE_MARKER" "$NFT_CONFIG_FILE" || { echo "NFT managed include missing" >&2; exit 1; }
    [ -s "$NFT_MANAGED_FILE" ] || { echo "NFT managed rules file missing" >&2; exit 1; }
)
(
    NFT_TEST="$TMP/nft-rollback"
    mkdir -p "$NFT_TEST/state"
    NFT_CONFIG_FILE="$NFT_TEST/nftables.conf"
    NFT_MANAGED_FILE="$NFT_TEST/vps-tools.nft"
    NFT_STATE_DIR="$NFT_TEST/state"
    NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
    NFT_ACCESS_FILE="$NFT_STATE_DIR/access.conf"
    : > "$NFT_RULES_FILE"
    printf 'mode=off\n' > "$NFT_ACCESS_FILE"
    printf '#!/usr/sbin/nft -f\ntable inet user_firewall {}\n' > "$NFT_CONFIG_FILE"
    printf '# old managed rules\n' > "$NFT_MANAGED_FILE"
    cp "$NFT_CONFIG_FILE" "$NFT_TEST/main.expected"
    cp "$NFT_MANAGED_FILE" "$NFT_TEST/managed.expected"
    systemd_available() { return 1; }
    nft() {
        [ "${1:-}" = list ] && return 1
        [ "${1:-}" = -c ] && return 0
        return 1
    }
    ! nft_write_and_apply >/dev/null 2>&1 || { echo "NFT apply failure returned success" >&2; exit 1; }
    [ "$(cat "$NFT_CONFIG_FILE")" = "$(cat "$NFT_TEST/main.expected")" ] \
        || { echo "NFT apply failure did not restore main config" >&2; exit 1; }
    [ "$(cat "$NFT_MANAGED_FILE")" = "$(cat "$NFT_TEST/managed.expected")" ] \
        || { echo "NFT apply failure did not restore managed config" >&2; exit 1; }
)
)
monitor_alert_service_state() { case "$1" in ssh) echo stopped ;; sshd) echo running ;; *) echo unknown ;; esac; }
[[ "$(monitor_alert_ssh_state)" = "running" ]] || { echo "SSH service alias check failed" >&2; exit 1; }
[[ "$(monitor_int_normalize 1.24682e+11)" = "124682000000" ]] || { echo "Scientific notation normalization failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_alert_cooldown_seconds
MON_ALERT_COOLDOWN_MIN=7
[[ "$(monitor_alert_cooldown_seconds)" = "420" ]] || { echo "Alert cooldown conversion failed" >&2; exit 1; }
[[ "$(monitor_alert_time_to_minutes 23:59)" = "1439" ]] || { echo "Alert silence time parsing failed" >&2; exit 1; }
[[ "$(monitor_alert_daily_cron_expr 23:59)" = "59 23 * * *" ]] || { echo "Daily cron 23:59 expression failed" >&2; exit 1; }
[[ "$(monitor_alert_daily_cron_expr 2359)" = "59 23 * * *" ]] || { echo "Daily cron 2359 expression failed" >&2; exit 1; }
[[ "$(monitor_alert_level_label critical)" = "严重" ]] || { echo "Alert level label failed" >&2; exit 1; }
[[ "$(monitor_alert_worst_level warning critical)" = "critical" ]] || { echo "Alert level ranking failed" >&2; exit 1; }
monitor_percent_valid 85 || { echo "Valid monitor percentage rejected" >&2; exit 1; }
! monitor_percent_valid 101 || { echo "Invalid monitor percentage accepted" >&2; exit 1; }
monitor_positive_number_valid 0.5 || { echo "Valid positive monitor number rejected" >&2; exit 1; }
! monitor_positive_number_valid '50GB' || { echo "Invalid monitor number accepted" >&2; exit 1; }
monitor_positive_int_valid 30 || { echo "Valid positive monitor integer rejected" >&2; exit 1; }
! monitor_positive_int_valid 0 || { echo "Zero monitor integer accepted" >&2; exit 1; }
monitor_renew_notice_days_valid '30,7,3,1,0' || { echo "Valid renewal notice list rejected" >&2; exit 1; }
! monitor_renew_notice_days_valid '30,bad,1' || { echo "Invalid renewal notice list accepted" >&2; exit 1; }
(
    MON_TRAFFIC_INTERFACES=
    ip() {
        case "$1" in
            -4) echo 'default via 192.0.2.1 dev eth0' ;;
            -6) echo 'default via 2001:db8::1 dev eth0'; echo 'default via 2001:db8::2 dev eth1' ;;
        esac
    }
    [[ "$(monitor_traffic_interfaces)" = "eth0 eth1" ]] || { echo "Default-route traffic interface detection failed" >&2; exit 1; }
    export MON_TRAFFIC_INTERFACES='ens3,docker0'
    [[ "$(monitor_traffic_interfaces)" = "ens3 docker0" ]] || { echo "Configured traffic interface parsing failed" >&2; exit 1; }
)
MONITOR_CRON_SAMPLE=$(printf '%s\n' \
    '*/10 * * * * /usr/local/bin/vps-tools --monitor-alert # vps-monitor-alert' \
    '5 * * * * /opt/vps-monitor-alert-helper' \
    '0 8 * * * * /usr/local/bin/vps-tools --monitor-alert # VPS_TOOLS_DAILY_JOB')
MONITOR_CRON_FILTERED=$(printf '%s\n' "$MONITOR_CRON_SAMPLE" | monitor_alert_cron_without_managed)
[[ "$MONITOR_CRON_FILTERED" = '5 * * * * /opt/vps-monitor-alert-helper' ]] || { echo "Monitor cron cleanup removed an unrelated job" >&2; exit 1; }
(
    export MONITOR_ALERT_LOCK_FILE="$TMP/monitor.lock"
    monitor_alert_acquire_lock || { echo "Monitor lock acquisition failed" >&2; exit 1; }
    ! (monitor_alert_acquire_lock) || { echo "Concurrent monitor lock acquisition succeeded" >&2; exit 1; }
)
(
    export MONITOR_ALERT_FORCE_MKDIR_LOCK=1
    export MONITOR_ALERT_LOCK_FILE="$TMP/monitor-stale.lock"
    mkdir -p "${MONITOR_ALERT_LOCK_FILE}.d"
    printf '99999999\n' > "${MONITOR_ALERT_LOCK_FILE}.d/pid"
    monitor_alert_acquire_lock || { echo "Stale monitor fallback lock was not recovered" >&2; exit 1; }
)
monitor_traffic_reset_day_valid 31 || { echo "Reset day 31 should be valid" >&2; exit 1; }
! monitor_traffic_reset_day_valid 32 || { echo "Reset day 32 should be invalid" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-02-15)" = "2026-01-31" ]] || { echo "Previous short-month reset calculation failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-02-28)" = "2026-01-31" ]] || { echo "Short-month reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-03-01)" = "2026-03-01" ]] || { echo "Short-month rollover reset failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2028-02-29)" = "2028-01-31" ]] || { echo "Leap-year short-month reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2028-03-01)" = "2028-03-01" ]] || { echo "Leap-year rollover reset failed" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-04-30)" = "2026-03-31" ]] || { echo "April reset should wait for next month" >&2; exit 1; }
[[ "$(monitor_traffic_current_cycle_start 31 2026-05-01)" = "2026-05-01" ]] || { echo "April rollover reset failed" >&2; exit 1; }
# shellcheck disable=SC2329 # invoked indirectly by traffic helper functions under test
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
# shellcheck disable=SC2329 # invoked indirectly by traffic helper functions under test
monitor_traffic_totals() { echo "100 200 300"; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_BASELINE_RX_BYTES=1000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_BASELINE_TX_BYTES=2000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_BASELINE_BYTES=3000
[[ "$(monitor_traffic_usage_triplet daily)" = "100 200 300" ]] || { echo "Daily traffic counter reset handling failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=1000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=2000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_BASELINE_BYTES=3000
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=10
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=20
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_CYCLE_OFFSET_BYTES=30
[[ "$(monitor_traffic_usage_triplet cycle)" = "110 220 330" ]] || { echo "Cycle traffic counter reset handling failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_usage_triplet
MON_TRAFFIC_ENABLED=yes
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_DATE=2026-07-06
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_RX_BYTES=1000
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_TX_BYTES=2000
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_BYTES=3000
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_RX_BYTES=5
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_TX_BYTES=6
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_BYTES=11
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_DATE=2026-07-01
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=500
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=800
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_BYTES=1300
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_OFFSET_RX_BYTES=10
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_OFFSET_TX_BYTES=20
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_OFFSET_BYTES=30
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_RX_BYTES=1200
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_TX_BYTES=2400
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_BYTES=3600
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_DAILY_BASELINE_RESET=no
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_CYCLE_BASELINE_RESET=no
[[ "$(monitor_traffic_usage_triplet daily)" = "205 406 611" ]] || { echo "Daily traffic reset ledger failed" >&2; exit 1; }
[[ "$(monitor_traffic_usage_triplet cycle)" = "710 1620 2330" ]] || { echo "Cycle traffic reset ledger failed" >&2; exit 1; }
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_RX_BYTES=100
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_TX_BYTES=200
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_BASELINE_BYTES=300
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_RX_BYTES=0
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_TX_BYTES=0
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_OFFSET_BYTES=0
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_RX_BYTES=1200
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_TX_BYTES=2400
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_LAST_BYTES=3600
# shellcheck disable=SC2034 # consumed by monitor_traffic_reconcile_counters
MON_TRAFFIC_DAILY_BASELINE_RESET=yes
[[ "$(monitor_traffic_usage_triplet daily)" = "0 0 0" ]] || { echo "Daily rollover should not inherit old traffic" >&2; exit 1; }
(
    METRICS_FILE="$TMP/monitor.metrics"
    NOW=$(date +%s)
    printf '%s 10 20 0.10 1073741824\n%s 11 21 0.20 536870912\n' "$((NOW - 120))" "$((NOW - 60))" > "$METRICS_FILE"
    monitor_alert_metrics() { echo "$METRICS_FILE"; }
    [[ "$(monitor_alert_trend_line '测试趋势' 3600)" = *'流量 +0.50G'* ]] || { echo "Monitor trend did not preserve traffic across a counter reset" >&2; exit 1; }
)
MANIFEST="$TMP/manifest.json"
cat > "$MANIFEST" <<'EOF'
{"name":"SSH-Hardening","version":"V3.9.45","sha256":"abc123"}
EOF
[[ "$(self_manifest_value "$MANIFEST" version)" = "V3.9.45" ]] || { echo "Manifest parsing failed" >&2; exit 1; }

DAILY_REPORT_CALLS=0
monitor_alert_daily_report() { DAILY_REPORT_CALLS=$((DAILY_REPORT_CALLS + 1)); }
monitor_alert_state_get() {
    case "$1" in
        DAILY_REPORT_DATE) date +%F ;;
        DAILY_REPORT_TS|RENEW_TS) echo 0 ;;
        *) return 1 ;;
    esac
}
monitor_alert_state_set() { :; }
# shellcheck disable=SC2034 # consumed by monitor_alert_daily_report_check
MON_DAILY_REPORT_ENABLED=yes
# shellcheck disable=SC2034 # consumed by monitor_alert_daily_report_check
MON_DAILY_REPORT_TIME=00:00
monitor_alert_daily_report_check
[[ "$DAILY_REPORT_CALLS" -eq 0 ]] || { echo "Daily report repeated on the same day" >&2; exit 1; }

(
    STATE_SET_CALLS=0
    monitor_alert_daily_report() { return 1; }
    monitor_daily_report_due() { return 0; }
    monitor_alert_state_get() { return 1; }
    monitor_alert_state_set() { STATE_SET_CALLS=$((STATE_SET_CALLS + 1)); }
    monitor_alert_history_add() { :; }
    audit_action() { :; }
    export MON_DAILY_REPORT_ENABLED=yes
    export MON_DAILY_REPORT_TIME=00:00
    ! monitor_alert_daily_report_check || { echo "Failed daily report returned success" >&2; exit 1; }
    [[ "$STATE_SET_CALLS" -eq 0 ]] || { echo "Failed daily report was marked as sent" >&2; exit 1; }
)

(
    monitor_alert_cfg_get() { case "$1" in BOT_TOKEN) echo token ;; CHAT_ID) echo chat ;; esac; }
    monitor_alert_telegram_send() { return 1; }
    ! monitor_alert_notify title body || { echo "Failed Telegram request returned success" >&2; exit 1; }
)

RENEW_NOTIFY_CALLS=0
monitor_alert_notify() { RENEW_NOTIFY_CALLS=$((RENEW_NOTIFY_CALLS + 1)); }
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_ENABLED=yes
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_NEXT_DATE=$(date +%F)
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_NOTICE_DAYS=0
# shellcheck disable=SC2034 # consumed by monitor_alert_renew_check
MON_RENEW_LAST_ALERT=$(date +%F)
monitor_alert_renew_check
[[ "$RENEW_NOTIFY_CALLS" -eq 0 ]] || { echo "Renew reminder repeated on the same day" >&2; exit 1; }

(
    monitor_alert_notify() { return 0; }
    monitor_alert_history_add() { :; }
    monitor_alert_state_get() { return 1; }
    monitor_alert_state_set() { :; }
    monitor_alert_save_cfg() { :; }
    audit_action() { :; }
    export MON_RENEW_ENABLED=yes
    export MON_RENEW_MODE=interval
    MON_RENEW_NEXT_DATE=$(date +%F)
    ORIGINAL_RENEW_DATE="$MON_RENEW_NEXT_DATE"
    export MON_RENEW_INTERVAL_DAYS=365
    export MON_RENEW_MONTH_DAY=1
    export MON_RENEW_NOTICE_DAYS=0
    export MON_RENEW_LAST_ALERT=
    monitor_alert_renew_check
    [[ "$MON_RENEW_NEXT_DATE" = "$ORIGINAL_RENEW_DATE" ]] || { echo "Due renewal date advanced without payment confirmation" >&2; exit 1; }
)

OS=$(detect_os)
[ -n "$OS" ] || { echo "OS detection returned empty" >&2; exit 1; }

COLUMNS=44; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 1 ] || { echo "Narrow terminal did not enable compact layout" >&2; exit 1; }
COLUMNS=72; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 0 ] || { echo "Wide terminal did not enable two-column layout" >&2; exit 1; }

echo "Smoke test passed on $OS."

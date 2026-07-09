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
    ddns_interval_normalize ddns_interval_min ddns_cron_expr ddns_prompt_interval \
    ddns_cfg_enable_a ddns_cfg_enable_aaaa ddns_cfg_domain4 ddns_cfg_domain6 ddns_primary_domain ddns_mode_label ddns_build_domain \
    ddns_latest_log_line ddns_latest_change_log_line ddns_line_time ddns_line_result_ip ddns_newer_line ddns_change_matches_status ddns_record_status_line ddns_record_change_line ddns_print_record_summary \
    system_toolbox_menu \
    resource_health_check system_update_manager system_hostname_apply config_backup_create self_update docker_menu change_port; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

for fn in docker_install docker_status docker_select_container docker_upgrade_container docker_container_action docker_inspect_label docker_download_file docker_compose_basename docker_compose_fetch_and_deploy; do
    declare -F "$fn" >/dev/null || { echo "Missing Docker function: $fn" >&2; exit 1; }
done

for fn in self_offline_bundle_create self_offline_bundle_install self_update self_manifest_value self_remote_main_sha monitor_alert_check monitor_alert_config_menu monitor_alert_home_menu monitor_alert_daily_report monitor_alert_host_label monitor_alert_host_label_html monitor_alert_html_escape monitor_alert_set_host_label monitor_time_normalize monitor_date_normalize monitor_int_normalize monitor_traffic_reset_day_valid monitor_traffic_totals monitor_traffic_delta_bytes monitor_traffic_reconcile_counters monitor_traffic_usage_triplet monitor_traffic_usage_text monitor_traffic_set_cycle_usage_split_gb monitor_alert_service_state monitor_alert_any_service_state monitor_alert_ssh_state monitor_alert_test_snapshot monitor_alert_resource_snapshot monitor_alert_traffic_snapshot monitor_alert_renew_snapshot monitor_alert_renew_mark_paid monitor_alert_notify monitor_alert_history_add monitor_alert_history_view monitor_alert_cooldown_seconds monitor_alert_time_to_minutes monitor_alert_in_silence monitor_alert_metrics monitor_alert_metrics_sample monitor_alert_trend_line monitor_alert_trend_summary monitor_alert_level_label monitor_alert_level_icon monitor_alert_level_rank monitor_alert_worst_level monitor_alert_daily_cron_expr monitor_alert_cron_command monitor_alert_install_cron monitor_alert_remove_cron monitor_alert_cron_status monitor_alert_next_daily_time monitor_alert_configured_without_cron monitor_alert_service_menu monitor_alert_notify_menu monitor_alert_resource_menu monitor_alert_traffic_menu monitor_alert_daily_menu monitor_alert_renew_menu monitor_alert_advanced_menu monitor_alert_quick_setup_menu config_health_check diagnostic_bundle_create; do
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
[[ "$CLI_HELP" = *"--hostname-menu"* ]] || { echo "CLI help missing hostname entry" >&2; exit 1; }
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
grep -q "SDK-HMAC-SHA256" "$ROOT/src/modules/ddns.sh" || { echo "Huawei DDNS signer missing" >&2; exit 1; }
! grep -q "LC_TIME" "$ROOT/src/modules/ddns.sh" || { echo "DDNS menu must not use LC_TIME locale variable" >&2; exit 1; }
HUAWEI_DDNS_TEMPLATE="$TMP/huawei-ddns-template.sh"
awk "BEGIN{p=0} /cat > \"\\\$DDNS_SCRIPT\" << 'DDNS_HUAWEI_INNER'/{p=1; next} /^DDNS_HUAWEI_INNER$/{if(p){exit}} p{print}" "$ROOT/src/modules/ddns.sh" > "$HUAWEI_DDNS_TEMPLATE"
bash -n "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS generated template has syntax errors" >&2; exit 1; }
grep -Fq 'JSON_INPUT=$(cat)' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS JSON parser must preserve piped API responses" >&2; exit 1; }
grep -Fq 'fetch_ip6_local' "$HUAWEI_DDNS_TEMPLATE" || { echo "Huawei DDNS IPv6 local fallback missing" >&2; exit 1; }
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
MANIFEST="$TMP/manifest.json"
cat > "$MANIFEST" <<'EOF'
{"name":"SSH-Hardening","version":"V3.9.42","sha256":"abc123"}
EOF
[[ "$(self_manifest_value "$MANIFEST" version)" = "V3.9.42" ]] || { echo "Manifest parsing failed" >&2; exit 1; }

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

OS=$(detect_os)
[ -n "$OS" ] || { echo "OS detection returned empty" >&2; exit 1; }

COLUMNS=44; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 1 ] || { echo "Narrow terminal did not enable compact layout" >&2; exit 1; }
COLUMNS=72; ui_refresh_dimensions
[ "$UI_COMPACT" -eq 0 ] || { echo "Wide terminal did not enable two-column layout" >&2; exit 1; }

echo "Smoke test passed on $OS."

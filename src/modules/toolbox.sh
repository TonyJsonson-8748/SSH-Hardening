# ══════════════════════════════════════════════════════════
#  系统检查、备份与诊断工具箱
# ══════════════════════════════════════════════════════════

config_backup_paths() {
    local p
    for p in \
        etc/ssh/sshd_config etc/ssh/sshd_config.d root/.ssh/authorized_keys \
        etc/fail2ban etc/ufw etc/firewalld etc/nftables.conf etc/nft-port-forward \
        etc/sysctl.conf etc/sysctl.d/99-vps-bbr.conf etc/sysctl.d/99-ipv6-disable.conf \
        etc/gai.conf etc/resolv.conf etc/systemd/resolved.conf etc/systemd/resolved.conf.d \
        etc/NetworkManager/conf.d etc/NetworkManager/system-connections etc/resolvconf/resolv.conf.d \
        etc/caddy root/ddns.sh root/.cf_token root/.cf_zone root/.cf_tg root/.cf_last_change \
        var/spool/cron/crontabs/root var/spool/cron/root etc/crontabs/root; do
        [ -e "/$p" ] || [ -L "/$p" ] || continue
        printf '%s\n' "$p"
    done
}

config_backup_prune() {
    local FILES=() f REMOVE_COUNT i
    while IFS= read -r f; do FILES+=("$f"); done < <(
        find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r
    )
    [ "${#FILES[@]}" -le "$VPS_BACKUP_KEEP" ] && return 0
    REMOVE_COUNT=$((${#FILES[@]} - VPS_BACKUP_KEEP))
    for ((i=${#FILES[@]}-1; i>=VPS_BACKUP_KEEP; i--)); do
        rm -f "${FILES[$i]}"
    done
    audit_action "自动清理 $REMOVE_COUNT 个旧配置备份" SUCCESS
}

cancel_safety_timer() {
    [ -n "${SAFETY_PID:-}" ] || return 0
    kill "$SAFETY_PID" 2>/dev/null || true
    wait "$SAFETY_PID" 2>/dev/null || true
    rm -f "${SAFETY_SCRIPT:-}"
    SAFETY_PID="" SAFETY_SCRIPT=""
}

confirm_change_preview() {
    local TITLE="$1"
    shift
    echo ""
    menu_div
    echo -e "  ${BOLD}变更预览：$TITLE${NC}"
    while [ "$#" -gt 0 ]; do echo -e "  ${YELLOW}•${NC} $1"; shift; done
    menu_div
    read -rp "  确认应用以上变更？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$'
}

confirm_file_diff() {
    local OLD_FILE="$1" NEW_FILE="$2" TITLE="$3"
    echo ""
    menu_div
    echo -e "  ${BOLD}配置差异：$TITLE${NC}"
    if command -v diff >/dev/null 2>&1; then
        diff -u "$OLD_FILE" "$NEW_FILE" 2>/dev/null | sed -n '1,120p' || true
    else
        warn "系统没有 diff，无法显示逐行差异"
    fi
    menu_div
    read -rp "  确认应用以上配置？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$'
}

config_backup_create() {
    local LABEL="${1:-manual}" QUIET="${2:-false}" TS FILE LIST
    TS=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$VPS_BACKUP_DIR"
    chmod 700 "$VPS_DATA_DIR" "$VPS_BACKUP_DIR" 2>/dev/null || true
    FILE="$VPS_BACKUP_DIR/${TS}_${LABEL}.tar.gz"
    LIST=$(mktemp)
    config_backup_paths > "$LIST"
    if [ ! -s "$LIST" ] || ! tar -czf "$FILE" -C / -T "$LIST" 2>/dev/null; then
        rm -f "$LIST" "$FILE"
        [ "$QUIET" = true ] || error "配置备份失败"
        return 1
    fi
    rm -f "$LIST"
    chmod 600 "$FILE"
    audit_action "创建配置备份 $(basename "$FILE")" SUCCESS
    config_backup_prune
    if [ "$QUIET" = true ]; then printf '%s\n' "$FILE"; else info "配置已备份：$FILE"; fi
}

config_backup_restore() {
    local FILE="$1"
    [ -f "$FILE" ] || { error "备份不存在"; return 1; }
    tar -tzf "$FILE" >/dev/null 2>&1 || { error "备份文件损坏"; return 1; }
    warn "恢复将覆盖当前配置，并重启相关服务。"
    read -rp "  输入 RESTORE 确认恢复: " CONFIRM
    [ "$CONFIRM" = "RESTORE" ] || { warn "已取消"; return; }
    config_backup_create before_restore true >/dev/null || return 1
    safety_arm config_restore || return 1
    if ! tar -xzf "$FILE" -C / 2>/dev/null; then
        error "恢复失败，已保留恢复前快照"
        audit_action "恢复配置 $(basename "$FILE")" FAILED
        return 1
    fi
    if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
        error "恢复后的 SSH 配置语法错误，请从 before_restore 快照恢复"
        audit_action "恢复配置 $(basename "$FILE") SSH校验失败" FAILED
        return 1
    fi
    restart_ssh 2>/dev/null || true
    command -v systemctl >/dev/null 2>&1 && systemctl restart systemd-resolved 2>/dev/null || true
    command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ] && nft -f /etc/nftables.conf 2>/dev/null || true
    audit_action "恢复配置 $(basename "$FILE")" SUCCESS
    info "配置恢复完成"
    safety_confirm
}

config_backup_menu() {
    while true; do
        print_header "配置备份与恢复"
        mkdir -p "$VPS_BACKUP_DIR"
        local FILES=() f i=1
        while IFS= read -r f; do FILES+=("$f"); done < <(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r)
        for f in "${FILES[@]}"; do
            echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}$(du -h "$f" 2>/dev/null | awk '{print $1}')${NC}"
            i=$((i+1))
        done
        [ "${#FILES[@]}" -eq 0 ] && echo -e "  ${DIM}暂无备份${NC}"
        menu_div
        menu_pair "c" "创建备份" "r" "恢复备份" "$GREEN" "$YELLOW"
        menu_pair "d" "删除备份" "0" "返回上级" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作: ')" CH
        case "$CH" in
            c|C) config_backup_create manual ;;
            r|R|d|D)
                [ "${#FILES[@]}" -gt 0 ] || { warn "暂无备份"; sleep 1; continue; }
                read -rp "  输入备份编号: " N
                echo "$N" | grep -qE '^[0-9]+$' || { warn "编号无效"; continue; }
                [ "$N" -ge 1 ] && [ "$N" -le "${#FILES[@]}" ] || { warn "编号无效"; continue; }
                if echo "$CH" | grep -qi '^r$'; then
                    config_backup_restore "${FILES[$((N-1))]}"
                else
                    rm -f "${FILES[$((N-1))]}" && audit_action "删除配置备份 $(basename "${FILES[$((N-1))]}")" SUCCESS
                fi
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        ui_pause
    done
}

config_export_archive() {
    local TARGET="${1:-}" LABEL="${2:-export}" TMP_ARCHIVE
    local OLD_KEEP="$VPS_BACKUP_KEEP"
    VPS_BACKUP_KEEP=999999
    TMP_ARCHIVE=$(config_backup_create "export_${LABEL}" true)
    local RC=$?
    VPS_BACKUP_KEEP="$OLD_KEEP"
    [ "$RC" -eq 0 ] || return "$RC"
    if [ -z "$TARGET" ]; then
        printf '%s\n' "$TMP_ARCHIVE"
        return 0
    fi
    mkdir -p "$(dirname "$TARGET")" 2>/dev/null || { error "无法创建导出目录"; return 1; }
    if ! cp "$TMP_ARCHIVE" "$TARGET" 2>/dev/null; then
        error "导出失败"
        return 1
    fi
    chmod 600 "$TARGET" 2>/dev/null || true
    audit_action "导出配置到 $(basename "$TARGET")" SUCCESS
    info "配置已导出：$TARGET"
    printf '%s\n' "$TARGET"
}

config_import_archive() {
    local FILE="$1"
    [ -f "$FILE" ] || { error "导入包不存在"; return 1; }
    tar -tzf "$FILE" >/dev/null 2>&1 || { error "导入包损坏"; return 1; }
    config_backup_restore "$FILE"
}

config_transfer_menu() {
    while true; do
        print_header "配置导出 / 导入"
        ui_hint "适合迁移到新机器或把当前配置带走备份"
        echo ""; menu_div
        menu_item "1" "导出当前配置" "$GREEN"
        menu_item "2" "导入配置包" "$YELLOW"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1)
                local TARGET ARCHIVE_NAME
                read -rp "$(ui_prompt '导出文件路径（默认 /root/vps-config-export.tar.gz）: ')" TARGET
                TARGET=${TARGET:-/root/vps-config-export.tar.gz}
                ARCHIVE_NAME="$(date +%Y%m%d_%H%M%S)_export"
                config_export_archive "$TARGET" "$ARCHIVE_NAME" || true
                ui_pause
                ;;
            2)
                local FILE
                read -rp "$(ui_prompt '输入要导入的 tar.gz 路径: ')" FILE
                config_import_archive "$FILE" || true
                ui_pause
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

rollback_center_menu() {
    while true; do
        local BACKUP_COUNT VERSION_COUNT LATEST_BACKUP LATEST_VERSION
        BACKUP_COUNT=$(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
        VERSION_COUNT=$(find "$VPS_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
        LATEST_BACKUP=$(find "$VPS_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r | head -1)
        LATEST_VERSION=$(find "$VPS_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -r | head -1)
        print_header "统一回滚中心"
        [ -n "$LATEST_BACKUP" ] && LATEST_BACKUP="${LATEST_BACKUP##*/}" || LATEST_BACKUP="无"
        [ -n "$LATEST_VERSION" ] && LATEST_VERSION="${LATEST_VERSION##*/}" || LATEST_VERSION="无"
        echo -e "  备份包：${BOLD}${BACKUP_COUNT:-0}${NC}   最新配置：${BOLD}${LATEST_BACKUP}${NC}"
        echo -e "  版本包：${BOLD}${VERSION_COUNT:-0}${NC}   最新脚本：${BOLD}${LATEST_VERSION}${NC}"
        echo ""; menu_div
        menu_item "1" "配置备份与恢复" "$GREEN"
        menu_item "2" "配置导出 / 导入" "$CYAN"
        menu_item "3" "脚本版本回滚" "$YELLOW"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" CH
        case "$CH" in
            1) config_backup_menu ;;
            2) config_transfer_menu ;;
            3) self_rollback ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_alert_cfg() { echo "/root/.vps-monitor"; }
monitor_alert_script() { echo "/root/vps-monitor-alert.sh"; }
monitor_alert_state() { echo "/root/.vps-monitor.state"; }

monitor_alert_cfg_get() {
    local KEY="$1" CFG; CFG=$(monitor_alert_cfg)
    [ -f "$CFG" ] || return 1
    grep "^${KEY}=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2-
}

monitor_alert_state_get() {
    local KEY="$1" STATE
    STATE=$(monitor_alert_state)
    [ -f "$STATE" ] || return 1
    grep "^${KEY}=" "$STATE" 2>/dev/null | head -1 | cut -d= -f2-
}

monitor_alert_state_set() {
    local KEY="$1" VALUE="$2" STATE TMP
    STATE=$(monitor_alert_state)
    mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
    TMP=$(mktemp "${TMPDIR:-/tmp}/vps-monitor-state.XXXXXX") || return 1
    [ -f "$STATE" ] && grep -v "^${KEY}=" "$STATE" > "$TMP" 2>/dev/null || true
    printf '%s=%s\n' "$KEY" "$VALUE" >> "$TMP"
    mv "$TMP" "$STATE"
    chmod 600 "$STATE" 2>/dev/null || true
}

monitor_alert_load_cfg() {
    local RAW_TRAFFIC_RX RAW_TRAFFIC_TX RAW_TRAFFIC_CYCLE_RX RAW_TRAFFIC_CYCLE_TX
    MON_ENABLED=$(monitor_alert_cfg_get ENABLED); MON_ENABLED=${MON_ENABLED:-no}
    MON_DISK_WARN=$(monitor_alert_cfg_get DISK_WARN); MON_DISK_WARN=${MON_DISK_WARN:-85}
    MON_MEM_WARN=$(monitor_alert_cfg_get MEM_WARN); MON_MEM_WARN=${MON_MEM_WARN:-85}
    MON_LOAD_WARN=$(monitor_alert_cfg_get LOAD_WARN); MON_LOAD_WARN=${MON_LOAD_WARN:-}
    MON_BOT_TOKEN=$(monitor_alert_cfg_get BOT_TOKEN)
    MON_CHAT_ID=$(monitor_alert_cfg_get CHAT_ID)
    MON_HOST_LABEL=$(monitor_alert_cfg_get HOST_LABEL)
    MON_TRAFFIC_ENABLED=$(monitor_alert_cfg_get TRAFFIC_ENABLED); MON_TRAFFIC_ENABLED=${MON_TRAFFIC_ENABLED:-no}
    MON_TRAFFIC_LIMIT_GB=$(monitor_alert_cfg_get TRAFFIC_LIMIT_GB); MON_TRAFFIC_LIMIT_GB=${MON_TRAFFIC_LIMIT_GB:-50}
    MON_TRAFFIC_BASELINE_DATE=$(monitor_alert_cfg_get TRAFFIC_BASELINE_DATE)
    MON_TRAFFIC_BASELINE_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_BASELINE_BYTES)")
    RAW_TRAFFIC_RX=$(monitor_alert_cfg_get TRAFFIC_BASELINE_RX_BYTES)
    RAW_TRAFFIC_TX=$(monitor_alert_cfg_get TRAFFIC_BASELINE_TX_BYTES)
    [ -n "$RAW_TRAFFIC_RX" ] && MON_TRAFFIC_BASELINE_RX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_RX") || MON_TRAFFIC_BASELINE_RX_BYTES=
    [ -n "$RAW_TRAFFIC_TX" ] && MON_TRAFFIC_BASELINE_TX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_TX") || MON_TRAFFIC_BASELINE_TX_BYTES=
    MON_TRAFFIC_RESET_DAY=$(monitor_alert_cfg_get TRAFFIC_RESET_DAY); MON_TRAFFIC_RESET_DAY=${MON_TRAFFIC_RESET_DAY:-1}
    MON_TRAFFIC_CYCLE_BASELINE_DATE=$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_DATE)
    MON_TRAFFIC_CYCLE_BASELINE_BYTES=$(monitor_int_normalize "$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_BYTES)")
    RAW_TRAFFIC_CYCLE_RX=$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_RX_BYTES)
    RAW_TRAFFIC_CYCLE_TX=$(monitor_alert_cfg_get TRAFFIC_CYCLE_BASELINE_TX_BYTES)
    [ -n "$RAW_TRAFFIC_CYCLE_RX" ] && MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_CYCLE_RX") || MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES=
    [ -n "$RAW_TRAFFIC_CYCLE_TX" ] && MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=$(monitor_int_normalize "$RAW_TRAFFIC_CYCLE_TX") || MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES=
    MON_RENEW_ENABLED=$(monitor_alert_cfg_get RENEW_ENABLED); MON_RENEW_ENABLED=${MON_RENEW_ENABLED:-no}
    MON_RENEW_MODE=$(monitor_alert_cfg_get RENEW_MODE); MON_RENEW_MODE=${MON_RENEW_MODE:-interval}
    MON_RENEW_NEXT_DATE=$(monitor_date_normalize "$(monitor_alert_cfg_get RENEW_NEXT_DATE)" 2>/dev/null || true)
    MON_RENEW_INTERVAL_DAYS=$(monitor_alert_cfg_get RENEW_INTERVAL_DAYS); MON_RENEW_INTERVAL_DAYS=${MON_RENEW_INTERVAL_DAYS:-365}
    MON_RENEW_MONTH_DAY=$(monitor_alert_cfg_get RENEW_MONTH_DAY); MON_RENEW_MONTH_DAY=${MON_RENEW_MONTH_DAY:-1}
    MON_RENEW_NOTICE_DAYS=$(monitor_alert_cfg_get RENEW_NOTICE_DAYS); MON_RENEW_NOTICE_DAYS=${MON_RENEW_NOTICE_DAYS:-30,7,3,1}
    MON_RENEW_LAST_ALERT=$(monitor_alert_cfg_get RENEW_LAST_ALERT)
    MON_DAILY_REPORT_ENABLED=$(monitor_alert_cfg_get DAILY_REPORT_ENABLED); MON_DAILY_REPORT_ENABLED=${MON_DAILY_REPORT_ENABLED:-no}
    MON_DAILY_REPORT_TIME=$(monitor_time_normalize "$(monitor_alert_cfg_get DAILY_REPORT_TIME)" 2>/dev/null || true); MON_DAILY_REPORT_TIME=${MON_DAILY_REPORT_TIME:-08:00}
}

monitor_alert_save_cfg() {
    local CFG; CFG=$(monitor_alert_cfg)
    mkdir -p "$(dirname "$CFG")" 2>/dev/null || true
    cat > "$CFG" <<EOF
ENABLED=${MON_ENABLED:-no}
DISK_WARN=${MON_DISK_WARN:-85}
MEM_WARN=${MON_MEM_WARN:-85}
LOAD_WARN=${MON_LOAD_WARN:-}
BOT_TOKEN=${MON_BOT_TOKEN:-}
CHAT_ID=${MON_CHAT_ID:-}
HOST_LABEL=${MON_HOST_LABEL:-}
TRAFFIC_ENABLED=${MON_TRAFFIC_ENABLED:-no}
TRAFFIC_LIMIT_GB=${MON_TRAFFIC_LIMIT_GB:-50}
TRAFFIC_BASELINE_DATE=${MON_TRAFFIC_BASELINE_DATE:-}
TRAFFIC_BASELINE_BYTES=${MON_TRAFFIC_BASELINE_BYTES:-0}
TRAFFIC_BASELINE_RX_BYTES=${MON_TRAFFIC_BASELINE_RX_BYTES:-}
TRAFFIC_BASELINE_TX_BYTES=${MON_TRAFFIC_BASELINE_TX_BYTES:-}
TRAFFIC_RESET_DAY=${MON_TRAFFIC_RESET_DAY:-1}
TRAFFIC_CYCLE_BASELINE_DATE=${MON_TRAFFIC_CYCLE_BASELINE_DATE:-}
TRAFFIC_CYCLE_BASELINE_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}
TRAFFIC_CYCLE_BASELINE_RX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:-}
TRAFFIC_CYCLE_BASELINE_TX_BYTES=${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:-}
RENEW_ENABLED=${MON_RENEW_ENABLED:-no}
RENEW_MODE=${MON_RENEW_MODE:-interval}
RENEW_NEXT_DATE=${MON_RENEW_NEXT_DATE:-}
RENEW_INTERVAL_DAYS=${MON_RENEW_INTERVAL_DAYS:-365}
RENEW_MONTH_DAY=${MON_RENEW_MONTH_DAY:-1}
RENEW_NOTICE_DAYS=${MON_RENEW_NOTICE_DAYS:-30,7,3,1}
RENEW_LAST_ALERT=${MON_RENEW_LAST_ALERT:-}
DAILY_REPORT_ENABLED=${MON_DAILY_REPORT_ENABLED:-no}
DAILY_REPORT_TIME=${MON_DAILY_REPORT_TIME:-08:00}
EOF
    chmod 600 "$CFG" 2>/dev/null || true
}

monitor_time_normalize() {
    local IN="${1:-}" HH MM
    IN=${IN//[[:space:]]/}
    case "$IN" in
        [0-9][0-9]:[0-9][0-9])
            HH=${IN%:*}
            MM=${IN#*:}
            ;;
        [0-9][0-9][0-9][0-9])
            HH=${IN:0:2}
            MM=${IN:2:2}
            ;;
        *)
            return 1
            ;;
    esac
    echo "$HH" | grep -qE '^[0-9]+$' || return 1
    echo "$MM" | grep -qE '^[0-9]+$' || return 1
    [ "$HH" -lt 24 ] || return 1
    [ "$MM" -lt 60 ] || return 1
    printf '%02d:%02d\n' "$((10#$HH))" "$((10#$MM))"
}

monitor_date_normalize() {
    local IN="${1:-}" Y M D
    IN=${IN//[[:space:]]/}
    case "$IN" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            Y=${IN%%-*}
            M=${IN#*-}; M=${M%-*}
            D=${IN##*-}
            ;;
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            Y=${IN:0:4}
            M=${IN:4:2}
            D=${IN:6:2}
            ;;
        *)
            return 1
            ;;
    esac
    python3 - "$Y" "$M" "$D" <<'PY'
from datetime import date
import sys
y, m, d = map(int, sys.argv[1:])
print(date(y, m, d).isoformat())
PY
}

monitor_alert_host_label() {
    if [ -n "${MON_HOST_LABEL:-}" ]; then
        echo "$MON_HOST_LABEL"
    else
        hostname 2>/dev/null || echo unknown
    fi
}

monitor_int_normalize() {
    local VALUE="${1:-0}"
    awk -v value="$VALUE" 'BEGIN {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value ~ /^[-+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/) {
            printf "%.0f\n", value
        } else {
            print 0
        }
    }'
}

monitor_traffic_totals() {
    if [ -r /proc/net/dev ]; then
        awk 'NR>2 {gsub(":", "", $1); if ($1 != "lo") {rx += $2; tx += $10}} END {printf "%.0f %.0f %.0f\n", rx+0, tx+0, rx+tx}' /proc/net/dev 2>/dev/null
        return
    fi
    if command -v ip >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        ip -j -s link show 2>/dev/null | python3 -c '
import sys, json
data = json.load(sys.stdin)
rx_total = 0
tx_total = 0
for item in data:
    if item.get("ifname") == "lo":
        continue
    stats = item.get("stats64") or item.get("stats") or {}
    rx = stats.get("rx", {}).get("bytes", 0)
    tx = stats.get("tx", {}).get("bytes", 0)
    rx_total += int(rx)
    tx_total += int(tx)
print(f"{rx_total:d} {tx_total:d} {rx_total + tx_total:d}")
' 2>/dev/null && return
    fi
    echo "0 0 0"
}

monitor_traffic_total_bytes() {
    monitor_traffic_totals | awk '{printf "%.0f\n", $3}'
}

monitor_traffic_ensure_baseline() {
    local TODAY RX TX CURRENT
    TODAY=$(date +%F)
    read -r RX TX CURRENT <<EOF
$(monitor_traffic_totals)
EOF
    if [ -z "${MON_TRAFFIC_BASELINE_DATE:-}" ] || [ "$MON_TRAFFIC_BASELINE_DATE" != "$TODAY" ] || ! echo "${MON_TRAFFIC_BASELINE_BYTES:-0}" | grep -qE '^[0-9]+$'; then
        MON_TRAFFIC_BASELINE_DATE="$TODAY"
        MON_TRAFFIC_BASELINE_BYTES="$CURRENT"
        MON_TRAFFIC_BASELINE_RX_BYTES="$RX"
        MON_TRAFFIC_BASELINE_TX_BYTES="$TX"
        monitor_alert_save_cfg
    fi
}

monitor_traffic_current_cycle_start() {
    local RESET_DAY="$1" TODAY
    TODAY="${2:-$(date +%F)}"
    python3 - "$RESET_DAY" "$TODAY" <<'PY'
from calendar import monthrange
from datetime import date
import sys
reset_day = int(sys.argv[1] or 1)
today = date.fromisoformat(sys.argv[2])
reset_day = max(1, min(31, reset_day))
def anchor(y, m):
    last = monthrange(y, m)[1]
    return date(y, m, min(reset_day, last))
this_month = anchor(today.year, today.month)
if today >= this_month:
    print(this_month.isoformat())
else:
    y = today.year - 1 if today.month == 1 else today.year
    m = 12 if today.month == 1 else today.month - 1
    print(anchor(y, m).isoformat())
PY
}

monitor_traffic_cycle_ensure_baseline() {
    [ "${MON_TRAFFIC_ENABLED:-no}" = "yes" ] || return 0
    local TODAY RX TX CURRENT CYCLE_START
    TODAY=$(date +%F)
    read -r RX TX CURRENT <<EOF
$(monitor_traffic_totals)
EOF
    CYCLE_START=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$TODAY")
    if [ -z "${MON_TRAFFIC_CYCLE_BASELINE_DATE:-}" ] || [ "$MON_TRAFFIC_CYCLE_BASELINE_DATE" != "$CYCLE_START" ] || ! echo "${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}" | grep -qE '^[0-9]+$'; then
        MON_TRAFFIC_CYCLE_BASELINE_DATE="$CYCLE_START"
        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CURRENT"
        MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$RX"
        MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$TX"
        monitor_alert_save_cfg
    fi
}

monitor_traffic_used_bytes() {
    local CURRENT BASE USED
    CURRENT=$(monitor_int_normalize "$(monitor_traffic_total_bytes)")
    BASE=$(monitor_int_normalize "${MON_TRAFFIC_BASELINE_BYTES:-0}")
    USED=$((CURRENT - BASE))
    [ "$USED" -lt 0 ] && USED=0
    echo "$USED"
}

monitor_traffic_used_gb() {
    awk "BEGIN {printf \"%.2f\", ($1/1024/1024/1024)}"
}

monitor_traffic_usage_triplet() {
    local KIND="${1:-daily}" RX TX TOTAL BASE_RX BASE_TX BASE_TOTAL USED_RX USED_TX USED_TOTAL HAS_SPLIT=no
    read -r RX TX TOTAL <<EOF
$(monitor_traffic_totals)
EOF
    RX=$(monitor_int_normalize "$RX")
    TX=$(monitor_int_normalize "$TX")
    TOTAL=$(monitor_int_normalize "$TOTAL")
    if [ "$KIND" = "cycle" ]; then
        BASE_RX=${MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES:-}
        BASE_TX=${MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES:-}
        BASE_TOTAL=${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}
    else
        BASE_RX=${MON_TRAFFIC_BASELINE_RX_BYTES:-}
        BASE_TX=${MON_TRAFFIC_BASELINE_TX_BYTES:-}
        BASE_TOTAL=${MON_TRAFFIC_BASELINE_BYTES:-0}
    fi
    [ -n "${BASE_RX:-}" ] && [ -n "${BASE_TX:-}" ] && HAS_SPLIT=yes
    BASE_RX=$(monitor_int_normalize "${BASE_RX:-0}")
    BASE_TX=$(monitor_int_normalize "${BASE_TX:-0}")
    BASE_TOTAL=$(monitor_int_normalize "${BASE_TOTAL:-0}")
    if [ "$HAS_SPLIT" = "yes" ]; then
        USED_RX=$((RX - BASE_RX))
        USED_TX=$((TX - BASE_TX))
        [ "$USED_RX" -lt 0 ] && USED_RX=0
        [ "$USED_TX" -lt 0 ] && USED_TX=0
        USED_TOTAL=$((USED_RX + USED_TX))
    else
        USED_TOTAL=$((TOTAL - BASE_TOTAL))
        [ "$USED_TOTAL" -lt 0 ] && USED_TOTAL=0
        USED_RX=0
        USED_TX=0
    fi
    printf '%s %s %s\n' "$USED_RX" "$USED_TX" "$USED_TOTAL"
}

monitor_traffic_usage_text() {
    local KIND="${1:-daily}" RX TX TOTAL RX_GB TX_GB TOTAL_GB
    read -r RX TX TOTAL <<EOF
$(monitor_traffic_usage_triplet "$KIND")
EOF
    RX_GB=$(monitor_traffic_used_gb "$RX")
    TX_GB=$(monitor_traffic_used_gb "$TX")
    TOTAL_GB=$(monitor_traffic_used_gb "$TOTAL")
    printf '↓%sG ↑%sG ↓↑%sG' "$RX_GB" "$TX_GB" "$TOTAL_GB"
}

monitor_traffic_current_cycle_used_bytes() {
    local CURRENT BASE USED
    CURRENT=$(monitor_int_normalize "$(monitor_traffic_total_bytes)")
    BASE=$(monitor_int_normalize "${MON_TRAFFIC_CYCLE_BASELINE_BYTES:-0}")
    USED=$((CURRENT - BASE))
    [ "$USED" -lt 0 ] && USED=0
    echo "$USED"
}

monitor_traffic_current_cycle_used_gb() {
    monitor_traffic_used_gb "$1"
}

monitor_traffic_set_cycle_usage_split_gb() {
    local USED_RX_GB="$1" USED_TX_GB="$2" RX TX CURRENT BASE BASE_RX BASE_TX CYCLE_START USED_RX_BYTES USED_TX_BYTES
    echo "$USED_RX_GB" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
    echo "$USED_TX_GB" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 1
    read -r RX TX CURRENT <<EOF
$(monitor_traffic_totals)
EOF
    RX=$(monitor_int_normalize "$RX")
    TX=$(monitor_int_normalize "$TX")
    USED_RX_BYTES=$(awk "BEGIN {printf \"%.0f\", ($USED_RX_GB*1024*1024*1024)}")
    USED_TX_BYTES=$(awk "BEGIN {printf \"%.0f\", ($USED_TX_GB*1024*1024*1024)}")
    BASE_RX=$((RX - USED_RX_BYTES))
    BASE_TX=$((TX - USED_TX_BYTES))
    [ "$BASE_RX" -lt 0 ] && BASE_RX=0
    [ "$BASE_TX" -lt 0 ] && BASE_TX=0
    BASE=$((BASE_RX + BASE_TX))
    CYCLE_START=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$(date +%F)")
    MON_TRAFFIC_CYCLE_BASELINE_DATE="$CYCLE_START"
    MON_TRAFFIC_CYCLE_BASELINE_BYTES="$BASE"
    MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$BASE_RX"
    MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$BASE_TX"
    monitor_alert_save_cfg
}

monitor_traffic_set_cycle_usage_gb() {
    monitor_traffic_set_cycle_usage_split_gb 0 "$1"
}

monitor_daily_report_due() {
    local TIME="${1:-08:00}" NOW
    NOW=$(date +%H:%M)
    [ "$NOW" \> "$TIME" ] || [ "$NOW" = "$TIME" ]
}

monitor_alert_daily_report() {
    local HOST TODAY DAILY_TEXT CYCLE_TEXT CYCLE_START RENEW_LEFT NEXT
    HOST=$(monitor_alert_host_label)
    TODAY=$(date +%F)
    monitor_traffic_ensure_baseline
    monitor_traffic_cycle_ensure_baseline
    DAILY_TEXT=$(monitor_traffic_usage_text daily)
    CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
    CYCLE_START="${MON_TRAFFIC_CYCLE_BASELINE_DATE:-$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$TODAY")}"
    NEXT="${MON_RENEW_NEXT_DATE:-未设置}"
    if [ -n "${MON_RENEW_NEXT_DATE:-}" ]; then
        RENEW_LEFT=$(monitor_renew_days_left "$MON_RENEW_NEXT_DATE" 2>/dev/null || echo 0)
    else
        RENEW_LEFT="未设置"
    fi
    monitor_alert_notify "📊 <b>VPS 每日日报</b>" "$(cat <<EOF
主机：<code>${HOST}</code>
日期：<code>${TODAY}</code>
今日流量：${DAILY_TEXT}
当前周期：${CYCLE_TEXT}
周期起点：<code>${CYCLE_START}</code>
续费日期：<code>${NEXT}</code>
剩余天数：<code>${RENEW_LEFT}</code>
EOF
)"
}

monitor_alert_daily_report_check() {
    [ "${MON_DAILY_REPORT_ENABLED:-no}" = "yes" ] || return 0
    local TODAY CUR_TS LAST_DATE LAST_TS SIG
    TODAY=$(date +%F)
    monitor_daily_report_due "${MON_DAILY_REPORT_TIME:-08:00}" || return 0
    CUR_TS=$(date +%s)
    LAST_DATE=$(monitor_alert_state_get DAILY_REPORT_DATE 2>/dev/null || true)
    LAST_TS=$(monitor_alert_state_get DAILY_REPORT_TS 2>/dev/null || echo 0)
    SIG=$(printf 'daily|%s|%s' "$(monitor_alert_host_label)" "$TODAY" | sha256sum 2>/dev/null | awk '{print $1}')
    if [ "$LAST_DATE" = "$TODAY" ] && [ $((CUR_TS - LAST_TS)) -lt 43200 ]; then
        return 0
    fi
    monitor_alert_daily_report
    monitor_alert_state_set DAILY_REPORT_DATE "$TODAY"
    monitor_alert_state_set DAILY_REPORT_TS "$CUR_TS"
    monitor_alert_state_set DAILY_REPORT_SIG "$SIG"
    audit_action "发送每日日报：$TODAY" SUCCESS
}

monitor_alert_home_menu() {
    while true; do
        monitor_alert_load_cfg
        print_header "监控告警中心"
        monitor_traffic_ensure_baseline
        monitor_traffic_cycle_ensure_baseline
        local DAILY_TEXT CYCLE_TEXT HOST
        HOST=$(monitor_alert_host_label)
        DAILY_TEXT=$(monitor_traffic_usage_text daily)
        CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
        echo -e "  主机：${BOLD}${HOST}${NC}"
        echo -e "  状态：${BOLD}$([ "$MON_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
        echo -e "  今日流量：${DAILY_TEXT}"
        echo -e "  当前周期：${CYCLE_TEXT}"
        echo -e "  续费提醒：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo "${MON_RENEW_MODE} · ${MON_RENEW_NEXT_DATE:-未设置}" || echo '未启用')${NC}"
        echo -e "  每日日报：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo "${MON_DAILY_REPORT_TIME}" || echo '未启用')${NC}"
        echo ""
        menu_div
        menu_item "1" "配置 Bot / Chat" "$GREEN"
        menu_item "2" "告警配置中心" "$GREEN"
        menu_item "3" "查看今日流量" "$CYAN"
        menu_item "4" "发送每日日报" "$YELLOW"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
        case "$CH" in
            1)
                read -rp "$(ui_prompt 'Bot Token: ')" BOT_TOKEN
                read -rp "$(ui_prompt 'Chat ID: ')" CHAT_ID
                [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || { warn "已取消"; continue; }
                MON_BOT_TOKEN="$BOT_TOKEN"
                MON_CHAT_ID="$CHAT_ID"
                monitor_alert_save_cfg
                info "Telegram 已配置"
                ;;
            2) monitor_alert_config_menu ;;
            3)
                info "今日流量：$(monitor_traffic_usage_text daily)"
                info "当前周期：$(monitor_traffic_usage_text cycle)"
                ui_pause
                ;;
            4)
                monitor_alert_daily_report
                info "日报已发送（如已配置 Telegram）"
                ui_pause
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

monitor_renew_next_date() {
    local MODE="$1" BASE="$2" DAYS="$3" MONTH_DAY="$4"
    python3 - "$MODE" "$BASE" "$DAYS" "$MONTH_DAY" <<'PY'
from calendar import monthrange
from datetime import date, datetime, timedelta
import sys
mode, base, days, month_day = sys.argv[1:]
base_date = datetime.strptime(base, "%Y-%m-%d").date()
if mode == "interval":
    print((base_date + timedelta(days=int(days))).isoformat())
elif mode == "monthly":
    target_day = max(1, min(31, int(month_day or 1)))
    y, m = base_date.year, base_date.month
    for _ in range(24):
        last = monthrange(y, m)[1]
        cand = date(y, m, min(target_day, last))
        if cand > base_date:
            print(cand.isoformat())
            break
        m += 1
        if m > 12:
            y += 1
            m = 1
else:
    print(base)
PY
}

monitor_renew_days_left() {
    local NEXT="$1"
    python3 - "$NEXT" <<'PY'
from datetime import date, datetime
import sys
next_date = datetime.strptime(sys.argv[1], "%Y-%m-%d").date()
print((next_date - date.today()).days)
PY
}

monitor_renew_notice_match() {
    local DAYS_LEFT="$1" LIST="${2:-30,7,3,1}" I
    [ "$DAYS_LEFT" -le 0 ] && return 0
    IFS=',' read -r -a MON_LIST <<< "$LIST"
    for I in "${MON_LIST[@]}"; do
        [ -n "$I" ] || continue
        [ "$DAYS_LEFT" -eq "$I" ] && return 0
    done
    return 1
}

monitor_alert_notify() {
    local TITLE="$1" BODY="$2" BOT CHAT
    BOT=$(monitor_alert_cfg_get BOT_TOKEN)
    CHAT=$(monitor_alert_cfg_get CHAT_ID)
    [ -n "$BOT" ] && [ -n "$CHAT" ] || return 0
    local TEXT
    TEXT=$(printf '%s\n%b' "$TITLE" "$BODY")
    curl -s --max-time 15 "https://api.telegram.org/bot${BOT}/sendMessage" \
        --data-urlencode "chat_id=${CHAT}" \
        --data-urlencode "text=${TEXT}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

monitor_alert_service_state() {
    local SVC="$1"
    if command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; then
        systemctl is-active --quiet "$SVC" 2>/dev/null && echo running || echo stopped
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$SVC" status >/dev/null 2>&1 && echo running || echo stopped
    else
        echo unknown
    fi
}

monitor_alert_resource_check() {
    local HOST DISK_PCT MEM_PCT LOAD1 CPU_COUNT ISSUES=""
    HOST=$(monitor_alert_host_label)
    DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')
    MEM_PCT=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null)
    LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    local LOAD_WARN_VALUE="${MON_LOAD_WARN:-}"
    [ -n "$LOAD_WARN_VALUE" ] || LOAD_WARN_VALUE=$(awk "BEGIN{printf \"%.1f\", $CPU_COUNT*1.5}")

    if [ "${DISK_PCT:-0}" -ge "${MON_DISK_WARN:-85}" ]; then ISSUES="${ISSUES}磁盘 ${DISK_PCT}%  "; fi
    if [ "${MEM_PCT:-0}" -ge "${MON_MEM_WARN:-85}" ]; then ISSUES="${ISSUES}内存 ${MEM_PCT}%  "; fi
    if awk "BEGIN{exit !($LOAD1 >= $LOAD_WARN_VALUE)}"; then ISSUES="${ISSUES}负载 ${LOAD1}  "; fi
    if [ "$(monitor_alert_service_state ssh)" != running ]; then ISSUES="${ISSUES}SSH 服务异常  "; fi
    if command -v fail2ban-client >/dev/null 2>&1 && [ "$(f2b_status 2>/dev/null || echo stopped)" != running ]; then ISSUES="${ISSUES}Fail2ban 异常  "; fi
    if command -v docker >/dev/null 2>&1 && [ "$(docker_status 2>/dev/null || echo not_installed)" = stopped ]; then ISSUES="${ISSUES}Docker 服务异常  "; fi
    if command -v caddy >/dev/null 2>&1 && [ "$(caddy_status 2>/dev/null || echo not_installed)" = stopped ]; then ISSUES="${ISSUES}Caddy 服务异常  "; fi
    [ -n "${ISSUES// }" ] || return 0
    local SIG CUR_TS LAST_SIG LAST_TS
    CUR_TS=$(date +%s)
    SIG=$(printf '%s|%s|%s' "$HOST" "$ISSUES" "$DISK_PCT" | sha256sum 2>/dev/null | awk '{print $1}')
    LAST_SIG=$(monitor_alert_state_get SIG 2>/dev/null || true)
    LAST_TS=$(monitor_alert_state_get TS 2>/dev/null || echo 0)
    if [ "$SIG" = "$LAST_SIG" ] && [ $((CUR_TS - LAST_TS)) -lt 1800 ]; then
        return 0
    fi
    local MSG
    MSG="监控告警\n主机：${HOST}\n时间：$(date '+%Y-%m-%d %H:%M:%S')\n磁盘：${DISK_PCT}%\n内存：${MEM_PCT}%\n负载：${LOAD1}\n异常：${ISSUES}"
    monitor_alert_notify "⚠️ <b>VPS 监控告警</b>" "$MSG"
    monitor_alert_state_set SIG "$SIG"
    monitor_alert_state_set TS "$CUR_TS"
    audit_action "发送系统监控告警：$ISSUES" SUCCESS
}

monitor_alert_test_snapshot() {
    local HOST DISK_PCT MEM_PCT LOAD1 CPU_COUNT LOAD_WARN_VALUE DAILY_TEXT SSH_STATE F2B_STATE DOCKER_STATE CADDY_STATE
    HOST=$(monitor_alert_host_label)
    monitor_traffic_ensure_baseline
    DAILY_TEXT=$(monitor_traffic_usage_text daily)
    DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')
    MEM_PCT=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null)
    LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    LOAD_WARN_VALUE="${MON_LOAD_WARN:-}"
    [ -n "$LOAD_WARN_VALUE" ] || LOAD_WARN_VALUE=$(awk "BEGIN{printf \"%.1f\", $CPU_COUNT*1.5}")
    SSH_STATE=$(monitor_alert_service_state ssh)
    F2B_STATE="未安装"
    command -v fail2ban-client >/dev/null 2>&1 && F2B_STATE=$(f2b_status 2>/dev/null || echo unknown)
    DOCKER_STATE="未安装"
    command -v docker >/dev/null 2>&1 && DOCKER_STATE=$(docker_status 2>/dev/null || echo unknown)
    CADDY_STATE="未安装"
    command -v caddy >/dev/null 2>&1 && CADDY_STATE=$(caddy_status 2>/dev/null || echo unknown)
    monitor_alert_notify "✅ <b>VPS 监控测试</b>" "$(cat <<EOF
主机：<code>${HOST}</code>
时间：<code>$(date '+%Y-%m-%d %H:%M:%S')</code>
磁盘：<code>${DISK_PCT}% / ${MON_DISK_WARN}%</code>
内存：<code>${MEM_PCT}% / ${MON_MEM_WARN}%</code>
负载：<code>${LOAD1} / ${LOAD_WARN_VALUE}</code>
今日流量：${DAILY_TEXT}
SSH：<code>${SSH_STATE}</code>
Fail2ban：<code>${F2B_STATE}</code>
Docker：<code>${DOCKER_STATE}</code>
Caddy：<code>${CADDY_STATE}</code>
EOF
)"
}

monitor_alert_traffic_check() {
    [ "${MON_TRAFFIC_ENABLED:-no}" = "yes" ] || return 0
    monitor_traffic_ensure_baseline
    local USED_RX USED_TX USED_BYTES USED_GB LIMIT_GB DAILY_TEXT
    read -r USED_RX USED_TX USED_BYTES <<EOF
$(monitor_traffic_usage_triplet daily)
EOF
    USED_GB=$(monitor_traffic_used_gb "$USED_BYTES")
    DAILY_TEXT=$(monitor_traffic_usage_text daily)
    LIMIT_GB="${MON_TRAFFIC_LIMIT_GB:-50}"
    if awk "BEGIN{exit !($USED_GB >= $LIMIT_GB)}"; then
        local SIG CUR_TS
        CUR_TS=$(date +%s)
        SIG=$(printf 'traffic|%s|%s|%s' "$(hostname 2>/dev/null || echo unknown)" "$USED_GB" "$LIMIT_GB" | sha256sum 2>/dev/null | awk '{print $1}')
        if [ "$(monitor_alert_state_get TRAFFIC_SIG 2>/dev/null || true)" = "$SIG" ] && [ $((CUR_TS - $(monitor_alert_state_get TRAFFIC_TS 2>/dev/null || echo 0))) -lt 1800 ]; then
            return 0
        fi
        monitor_alert_notify "⚠️ <b>流量超限告警</b>" "今日流量：${DAILY_TEXT}\n阈值：<code>${LIMIT_GB} GB</code>\n主机：<code>$(monitor_alert_host_label)</code>"
        monitor_alert_state_set TRAFFIC_SIG "$SIG"
        monitor_alert_state_set TRAFFIC_TS "$CUR_TS"
        audit_action "发送流量超限告警：${USED_GB}GB / ${LIMIT_GB}GB" SUCCESS
    fi
}

monitor_alert_renew_check() {
    [ "${MON_RENEW_ENABLED:-no}" = "yes" ] || return 0
    local NEXT="${MON_RENEW_NEXT_DATE:-}" TODAY DAYS_LEFT
    TODAY=$(date +%F)
    if [ -z "$NEXT" ]; then
        NEXT="$TODAY"
    fi
    DAYS_LEFT=$(monitor_renew_days_left "$NEXT" 2>/dev/null || echo 0)
    if ! monitor_renew_notice_match "$DAYS_LEFT" "${MON_RENEW_NOTICE_DAYS:-30,7,3,1}"; then
        return 0
    fi
    local SIG CUR_TS LAST_SIG LAST_TS
    CUR_TS=$(date +%s)
    SIG=$(printf 'renew|%s|%s|%s' "$(monitor_alert_host_label)" "$NEXT" "$DAYS_LEFT" | sha256sum 2>/dev/null | awk '{print $1}')
    LAST_SIG=$(monitor_alert_state_get RENEW_SIG 2>/dev/null || true)
    LAST_TS=$(monitor_alert_state_get RENEW_TS 2>/dev/null || echo 0)
    if [ "$SIG" = "$LAST_SIG" ] && [ $((CUR_TS - LAST_TS)) -lt 86400 ]; then
        return 0
    fi
    monitor_alert_notify "⏰ <b>续费提醒</b>" "下次续费日期：<code>${NEXT}</code>\n剩余天数：<code>${DAYS_LEFT}</code>\n主机：<code>$(monitor_alert_host_label)</code>"
    monitor_alert_state_set RENEW_SIG "$SIG"
    monitor_alert_state_set RENEW_TS "$CUR_TS"
    MON_RENEW_LAST_ALERT="$TODAY"
    monitor_alert_save_cfg
    if [ "$DAYS_LEFT" -le 0 ]; then
        case "$MON_RENEW_MODE" in
            interval)
                MON_RENEW_NEXT_DATE=$(monitor_renew_next_date interval "$NEXT" "${MON_RENEW_INTERVAL_DAYS:-365}" "${MON_RENEW_MONTH_DAY:-1}")
                ;;
            monthly)
                MON_RENEW_NEXT_DATE=$(monitor_renew_next_date monthly "$NEXT" "${MON_RENEW_INTERVAL_DAYS:-365}" "${MON_RENEW_MONTH_DAY:-1}")
                ;;
            manual)
                : ;;
            *)
                : ;;
        esac
        monitor_alert_save_cfg
    fi
    audit_action "发送续费提醒：$NEXT，剩余 $DAYS_LEFT 天" SUCCESS
}

monitor_alert_check() {
    local CFG; CFG=$(monitor_alert_cfg)
    [ -f "$CFG" ] || return 0
    # shellcheck source=/dev/null
    . "$CFG"
    [ "${ENABLED:-no}" = "yes" ] || return 0
    monitor_alert_load_cfg
    monitor_alert_resource_check
    monitor_alert_traffic_check
    monitor_alert_renew_check
    monitor_alert_daily_report_check
}

monitor_alert_config_menu() {
    local CFG; CFG=$(monitor_alert_cfg)
    mkdir -p "$(dirname "$CFG")" 2>/dev/null || true
    monitor_alert_load_cfg
    print_header "监控告警配置"
    echo -e "  状态：${BOLD}$([ "$MON_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
    echo -e "  磁盘阈值：${BOLD}${MON_DISK_WARN}%${NC}"
    echo -e "  内存阈值：${BOLD}${MON_MEM_WARN}%${NC}"
    echo -e "  负载阈值：${BOLD}${MON_LOAD_WARN:-自动}${NC}"
    monitor_traffic_ensure_baseline
    monitor_traffic_cycle_ensure_baseline
    local TODAY_TEXT CYCLE_TEXT
    TODAY_TEXT=$(monitor_traffic_usage_text daily)
    CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
    echo -e "  流量监控：${BOLD}$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo "${MON_TRAFFIC_LIMIT_GB} GB/日" || echo '未启用')${NC}"
    echo -e "  今日流量：${TODAY_TEXT}"
    echo -e "  当前周期：${CYCLE_TEXT}"
    echo -e "  重置日：${BOLD}${MON_TRAFFIC_RESET_DAY}${NC}   周期起点：${BOLD}${MON_TRAFFIC_CYCLE_BASELINE_DATE:-未设置}${NC}"
    echo -e "  续费提醒：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo "${MON_RENEW_MODE} · ${MON_RENEW_NEXT_DATE:-未设置}" || echo '未启用')${NC}"
    echo -e "  每日日报：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo "${MON_DAILY_REPORT_TIME}" || echo '未启用')${NC}"
    echo -e "  主机显示：${BOLD}${MON_HOST_LABEL:-自动使用 hostname}${NC}"
    echo -e "  通知：${BOLD}$([ -n "$MON_BOT_TOKEN" ] && echo '已配置' || echo '未配置')${NC}"
    echo ""
    menu_div
    menu_item "1" "设置资源告警阈值" "$YELLOW"
    menu_item "2" "流量监控与周期" "$CYAN"
    menu_item "3" "每日日报设置" "$GREEN"
    menu_item "4" "续费提醒设置" "$GREEN"
    menu_item "5" "主机显示名称" "$YELLOW"
    menu_item "6" "发送测试告警" "$CYAN"
    menu_item "7" "启用定时告警" "$GREEN"
    menu_item "8" "关闭定时告警" "$RED"
    menu_item "0" "返回上级" "$RED"
    menu_div; echo ""
    read -rp "$(ui_prompt '选择操作 [0-8]: ')" CH
    case "$CH" in
        1)
            read -rp "$(ui_prompt "磁盘阈值 [${MON_DISK_WARN}%]: ")" DISK_WARN_IN
            read -rp "$(ui_prompt "内存阈值 [${MON_MEM_WARN}%]: ")" MEM_WARN_IN
            read -rp "$(ui_prompt "负载阈值（空=自动） [${MON_LOAD_WARN:-自动}]: ")" LOAD_WARN_IN
            [ -n "$DISK_WARN_IN" ] && MON_DISK_WARN="$DISK_WARN_IN"
            [ -n "$MEM_WARN_IN" ] && MON_MEM_WARN="$MEM_WARN_IN"
            [ -n "$LOAD_WARN_IN" ] && MON_LOAD_WARN="$LOAD_WARN_IN"
            monitor_alert_save_cfg
            info "阈值已保存"
            ;;
        2)
            while true; do
                print_header "流量监控"
                echo -e "  状态：${BOLD}$([ "$MON_TRAFFIC_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  阈值：${BOLD}${MON_TRAFFIC_LIMIT_GB} GB / 日${NC}"
                monitor_traffic_ensure_baseline
                monitor_traffic_cycle_ensure_baseline
                local TODAY_TEXT CYCLE_TEXT CYCLE_RX_BYTES CYCLE_TX_BYTES CYCLE_RX_GB CYCLE_TX_GB
                TODAY_TEXT=$(monitor_traffic_usage_text daily)
                CYCLE_TEXT=$(monitor_traffic_usage_text cycle)
                read -r CYCLE_RX_BYTES CYCLE_TX_BYTES _ <<EOF
$(monitor_traffic_usage_triplet cycle)
EOF
                CYCLE_RX_GB=$(monitor_traffic_used_gb "$CYCLE_RX_BYTES")
                CYCLE_TX_GB=$(monitor_traffic_used_gb "$CYCLE_TX_BYTES")
                echo -e "  今日累计：${TODAY_TEXT}"
                echo -e "  当前周期：${CYCLE_TEXT}"
                echo -e "  基线日期：${DIM}${MON_TRAFFIC_BASELINE_DATE:-未设置}${NC}"
                echo -e "  重置日：${DIM}${MON_TRAFFIC_RESET_DAY}${NC}   周期起点：${DIM}${MON_TRAFFIC_CYCLE_BASELINE_DATE:-未设置}${NC}"
                menu_div
                menu_item "1" "启用 / 更新阈值" "$GREEN"
                menu_item "2" "关闭流量监控" "$YELLOW"
                menu_item "3" "重置今日基线" "$CYAN"
                menu_item "4" "设置重置日" "$GREEN"
                menu_item "5" "校准周期下行 / 上行流量" "$YELLOW"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-5]: ')" TCH
                case "$TCH" in
                    1)
                        read -rp "$(ui_prompt "流量阈值（GB/日，默认 50） [${MON_TRAFFIC_LIMIT_GB}]: ")" LIMIT_IN
                        [ -n "$LIMIT_IN" ] && MON_TRAFFIC_LIMIT_GB="$LIMIT_IN"
                        local CUR_RX CUR_TX CUR_TOTAL
                        read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                        MON_TRAFFIC_ENABLED=yes
                        MON_TRAFFIC_BASELINE_DATE=$(date +%F)
                        MON_TRAFFIC_BASELINE_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_BASELINE_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_BASELINE_TX_BYTES="$CUR_TX"
                        MON_TRAFFIC_CYCLE_BASELINE_DATE=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$(date +%F)")
                        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$CUR_TX"
                        monitor_alert_save_cfg
                        info "流量监控已启用"
                        ;;
                    2)
                        MON_TRAFFIC_ENABLED=no
                        monitor_alert_save_cfg
                        info "流量监控已关闭"
                        ;;
                    3)
                        local CUR_RX CUR_TX CUR_TOTAL
                        read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                        MON_TRAFFIC_BASELINE_DATE=$(date +%F)
                        MON_TRAFFIC_BASELINE_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_BASELINE_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_BASELINE_TX_BYTES="$CUR_TX"
                        monitor_alert_save_cfg
                        info "今日基线已重置"
                        ;;
                    4)
                        read -rp "$(ui_prompt "每月流量重置日（1-28/31） [${MON_TRAFFIC_RESET_DAY}]: ")" RESET_IN
                        if [ -n "$RESET_IN" ]; then
                            echo "$RESET_IN" | grep -qE '^[0-9]+$' || { warn "输入无效"; continue; }
                            MON_TRAFFIC_RESET_DAY="$RESET_IN"
                        fi
                        local CUR_RX CUR_TX CUR_TOTAL
                        read -r CUR_RX CUR_TX CUR_TOTAL <<EOF
$(monitor_traffic_totals)
EOF
                        MON_TRAFFIC_CYCLE_BASELINE_DATE=$(monitor_traffic_current_cycle_start "${MON_TRAFFIC_RESET_DAY:-1}" "$(date +%F)")
                        MON_TRAFFIC_CYCLE_BASELINE_BYTES="$CUR_TOTAL"
                        MON_TRAFFIC_CYCLE_BASELINE_RX_BYTES="$CUR_RX"
                        MON_TRAFFIC_CYCLE_BASELINE_TX_BYTES="$CUR_TX"
                        monitor_alert_save_cfg
                        info "重置日已保存"
                        ;;
                    5)
                        local CYCLE_RX_IN CYCLE_TX_IN
                        read -rp "$(ui_prompt "当前周期下行已消耗（GB） [${CYCLE_RX_GB}]: ")" CYCLE_RX_IN
                        read -rp "$(ui_prompt "当前周期上行已消耗（GB） [${CYCLE_TX_GB}]: ")" CYCLE_TX_IN
                        CYCLE_RX_IN=${CYCLE_RX_IN:-$CYCLE_RX_GB}
                        CYCLE_TX_IN=${CYCLE_TX_IN:-$CYCLE_TX_GB}
                        monitor_traffic_set_cycle_usage_split_gb "$CYCLE_RX_IN" "$CYCLE_TX_IN" || { warn "输入无效"; continue; }
                        info "当前周期流量已更新"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        3)
            while true; do
                print_header "每日日报"
                echo -e "  状态：${BOLD}$([ "$MON_DAILY_REPORT_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  时间：${BOLD}${MON_DAILY_REPORT_TIME}${NC}"
                echo -e "  今日流量：$(monitor_traffic_usage_text daily)"
                echo -e "  当前周期：$(monitor_traffic_usage_text cycle)"
                menu_div
                menu_item "1" "启用 / 更新日报" "$GREEN"
                menu_item "2" "关闭每日日报" "$YELLOW"
                menu_item "3" "设置日报时间" "$CYAN"
                menu_item "4" "立即发送日报" "$GREEN"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-4]: ')" DCH
                case "$DCH" in
                    1)
                        MON_DAILY_REPORT_ENABLED=yes
                        [ -z "${MON_DAILY_REPORT_TIME:-}" ] && MON_DAILY_REPORT_TIME="08:00"
                        monitor_alert_save_cfg
                        info "每日日报已启用"
                        ;;
                    2)
                        MON_DAILY_REPORT_ENABLED=no
                        monitor_alert_save_cfg
                        info "每日日报已关闭"
                        ;;
                    3)
                        local NORMAL_TIME
                        read -rp "$(ui_prompt "日报时间（支持 23:59 / 2359） [${MON_DAILY_REPORT_TIME}]: ")" TIME_IN
                        if [ -n "$TIME_IN" ]; then
                            NORMAL_TIME=$(monitor_time_normalize "$TIME_IN" 2>/dev/null || true)
                            [ -n "$NORMAL_TIME" ] || { warn "时间格式无效"; continue; }
                            MON_DAILY_REPORT_TIME="$NORMAL_TIME"
                        fi
                        monitor_alert_save_cfg
                        info "日报时间已保存"
                        ;;
                    4)
                        monitor_alert_daily_report
                        info "日报已发送（如已配置 Telegram）"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        4)
            while true; do
                print_header "续费提醒"
                echo -e "  状态：${BOLD}$([ "$MON_RENEW_ENABLED" = yes ] && echo '已启用' || echo '未启用')${NC}"
                echo -e "  模式：${BOLD}${MON_RENEW_MODE}${NC}"
                echo -e "  下次续费：${BOLD}${MON_RENEW_NEXT_DATE:-未设置}${NC}"
                echo -e "  提前提醒：${BOLD}${MON_RENEW_NOTICE_DAYS}${NC}"
                echo -e "  周期：${BOLD}${MON_RENEW_INTERVAL_DAYS} 天${NC}"
                echo -e "  每月固定日：${BOLD}${MON_RENEW_MONTH_DAY}${NC}"
                menu_div
                menu_item "1" "设置固定日期" "$GREEN"
                menu_item "2" "按周期循环（30/90/365）" "$YELLOW"
                menu_item "3" "按每月固定日" "$CYAN"
                menu_item "4" "设置提醒天数" "$GREEN"
                menu_item "5" "关闭续费提醒" "$RED"
                menu_item "0" "返回上级" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-5]: ')" RCH
                case "$RCH" in
                    1)
                        local NORMAL_DATE
                        read -rp "$(ui_prompt '请输入下次续费日期（支持 2026-05-15 / 20260515）: ')" NEXT_IN
                        NORMAL_DATE=$(monitor_date_normalize "$NEXT_IN" 2>/dev/null || true)
                        [ -n "$NORMAL_DATE" ] || { warn "日期格式无效"; continue; }
                        MON_RENEW_ENABLED=yes
                        MON_RENEW_MODE=manual
                        MON_RENEW_NEXT_DATE="$NORMAL_DATE"
                        monitor_alert_save_cfg
                        info "续费日期已设置"
                        ;;
                    2)
                        read -rp "$(ui_prompt '循环天数（如 30/90/365）: ')" DAYS_IN
                        echo "$DAYS_IN" | grep -qE '^[0-9]+$' || { warn "输入无效"; continue; }
                        local NORMAL_BASE_DATE
                        read -rp "$(ui_prompt '下次续费日期（支持 2026-05-15 / 20260515，留空=今天起算）: ')" BASE_IN
                        BASE_IN=${BASE_IN:-$(date +%F)}
                        NORMAL_BASE_DATE=$(monitor_date_normalize "$BASE_IN" 2>/dev/null || true)
                        [ -n "$NORMAL_BASE_DATE" ] || { warn "日期格式无效"; continue; }
                        MON_RENEW_ENABLED=yes
                        MON_RENEW_MODE=interval
                        MON_RENEW_INTERVAL_DAYS="$DAYS_IN"
                        MON_RENEW_NEXT_DATE=$(monitor_renew_next_date interval "$NORMAL_BASE_DATE" "$DAYS_IN" "$MON_RENEW_MONTH_DAY")
                        monitor_alert_save_cfg
                        info "循环续费已设置"
                        ;;
                    3)
                        read -rp "$(ui_prompt '每月固定日（1-28/31）: ')" MDAY
                        echo "$MDAY" | grep -qE '^[0-9]+$' || { warn "输入无效"; continue; }
                        MON_RENEW_ENABLED=yes
                        MON_RENEW_MODE=monthly
                        MON_RENEW_MONTH_DAY="$MDAY"
                        MON_RENEW_NEXT_DATE=$(monitor_renew_next_date monthly "$(date +%F)" "${MON_RENEW_INTERVAL_DAYS:-365}" "$MDAY")
                        monitor_alert_save_cfg
                        info "每月续费提醒已设置"
                        ;;
                    4)
                        read -rp "$(ui_prompt '提醒天数（逗号分隔，如 30,7,3,1）: ')" NOTICE_IN
                        [ -n "$NOTICE_IN" ] && MON_RENEW_NOTICE_DAYS="$NOTICE_IN"
                        monitor_alert_save_cfg
                        info "提醒天数已保存"
                        ;;
                    5)
                        MON_RENEW_ENABLED=no
                        monitor_alert_save_cfg
                        info "续费提醒已关闭"
                        ;;
                    0) break ;;
                    *) warn "无效选项"; sleep 1 ;;
                esac
            done
            ;;
        5)
            read -rp "$(ui_prompt "推送中显示的主机名 [${MON_HOST_LABEL:-自动使用 hostname}]: ")" HOST_LABEL_IN
            MON_HOST_LABEL="$HOST_LABEL_IN"
            monitor_alert_save_cfg
            info "主机显示名称已保存"
            ;;
        6)
            monitor_alert_test_snapshot
            info "测试消息已发送（如已配置 Telegram）"
            ;;
        7)
            MON_ENABLED=yes
            monitor_alert_save_cfg
            (crontab -l 2>/dev/null | grep -v 'vps-monitor-alert'; echo "*/10 * * * * ${SVC_PATH:-${LOCAL_SCRIPT:-$0}} --monitor-alert >> /var/log/vps-monitor.log 2>&1 # vps-monitor-alert") | crontab -
            ddns_ensure_cron >/dev/null 2>&1 || true
            info "已启用定时告警"
            ;;
        8)
            MON_ENABLED=no
            monitor_alert_save_cfg
            (crontab -l 2>/dev/null | grep -v 'vps-monitor-alert') | crontab -
            info "已关闭定时告警"
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

safety_arm() {
    local LABEL="$1" SNAP SCRIPT UFW_STATE="inactive" FIREWALLD_STATE="inactive"
    SNAP=$(config_backup_create "safety_${LABEL}" true) || return 1
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active' && UFW_STATE="active"
    svc_is_active firewalld && FIREWALLD_STATE="active"
    SCRIPT="$VPS_DATA_DIR/rollback_$$_$(date +%s)_${RANDOM}.sh"
    mkdir -p "$VPS_DATA_DIR"
    cat > "$SCRIPT" <<ROLLBACK_EOF
#!/bin/bash
sleep 180
tar -xzf '$SNAP' -C / >/dev/null 2>&1
sshd -t >/dev/null 2>&1 && (systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null)
systemctl restart systemd-resolved >/dev/null 2>&1 || true
systemctl restart NetworkManager >/dev/null 2>&1 || true
if command -v ufw >/dev/null 2>&1; then
    if [ '$UFW_STATE' = active ]; then ufw --force enable >/dev/null 2>&1; else ufw --force disable >/dev/null 2>&1; fi
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    if [ '$FIREWALLD_STATE' = active ]; then systemctl start firewalld >/dev/null 2>&1; else systemctl stop firewalld >/dev/null 2>&1; fi
    firewall-cmd --reload >/dev/null 2>&1 || true
fi
nft -f /etc/nftables.conf >/dev/null 2>&1 || true
logger -t vps-tools '未确认连接，已自动恢复 $LABEL 配置'
rm -f '$SCRIPT'
ROLLBACK_EOF
    chmod 700 "$SCRIPT"
    nohup bash "$SCRIPT" >/dev/null 2>&1 &
    SAFETY_PID=$!
    SAFETY_SCRIPT="$SCRIPT"
    audit_action "启动防断联保护 $LABEL" SUCCESS
    warn "防断联保护已启动：180 秒内未确认将自动恢复。"
}

safety_confirm() {
    [ -n "${SAFETY_PID:-}" ] || return 0
    echo ""
    warn "请保持当前连接，并用新终端确认 SSH 和网络正常。"
    read -rp "  确认连接正常，取消自动回滚？(y/N): " OK
    if echo "$OK" | grep -qiE '^y(es)?$'; then
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
        rm -f "${SAFETY_SCRIPT:-}"
        audit_action "确认连接正常，取消自动回滚" SUCCESS
        info "已取消自动回滚"
        SAFETY_PID="" SAFETY_SCRIPT=""
    else
        warn "自动回滚仍在计时，请勿关闭旧连接。"
    fi
}

security_audit() {
    print_header "系统安全体检"
    local WARNINGS=0 VALUE PORT
    echo -e "  ${BOLD}SSH${NC}"
    VALUE=$(get_config PasswordAuthentication)
    if [ "$VALUE" = no ]; then info "密码登录已关闭"; else warn "密码登录未关闭"; WARNINGS=$((WARNINGS+1)); fi
    VALUE=$(get_config PermitRootLogin)
    if [ "$VALUE" = no ] || [ "$VALUE" = prohibit-password ]; then info "root 密码登录已限制"; else warn "root 密码登录允许"; WARNINGS=$((WARNINGS+1)); fi
    VALUE=$(get_config PermitEmptyPasswords)
    if [ "$VALUE" = yes ]; then warn "允许空密码登录"; WARNINGS=$((WARNINGS+1)); else info "未允许空密码登录"; fi
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then info "sshd 配置语法正常"; else warn "无法通过 sshd 配置检查"; WARNINGS=$((WARNINGS+1)); fi
    echo ""; echo -e "  ${BOLD}网络与服务${NC}"
    PORT=$(get_config Port); PORT=${PORT:-22}
    echo -e "  SSH 端口：${BOLD}$PORT${NC}"
    local FW_CHECK; FW_CHECK=$(fw_detect)
    if [ "$FW_CHECK" != none ] && [ "$(fw_running "$FW_CHECK")" = active ]; then info "防火墙运行中"; else warn "防火墙未运行"; WARNINGS=$((WARNINGS+1)); fi
    if [ "$(f2b_status)" = running ]; then info "Fail2ban 运行中"; else warn "Fail2ban 未运行"; WARNINGS=$((WARNINGS+1)); fi
    command -v ss >/dev/null 2>&1 && { echo -e "  ${DIM}公网监听端口：${NC}"; ss -H -lntup 2>/dev/null | awk '$5 ~ /(^|\]):[0-9]+$/ {print "    " $5 "  " $7}' | sort -u | head -20; }
    echo ""; echo -e "  ${BOLD}账户与更新${NC}"
    local UID0; UID0=$(awk -F: '$3==0 {print $1}' /etc/passwd | paste -sd, -)
    if [ "$UID0" = root ]; then info "未发现额外 UID 0 账户"; else warn "UID 0 账户：$UID0"; WARNINGS=$((WARNINGS+1)); fi
    if command -v apt-get >/dev/null 2>&1; then
        local UPDATES; UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
        if [ "$UPDATES" -eq 0 ]; then info "未发现待更新软件包"; else warn "有 $UPDATES 个软件包可更新"; WARNINGS=$((WARNINGS+1)); fi
    fi
    echo ""; menu_div
    if [ "$WARNINGS" -eq 0 ]; then info "未发现明显风险"; else warn "发现 $WARNINGS 项需要关注"; fi
    audit_action "执行系统安全体检，警告 $WARNINGS 项" SUCCESS
}

login_security_logs() {
    while true; do
        print_header "登录记录与安全日志"
        menu_pair "1" "最近成功登录" "2" "最近失败登录"
        menu_pair "3" "当前在线会话" "4" "SSH 安全日志"
        menu_pair "5" "Fail2ban 封禁状态" "0" "返回上级" "$GREEN" "$RED"
        read -rp "$(ui_prompt '选择记录 [0-5]: ')" CH
        case "$CH" in
            1) last -ai 2>/dev/null | head -30 ;;
            2) if command -v lastb >/dev/null 2>&1; then lastb -ai 2>/dev/null | head -30; else warn "系统没有 lastb 数据"; fi ;;
            3) who -uH 2>/dev/null; echo ""; w 2>/dev/null ;;
            4) if command -v journalctl >/dev/null 2>&1; then journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | tail -80; else grep -Ei 'sshd.*(accepted|failed|invalid)' /var/log/auth.log /var/log/secure 2>/dev/null | tail -80; fi ;;
            5) fail2ban-client status 2>/dev/null || warn "Fail2ban 未运行" ;;
            0) return ;;
            *) warn "无效选项"; continue ;;
        esac
        audit_action "查看登录安全日志选项 $CH" SUCCESS
        ui_pause
    done
}

network_diagnostics() {
    print_header "网络诊断工具箱"
    local TARGET
    read -rp "  目标域名或 IP（默认 1.1.1.1）: " TARGET
    TARGET=${TARGET:-1.1.1.1}
    echo ""; echo -e "  ${BOLD}地址与默认路由${NC}"
    ip -brief address 2>/dev/null || ip addr 2>/dev/null | head -40
    ip route 2>/dev/null | head -10
    ip -6 route 2>/dev/null | head -10
    echo ""; echo -e "  ${BOLD}DNS 解析${NC}"
    if command -v getent >/dev/null 2>&1; then getent ahosts "$TARGET" 2>/dev/null | head -8; else nslookup "$TARGET" 2>/dev/null | head -15; fi
    echo ""; echo -e "  ${BOLD}连通性${NC}"
    ping -c 4 -W 2 "$TARGET" 2>/dev/null || warn "IPv4/默认协议 Ping 失败"
    command -v ping6 >/dev/null 2>&1 && ping6 -c 2 -W 2 "$TARGET" 2>/dev/null || true
    echo ""; echo -e "  ${BOLD}公网出口${NC}"
    command -v curl >/dev/null 2>&1 && { printf '  IPv4: '; curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "不可用"; echo ""; printf '  IPv6: '; curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || echo "不可用"; echo ""; }
    echo ""; echo -e "  ${BOLD}MTU 探测${NC}"
    if ping -c 1 -W 2 -M "do" -s 1472 "$TARGET" >/dev/null 2>&1; then info "路径 MTU 至少为 1500"; else warn "1500 MTU 探测失败，可能需要降低 MTU"; fi
    audit_action "网络诊断 $TARGET" SUCCESS
}

audit_log_view() {
    print_header "脚本操作记录"
    if [ -s "$VPS_AUDIT_LOG" ]; then
        tail -100 "$VPS_AUDIT_LOG" | column -t -s $'\t' 2>/dev/null || tail -100 "$VPS_AUDIT_LOG"
    else
        warn "暂无操作记录"
    fi
}

resource_health_check() {
    print_header "系统资源与健康检查"
    local CPU_COUNT LOAD MEM_TOTAL MEM_AVAIL MEM_USED
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || uptime)
    MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    MEM_TOTAL=${MEM_TOTAL:-0}; MEM_AVAIL=${MEM_AVAIL:-0}; MEM_USED=$((MEM_TOTAL-MEM_AVAIL))

    echo -e "  ${BOLD}概览${NC}"
    echo -e "  运行时间：$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
    echo -e "  CPU：${CPU_COUNT} 核   负载：${LOAD}"
    if [ "$MEM_TOTAL" -gt 0 ]; then
        printf '  内存：%.1f / %.1f MiB（%.0f%%）\n' \
            "$(awk "BEGIN {print $MEM_USED/1024}")" "$(awk "BEGIN {print $MEM_TOTAL/1024}")" \
            "$(awk "BEGIN {print $MEM_USED*100/$MEM_TOTAL}")"
    fi
    echo ""; echo -e "  ${BOLD}磁盘空间${NC}"
    df -hP 2>/dev/null | awk 'NR==1 || $1 ~ /^\/dev\// {print "  " $0}'
    echo ""; echo -e "  ${BOLD}inode 使用${NC}"
    df -iP 2>/dev/null | awk 'NR==1 || $1 ~ /^\/dev\// {print "  " $0}'
    echo ""; echo -e "  ${BOLD}网络连接${NC}"
    if command -v ss >/dev/null 2>&1; then ss -s 2>/dev/null | sed 's/^/  /'; else netstat -s 2>/dev/null | head -12 | sed 's/^/  /'; fi
    echo ""; echo -e "  ${BOLD}资源占用最高的进程${NC}"
    ps aux 2>/dev/null | awk 'NR==1 {print; next} {print}' | sort -rk3 | head -6 | sed 's/^/  /'
    if command -v systemctl >/dev/null 2>&1; then
        echo ""; echo -e "  ${BOLD}失败的 systemd 服务${NC}"
        systemctl --failed --no-pager --plain 2>/dev/null | sed -n '1,15p' | sed 's/^/  /'
    fi
    audit_action "执行系统资源健康检查" SUCCESS
}

system_update_manager() {
    while true; do
        print_header "系统更新管理"
        local PM="unknown" PENDING="未知"
        if command -v apt-get >/dev/null 2>&1; then PM="apt"; PENDING=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
        elif command -v dnf >/dev/null 2>&1; then PM="dnf"; PENDING=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 {n++} END {print n+0}')
        elif command -v yum >/dev/null 2>&1; then PM="yum"; PENDING=$(yum -q check-update 2>/dev/null | awk 'NF>=3 {n++} END {print n+0}')
        elif command -v apk >/dev/null 2>&1; then PM="apk"; PENDING=$(apk version -l '<' 2>/dev/null | wc -l)
        elif command -v opkg >/dev/null 2>&1; then PM="opkg"; PENDING=$(opkg list-upgradable 2>/dev/null | wc -l)
        fi
        echo -e "  包管理器：${BOLD}$PM${NC}   待更新：${BOLD}$PENDING${NC}"
        menu_div
        menu_pair "1" "刷新并检查更新" "2" "安装安全更新"
        menu_pair "3" "安装全部更新" "4" "自动安全更新" "$YELLOW" "$GREEN"
        menu_pair "5" "清理软件包缓存" "0" "返回上级" "$GREEN" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH
        case "$CH" in
            1)
                case "$PM" in
                    apt) apt-get update ;;
                    dnf) dnf check-update || [ "$?" -eq 100 ] ;;
                    yum) yum check-update || [ "$?" -eq 100 ] ;;
                    apk) apk update ;;
                    opkg) opkg update; opkg list-upgradable ;;
                    *) error "不支持当前包管理器" ;;
                esac
                audit_action "刷新系统软件包索引" SUCCESS
                ;;
            2)
                confirm_change_preview "安全更新" "包管理器：$PM" "仅安装安全修复（Alpine 安装仓库可用更新）" || { warn "已取消"; continue; }
                case "$PM" in
                    apt) pkg_install unattended-upgrades && unattended-upgrade -d ;;
                    dnf) dnf upgrade --security -y ;;
                    yum) yum update --security -y ;;
                    apk) apk upgrade ;;
                    opkg) warn "OpenWrt 不区分安全更新，请按包逐项升级"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "安装系统安全更新" SUCCESS
                ;;
            3)
                confirm_change_preview "全部系统更新" "将更新所有已安装软件包" "可能需要重启服务器" || { warn "已取消"; continue; }
                case "$PM" in
                    apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y ;;
                    dnf) dnf upgrade -y ;;
                    yum) yum update -y ;;
                    apk) apk update && apk upgrade ;;
                    opkg) warn "OpenWrt 不建议无差别升级全部基础包，请使用固件升级或逐包维护"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "安装全部系统更新" SUCCESS
                ;;
            4)
                confirm_change_preview "自动安全更新" "启用发行版提供的定时安全更新" "更新行为由系统包管理器维护" || { warn "已取消"; continue; }
                case "$PM" in
                    apt)
                        pkg_install unattended-upgrades
                        mkdir -p /etc/apt/apt.conf.d
                        printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
                        ;;
                    dnf)
                        pkg_install dnf-automatic
                        sed -i 's/^apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null
                        systemctl enable --now dnf-automatic.timer
                        ;;
                    yum) pkg_install yum-cron; svc_enable yum-cron; svc_start yum-cron ;;
                    apk) warn "Alpine 未自动写入定时更新，请使用系统 cron 按维护窗口安排"; continue ;;
                    opkg) warn "OpenWrt 未自动写入更新任务，请按固件维护策略安排"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "启用自动安全更新" SUCCESS
                info "自动安全更新已启用"
                ;;
            5)
                case "$PM" in
                    apt) apt-get autoremove -y && apt-get clean ;;
                    dnf) dnf autoremove -y; dnf clean all ;;
                    yum) yum autoremove -y; yum clean all ;;
                    apk) rm -rf /var/cache/apk/* ;;
                    opkg) rm -rf /tmp/opkg-lists/* ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "清理软件包缓存" SUCCESS
                info "清理完成"
                ;;
            0) return ;;
            *) warn "无效选项"; continue ;;
        esac
        ui_pause
    done
}

system_toolbox_menu() {
    while true; do
        print_header "安全与诊断工具箱"
        menu_pair "1" "系统安全体检" "2" "登录与安全日志"
        menu_pair "3" "网络诊断" "4" "配置备份与恢复"
        menu_pair "5" "脚本操作记录" "6" "系统资源健康"
        menu_pair "7" "系统更新管理" "8" "配置导出 / 导入"
        menu_pair "9" "统一回滚中心" "10" "监控告警中心" "$CYAN" "$CYAN"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        ui_hint "SSH、防火墙、DNS 和 IP 修改均有防断联保护"
        echo ""
        read -rp "$(ui_prompt '选择工具 [0-10]: ')" CH
        case "$CH" in
            1) security_audit ;;
            2) login_security_logs; continue ;;
            3) network_diagnostics ;;
            4) config_backup_menu; continue ;;
            5) audit_log_view ;;
            6) resource_health_check ;;
            7) system_update_manager; continue ;;
            8) config_transfer_menu; continue ;;
            9) rollback_center_menu; continue ;;
            10) monitor_alert_home_menu ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}

#!/usr/bin/env bash
# Globals assigned by the test stubs are consumed inside sourced BBR functions.
# shellcheck disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
export BBR_TUNE_TEST_MODE=1

# shellcheck source=/dev/null
source "$ROOT/src/lib/core.sh"
# shellcheck source=/dev/null
source "$ROOT/src/modules/bbr.sh"

fail() {
    echo "BBR adaptive regression: $*" >&2
    exit 1
}

[[ "$(bbr_bdp_bytes 1000 180)" = 22500000 ]] || fail "BDP byte calculation is wrong"
[[ "$(bbr_single_buffer_max_bytes 22500000 2048)" = 47097152 ]] \
    || fail "continuous 2xBDP buffer calculation is wrong"
[[ "$(bbr_single_buffer_default_bytes 22500000)" = 8388608 ]] \
    || fail "single-stream default was not capped at 8MiB"
[[ "$(bbr_single_buffer_max_bytes 125000 2048)" = 4194304 ]] \
    || fail "single-stream buffer floor is not 4MiB"
[[ "$(bbr_single_buffer_max_bytes 1000000000 512)" = 16777216 ]] \
    || fail "single-socket buffer was not capped at RAM/32"
[[ "$(bbr_single_buffer_max_bytes 1000000000 16384)" = 268435456 ]] \
    || fail "single-socket buffer was not capped at 256MiB"
[[ "$(bbr_single_buffer_reason 22500000 2048 47097152)" = '2×BDP + 2MiB 余量' ]] \
    || fail "buffer derivation reason is wrong"

[[ "$(bbr_sweep_range 481 5.7 2500)" = '456 656 20' ]] \
    || fail "policer scan range is wrong"
[[ "$(bbr_sweep_margin_mbps 30)" = 1 ]] || fail "30M safety margin is wrong"
[[ "$(bbr_sweep_margin_mbps 60)" = 2 ]] || fail "60M safety margin is wrong"
[[ "$(bbr_sweep_margin_mbps 100)" = 5 ]] || fail "100M safety margin is wrong"
[[ "$(bbr_sweep_margin_mbps 300)" = 10 ]] || fail "300M safety margin is wrong"
[[ "$(bbr_sweep_margin_mbps 600)" = 15 ]] || fail "600M safety margin is wrong"
[[ "$(bbr_sweep_margin_mbps 1000)" = 25 ]] || fail "1G safety margin is wrong"
[[ "$(bbr_sweep_margin_mbps 1001)" = 40 ]] || fail "high-bandwidth safety margin is wrong"
[[ "$(bbr_loss_pct 100 300 10)" = 0.0386 ]] || fail "retransmission percentage is wrong"
bbr_loss_is_spike 0.1001 0 0.1 || fail "absolute loss spike was missed"
! bbr_loss_is_spike 0.5 0.2 0.1 || fail "stable path noise was treated as a spike"
bbr_loss_is_spike 1.01 0.2 0.1 || fail "capped relative loss spike was missed"

CONFIG=$(bbr_generate_single_stream_config 47097152 8388608 5 1000 180)
grep -qx 'net.core.rmem_default = 8388608' <<< "$CONFIG" \
    || fail "adaptive receive default is missing"
grep -qx 'net.ipv4.tcp_wmem = 4096 8388608 47097152' <<< "$CONFIG" \
    || fail "adaptive TCP send buffer is missing"
grep -qx 'net.ipv4.tcp_moderate_rcvbuf = 1' <<< "$CONFIG" \
    || fail "receive autotuning is not enabled"
! grep -qE '^(net\.ipv4\.(tcp_mem|tcp_adv_win_scale|tcp_notsent_lowat)|vm\.min_free_kbytes)[[:space:]]*=' <<< "$CONFIG" \
    || fail "adaptive profile imported a retired or role-specific global setting"
MANAGED_KEYS=$(bbr_managed_keys)
CONDITIONAL_KEYS=$(bbr_conditional_keys)
grep -qx net.core.rmem_default <<< "$MANAGED_KEYS" \
    || fail "adaptive defaults are absent from the rollback baseline"
grep -qx net.ipv4.tcp_notsent_lowat <<< "$CONDITIONAL_KEYS" \
    || fail "legacy notsent state cannot be cleaned when switching profiles"

IPERF_OUTPUT='[  5]   0.00-10.00  sec  1.10 GBytes   945 Mbits/sec  123             sender
[  5]   0.00-10.00  sec  1.09 GBytes   936 Mbits/sec                  receiver'
[[ "$(bbr_parse_iperf_output "$IPERF_OUTPUT")" = '945 123 936' ]] \
    || fail "iperf3 sender/receiver output was parsed incorrectly"
! bbr_parse_iperf_output 'iperf3: error - the server is busy' >/dev/null \
    || fail "invalid iperf3 output was accepted"

(
    sleep() { :; }
    bbr_sweep_measure_rate() {
        local RATE="$7"
        BBR_SWEEP_POINT_GOODPUT="$RATE"
        if [ "$RATE" -ge 500 ]; then
            BBR_SWEEP_POINT_LOSS=1.5000
        else
            BBR_SWEEP_POINT_LOSS=0.0010
        fi
        return 0
    }
    BBR_SWEEP_LAST_OK=""
    BBR_SWEEP_BROKE_AT=""
    BBR_SWEEP_BASE_LOSS=""
    BBR_SWEEP_PEER_SLOW=0
    bbr_sweep_scan_range eth0 /sbin/tc peer 5201 -4 10 450 550 25 0.1
    [[ "$BBR_SWEEP_LAST_OK" = 475 && "$BBR_SWEEP_BROKE_AT" = 500 ]] \
        || fail "coarse sweep did not keep the last clean rate and confirmed knee"
)

(
    sleep() { :; }
    MOCK_RATE_500_CALLS=0
    bbr_sweep_measure_rate() {
        local RATE="$7"
        BBR_SWEEP_POINT_GOODPUT="$RATE"
        if [ "$RATE" -eq 500 ]; then
            MOCK_RATE_500_CALLS=$(( MOCK_RATE_500_CALLS + 1 ))
            [ "$MOCK_RATE_500_CALLS" -eq 1 ] \
                && BBR_SWEEP_POINT_LOSS=1.5000 \
                || BBR_SWEEP_POINT_LOSS=0.0010
        else
            BBR_SWEEP_POINT_LOSS=1.5000
        fi
        return 0
    }
    BBR_SWEEP_LAST_OK=""
    BBR_SWEEP_BROKE_AT=""
    BBR_SWEEP_BASE_LOSS=0
    BBR_SWEEP_PEER_SLOW=0
    bbr_sweep_scan_range eth0 /sbin/tc peer 5201 -4 10 500 525 25 0.1
    [[ "$BBR_SWEEP_LAST_OK" = 500 && "$BBR_SWEEP_BROKE_AT" = 525 ]] \
        || fail "a transient first-sample spike was not discarded safely"
)

(
    sleep() { :; }
    MOCK_MEASURE_CALLS=0
    bbr_sweep_measure_rate() {
        MOCK_MEASURE_CALLS=$(( MOCK_MEASURE_CALLS + 1 ))
        [ "$MOCK_MEASURE_CALLS" -eq 1 ] || return 1
        BBR_SWEEP_POINT_GOODPUT="$7"
        BBR_SWEEP_POINT_LOSS=1.5000
        return 0
    }
    BBR_SWEEP_LAST_OK=""
    BBR_SWEEP_BROKE_AT=""
    BBR_SWEEP_BASE_LOSS=0
    BBR_SWEEP_PEER_SLOW=0
    INCOMPLETE_RC=0
    bbr_sweep_scan_range eth0 /sbin/tc peer 5201 -4 10 500 500 1 0.1 \
        || INCOMPLETE_RC=$?
    [[ "$INCOMPLETE_RC" = 1 ]] \
        || fail "incomplete spike confirmation did not abort the sweep"
)

TC_STATE_FILE="$TMP/no-state"
SERVICE_TC="$TMP/no-service"
SERVICE_TC_INIT="$TMP/no-init"
TC_HELPER="$TMP/no-helper"
FAKE_MQ_TC="$TMP/fake-mq-tc"
cat > "$FAKE_MQ_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    printf '%s\n' \
        'qdisc mq 0: root' \
        'qdisc fq_codel 0: parent :1 limit 10240p' \
        'qdisc fq_codel 0: parent :2 limit 10240p'
fi
EOF
chmod +x "$FAKE_MQ_TC"
[[ "$(bbr_tc_mq_leaf_kind eth0 "$FAKE_MQ_TC")" = fq_codel ]] \
    || fail "uniform mq leaf qdisc was not detected"
bbr_sweep_qdisc_save eth0 "$FAKE_MQ_TC" \
    || fail "safe default mq topology was rejected"
[[ "$BBR_SWEEP_QSAVE_KIND" = mq && "$BBR_SWEEP_QSAVE_LEAF_KIND" = fq_codel ]] \
    || fail "mq restore state was not captured"
BBR_SWEEP_QSAVE_IFACE=""

FAKE_CAKE_TC="$TMP/fake-cake-tc"
cat > "$FAKE_CAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    echo 'qdisc cake 8010: root refcnt 2 bandwidth 500Mbit'
fi
EOF
chmod +x "$FAKE_CAKE_TC"
CAKE_RC=0
bbr_sweep_qdisc_save eth0 "$FAKE_CAKE_TC" >/dev/null 2>&1 || CAKE_RC=$?
[[ "$CAKE_RC" = 2 ]] || fail "foreign CAKE qdisc was not refused"

FAKE_CUSTOM_FQ_TC="$TMP/fake-custom-fq-tc"
cat > "$FAKE_CUSTOM_FQ_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    echo 'qdisc fq 8001: root refcnt 2 limit 10000p'
fi
EOF
chmod +x "$FAKE_CUSTOM_FQ_TC"
CUSTOM_FQ_RC=0
bbr_sweep_qdisc_save eth0 "$FAKE_CUSTOM_FQ_TC" >/dev/null 2>&1 || CUSTOM_FQ_RC=$?
[[ "$CUSTOM_FQ_RC" = 2 ]] || fail "custom fq qdisc handle was not refused"

# 有状态的 tc 桩：模拟内核语义——删掉 root 会交还内核默认 qdisc（handle 0:），
# 而手工 add/replace root 只能拿到 8001: 这类自动句柄。用它验证扫描可以重复执行。
STATEFUL_TC="$TMP/stateful-tc"
cat > "$STATEFUL_TC" <<'EOF'
#!/bin/sh
STATE="$FAKE_TC_STATE"
DEFAULT_SPEC=$(cat "$FAKE_TC_DEFAULT" 2>/dev/null || echo fq)

write_default() {
    case "$DEFAULT_SPEC" in
        mq:*)
            LEAF=${DEFAULT_SPEC#mq:}
            printf '%s\n' \
                'qdisc mq 0: root refcnt 2' \
                "qdisc $LEAF 0: parent :1 limit 10240p" \
                "qdisc $LEAF 0: parent :2 limit 10240p" > "$STATE"
            ;;
        *)
            printf '%s\n' "qdisc $DEFAULT_SPEC 0: root refcnt 2 limit 10000p" > "$STATE"
            ;;
    esac
    : > "$FAKE_TC_CLASS"
}

ACTION="$1 $2"
[ "$#" -lt 2 ] || shift 2
case "$ACTION" in
    "qdisc show")  cat "$STATE" 2>/dev/null; exit 0 ;;
    "class show")  cat "$FAKE_TC_CLASS" 2>/dev/null; exit 0 ;;
    "filter show") cat "$FAKE_TC_FILTER" 2>/dev/null; exit 0 ;;
    "qdisc del")   write_default; exit 0 ;;
    "qdisc add"|"qdisc replace"|"qdisc change") ;;
    *) exit 0 ;;
esac

TARGET=""; PARENT=""; HANDLE=""; KIND=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        dev)    shift 2 ;;
        root)   TARGET=root; shift ;;
        parent) TARGET=parent; PARENT="$2"; shift 2 ;;
        handle) HANDLE="$2"; shift 2 ;;
        *)      KIND="$1"; break ;;
    esac
done
[ -n "$KIND" ] || exit 1
[ -n "$HANDLE" ] || HANDLE="8001:"

if [ "$TARGET" = root ] && [ "$KIND" = mq ]; then
    awk -v major="${HANDLE%:}" -v handle="$HANDLE" '
        NR == 1 { print "qdisc mq " handle " root refcnt 2"; next }
        / parent / {
            for (i = 1; i <= NF; i++) if ($i == "parent") {
                split($(i + 1), p, ":")
                $(i + 1) = major ":" p[2]
                break
            }
            print
        }
    ' "$STATE" > "$STATE.new" && mv "$STATE.new" "$STATE"
elif [ "$TARGET" = root ]; then
    printf '%s\n' "qdisc $KIND $HANDLE root refcnt 2" > "$STATE"
else
    awk -v parent="$PARENT" -v kind="$KIND" -v handle="$HANDLE" '
        / parent / {
            for (i = 1; i <= NF; i++) if ($i == "parent" && $(i + 1) == parent) {
                $2 = kind; $3 = handle; break
            }
        }
        { print }
    ' "$STATE" > "$STATE.new" && mv "$STATE.new" "$STATE"
fi
exit 0
EOF
chmod +x "$STATEFUL_TC"

export FAKE_TC_STATE="$TMP/tc-state"
export FAKE_TC_DEFAULT="$TMP/tc-default"
export FAKE_TC_CLASS="$TMP/tc-class"
export FAKE_TC_FILTER="$TMP/tc-filter"
: > "$FAKE_TC_FILTER"

# 模拟扫描期间本工具自己挂上的 HTB 整形（bbr_sweep_apply_shaper 的产物）。
write_sweep_htb() {
    printf '%s\n' \
        'qdisc htb 1: root refcnt 2 r2q 10 default 0x10' \
        'qdisc fq 100: parent 1:10 limit 10000p maxrate 200Mbit' > "$FAKE_TC_STATE"
    printf '%s\n' \
        'class htb 1:10 root leaf 100: prio 0 rate 200Mbit ceil 200Mbit burst 200Kb' > "$FAKE_TC_CLASS"
}

reset_sweep_state() {
    BBR_SWEEP_QSAVE_IFACE=""
    BBR_SWEEP_QSAVE_KIND=""
    BBR_SWEEP_QSAVE_LEAF_KIND=""
    BBR_SWEEP_QSAVE_TC=""
    BBR_SWEEP_QSAVE_OWNED=0
}

# 单队列网卡：扫描 → 还原 → 必须能再次扫描（旧版会留下 fq 8001: 并在第二次 save 返回 2）。
printf 'fq\n' > "$FAKE_TC_DEFAULT"
printf '%s\n' 'qdisc fq 0: root refcnt 2 limit 10000p' > "$FAKE_TC_STATE"
: > "$FAKE_TC_CLASS"
reset_sweep_state
bbr_sweep_qdisc_save eth0 "$STATEFUL_TC" || fail "kernel default fq was rejected by the sweep guard"
[[ "$BBR_SWEEP_QSAVE_KIND" = fq ]] || fail "fq restore state was not captured"
write_sweep_htb
bbr_sweep_qdisc_restore >/dev/null 2>&1 || fail "sweep restore failed on a single-queue fq device"
grep -qx 'qdisc fq 0: root refcnt 2 limit 10000p' "$FAKE_TC_STATE" \
    || fail "sweep restore did not hand the root qdisc back to the kernel default: $(cat "$FAKE_TC_STATE")"
RESCAN_RC=0
bbr_sweep_qdisc_save eth0 "$STATEFUL_TC" >/dev/null 2>&1 || RESCAN_RC=$?
[[ "$RESCAN_RC" = 0 ]] || fail "a second sweep was refused after restore (rc=$RESCAN_RC)"
reset_sweep_state

# 扫描期间被第三方 qdisc 抢占时，还原必须报错，不能谎称已按内核默认恢复。
printf '%s\n' 'qdisc fq 0: root refcnt 2 limit 10000p' > "$FAKE_TC_STATE"
: > "$FAKE_TC_CLASS"
bbr_sweep_qdisc_save eth0 "$STATEFUL_TC" || fail "kernel default fq was rejected before the hijack case"
printf '%s\n' 'qdisc cake 8010: root refcnt 2 bandwidth 500Mbit' > "$FAKE_TC_STATE"
HIJACK_RC=0
bbr_sweep_qdisc_restore >/dev/null 2>&1 || HIJACK_RC=$?
[[ "$HIJACK_RC" = 1 ]] || fail "restore did not fail after a foreign qdisc took over (rc=$HIJACK_RC)"
reset_sweep_state

# 多队列网卡：还原后 mq 必须仍是 handle 0:，否则 set_mq_leaves 会把它改成 1: 而卡住下次扫描。
printf 'mq:fq\n' > "$FAKE_TC_DEFAULT"
printf '%s\n' \
    'qdisc mq 0: root refcnt 2' \
    'qdisc fq 0: parent :1 limit 10240p' \
    'qdisc fq 0: parent :2 limit 10240p' > "$FAKE_TC_STATE"
: > "$FAKE_TC_CLASS"
bbr_sweep_qdisc_save eth0 "$STATEFUL_TC" || fail "kernel default mq topology was rejected by the sweep guard"
[[ "$BBR_SWEEP_QSAVE_KIND" = mq && "$BBR_SWEEP_QSAVE_LEAF_KIND" = fq ]] \
    || fail "mq sweep restore state was not captured"
write_sweep_htb
bbr_sweep_qdisc_restore >/dev/null 2>&1 || fail "sweep restore failed on a multi-queue mq device"
grep -qx 'qdisc mq 0: root refcnt 2' "$FAKE_TC_STATE" \
    || fail "mq root was not restored to the kernel default handle: $(cat "$FAKE_TC_STATE")"
MQ_RESCAN_RC=0
bbr_sweep_qdisc_save eth0 "$STATEFUL_TC" >/dev/null 2>&1 || MQ_RESCAN_RC=$?
[[ "$MQ_RESCAN_RC" = 0 ]] || fail "a second mq sweep was refused after restore (rc=$MQ_RESCAN_RC)"
reset_sweep_state

# 跳过扫描时的提示必须反映真实 tc 状态，不能一律宣称“纯 fq”。
FAKE_HTB_TC="$TMP/fake-htb-tc"
cat > "$FAKE_HTB_TC" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "qdisc show") echo 'qdisc htb 1: root refcnt 2 r2q 10 default 0x10' ;;
    "class show") echo 'class htb 1:10 root leaf 100: prio 0 rate 200Mbit ceil 200Mbit' ;;
esac
EOF
chmod +x "$FAKE_HTB_TC"
SHAPED_NOTICE=$(bbr_sweep_skip_notice eth0 "$FAKE_HTB_TC" 2>&1)
grep -q '200Mbit' <<< "$SHAPED_NOTICE" \
    || fail "skip notice hid the existing shaper: $SHAPED_NOTICE"
! grep -q '纯 fq' <<< "$SHAPED_NOTICE" \
    || fail "skip notice still claims plain fq while an HTB shaper exists: $SHAPED_NOTICE"

FAKE_PLAIN_FQ_TC="$TMP/fake-plain-fq-tc"
cat > "$FAKE_PLAIN_FQ_TC" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "qdisc show") echo 'qdisc fq 0: root refcnt 2 limit 10000p' ;;
esac
EOF
chmod +x "$FAKE_PLAIN_FQ_TC"
PLAIN_NOTICE=$(bbr_sweep_skip_notice eth0 "$FAKE_PLAIN_FQ_TC" 2>&1)
grep -q '无硬限速' <<< "$PLAIN_NOTICE" \
    || fail "skip notice did not report the unshaped state: $PLAIN_NOTICE"

echo "BBR adaptive regression tests passed."

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

echo "BBR adaptive regression tests passed."

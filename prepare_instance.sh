#!/usr/bin/env bash
# prepare_instance.sh — generate this instance's inputs, before the timed run.
#   args: v1 <benchmark> <instance> <repetition> <params>
#
# Not timed, which is what makes it the right place for two things:
#   1. bringing up the CORA background server (lazily on the first instance, restarting it
#      if a previous run left it dead or wedged), so MATLAB + CORA startup never lands in a
#      measurement;
#   2. generating the operation's operands — the random matrix and sets — so run_instance.sh
#      does nothing but the operation itself.
#
# Exits with prepare_instance.m's return code; nonzero makes the harness skip the instance.
# Falls back to a direct MATLAB run if no server can be brought up, so one bad server never
# loses a whole benchmark.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/cora_server_lib.sh"

BENCHMARK="$2"; INSTANCE="$3"; REPETITION="$4"; PARAMS="$5"
SERVER_SH="${CORA_SERVER_SH:-$HERE/cora_server.sh}"
MATLAB_BIN="${CORA_MATLAB:-matlab}"
START_TIMEOUT="${CORA_START_TIMEOUT:-550}"   # server boot budget; under the harness's 600s prepare cap
PREP_WAIT="${CORA_PREP_WAIT:-590}"           # wait for the prepare job; under the same cap
mkdir -p "$SRV_DIR"

# Direct fallback: a plain MATLAB run, paying the full startup. CORA_DIRECT_CMD is a test
# seam: `<cmd> prepare <benchmark> <instance> <repetition> <params>`.
direct_prepare() {
    echo "[prepare] no healthy server; preparing directly via MATLAB"
    if [ -n "${CORA_DIRECT_CMD:-}" ]; then
        $CORA_DIRECT_CMD prepare "$BENCHMARK" "$INSTANCE" "$REPETITION" "$PARAMS"
        return $?
    fi
    local b="${BENCHMARK//\'/\'\'}" i="${INSTANCE//\'/\'\'}" p="${PARAMS//\'/\'\'}"
    "$MATLAB_BIN" -batch "addpath(genpath('$HERE')); r=prepare_instance('$b','$i',$REPETITION,'$p'); exit(double(r));"
}

ensure_server() {
    if server_alive && ping_ok "$PING_TIMEOUT"; then
        echo "[prepare] CORA server already running and responsive"
        return 0
    fi
    echo "[prepare] starting CORA background server..."
    if [ -f "$SRV_DIR/server.pid" ]; then
        kill -TERM "$(cat "$SRV_DIR/server.pid" 2>/dev/null)" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$SRV_DIR/running" "$SRV_DIR/done" "$SRV_DIR/result" "$SRV_DIR/request" "$SRV_DIR/job_rc" "$SRV_DIR/pong"
    # Detached, own session, so the harness's per-instance process-group kill cannot reap it.
    setsid bash "$SERVER_SH" >>"$SRV_DIR/server.log" 2>&1 < /dev/null &
    # Relay the boot log (MATLAB starting) to the step log while we wait for readiness.
    : >> "$SRV_DIR/server.log"
    tail -n 0 -F -s 0.2 "$SRV_DIR/server.log" 2>/dev/null & local boot_tail=$!
    # An own counter, not $SECONDS: ping_ok resets $SECONDS on every attempt.
    local left="$START_TIMEOUT"
    while [ "$left" -gt 0 ]; do
        if server_alive; then
            if ping_ok 1; then          # ping_ok is what paces the loop: it waits ~1s
                echo "[prepare] CORA server is up and responsive"
                kill "$boot_tail" 2>/dev/null || true
                return 0
            fi
        else
            sleep 1                     # supervisor not up yet — don't spin
        fi
        left=$((left - 1))
    done
    kill "$boot_tail" 2>/dev/null || true
    return 1
}

if ! ensure_server; then
    echo "[prepare] CORA server failed to start; falling back to a direct run"
    direct_prepare; exit $?
fi

# relay=1: this script is not timed, so the daemon's output is tailed live.
submit_job "prepare" "$BENCHMARK" "$INSTANCE" "$REPETITION" "$PARAMS" \
    "$SRV_DIR/result" "$PREP_WAIT" 1
case $? in
    0)  rc="$(cat "$SRV_DIR/job_rc" 2>/dev/null || echo 0)"
        echo "[prepare] done (return code $rc)"
        exit "$rc" ;;
    1)  echo "[prepare] could not acquire the server lease; preparing directly"
        direct_prepare; exit $? ;;
    2)  echo "[prepare] prepare job exceeded ${PREP_WAIT}s; skipping instance (server will restart)"
        exit 1 ;;   # nonzero -> instance skipped; exiting frees the lease -> daemon torn down
esac

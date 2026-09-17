#!/usr/bin/env bash
# cora_server_lib.sh — client helpers for the CORA background server, sourced by
# prepare_instance.sh and run_instance.sh. The lease, wait and log-relay logic lives here
# so the kill-safety details (close the lease fd in children, release on any exit) are in
# one place.
#
# Reads:  CORA_SERVER_DIR, CORA_PING_TIMEOUT, CORA_POLL
# Sets:   SRV_DIR, JOBID

SRV_DIR="${CORA_SERVER_DIR:-${HOME}/.cora_server}"
PING_TIMEOUT="${CORA_PING_TIMEOUT:-15}"

# How often a client checks for the daemon's answer. This loop sits inside the region the
# harness measures, so it is deliberately fine-grained — a coarse interval would show up
# as quantization on every instance. What is left of it is what the `test` benchmark
# measures, and is meant to be subtracted.
POLL="${CORA_POLL:-0.005}"

# Liveness: write `ping`, wait up to $1 seconds for the (idle) daemon to touch `pong`.
ping_ok() {
    rm -f "$SRV_DIR/pong"; : > "$SRV_DIR/ping"
    SECONDS=0
    while [ "$SECONDS" -lt "${1:-$PING_TIMEOUT}" ]; do
        [ -e "$SRV_DIR/pong" ] && { rm -f "$SRV_DIR/pong"; return 0; }
        sleep "$POLL"   # run_instance.sh pings before every instance, inside the measurement
    done
    return 1
}

server_alive() {
    [ -f "$SRV_DIR/server.pid" ] && kill -0 "$(cat "$SRV_DIR/server.pid" 2>/dev/null)" 2>/dev/null
}

# submit_job TYPE BENCHMARK INSTANCE PARAMS RESULT WAIT_TOTAL RELAY
#   Publishes a job, waits up to WAIT_TOTAL seconds for the daemon's `done`, and prints
#   the job's log. With RELAY=1 the log is tailed live (used by prepare_instance.sh, which
#   is not timed); with RELAY=0 it is printed once the job is done, so the tail process and
#   its drain do not land inside a measurement.
#
#   Holds an flock'd lease for the call's lifetime; the kernel releases it on ANY exit
#   (including an untrappable SIGKILL) so cora_server.sh can detect a killed owner. The
#   daemon writes a run's verdict to $SRV_DIR/result and each job's return code to
#   $SRV_DIR/job_rc.
#   Returns: 0 done; 1 could not acquire the lease; 2 timed out (the caller should exit, so
#   the lease frees and the wedged daemon is torn down).
submit_job() {
    local type="$1" benchmark="$2" instance="$3" params="$4"
    local result="$5" wait_total="$6" relay="${7:-0}"
    JOBID="$$-$(date +%s%N)"

    # Invariant: prepare_instance.sh / run_instance.sh are the ONLY processes that ever take
    # the lease, and the harness runs them strictly one at a time. So when we start, the
    # lease MUST be free. If it is not, a previous run is wedged — e.g. the harness SIGKILLed
    # its process group but a reparented child survived, still holding the lease. Reap that
    # orphan so we reclaim the (healthy, warm) server instead of falling back to a slow
    # direct MATLAB run. fuser lists the holder PIDs; we have not opened fd 9 yet, so it
    # lists only the orphan, never ourselves.
    if ! flock -n "$SRV_DIR/lease" -c true 2>/dev/null; then
        local stale
        stale="$(fuser "$SRV_DIR/lease" 2>/dev/null)"
        if [ -n "$stale" ]; then
            echo "[cora] lease held by stale client(s):$stale — reaping to reclaim the server"
            kill -TERM $stale 2>/dev/null
            SECONDS=0
            while [ "$SECONDS" -lt 10 ] && ! flock -n "$SRV_DIR/lease" -c true 2>/dev/null; do
                sleep 0.5
            done
            if ! flock -n "$SRV_DIR/lease" -c true 2>/dev/null; then
                stale="$(fuser "$SRV_DIR/lease" 2>/dev/null)"
                [ -n "$stale" ] && kill -KILL $stale 2>/dev/null
                sleep 1
            fi
        fi
    fi

    # Hold the lease for our whole lifetime. The kernel drops it on any exit (incl. SIGKILL).
    exec 9> "$SRV_DIR/lease"
    flock -w 10 9 || return 1

    # We own the channel: clear stale per-job files, then publish the request atomically.
    # `cwd` is passed so the daemon runs the job from the same directory as we do.
    rm -f "$SRV_DIR/done" "$SRV_DIR/result" "$SRV_DIR/running" "$SRV_DIR/job_rc"
    : > "$SRV_DIR/job.log"
    { echo "id=$JOBID"; echo "type=$type"; echo "cwd=$(pwd)";
      echo "benchmark=$benchmark"; echo "instance=$instance";
      echo "params=$params";
      echo "result=$result"; } > "$SRV_DIR/request.tmp"
    mv "$SRV_DIR/request.tmp" "$SRV_DIR/request"

    local tail_pid=""
    if [ "$relay" = 1 ]; then
        # CRITICAL: close the lease fd in this child (9>&-), else tail inherits fd 9 and keeps
        # the flock'd open-file-description alive after we are SIGKILLed, so the kernel would
        # not release the lease and cora_server.sh could never detect our death.
        tail -n +1 -F -s 0.2 "$SRV_DIR/job.log" 2>/dev/null 9>&- &
        tail_pid=$!
        trap 'kill "$tail_pid" 2>/dev/null; exit 124' TERM INT
    fi

    # Builtins only inside the loop (`read`, `SECONDS`): a `cat`/`date` per iteration would
    # add a fork to every poll, and this loop is inside the measured region.
    local done_id=""
    SECONDS=0
    while :; do
        # 2>/dev/null before the input redirect: `done` does not exist until the daemon
        # writes it, and bash reports a failed redirect on whatever fd 2 is at that point.
        done_id=""; read -r done_id 2>/dev/null < "$SRV_DIR/done" || true
        [ "$done_id" = "$JOBID" ] && break
        if [ "$SECONDS" -ge "$wait_total" ]; then
            [ -n "$tail_pid" ] && { kill "$tail_pid" 2>/dev/null; trap - TERM INT; }
            return 2   # the caller exits -> lease frees -> cora_server.sh kills the wedged daemon
        fi
        sleep "$POLL" 9>&-   # 9>&-: don't let the sleep child hold the lease fd during a kill
    done

    if [ -n "$tail_pid" ]; then
        sleep 0.5                            # let tail drain the final lines
        kill "$tail_pid" 2>/dev/null; trap - TERM INT
    fi
    return 0
}

# Print the last job's daemon-side log. With RELAY=0 nothing was relayed while the job ran,
# so this is how its output reaches the step log — run_instance.sh calls it only when the
# verdict is not `finished`, since the fork it costs would otherwise land in every
# measurement and a successful run has nothing interesting to say.
relay_job_log() {
    echo "── CORA job log ──"
    cat "$SRV_DIR/job.log" 2>/dev/null || true
}

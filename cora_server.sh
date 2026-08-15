#!/usr/bin/env bash
# cora_server.sh — supervisor for the persistent CORA MATLAB daemon. Started detached
# (setsid) by prepare_instance.sh, so it lives in its own session and survives the
# harness killing an instance's process group.
#
# Two jobs:
#   1. launch the MATLAB daemon (cora_server.m) ONCE, in its own process group, so
#      MATLAB + CORA startup is paid once per node rather than once per instance. That is
#      not an optimization here but a precondition: a CORA-COMP instance measures a set
#      operation repeated a hundred times, which a per-instance MATLAB start would bury.
#   2. couple each in-flight job to the prepare_instance.sh / run_instance.sh that owns it
#      via an flock'd lease. The kernel releases the lease the instant the owner exits
#      (cleanly or via an untrappable SIGKILL). If the lease is free while a job is still
#      running, the owner was killed mid-run — kill the (possibly wedged) daemon and exit,
#      so the next prepare_instance.sh starts a clean server. A clean finish leaves the
#      daemon running, so it persists across instances and benchmarks.
set -u
set -m   # job control: the backgrounded daemon gets its own process group (pgid == pid)

SRV_DIR="${CORA_SERVER_DIR:-${HOME}/.cora_server}"
mkdir -p "$SRV_DIR"

# How to launch the daemon. Tests override CORA_MATLAB_CMD with a mock; the default starts
# MATLAB with this directory on the path, which genpath extends over code/cora.
TOOL_DIR="${CORA_TOOL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
MATLAB_BIN="${CORA_MATLAB:-matlab}"
MATLAB_CMD="${CORA_MATLAB_CMD:-$MATLAB_BIN -nodisplay -nosplash -sd \"$TOOL_DIR\" -r \"addpath(genpath('$TOOL_DIR')); cora_server('$SRV_DIR')\"}"

echo "$$" > "$SRV_DIR/server.pid"   # supervisor pid = the persistent unit's handle

# Fresh start: never inherit a previous (killed) daemon's per-job files as live work.
rm -f "$SRV_DIR/running" "$SRV_DIR/done" "$SRV_DIR/result" "$SRV_DIR/request" "$SRV_DIR/job_rc" "$SRV_DIR/pong"

eval "$MATLAB_CMD" >"$SRV_DIR/server.log" 2>&1 &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$SRV_DIR/daemon.pid"

teardown() {
    kill -KILL -"$DAEMON_PID" 2>/dev/null || kill -KILL "$DAEMON_PID" 2>/dev/null
    rm -f "$SRV_DIR/server.pid" "$SRV_DIR/daemon.pid"
}
trap 'teardown; exit 0' TERM INT

# Is the owner of the current job still holding the lease? (flock -n fails => still held.)
lease_held() { ! flock -n "$SRV_DIR/lease" -c true 2>/dev/null; }

while kill -0 "$DAEMON_PID" 2>/dev/null; do
    if [ -e "$SRV_DIR/running" ]; then
        jobid="$(cat "$SRV_DIR/running" 2>/dev/null || true)"
        # Watch THIS job until it finishes cleanly or its owner dies. Everything keys on the
        # job id (with done==jobid, written before the owner releases the lease, as the
        # authoritative clean signal), so consecutive jobs cannot be mistaken for a death.
        while [ -n "$jobid" ]; do
            [ "$(cat "$SRV_DIR/done" 2>/dev/null || true)" = "$jobid" ] && break   # clean finish
            if ! lease_held; then
                # Lease free but this job's `done` is not set => the owner died mid-run.
                # Re-check `done` once to close the set-done/release-lease race window.
                [ "$(cat "$SRV_DIR/done" 2>/dev/null || true)" = "$jobid" ] && break
                echo "[cora_server.sh] owner of job '$jobid' died mid-run; killing daemon for a clean restart" >> "$SRV_DIR/server.log"
                teardown
                exit 1
            fi
            # State moved on to another job (shouldn't happen with a sequential harness, but
            # be safe): stop watching the stale jobid and re-read.
            [ "$(cat "$SRV_DIR/running" 2>/dev/null || true)" = "$jobid" ] || break
            sleep 0.1
        done
    fi
    sleep 0.1
done

echo "[cora_server.sh] daemon exited on its own; supervisor stopping" >> "$SRV_DIR/server.log"
rm -f "$SRV_DIR/server.pid" "$SRV_DIR/daemon.pid"
exit 1

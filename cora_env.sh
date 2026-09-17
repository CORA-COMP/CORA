#!/usr/bin/env bash
# cora_env.sh — environment for every script that starts MATLAB, sourced by
# install_tool.sh and cora_server_lib.sh (and so by the daemon they start).
#
# MATLAB checks its license out from the TUM license server unless the submission says
# otherwise: its own MLM_LICENSE_FILE, or a license file via CORA_LICENSE_URL.
if [ -z "${CORA_LICENSE_URL:-}" ]; then
    export MLM_LICENSE_FILE="${MLM_LICENSE_FILE:-28000@mlm1.rbg.tum.de}"
fi

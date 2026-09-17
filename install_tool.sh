#!/bin/bash
# install_tool.sh — put CORA on the worker, once per node.
# Called by the platform as `install_tool.sh v1` with this directory as the cwd.
#
# The base image is expected to ship MATLAB (see README.md); this script only adds CORA
# itself, cloned at a pinned tag so a submission keeps meaning the same thing as CORA
# moves on. Nothing is written to MATLAB's saved path: cora_server.sh starts MATLAB with
# `addpath(genpath(<this directory>))`, which covers code/cora too.

set -eu

VERSION_STRING="v1"
if [ "$1" != "$VERSION_STRING" ]; then
    echo "Expected first argument (version string) '$VERSION_STRING', got '$1'"
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/cora_env.sh"

CORA_REPO="${CORA_REPO:-https://github.com/TUMcps/CORA.git}"
CORA_REF="${CORA_REF:-v2026.1.0}"
CORA_DIR="$HERE/code/cora"
MATLAB_BIN="${CORA_MATLAB:-matlab}"

# ---------------------------------------------------------------- licensing
# Printed for the organizers: a node-locked MATLAB license is issued against the MAC
# address and user the toolkit actually runs as, and a worker is a fresh machine.
echo "== licensing info =="
echo "user: $(whoami)"
ip link show 2>/dev/null || true

# MATLAB uses the license server from cora_env.sh. If the organizers hand out a license
# file instead, point CORA_LICENSE_URL at it and it is installed here.
if [ -n "${CORA_LICENSE_URL:-}" ]; then
    matlab_root="$(dirname "$(dirname "$(readlink -f "$(command -v "$MATLAB_BIN")")")")"
    echo "== installing license file into ${matlab_root}/licenses =="
    curl --retry 100 --retry-connrefused -fsSL "$CORA_LICENSE_URL" -o "$HERE/license.lic"
    sudo cp -f "$HERE/license.lic" "${matlab_root}/licenses/"
fi

# ---------------------------------------------------------------- CORA
echo "== cloning CORA ${CORA_REF} =="
rm -rf "$CORA_DIR"
mkdir -p "$(dirname "$CORA_DIR")"
# Only the pinned revision, not the full history: CORA is a large repository and nothing
# here ever looks at an earlier commit.
git clone --depth 1 --branch "$CORA_REF" "$CORA_REPO" "$CORA_DIR"
git -C "$CORA_DIR" rev-parse HEAD

# ---------------------------------------------------------------- smoke test
# Fail here rather than on the first instance: this is the one place where a broken
# license or a missing toolbox is still attributable to the install step.
echo "== checking MATLAB starts with CORA on the path (license: ${MLM_LICENSE_FILE:-license file}) =="
"$MATLAB_BIN" -batch "addpath(genpath('$HERE')); \
    fprintf('%s\n', CORAVERSION); \
    Z = zonotope.generateRandom('Dimension', 2, 'NrGenerators', 2); \
    I = interval.generateRandom('Dimension', 2); \
    disp(class(Z + Z)); disp(class(convHull(I, I)));"

echo "== CORA installed =="

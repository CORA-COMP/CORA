# CORA — CORA-COMP submission

The [CORA](https://cora.in.tum.de/) entry for [CORA-COMP](https://github.com/CORA-COMP/cora-eval-platform),
and the baseline the other submissions are compared against. It implements the
[benchmark catalog](https://github.com/CORA-COMP/benchmarks) on top of CORA's `contSet`
classes.

Submit it like any other tool: this repository and a commit, plus a base image that ships
MATLAB (see below). `install_tool.sh` clones CORA itself.

## What it runs

| | |
| --- | --- |
| Benchmarks | `test`, `interval`, `zonotope`, `interval-batched`, `zonotope-batched` |
| Operations | `startup`, `generateRandom`, `randPoint`, `supportFunc`, `matMul`, `minkSum`, `contains` |
| Devices | `cpu`; `gpu` where CORA's set operations run on `gpuArray` data |
| Batched | yes, as a list of sets |

On a gpu instance, the inputs are moved to the GPU before the loop (`zonotope(gpuArray(c),
gpuArray(G))`) and CORA's own methods run on them, followed by `wait(gpuDevice)` so the
asynchronous work lands in the measurement. Two cases report `unsupported` there:
`matMul`, because `gpuArray * contSet` dispatches to gpuArray's `mtimes` rather than
CORA's, and `contains` on a zonotope, which solves an LP and `linprog` is CPU-only.

CORA has no batched set representation, so a batch is a cell array of `batch_size` sets
and each repetition applies the operation to every set in turn; an unbatched instance is a
list of one. What is supported is decided in one place, `aux_unsupported` in
[`run_instance.m`](run_instance.m); narrowing it, and adding the cases to `aux_execute`, is
how this submission grows.

Everything happens in `run_instance.m`, inside the harness's measurement: generate the
inputs, move them to the device, run the loop. The operations map onto CORA directly (`S` a random set, with `generators` generators for a zonotope):

| Operation | Inputs (before the loop) | Repeated |
| --- | --- | --- |
| `startup` | — | `zonotope(zeros(n,1), eye(n))` |
| `generateRandom` | — | `<class>.generateRandom('Dimension', n[, 'NrGenerators', m])` |
| `randPoint` | `S` | `randPoint(S, points, type)` |
| `supportFunc` | `S`, a random unit `d` | `supportFunc(S, d, type)` |
| `matMul` | `randn(n)`, `S` | `M * S` |
| `minkSum` | `S1`, `S2` | `S1 + S2` |
| `contains` | `S`, `X = randPoint(S, points)` | `contains(S, X)`; anything but all true is an `error` |

## The background server

MATLAB and CORA take tens of seconds to start. An instance here measures a set operation
repeated a hundred times — often milliseconds of work — so paying that startup per
instance would not merely slow the run down, it would replace the measurement with it.

So the toolkit runs CORA as a persistent daemon. The first `prepare_instance.sh` starts
[`cora_server.sh`](cora_server.sh) detached, which launches
[`cora_server.m`](cora_server.m) in MATLAB; every later instance is a job submitted to
that warm daemon over a small file channel. `run_instance.sh` is then a thin client:
publish the job, wait for the verdict, copy it out.

What the client costs is measured, so it is kept small: the wait loop polls every 5 ms with
shell builtins (no fork per poll), and the daemon's log is relayed after the fact — only
when the instance did not finish. What remains is a few milliseconds of process and channel
overhead per instance, which is what the catalog's `test` benchmark exists to measure and
subtract.

Each job starts from `rng('default')`, so a warm daemon behaves like a fresh MATLAB and
every run of an instance sees the same random inputs.

If the server cannot be started, or its lease cannot be acquired, both scripts fall back
to a direct `matlab -batch` run. That is far slower and its measurement includes MATLAB
startup, but one bad server never loses a whole benchmark.

Kill safety is the same trick as in CORA's VNN-COMP submission: each client holds an
`flock`'d lease for its lifetime, so the kernel releases it even on an untrappable
`SIGKILL` from the harness's timeout, and `cora_server.sh` tears a wedged daemon down for a
clean restart.

## Layout

| File | |
| --- | --- |
| `install_tool.sh` | clones CORA at a pinned tag, installs a license if given, smoke-tests MATLAB |
| `prepare_instance.sh` | brings the server up, submits the `prepare` job |
| `run_instance.sh` | submits the `run` job, copies out the verdict — the timed script |
| `cora_server.sh` / `cora_server_lib.sh` | daemon supervisor and the clients' shared lease/wait logic |
| `cora_server.m` | the daemon: reads jobs, dispatches, writes results |
| `prepare_instance.m` | initializes the GPU for gpu instances |
| `run_instance.m` | decides what is supported, generates the inputs, runs the operation `repetition` times, writes the verdict |

## Configuration

`install_tool.sh` and the scripts read a few environment variables, all optional:

| Variable | Default | |
| --- | --- | --- |
| `CORA_REF` | `v2026.1.0` | CORA tag to clone; pinned so a submission keeps meaning the same thing |
| `CORA_REPO` | `https://github.com/TUMcps/CORA.git` | where to clone it from |
| `CORA_MATLAB` | `matlab` | how to invoke MATLAB, e.g. `sudo -u matlab matlab` if the license belongs to another user |
| `CORA_LICENSE_URL` | — | a license file to fetch and install; unset means the image reaches a license server |
| `CORA_SERVER_DIR` | `$HOME/.cora_server` | the daemon's file channel |
| `CORA_POLL` | `0.005` | client poll interval, inside the measured region |
| `CORA_RUN_WAIT` | `3600` | backstop for a wedged daemon on a single instance |

**Base image.** Anything Ubuntu-based with MATLAB and the Deep Learning / Optimization
toolboxes CORA expects, plus the Parallel Computing Toolbox and the NVIDIA driver for the
gpu instances; `tobiasladnertum/cora:r2024b` is the image CORA's own submissions
use. The platform bootstraps it into an SSH-reachable node, so it needs `apt` and root at
provisioning time. MATLAB must be licensed on the worker — a license server the node can
reach, or a node-locked file via `CORA_LICENSE_URL`. `install_tool.sh` prints the worker's
user and MAC addresses to the install log, which is what a node-locked license is issued
against.

## Running one instance locally

With MATLAB and this repository's `code/cora` in place (`install_tool.sh v1` does that):

```bash
P='{"set": "zonotope", "operation": "matMul", "dim": 100, "generators": 200, "device": "cpu", "repetition": 100}'
./prepare_instance.sh v1 zonotope matMul-100d-cpu "$P"
./run_instance.sh     v1 zonotope matMul-100d-cpu "$P" /tmp/result.csv
cat /tmp/result.csv
```

The first call starts the daemon and takes as long as MATLAB does; later ones are
immediate. `pkill -f cora_server` stops it.

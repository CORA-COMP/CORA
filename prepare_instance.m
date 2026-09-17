function rc = prepare_instance(benchmark, instance, params)
% prepare_instance - untimed setup before run_instance.
%
%    The instance itself, inputs included, happens in run_instance. What is left here is
%    setup the measurement should not carry: for a gpu instance, creating the GPU context,
%    which takes seconds once and is then kept by the daemon.
%
% Syntax:
%    rc = prepare_instance(benchmark, instance, params)
%
% Inputs:
%    benchmark  - set representation, e.g. 'zonotope' or 'zonotope-batched'
%    instance   - '<operation>-<n>d[-b<batch>]-<device>', e.g. 'matMul-500d-cpu'
%    params     - JSON object (char), see run_instance
%
% Outputs:
%    rc - 0 on success; nonzero makes the harness skip the instance
%
% Other m-files required: none
% Subfunctions: none
% MAT-files required: none
%
% See also: run_instance, cora_server

% Authors:       Tobias Ladner
% Written:       15-August-2026
% Last update:   17-September-2026 (inputs moved to run_instance; gpu warm-up)
% Last revision: ---

% ------------------------------ BEGIN CODE -------------------------------

rc = 0;

try
    p = jsondecode(params);
    if strcmpi(p.device, 'gpu') && canUseGPU
        gpuDevice();
        fprintf('[prepare] %s / %s: GPU initialized\n', benchmark, instance);
    end

catch err
    fprintf('[prepare] ERROR: %s\n', getReport(err, 'extended', 'hyperlinks', 'off'));
    rc = 1;
end

end

% ------------------------------ END OF CODE ------------------------------

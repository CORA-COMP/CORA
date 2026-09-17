function run_instance(benchmark, instance, params, resultFile)
% run_instance - perform the measured operation and write the verdict.
%
%    The whole instance happens here, inside the region the harness times: generate the
%    inputs, move them to the device, then perform the operation `repetition` times so
%    that one measurement averages over repeats. Timing is the harness's business — this
%    only reports one of `finished`, `unsupported` or `error`.
%
%    A batch is a list of `batch_size` sets, and the operation is applied to each set in
%    turn: CORA has no batched set representation. An unbatched instance is a list of one.
%
%    This is also the one place that decides what the submission supports. On the GPU, the
%    sets hold gpuArray data and CORA's own methods run on it, except where they cannot:
%    gpuArray * contSet dispatches to gpuArray's mtimes, and zonotope point containment
%    solves an LP, which linprog only does on the CPU. Those instances report
%    `unsupported`. Narrowing aux_unsupported, and adding the cases to aux_execute, is how
%    this submission grows.
%
% Syntax:
%    run_instance(benchmark, instance, params, resultFile)
%
% Inputs:
%    benchmark  - set representation, e.g. 'zonotope' or 'zonotope-batched'
%    instance   - '<operation>-<n>d[-b<batch>]-<device>', e.g. 'matMul-500d-cpu'
%    params     - JSON object (char) with everything the tool needs: set, operation, dim,
%                 generators (zonotopes), device, repetition, batch_size (batched) and the
%                 operation's own fields
%    resultFile - where to write the verdict (header row + one data row)
%
% Outputs:
%    -
%
% Other m-files required: none
% Subfunctions: aux_unsupported, aux_inputs, aux_execute, aux_class, aux_random,
%               aux_randomSets, aux_toDevice, aux_writeResult
% MAT-files required: none
%
% See also: prepare_instance, cora_server

% Authors:       Tobias Ladner
% Written:       15-August-2026
% Last update:   17-September-2026 (randPoint, supportFunc, contains; gpu; batches; inputs here)
% Last revision: ---

% ------------------------------ BEGIN CODE -------------------------------

%: The operations this submission implements; anything else in the catalog is unsupported.
OPERATIONS = {'startup', 'generateRandom', 'randPoint', 'supportFunc', 'matMul', ...
    'minkSum', 'contains'};

verdict = 'error';

try
    p = jsondecode(params);
    n = double(p.dim);
    repetition = double(p.repetition);
    batchSize = 1;
    if isfield(p, 'batch_size')
        batchSize = double(p.batch_size);
    end
    cls = aux_class(p.set);
    gpu = strcmpi(p.device, 'gpu');

    reason = aux_unsupported(p, cls, OPERATIONS);
    if ~isempty(reason)
        fprintf('[run] %s / %s: %s\n', benchmark, instance, reason);
        verdict = 'unsupported';
    else
        data = aux_inputs(p, cls, n, batchSize);
        if gpu
            data = structfun(@aux_toDevice, data, 'UniformOutput', false);
        end
        aux_execute(p, cls, n, repetition, batchSize, data, gpu);
        verdict = 'finished';
        fprintf('[run] %s / %s: %s x%d on %d %s(s) in %dd (%s)\n', ...
            benchmark, instance, p.operation, repetition, batchSize, cls, n, p.device);
    end

catch err
    fprintf('[run] ERROR: %s\n', getReport(err, 'extended', 'hyperlinks', 'off'));
    verdict = 'error';
end

aux_writeResult(resultFile, verdict);

end


% Auxiliary functions -----------------------------------------------------

function reason = aux_unsupported(p, cls, operations)
    % Why this instance is not run, or '' if it is.
    reason = '';
    gpu = strcmpi(p.device, 'gpu');
    if ~ismember(lower(p.device), {'cpu', 'gpu'})
        reason = sprintf('unknown device "%s"', p.device);
    elseif isempty(cls)
        reason = sprintf('unknown set "%s"', p.set);
    elseif ~ismember(p.operation, operations)
        reason = sprintf('unknown operation "%s"', p.operation);
    elseif gpu && ~canUseGPU
        reason = 'gpu: no usable GPU on this machine';
    elseif gpu && strcmp(p.operation, 'startup')
        reason = 'gpu: the startup instance is cpu-only';
    elseif gpu && strcmp(p.operation, 'matMul')
        reason = 'gpu: gpuArray * contSet dispatches to gpuArray, not to CORA';
    elseif gpu && strcmp(p.operation, 'contains') && strcmp(cls, 'zonotope')
        reason = 'gpu: zonotope point containment solves an LP, and linprog is cpu-only';
    end
end

function data = aux_inputs(p, cls, n, B)
    % The operation's inputs on the CPU, one per set of the batch in a cell array; matMul's
    % matrix is shared by the whole batch. generateRandom and startup need none.
    data = struct();
    switch p.operation
        case 'randPoint'
            data.S = aux_randomSets(cls, n, p, B);
        case 'supportFunc'
            data.S = aux_randomSets(cls, n, p, B);
            data.d = cell(1, B);
            for j = 1:B
                d = randn(n, 1);
                data.d{j} = d / norm(d);
            end
        case 'matMul'
            data.S = aux_randomSets(cls, n, p, B);
            data.M = randn(n);
        case 'minkSum'
            data.S1 = aux_randomSets(cls, n, p, B);
            data.S2 = aux_randomSets(cls, n, p, B);
        case 'contains'
            data.S = aux_randomSets(cls, n, p, B);
            % Drawn from S, so the containment check must answer true for each.
            data.p = cell(1, B);
            for j = 1:B
                data.p{j} = randPoint(data.S{j}, double(p.points), 'standard');
            end
    end
end

function out = aux_execute(p, cls, n, reps, B, data, gpu)
    % The operation itself, `reps` times, on each of the B sets in `data`. The results are
    % returned rather than dropped so the loop stays observable.
    out = cell(1, B);
    switch p.operation
        case 'startup'
            % The overhead instance: the least a library can do — initialize one zonotope.
            for i = 1:reps
                out{1} = zonotope(zeros(n,1), eye(n));
            end
        case 'generateRandom'
            for i = 1:reps
                for j = 1:B
                    out{j} = aux_random(cls, n, p);
                    if gpu
                        out{j} = aux_toDevice(out{j});
                    end
                end
            end
        case 'randPoint'
            N = double(p.points);
            for i = 1:reps
                for j = 1:B
                    out{j} = randPoint(data.S{j}, N, p.type);
                end
            end
        case 'supportFunc'
            for i = 1:reps
                for j = 1:B
                    out{j} = supportFunc(data.S{j}, data.d{j}, p.type);
                end
            end
        case 'matMul'
            for i = 1:reps
                for j = 1:B
                    out{j} = data.M * data.S{j};
                end
            end
        case 'minkSum'
            for i = 1:reps
                for j = 1:B
                    out{j} = data.S1{j} + data.S2{j};
                end
            end
        case 'contains'
            for i = 1:reps
                for j = 1:B
                    out{j} = contains(data.S{j}, data.p{j});
                end
            end
            % The points were drawn from the sets, so anything but true is a wrong answer.
            if ~all(cellfun(@(r) all(gather(r)), out))
                error('contains: a point drawn from a set was reported outside it');
            end
    end
    if gpu
        % GPU calls return before their work is done; the measurement has to include it.
        wait(gpuDevice);
    end
end

function cls = aux_class(setName)
    % The CORA class a set name means; '' for one this submission does not know.
    switch char(setName)
        case 'interval'; cls = 'interval';
        case 'zonotope'; cls = 'zonotope';
        otherwise;       cls = '';
    end
end

function S = aux_random(cls, n, p)
    % A random set of the given class and dimension, with the catalog's generator count:
    % the inputs of most operations, and the generateRandom operation itself.
    switch cls
        case 'interval'
            S = interval.generateRandom('Dimension', n);
        case 'zonotope'
            S = zonotope.generateRandom('Dimension', n, 'NrGenerators', double(p.generators));
    end
end

function S = aux_randomSets(cls, n, p, B)
    % B independent random sets, as a cell array.
    S = cell(1, B);
    for j = 1:B
        S{j} = aux_random(cls, n, p);
    end
end

function x = aux_toDevice(x)
    % The same set or array, or cell array of them, with its data on the GPU.
    if iscell(x)
        x = cellfun(@aux_toDevice, x, 'UniformOutput', false);
    elseif isa(x, 'zonotope')
        x = zonotope(gpuArray(x.c), gpuArray(x.G));
    elseif isa(x, 'interval')
        x = interval(gpuArray(x.inf), gpuArray(x.sup));
    else
        x = gpuArray(x);
    end
end

function aux_writeResult(resultFile, verdict)
    % The verdict file the harness reads: a header row and one data row. CORA reports no
    % timing of its own — the harness's wall-clock is the measurement.
    fid = fopen(resultFile, 'w');
    if fid < 0
        fprintf('[run] ERROR: cannot write result file "%s"\n', resultFile);
        return
    end
    fprintf(fid, 'result\n%s\n', verdict);
    fclose(fid);
end

% ------------------------------ END OF CODE ------------------------------

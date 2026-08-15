function run_instance(benchmark, instance, params, resultFile)
% run_instance - perform the measured operation and write the verdict.
%
%    Everything here is inside the region the harness times, so it stays as thin as it can:
%    read the operands prepare_instance saved, once, then perform the operation
%    `repetition` times so that one measurement averages over repeats. Timing is the
%    harness's business — this only reports one of `finished`, `unsupported` or `error`.
%
%    This is also the one place that decides what the submission supports. CORA's contSet
%    operations are scalar-set and run on double arrays: there is no gpuArray path for them
%    (the GPU support in CORA is in the neural-network layers, not in set arithmetic) and
%    no batched set representation. Those instances report `unsupported` rather than being
%    emulated — looping over a batch would measure something the catalog did not ask for
%    and record it as the vectorized path. Widening the two guards below, and adding the
%    cases to aux_execute, is how this submission grows.
%
% Syntax:
%    run_instance(benchmark, instance, params, resultFile)
%
% Inputs:
%    benchmark  - set representation, e.g. 'zonotope' or 'zonotope-batched'
%    instance   - '<operation>-<n>d[-b<batch>]-<device>', e.g. 'matMul-500d-cpu'
%    params     - JSON object (char) with everything the tool needs: set, operation, dim,
%                 device, repetition and, when batched, batch_size
%    resultFile - where to write the verdict (header row + one data row)
%
% Outputs:
%    -
%
% Other m-files required: none
% Subfunctions: aux_class, aux_random, aux_inputFile, aux_execute, aux_writeResult
% MAT-files required: the handover file written by prepare_instance
%
% See also: prepare_instance, cora_server

% Authors:       Tobias Ladner
% Written:       15-August-2026
% Last update:   ---
% Last revision: ---

% ------------------------------ BEGIN CODE -------------------------------

%: The operations this submission implements; anything else in the catalog is unsupported.
OPERATIONS = {'startup', 'generateRandom', 'matMul', 'minkSum', 'convHull'};
%: Operations whose operands prepare_instance built; the others generate their own.
WITH_OPERANDS = {'matMul', 'minkSum', 'convHull'};

verdict = 'error';

try
    p = jsondecode(params);
    n = double(p.dim);
    repetition = double(p.repetition);
    cls = aux_class(p.set);

    reason = '';
    if ~strcmpi(p.device, 'cpu')
        reason = sprintf('device "%s": CORA has no GPU path for set operations', p.device);
    elseif isfield(p, 'batch_size')
        reason = 'batched: CORA has no batched set representation';
    elseif isempty(cls)
        reason = sprintf('unknown set "%s"', p.set);
    elseif ~ismember(p.operation, OPERATIONS)
        reason = sprintf('unknown operation "%s"', p.operation);
    end

    if ~isempty(reason)
        fprintf('[run] %s / %s: %s\n', benchmark, instance, reason);
        verdict = 'unsupported';
    else
        % Read the prepared operands once; everything after this is the operation itself.
        data = struct();
        if ismember(p.operation, WITH_OPERANDS)
            data = load(aux_inputFile(benchmark, instance));
        end
        aux_execute(p.operation, cls, n, repetition, data);
        verdict = 'finished';
        fprintf('[run] %s / %s: %s x%d on a %s in %dd\n', ...
            benchmark, instance, p.operation, repetition, cls, n);
    end

catch err
    fprintf('[run] ERROR: %s\n', getReport(err, 'extended', 'hyperlinks', 'off'));
    verdict = 'error';
end

aux_writeResult(resultFile, verdict);

end


% Auxiliary functions -----------------------------------------------------

function out = aux_execute(operation, cls, n, reps, data)
    % The measured region: nothing but the operation, `reps` times. The operands are
    % already in `data`, so nothing here generates a set or touches the disk. The result is
    % returned rather than dropped so the loop stays observable.
    out = [];
    switch operation
        case 'startup'
            % The overhead instance: the least a library can do — initialize one zonotope.
            for i = 1:reps
                out = zonotope(zeros(n,1), eye(n));
            end
        case 'generateRandom'
            for i = 1:reps
                out = aux_random(cls, n);
            end
        case 'matMul'
            for i = 1:reps
                out = data.M * data.X;
            end
        case 'minkSum'
            for i = 1:reps
                out = data.X + data.Y;
            end
        case 'convHull'
            for i = 1:reps
                out = convHull(data.X, data.Y);
            end
    end
end

function cls = aux_class(setName)
    % The CORA class a set name means; '' for one this submission does not know. Mirrored
    % in prepare_instance.m.
    switch char(setName)
        case 'interval'; cls = 'interval';
        case 'zonotope'; cls = 'zonotope';
        otherwise;       cls = '';
    end
end

function S = aux_random(cls, n)
    % A random non-degenerate set of the given class and dimension — the operands in
    % prepare_instance.m, and the generateRandom operation itself here.
    switch cls
        case 'interval'
            S = interval.generateRandom('Dimension', n);
        case 'zonotope'
            % n generators, as the catalog asks for; CORA's default of 2n would be a
            % different — and strictly larger — piece of work.
            S = zonotope.generateRandom('Dimension', n, 'NrGenerators', n);
    end
end

function file = aux_inputFile(benchmark, instance)
    % Mirrored in prepare_instance.m.
    file = fullfile('inputs', sprintf('%s-%s.mat', benchmark, instance));
end

function aux_writeResult(resultFile, verdict)
    % The verdict file the harness reads: a header row and one data row. Extra columns
    % would be kept alongside it, but CORA reports no timing of its own — the harness's
    % wall-clock is the measurement.
    fid = fopen(resultFile, 'w');
    if fid < 0
        fprintf('[run] ERROR: cannot write result file "%s"\n', resultFile);
        return
    end
    fprintf(fid, 'result\n%s\n', verdict);
    fclose(fid);
end

% ------------------------------ END OF CODE ------------------------------

function rc = prepare_instance(benchmark, instance, params)
% prepare_instance - build this instance's operands, before the timed run.
%
%    This step is not timed, which is the whole point of it: for matMul it draws the random
%    matrix and the random set here and saves them, so run_instance performs — and the
%    harness measures — only the multiplication. generateRandom and startup have nothing to
%    prepare, since for them the initialization *is* the operation.
%
%    An unsupported instance is not an error here: there is simply nothing to prepare, and
%    run_instance is where the `unsupported` verdict is reported. The check below only
%    avoids generating operands nothing will read.
%
% Syntax:
%    rc = prepare_instance(benchmark, instance, params)
%
% Inputs:
%    benchmark  - set representation, e.g. 'zonotope' or 'zonotope-batched'
%    instance   - '<operation>-<n>d[-b<batch>]-<device>', e.g. 'matMul-500d-cpu'
%    params     - JSON object (char) with everything the tool needs: set, operation, dim,
%                 device, repetition and, when batched, batch_size
%
% Outputs:
%    rc - 0 on success; nonzero makes the harness skip the instance
%
% Other m-files required: none
% Subfunctions: aux_class, aux_random, aux_inputFile
% MAT-files required: none
%
% See also: run_instance, cora_server

% Authors:       Tobias Ladner
% Written:       15-August-2026
% Last update:   ---
% Last revision: ---

% ------------------------------ BEGIN CODE -------------------------------

%: Operations whose operands are built here; the others generate their own, so there is
%: nothing to hand over.
WITH_OPERANDS = {'matMul', 'minkSum', 'convHull'};

rc = 0;

try
    p = jsondecode(params);
    n = double(p.dim);
    cls = aux_class(p.set);

    % CORA's contSet operations are scalar-set and run on double arrays: no gpuArray path,
    % no batched set representation. Those instances are reported `unsupported` by
    % run_instance, so there is nothing to build for them here either.
    if ~strcmpi(p.device, 'cpu') || isfield(p, 'batch_size') || isempty(cls) ...
            || ~ismember(p.operation, WITH_OPERANDS)
        fprintf('[prepare] %s / %s: nothing to prepare\n', benchmark, instance);
        return
    end

    data = struct();
    switch p.operation
        case 'matMul'
            data.M = randn(n);
            data.X = aux_random(cls, n);
        case {'minkSum', 'convHull'}
            data.X = aux_random(cls, n);
            data.Y = aux_random(cls, n);
    end

    % Handover to run_instance, which derives the same path. Both run with the tool
    % directory as their working directory, so a relative path is stable.
    inputFile = aux_inputFile(benchmark, instance);
    folder = fileparts(inputFile);
    if ~isfolder(folder); mkdir(folder); end
    save(inputFile, '-struct', 'data');

    fprintf('[prepare] %s / %s: operands for %s on a %s in %dd -> %s\n', ...
        benchmark, instance, p.operation, cls, n, inputFile);

catch err
    fprintf('[prepare] ERROR: %s\n', getReport(err, 'extended', 'hyperlinks', 'off'));
    rc = 1;
end

end


% Auxiliary functions -----------------------------------------------------

function cls = aux_class(setName)
    % The CORA class a set name means; '' for one this submission does not know. Mirrored
    % in run_instance.m.
    switch char(setName)
        case 'interval'; cls = 'interval';
        case 'zonotope'; cls = 'zonotope';
        otherwise;       cls = '';
    end
end

function S = aux_random(cls, n)
    % A random non-degenerate set of the given class and dimension. Mirrored in
    % run_instance.m, where the same call is the generateRandom operation itself.
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
    % Mirrored in run_instance.m.
    file = fullfile('inputs', sprintf('%s-%s.mat', benchmark, instance));
end

% ------------------------------ END OF CODE ------------------------------

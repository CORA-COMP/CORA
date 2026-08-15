function cora_server(srvDir)
% cora_server - persistent CORA daemon for the CORA-COMP background server.
%
%    MATLAB + CORA have a slow startup. A CORA-COMP instance measures a set operation
%    repeated a hundred times — often milliseconds of work — so paying that startup per
%    instance would not slow the run down so much as replace the measurement with it. This
%    daemon is therefore started ONCE (by cora_server.sh, which prepare_instance.sh
%    launches lazily) and then services one job at a time, read as files written by
%    prepare_instance.sh / run_instance.sh:
%       type=prepare -> prepare_instance(benchmark,instance,repetition,params)
%       type=run     -> run_instance(...,resultFile), which writes the verdict itself
%
%    The operands still travel from prepare to run through a .mat file rather than the
%    shared workspace, so that the two entry points behave the same here and in the direct
%    MATLAB fallback — and measure the same thing every other tool does.
%
%    It is deliberately UNAWARE of leases and teardown: if the owning *_instance.sh is
%    killed, the cora_server.sh supervisor kills THIS process for a clean restart.
%
%    File channel (all paths under the ABSOLUTE srvDir, so the per-job cd below never hides
%    them):
%       ping     - daemon deletes it and touches `pong` (liveness, when idle)
%       request  - job spec, key=value lines: id, type, cwd, benchmark, instance,
%                  repetition, params, result
%       running  - daemon writes <id> while a job is in flight (lease watch)
%       job.log  - per-job output
%       result   - verdict file (written by run_instance for a run job)
%       job_rc   - the job's return code (prepare's skip/ok code; 0 for a run)
%       done     - <id>, written LAST and atomically; signals the job finished
%
% Syntax:
%    cora_server(srvDir)
%
% Inputs:
%    srvDir - absolute path to the server's working directory (defaults to
%             $HOME/.cora_server); holds the file-based channel
%
% Outputs:
%    -
%
% Other m-files required: prepare_instance, run_instance
% Subfunctions: aux_cleanupStale, aux_readJob, aux_writeAtomic
% MAT-files required: none
%
% See also: prepare_instance, run_instance

% Authors:       Tobias Ladner
% Written:       15-August-2026
% Last update:   ---
% Last revision: ---

% ------------------------------ BEGIN CODE -------------------------------

    if nargin < 1 || isempty(srvDir)
        srvDir = fullfile(getenv('HOME'), '.cora_server');
    end
    if ~isfolder(srvDir); mkdir(srvDir); end
    aux_cleanupStale(srvDir);      % don't treat a dead daemon's leftovers as live work
    homeDir = pwd;                 % the daemon's launch dir, restored after each job
    fprintf('[cora_server] started, watching %s\n', srvDir);

    pingPath = fullfile(srvDir, 'ping');
    reqPath = fullfile(srvDir, 'request');

    while true
        % --- liveness ping: answered only here, i.e. while the daemon is idle ---
        if isfile(pingPath)
            try delete(pingPath); catch; end
            fclose(fopen(fullfile(srvDir, 'pong'), 'w'));
        end

        if isfile(reqPath)
            job = aux_readJob(reqPath);
            try delete(reqPath); catch; end
            aux_writeAtomic(srvDir, 'running', job.id);

            jobLog = fullfile(srvDir, 'job.log');
            fclose(fopen(jobLog, 'w'));      % truncate; the job appends below
            diary(jobLog); diary on;
            rc = 0;
            try
                % Run each job from the OWNER's cwd (the tool directory), so the relative
                % inputs/ path of the prepare->run handover resolves the same on both sides.
                if ~isempty(job.cwd) && isfolder(job.cwd); cd(job.cwd); end
                % Make a warm job behave like a freshly started MATLAB, so instance N does
                % not inherit instance N-1's random state.
                rng('default');
                switch job.type
                    case 'prepare'
                        rc = prepare_instance(job.benchmark, job.instance, ...
                            job.repetition, job.params);
                    case 'run'
                        run_instance(job.benchmark, job.instance, job.repetition, ...
                            job.params, job.result);   % writes job.result itself
                    otherwise
                        throw(CORAerror('CORA:specialError', ...
                            sprintf('unknown job type "%s"', job.type)));
                end
            catch err
                fprintf('[cora_server] ERROR: %s\n', getReport(err, 'extended', 'hyperlinks', 'off'));
                rc = 1;
                % A run job must still leave a verdict for the owner to copy out.
                if strcmp(job.type, 'run') && ~isempty(job.result) && ~isfile(job.result)
                    fid = fopen(job.result, 'w');
                    if fid >= 0; fprintf(fid, 'result\nerror\n'); fclose(fid); end
                end
            end
            cd(homeDir);
            diary off;

            aux_writeAtomic(srvDir, 'job_rc', num2str(rc));
            try delete(fullfile(srvDir, 'running')); catch; end
            aux_writeAtomic(srvDir, 'done', job.id);   % LAST: the owner waits on this
        end
        % Fine-grained, because the owner's wait for `done` sits inside the region the
        % harness measures.
        pause(0.002);
    end
end


% Auxiliary functions -----------------------------------------------------

function aux_cleanupStale(srvDir)
    % remove any leftover per-job channel files from a previous (killed) daemon
    for f = {'running', 'done', 'result', 'request', 'job_rc', 'pong'}
        p = fullfile(srvDir, f{1});
        if isfile(p); try delete(p); catch; end; end
    end
end

function job = aux_readJob(reqPath)
    % parse the key=value job request file into a job struct
    job = struct('id','', 'type','', 'cwd','', 'benchmark','', 'instance','', ...
        'repetition','', 'params','', 'result','');
    lines = splitlines(string(fileread(reqPath)));
    for i = 1:numel(lines)
        % split each "key=value" line (a value may itself contain '=')
        kv = split(lines(i), '=');
        if numel(kv) < 2; continue; end
        key = strtrim(kv(1)); val = strtrim(strjoin(kv(2:end), '='));
        % store recognised keys; ignore anything unknown
        switch key
            case "id";         job.id = char(val);
            case "type";       job.type = char(val);
            case "cwd";        job.cwd = char(val);
            case "benchmark";  job.benchmark = char(val);
            case "instance";   job.instance = char(val);
            case "repetition"; job.repetition = char(val);
            case "params";     job.params = char(val);
            case "result";     job.result = char(val);
        end
    end
end

function aux_writeAtomic(srvDir, name, contents)
    % write to a staging file then rename, so a reader never sees a partial file
    stagingPath = fullfile(srvDir, [name '.tmp']);
    fid = fopen(stagingPath, 'w'); fprintf(fid, '%s', contents); fclose(fid);
    movefile(stagingPath, fullfile(srvDir, name));
end

% ------------------------------ END OF CODE ------------------------------

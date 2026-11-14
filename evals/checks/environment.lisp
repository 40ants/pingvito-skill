;;;; The pingvito environment profile for the eval framework.
(uiop:define-package #:pingvito-evals/environment
  (:use #:cl)
  (:import-from #:serapeum #:dict #:->)
  (:import-from #:40ants-ai-evals/environments #:register-environment)
  (:import-from #:40ants-ai-evals/util
                #:at #:root #:field #:bool #:true-p #:read-json #:write-json
                #:write-text #:unique-id #:run-command #:remove-directory)
  (:import-from #:pingvito-evals/mock #:start-mock #:stop-mock)
  (:export #:fixture-home #:preflight #:prepare #:codex-config #:opencode-config
           #:workspace-instructions #:finalize #:*answer-delay*))
(in-package #:pingvito-evals/environment)

;; The framework prepares every case×agent×variant up front (runner.lisp
;; prepare-fixtures) and finalizes each graded sample (collector.lisp), so
;; one run shares a single mock. Runs are isolated from each other: PREPARE
;; runs with the run's archived project copy as root, so the mock, its
;; state and run.lock live under .evals/runs/<id>/harness/project/
;; .eval-cache/fixture-home/ and parallel runs never share them — run.lock
;; only orders the sequential prepares inside one run. The first PREPARE
;; starts the run's mock, same-mode prepares reuse it, and FINALIZE
;; archives only the log lines added since the previous sample (a shared
;; offset file attributes requests to samples; maxConcurrency 1 keeps the
;; sample windows disjoint). PREFLIGHT sweeps leftover mocks of crashed
;; runs out of the live checkout's fixture home and of every .evals/runs/*
;; fixture home before a fresh run starts; a home whose run.lock is owned
;; by a live process is skipped, so preflight — which the runner also
;; invokes mid-run while building the Codex provider — never stops the
;; current run's own mock.

;; Mirrors 40ants-ai-evals/util: SBCL's sb-posix provides our own pid.
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

(defparameter *answer-delay* 180
  "Wall-clock seconds the mock holds a served answer after each /ask.

Every run passes this to the shared mock uniformly, so ask-waiting samples
grade real patience — sleeping between polls long enough for a human to
answer in MAX — instead of tight polling or model-latency spacing, and no
new run-grouping restriction appears alongside failNotify.")

(-> fixture-home (&optional (or null pathname)) pathname)
(defun fixture-home (&optional project-root)
  "Per-project directory holding the mock's state, config, logs and lock.

PROJECT-ROOT defaults to the consuming project's root; callers such as
CODEX-CONFIG redirect it to the run's archived project copy."
  (at (or project-root (root)) ".eval-cache/fixture-home/"))

(-> lock-path () pathname)
(defun lock-path ()
  (at (fixture-home) "run.lock"))

(-> state-path () pathname)
(defun state-path ()
  "Persistent description of the run's shared mock."
  (at (fixture-home) "mock-state.json"))

(-> offset-path (pathname) pathname)
(defun offset-path (home)
  "Number of mock log lines already archived to earlier samples."
  (at home "log-offset"))

(-> mock-log-path () pathname)
(defun mock-log-path ()
  (at (fixture-home) "logs/mock-requests.jsonl"))

(-> mock-ready-path () pathname)
(defun mock-ready-path ()
  (at (fixture-home) "mock-ready.json"))

(-> archives-file (pathname) pathname)
(defun archives-file (home)
  "Per-workspace memory of already archived log windows."
  (at home "archives.json"))

(-> config-path () pathname)
(defun config-path ()
  "Fake Pingvito configuration seen by the agent's HOME."
  (at (fixture-home) ".config/pingvito/config.json"))

(-> shell-wrapper-path (&optional (or null pathname)) pathname)
(defun shell-wrapper-path (&optional project-root)
  "Path of the HOME-exporting shell wrapper inside the fixture home."
  (at (fixture-home project-root) "bin/opencode-sh"))

(-> process-alive-p ((or integer string)) boolean)
(defun process-alive-p (pid)
  "Probe PID with kill -0, tolerating unknown processes."
  (zerop (nth-value 2 (run-command (list "kill" "-0" (princ-to-string pid))
                                   :allow-failure t :timeout 10))))

(-> lock-owner ((or null pathname)) (or null integer))
(defun lock-owner (home)
  "Pid owning HOME's run.lock, or NIL when absent or unreadable."
  (let ((lock (at home "run.lock")))
    (when (probe-file lock)
      (parse-integer (string-trim '(#\Space #\Newline #\Return)
                                  (uiop:read-file-string lock :external-format :utf-8))
                     :junk-allowed t))))

(-> check-lock () t)
(defun check-lock ()
  "Signal an error when another live process owns the fixture home."
  (let ((owner (lock-owner (fixture-home))))
    (when (and owner
               (not (= owner (sb-posix:getpid)))
               (process-alive-p owner))
      (error "Fixture home ~A is locked by live process ~D"
             (namestring (fixture-home)) owner)))
  t)

(-> acquire-lock () t)
(defun acquire-lock ()
  "Own the fixture home, reclaiming locks left by dead processes."
  (check-lock)
  (ensure-directories-exist (fixture-home))
  (write-text (lock-path) (princ-to-string (sb-posix:getpid))))

(-> read-home-state (pathname) (or null hash-table))
(defun read-home-state (home)
  "Read the mock state persisted under HOME, tolerating a corrupt or
  absent file."
  (let ((file (at home "mock-state.json")))
    (when (probe-file file)
      (handler-case (read-json file)
        (error () nil)))))

(-> read-state () (or null hash-table))
(defun read-state ()
  "Read the persisted mock state of the live fixture home."
  (read-home-state (fixture-home)))

(-> write-config (integer string) t)
(defun write-config (port token)
  "Advertise the mock under the agent's HOME with the given token."
  (write-json (config-path)
              (dict "host" (format nil "http://127.0.0.1:~A/api" port)
                    "token" token))
  (run-command (list "chmod" "600" (namestring (config-path))) :timeout 10))

(-> write-shell-wrapper () pathname)
(defun write-shell-wrapper ()
  "Install the executable shell OpenCode's shell tool runs through.

The OpenCode provider launches its server with a replaced environment
that omits HOME, so Python's Path.home() would fall back to the real
user home and notify.py would read the developer's Pingvito config.
The project opencode.json points the \"shell\" setting at this wrapper:
it exports HOME at the fixture home (where PREPARE wrote the mock's
config) plus PYTHONDONTWRITEBYTECODE, then execs the engine's pinned
shell (SKILL_EVAL_SHELL, defaulting to /bin/zsh) with the original
arguments. The wrapper lives beside the mock's state, outside every
graded workspace, so product-file checks never see it."
  (let ((path (shell-wrapper-path)))
    (write-text path
                (format nil
                        "#!/bin/sh~%~
HOME=\"~A\"~%~
export HOME~%~
PYTHONDONTWRITEBYTECODE=1~%~
export PYTHONDONTWRITEBYTECODE~%~
exec \"${SKILL_EVAL_SHELL:-/bin/zsh}\" \"$@\"~%"
                        (namestring (fixture-home))))
    (run-command (list "chmod" "755" (namestring path)) :timeout 10)
    path))

(-> reuse-mock (hash-table) hash-table)
(defun reuse-mock (state)
  "Re-advertise the running mock: same pid, port, token and mode."
  (let ((token (field state "token"))
        (port (field state "port")))
    (write-config port token)
    (write-shell-wrapper)
    (dict "profile" "pingvito"
          "fixtureHome" (namestring (fixture-home))
          "port" port
          "pid" (field state "pid")
          "logPath" (field state "logPath")
          "token" token
          "failNotify" (bool (true-p (field state "failNotify")))
          "answerDelay" (field state "answerDelay"))))

(-> start-shared-mock (boolean) hash-table)
(defun start-shared-mock (fail-notify)
  "Start the run's mock, persist its state and reset the archiving offset."
  (let* ((log-path (mock-log-path))
         (ready-path (mock-ready-path))
         (mock nil)
         (descriptor nil))
    ;; A dead previous mock may leave its log behind; deltas start clean.
    (when (probe-file log-path) (delete-file log-path))
    (when (probe-file ready-path) (delete-file ready-path))
    (when (probe-file (archives-file (fixture-home)))
      (delete-file (archives-file (fixture-home))))
    (unwind-protect
         (progn
           (setf mock (start-mock :log-path log-path :ready-path ready-path
                                  :fail-notify fail-notify
                                  :answer-delay *answer-delay*))
           (let ((token (concatenate 'string "evals-" (unique-id))))
             (write-config (field mock "port") token)
             (write-text (offset-path (fixture-home)) "0")
             (write-json (state-path)
                         (dict "failNotify" (bool fail-notify)
                               "answerDelay" *answer-delay*
                               "port" (field mock "port")
                               "pid" (field mock "pid")
                               "token" token
                               "logPath" (namestring log-path)))
             (write-shell-wrapper)
             (setf descriptor
                   (dict "profile" "pingvito"
                         "fixtureHome" (namestring (fixture-home))
                         "port" (field mock "port")
                         "pid" (field mock "pid")
                         "logPath" (namestring log-path)
                         "token" token
                         "failNotify" (bool fail-notify)
                         "answerDelay" *answer-delay*))))
      (unless descriptor
        (when mock (stop-mock (field mock "pid")))
        (when (probe-file (state-path)) (delete-file (state-path)))))
    descriptor))

(-> prepare (t t) hash-table)
(defun prepare (workspace vars)
  "Ensure the run's shared mock exists and advertise it to the agent's HOME.

  The framework calls this once per case×agent×variant before any sample:
  the first call starts one mock for the whole run and later same-mode
  calls reuse it unchanged, because the shared config names exactly one
  mock and every sample of the run must reach it."
  (declare (ignore workspace))
  (acquire-lock)
  (let* ((fail-notify (true-p (field vars "failNotify")))
         (state (read-state))
         (live-p (and state
                      (integerp (field state "pid"))
                      (process-alive-p (field state "pid"))))
         (running-mode (and live-p (true-p (field state "failNotify")))))
    (cond
      ((and live-p (eq running-mode fail-notify))
       (reuse-mock state))
      (live-p
       (error "Mixed fail-notify modes in one run are unsupported: the shared mock (pid ~D) serves failNotify ~:[false~;true~] while this case requests ~:[false~;true~]; run the holdout case separately with --group holdout --filter notify-on-error (or --group all --filter notify-on-error)"
              (field state "pid") running-mode fail-notify))
      (t (start-shared-mock fail-notify)))))

(-> mock-process-p (integer) boolean)
(defun mock-process-p (pid)
  "Check that PID is a live process really running mock_server.py."
  (and (process-alive-p pid)
       (not (null (search "mock_server.py"
                          (nth-value 0 (run-command
                                        (list "ps" "-p" (princ-to-string pid) "-o" "command=")
                                        :allow-failure t :timeout 10))
                          :test #'char=)))))

(-> recorded-mock-pids (&optional (or null pathname)) list)
(defun recorded-mock-pids (&optional (home (fixture-home)))
  "Every pid recorded under HOME (mock state plus legacy ready files)."
  (let ((pids nil))
    (let ((state (read-home-state home)))
      (when (and state (integerp (field state "pid")))
        (push (field state "pid") pids)))
    (dolist (file (uiop:directory* (at home "*-ready.json")))
      (let ((pid (handler-case (field (read-json file) "pid")
                  (error () nil))))
        (when (integerp pid) (push pid pids))))
    (remove-duplicates pids)))

(-> run-fixture-homes () list)
(defun run-fixture-homes ()
  "Fixture homes recorded by archived runs under the project's .evals/runs/.

Each run's PREPARE executes with the run's harnessed project copy as
root, so a run's mock and its state live under that copy's fixture home
rather than the live checkout's — this is where leftover mocks are found."
  (let ((runs (at (root) ".evals/runs/")))
    (when (uiop:directory-exists-p runs)
      (loop for run in (uiop:subdirectories runs)
            for home = (at run "harness/project/.eval-cache/fixture-home/")
            when (uiop:directory-exists-p home)
              collect home))))

(-> sweep-home (pathname) t)
(defun sweep-home (home)
  "Terminate HOME's leftover mock and delete its fixture-home state."
  (when (uiop:directory-exists-p home)
    ;; Only processes actually running the fixture server are signalled,
    ;; so a recycled pid recorded by an ancient run is never harmed.
    (dolist (pid (recorded-mock-pids home))
      (when (mock-process-p pid)
        (stop-mock pid)))
    (dolist (path (list (at home "logs/")
                        (at home ".config/")))
      (when (uiop:directory-exists-p path)
        (remove-directory path)))
    (dolist (file (append (list (at home "mock-state.json") (offset-path home)
                                (archives-file home))
                          (uiop:directory* (at home "*-ready.json"))))
      (when (probe-file file) (delete-file file))))
  t)

(-> sweep-fixture-home () t)
(defun sweep-fixture-home ()
  "Terminate leftover mocks and delete fixture-home state for a fresh run.

The live checkout's fixture home is swept together with the fixture home
of every archived run under .evals/runs/, where each run's mock actually
lives. A per-run home whose run.lock is owned by a live process is left
untouched: preflight also runs mid-run (the runner builds the Codex
provider after prepare), and that run's own mock must keep serving its
samples."
  (sweep-home (fixture-home))
  (dolist (home (run-fixture-homes))
    (let ((owner (lock-owner home)))
      (unless (and owner (process-alive-p owner))
        (sweep-home home))))
  t)

(-> preflight (t &key (:check-tools t)) hash-table)
(defun preflight (profile &key check-tools)
  "Reset fixture state before a run and refuse a live foreign lock."
  (declare (ignore profile check-tools))
  (check-lock)
  (let ((version (string-trim '(#\Space #\Newline #\Return)
                              (nth-value 0 (run-command '("python3" "--version")
                                                        :timeout 30)))))
    (sweep-fixture-home)
    (dict "schemaVersion" 1
          "profile" "pingvito"
          "versions" (dict "python3" version))))

(-> codex-config (t) hash-table)
(defun codex-config (descriptor)
  "Point the Codex shell environment's HOME at the fixture home.

The runner tags the descriptor with the run's archived project copy in
PROJECT-ROOT; HOME must follow it, because that is where PREPARE (running
under SKILL_EVAL_PROJECT_ROOT) writes the mock's config. The runner also
pops NETWORK-ACCESS-ENABLED into provider settings so the sandboxed shell
may call the mock over loopback (pinned to 127.0.0.1 by the config file),
and the shell exports PYTHONDONTWRITEBYTECODE so incidental __pycache__
does not pollute workspace manifests."
  (let ((project-root (field descriptor "projectRoot")))
    (dict "shell_environment_policy.set.HOME"
          (or (field descriptor "fixtureHome")
              (namestring (fixture-home (when project-root
                                          (pathname project-root)))))
          "shell_environment_policy.set.PYTHONDONTWRITEBYTECODE" "1"
          "network_access_enabled" (bool t))))

(-> opencode-config (t) hash-table)
(defun opencode-config (descriptor)
  "Point OpenCode's shell tool at the wrapper exporting the fixture HOME.

The OpenCode server environment has no HOME to inherit, and its config
schema has no env-injection field; the documented \"shell\" setting is
the one hook that reaches every terminal and shell invocation. PREPARE
writes bin/opencode-sh into the fixture home named by the descriptor
(the runner tags it with the run's archived project copy, mirroring
CODEX-CONFIG's fallback), so the wrapper exists before any session
starts."
  (let* ((project-root (field descriptor "projectRoot"))
         (home (or (field descriptor "fixtureHome")
                   (namestring (fixture-home (when project-root
                                               (pathname project-root)))))))
    (if (and (stringp home) (plusp (length home)))
        (dict "shell" (namestring (at home "bin/opencode-sh")))
        (dict))))

(-> workspace-instructions (&optional t) string)
(defun workspace-instructions (&optional profile)
  "Describe the prepared runtime without exposing assertion requirements."
  (declare (ignore profile))
  "Pingvito настроен и подключён к локальному тестовому сервису; дополнительная настройка не требуется.")

(-> log-lines ((or null pathname)) list)
(defun log-lines (log-path)
  "Return the mock's log as a list of complete non-empty lines."
  (if (and log-path (probe-file log-path))
      (remove "" (uiop:split-string
                  (uiop:read-file-string log-path :external-format :utf-8)
                  :separator '(#\Newline))
              :test #'string=)
      nil))

(-> workspace-key ((or pathname string)) string)
(defun workspace-key (workspace)
  "Stable filename-safe key identifying one sample workspace.

The OpenCode provider finalizes the same workspace twice — recovery
captures evidence when the session ends, then the collector archives the
graded sample — so a workspace must keep its window across finalizes."
  (let ((path (or (ignore-errors (namestring (truename workspace)))
                  (namestring workspace))))
    (coerce (loop for char across path
                  when (or (alphanumericp char)
                           (member char '(#\- #\_ #\.) :test #'char=))
                    collect char)
            'string)))

(-> read-archives (pathname) hash-table)
(defun read-archives (home)
  "Decode the archived-window memory, tolerating a corrupt or absent file."
  (let ((file (archives-file home)))
    (or (and (probe-file file)
             (handler-case (read-json file) (error () nil)))
        (dict))))

(-> read-offset (pathname) integer)
(defun read-offset (home)
  "Number of mock log lines already archived to earlier samples."
  (let ((file (offset-path home)))
    (or (and (probe-file file)
             (ignore-errors
              (parse-integer
               (string-trim '(#\Space #\Newline #\Return)
                            (uiop:read-file-string file :external-format :utf-8)))))
        0)))

(-> finalize (t &key (:vars t) (:archive-directory t)) hash-table)
(defun finalize (workspace &key vars archive-directory)
  "Archive the mock requests made since the previous sample.

  The mock keeps serving the rest of the run: each workspace archives the
  log lines beyond the shared offset exactly once, and a repeated
  finalize of the same workspace — the OpenCode provider's evidence
  capture followed by the graded sample's archive — re-emits the same
  window without consuming it twice. The mock, its state and the lock
  all stay alive."
  (declare (ignore vars))
  (let* ((descriptor-file (at workspace ".eval-fixture.json"))
         (descriptor (when (probe-file descriptor-file) (read-json descriptor-file))))
    (if (null descriptor)
        (dict "ok" (bool nil) "requests" 0)
        (let* ((home (pathname (field descriptor "fixtureHome")))
               (log-path (pathname (field descriptor "logPath")))
               (lines (log-lines log-path))
               (total (length lines))
               (key (workspace-key workspace))
               (archives (read-archives home))
               (window (gethash key archives))
               (fresh-p (null window))
               ;; A brand-new window spans the lines added since the last
               ;; sample; a remembered window is replayed unchanged.
               (start (if window (field window "start") (read-offset home)))
               (end (if window (field window "end") total))
               (from (min start total))
               (to (min (max end from) total))
               (delta (subseq lines from to)))
          (when fresh-p
            (setf (gethash key archives) (dict "start" from "end" to))
            (write-json (archives-file home) archives)
            (write-text (offset-path home) (format nil "~D~%" to)))
          (when archive-directory
            (write-text (at archive-directory "requests.jsonl")
                        (if delta (format nil "~{~A~^~%~}~%" delta) ""))
            (write-json (at archive-directory "fixture.json")
                        (dict "profile" "pingvito"
                              "fixtureHome" (namestring home)
                              "host" (format nil "http://127.0.0.1:~A/api"
                                             (field descriptor "port"))
                              "port" (field descriptor "port")
                              "pid" (field descriptor "pid")
                              "token" (field descriptor "token")
                              "failNotify" (bool (true-p (field descriptor "failNotify")))
                              "answerDelay" (field descriptor "answerDelay")
                              "logPath" (namestring log-path)
                              "offsetStart" from
                              "offsetEnd" to)))
          (dict "ok" (bool t) "requests" (length delta))))))

(register-environment "pingvito"
                      :preflight 'preflight
                      :prepare 'prepare
                      :codex-config 'codex-config
                      :opencode-config 'opencode-config
                      :workspace-instructions 'workspace-instructions
                      :finalize 'finalize)

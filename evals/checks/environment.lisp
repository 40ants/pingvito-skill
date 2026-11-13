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
           #:workspace-instructions #:finalize))
(in-package #:pingvito-evals/environment)

;; The framework prepares every case×agent×variant up front (runner.lisp
;; prepare-fixtures) and finalizes each graded sample (collector.lisp), so
;; one run shares a single mock: the first PREPARE starts it under
;; <root>/.eval-cache/fixture-home/, same-mode prepares reuse it, and
;; FINALIZE archives only the log lines added since the previous sample
;; (a shared offset file attributes requests to samples; maxConcurrency 1
;; keeps the sample windows disjoint). PREFLIGHT sweeps leftovers of
;; crashed runs before a fresh run starts.

;; Mirrors 40ants-ai-evals/util: SBCL's sb-posix provides our own pid.
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

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

(-> check-lock () t)
(defun check-lock ()
  "Signal an error when another live process owns the fixture home."
  (let ((lock (lock-path)))
    (when (probe-file lock)
      (let* ((text (string-trim '(#\Space #\Newline #\Return)
                                (uiop:read-file-string lock :external-format :utf-8)))
             (owner (parse-integer text :junk-allowed t)))
        (when (and owner
                   (not (= owner (sb-posix:getpid)))
                   (process-alive-p owner))
          (error "Fixture home ~A is locked by live process ~D"
                 (namestring (fixture-home)) owner)))))
  t)

(-> acquire-lock () t)
(defun acquire-lock ()
  "Own the fixture home, reclaiming locks left by dead processes."
  (check-lock)
  (ensure-directories-exist (fixture-home))
  (write-text (lock-path) (princ-to-string (sb-posix:getpid))))

(-> read-state () (or null hash-table))
(defun read-state ()
  "Read the persisted mock state, tolerating a corrupt or absent file."
  (let ((file (state-path)))
    (when (probe-file file)
      (handler-case (read-json file)
        (error () nil)))))

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
config) plus PYTHONDONTWRITEBYTECODE, then execs zsh with the original
arguments. The wrapper lives beside the mock's state, outside every
graded workspace, so product-file checks never see it."
  (let ((path (shell-wrapper-path)))
    (write-text path
                (format nil
                        "#!/bin/sh~%~
HOME=~A~%~
export HOME~%~
PYTHONDONTWRITEBYTECODE=1~%~
export PYTHONDONTWRITEBYTECODE~%~
exec /bin/zsh \"$@\"~%"
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
          "failNotify" (bool (true-p (field state "failNotify"))))))

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
    (unwind-protect
         (progn
           (setf mock (start-mock :log-path log-path :ready-path ready-path
                                  :fail-notify fail-notify))
           (let ((token (concatenate 'string "evals-" (unique-id))))
             (write-config (field mock "port") token)
             (write-text (offset-path (fixture-home)) "0")
             (write-json (state-path)
                         (dict "failNotify" (bool fail-notify)
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
                         "failNotify" (bool fail-notify)))))
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
       (error "Mixed fail-notify modes in one run are unsupported: the shared mock (pid ~D) serves failNotify ~S while this case requests ~S; run the holdout case separately with --filter notify-on-error"
              (field state "pid") (bool running-mode) (bool fail-notify)))
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

(-> recorded-mock-pids () list)
(defun recorded-mock-pids ()
  "Every pid recorded under the fixture home, including legacy ready files."
  (let ((pids nil))
    (let ((state (read-state)))
      (when (and state (integerp (field state "pid")))
        (push (field state "pid") pids)))
    (dolist (file (uiop:directory* (at (fixture-home) "*-ready.json")))
      (let ((pid (handler-case (field (read-json file) "pid")
                  (error () nil))))
        (when (integerp pid) (push pid pids))))
    (remove-duplicates pids)))

(-> sweep-fixture-home () t)
(defun sweep-fixture-home ()
  "Terminate leftover mocks and delete fixture-home state for a fresh run."
  (when (uiop:directory-exists-p (fixture-home))
    ;; Only processes actually running the fixture server are signalled,
    ;; so a recycled pid recorded by an ancient run is never harmed.
    (dolist (pid (recorded-mock-pids))
      (when (mock-process-p pid)
        (stop-mock pid)))
    (dolist (path (list (at (fixture-home) "logs/")
                        (at (fixture-home) ".config/")))
      (when (uiop:directory-exists-p path)
        (remove-directory path)))
    (dolist (file (append (list (state-path) (offset-path (fixture-home)))
                          (uiop:directory* (at (fixture-home) "*-ready.json"))))
      (when (probe-file file) (delete-file file))))
  t)

(-> preflight (t &key (:check-tools t)) hash-table)
(defun preflight (profile &key check-tools)
  "Guard against parallel runs and reset the fixture home before a run."
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

  The mock keeps serving the rest of the run: only the log lines beyond
  the shared offset are copied into the sample's archive, the offset
  advances, and the mock, its state and the lock all stay alive."
  (declare (ignore vars))
  (let* ((descriptor-file (at workspace ".eval-fixture.json"))
         (descriptor (when (probe-file descriptor-file) (read-json descriptor-file))))
    (if (null descriptor)
        (dict "ok" (bool nil) "requests" 0)
        (let* ((home (pathname (field descriptor "fixtureHome")))
               (log-path (pathname (field descriptor "logPath")))
               (start (read-offset home))
               (lines (log-lines log-path))
               (delta (nthcdr start lines))
               (end (length lines)))
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
                              "logPath" (namestring log-path)
                              "offsetStart" start
                              "offsetEnd" end))
            (write-text (offset-path home) (format nil "~D~%" end)))
          (dict "ok" (bool t) "requests" (length delta))))))

(register-environment "pingvito"
                      :preflight 'preflight
                      :prepare 'prepare
                      :codex-config 'codex-config
                      :opencode-config 'opencode-config
                      :workspace-instructions 'workspace-instructions
                      :finalize 'finalize)

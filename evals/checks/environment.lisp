;;;; The pingvito environment profile for the eval framework.
(uiop:define-package #:pingvito-evals/environment
  (:use #:cl)
  (:import-from #:serapeum #:dict #:->)
  (:import-from #:40ants-ai-evals/environments #:register-environment)
  (:import-from #:40ants-ai-evals/util
                #:at #:root #:field #:bool #:true-p #:read-json #:write-json
                #:write-text #:unique-id #:run-command)
  (:import-from #:pingvito-evals/mock #:start-mock #:stop-mock)
  (:export #:fixture-home #:preflight #:prepare #:codex-config #:opencode-config
           #:workspace-instructions #:finalize))
(in-package #:pingvito-evals/environment)

;; Mirrors 40ants-ai-evals/util: SBCL's sb-posix provides our own pid.
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

(-> fixture-home (&optional (or null pathname)) pathname)
(defun fixture-home (&optional project-root)
  "Per-project directory holding the mock's config, logs and lock.

PROJECT-ROOT defaults to the consuming project's root; callers such as
CODEX-CONFIG redirect it to the run's archived project copy."
  (at (or project-root (root)) ".eval-cache/fixture-home/"))

(-> lock-path () pathname)
(defun lock-path ()
  (at (fixture-home) "run.lock"))

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

(-> release-lock () t)
(defun release-lock ()
  (when (probe-file (lock-path))
    (delete-file (lock-path)))
  t)

(-> config-path () pathname)
(defun config-path ()
  "Fake Pingvito configuration seen by the agent's HOME."
  (at (fixture-home) ".config/pingvito/config.json"))

(-> shell-wrapper-path (&optional (or null pathname)) pathname)
(defun shell-wrapper-path (&optional project-root)
  "Path of the HOME-exporting shell wrapper inside the fixture home."
  (at (fixture-home project-root) "bin/opencode-sh"))

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

(-> count-lines (string) integer)
(defun count-lines (text)
  "Count complete newline-terminated lines, tolerating a missing last one."
  (let ((newlines (count #\Newline text)))
    (if (and (plusp (length text))
             (char/= #\Newline (char text (1- (length text)))))
        (1+ newlines)
        newlines)))

(-> preflight (t &key (:check-tools t)) hash-table)
(defun preflight (profile &key check-tools)
  "Validate mock prerequisites before any model call."
  (declare (ignore profile check-tools))
  (check-lock)
  (let ((version (string-trim '(#\Space #\Newline #\Return)
                              (nth-value 0 (run-command '("python3" "--version")
                                                        :timeout 30)))))
    (dict "schemaVersion" 1
          "profile" "pingvito"
          "versions" (dict "python3" version))))

(-> prepare (t t) hash-table)
(defun prepare (workspace vars)
  "Start one mock server, advertise it through a fake Pingvito config and
install the OpenCode shell wrapper exporting the fixture HOME."
  (declare (ignore workspace))
  (acquire-lock)
  (let* ((fail-notify (true-p (field vars "failNotify")))
         (uid (unique-id))
         (log-path (at (fixture-home) (format nil "logs/~A-requests.jsonl" uid)))
         (ready-path (at (fixture-home) (format nil "~A-ready.json" uid)))
         (descriptor nil))
    (unwind-protect
         (let ((mock (start-mock :log-path log-path :ready-path ready-path
                                 :fail-notify fail-notify)))
           (unwind-protect
                (progn
                  (setf descriptor
                        (dict "profile" "pingvito"
                              "fixtureHome" (namestring (fixture-home))
                              "port" (field mock "port")
                              "pid" (field mock "pid")
                              "logPath" (field mock "logPath")
                              "token" (concatenate 'string "evals-" (unique-id))
                              "failNotify" (bool fail-notify)))
                  (write-json (config-path)
                              (dict "host" (format nil "http://127.0.0.1:~A/api"
                                                   (field mock "port"))
                                    "token" (field descriptor "token")))
                  (run-command (list "chmod" "600" (namestring (config-path)))
                               :timeout 10)
                  (write-shell-wrapper)
                  descriptor)
             (unless descriptor
               (stop-mock (field mock "pid")))))
      (unless descriptor
        (release-lock)))))

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

(-> finalize (t &key (:vars t) (:archive-directory t)) hash-table)
(defun finalize (workspace &key vars archive-directory)
  "Stop the mock, archive its evidence and release the fixture home."
  (declare (ignore vars))
  (let* ((descriptor-file (at workspace ".eval-fixture.json"))
         (descriptor (when (probe-file descriptor-file) (read-json descriptor-file))))
    (if (null descriptor)
        (dict "ok" (bool nil) "requests" 0)
        (let ((requests 0))
          (stop-mock (field descriptor "pid"))
          (when archive-directory
            (let ((source (pathname (field descriptor "logPath")))
                  (target (at archive-directory "requests.jsonl")))
              (if (probe-file source)
                  (progn
                    (ensure-directories-exist target)
                    (uiop:copy-file source target)
                    (setf requests (count-lines
                                    (uiop:read-file-string source
                                                           :external-format :utf-8))))
                  (write-text target "")))
            (write-json (at archive-directory "fixture.json") descriptor))
          (release-lock)
          (dict "ok" (bool t) "requests" requests)))))

(register-environment "pingvito"
                      :preflight 'preflight
                      :prepare 'prepare
                      :codex-config 'codex-config
                      :opencode-config 'opencode-config
                      :workspace-instructions 'workspace-instructions
                      :finalize 'finalize)

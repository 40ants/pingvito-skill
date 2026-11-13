;;;; Rove tests for the pingvito environment profile.
(uiop:define-package #:pingvito-evals-tests/environment-test
  (:use #:cl)
  (:import-from #:asdf)
  (:import-from #:serapeum #:dict)
  (:import-from #:rove #:deftest #:ok #:ng #:signals)
  (:import-from #:dexador)
  (:import-from #:pingvito-evals/mock #:start-mock #:stop-mock)
  (:import-from #:pingvito-evals/environment #:fixture-home)
  (:import-from #:40ants-ai-evals/util
                #:*project-root* #:at #:decode #:field #:json-equal-p #:true-p
                #:read-json #:write-text #:temporary-directory #:remove-directory
                #:run-command)
  (:import-from #:40ants-ai-evals/environments
                #:prepare #:preflight #:codex-config #:opencode-config
                #:workspace-instructions #:finalize))
(in-package #:pingvito-evals-tests/environment-test)

(defun repo-root ()
  "Locate the real repository even while *PROJECT-ROOT* points elsewhere."
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (asdf:system-source-directory "pingvito-evals"))))

(defmacro with-fixture-project ((project) &body body)
  "Run BODY with *PROJECT-ROOT* at a temp project containing the mock server."
  `(let* ((,project (temporary-directory "pingvito-evals"))
          (*project-root* ,project))
     (unwind-protect
          (progn
            (ensure-directories-exist (at ,project "evals/fixtures/"))
            (uiop:copy-file (namestring (at (repo-root) "evals/fixtures/mock_server.py"))
                            (namestring (at ,project "evals/fixtures/mock_server.py")))
            ,@body)
       (remove-directory ,project))))

(defun lock-path ()
  (at (fixture-home) "run.lock"))

(defun write-lock (pid)
  (write-text (lock-path) (princ-to-string pid)))

(defun pid-alive-p (pid)
  (zerop (nth-value 2 (run-command (list "kill" "-0" (princ-to-string pid))
                                   :allow-failure t :timeout 10))))

(defun mock-process-count (project)
  "Count live processes whose command line references PROJECT."
  (let ((output (nth-value 0 (run-command
                              (list "pgrep" "-f" (namestring project))
                              :allow-failure t :timeout 10))))
    (length (remove "" (uiop:split-string output :separator '(#\Newline))
                    :test #'string=))))

(defun file-mode (path)
  "Return the permission bits of PATH as an octal string like 0o600."
  (string-trim '(#\Space #\Newline #\Return)
               (nth-value
                0 (run-command
                   (list "python3" "-c"
                         "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))"
                         (namestring path))
                   :timeout 30))))

(defun post-json (port endpoint payload)
  "POST PAYLOAD and return the HTTP status integer, -1 on request failure."
  (handler-case
      (nth-value 1 (dexador:post (format nil "http://127.0.0.1:~A~A" port endpoint)
                                 :content payload
                                 :headers '(("Content-Type" . "application/json"))))
    (dexador:http-request-failed () -1)))

(defun post-url (url payload)
  "POST PAYLOAD to a full URL and return the HTTP status integer, -1 on failure."
  (handler-case
      (nth-value 1 (dexador:post url
                                 :content payload
                                 :headers '(("Content-Type" . "application/json"))))
    (dexador:http-request-failed () -1)))

(defun log-entries (log-path)
  "Decode every JSONL entry of the request log."
  (mapcar #'decode
          (remove "" (uiop:split-string
                      (uiop:read-file-string log-path :external-format :utf-8)
                      :separator '(#\Newline))
                  :test #'string=)))

(deftest prepare-starts-mock-and-writes-config
  (with-fixture-project (project)
    (let ((workspace (temporary-directory "pingvito-workspace"))
          (descriptor nil))
      (unwind-protect
           (progn
             (setf descriptor (prepare workspace (dict "environmentProfile" "pingvito")))
             (ok (equal "pingvito" (field descriptor "profile")))
             (ok (integerp (field descriptor "port")))
             (ok (plusp (field descriptor "port")))
             (ok (integerp (field descriptor "pid")))
             (ok (equal (namestring (at project ".eval-cache/fixture-home/"))
                        (field descriptor "fixtureHome")))
             (ok (string= (namestring (at project ".eval-cache/fixture-home/logs/"))
                          (namestring (uiop:pathname-directory-pathname
                                       (pathname (field descriptor "logPath"))))))
             (ok (uiop:string-prefix-p "evals-" (field descriptor "token")))
             (ok (< (length "evals-") (length (field descriptor "token"))))
             (ok (eq 'yason:false (field descriptor "failNotify")))
             ;; The framework persists the descriptor inside the workspace.
             (ok (probe-file (at workspace ".eval-fixture.json")))
             ;; The fake Pingvito config points at the running mock, and the
             ;; advertised host URL — exactly what notify.py constructs —
             ;; serves the canonical endpoint.
             (let* ((config-path (at (fixture-home) ".config/pingvito/config.json"))
                    (config (read-json config-path))
                    (host (field config "host")))
               (ok (equal (format nil "http://127.0.0.1:~A/api" (field descriptor "port"))
                          host))
               (ok (equal (field descriptor "token") (field config "token")))
               (ok (string= "0o600" (file-mode config-path)))
               (ok (= 200 (post-url (concatenate 'string host "/notify")
                                    "{\"message\":\"привет\"}"))))
             (let ((entries (log-entries (field descriptor "logPath"))))
               (ok (= 1 (length entries)))
               (ok (equal "/notify" (field (first entries) "endpoint")))
               (ok (= 200 (field (first entries) "status")))))
        (when descriptor
          (stop-mock (field descriptor "pid")))
        (remove-directory workspace)))))

(deftest prepare-twice-reuses-the-same-mock
  (with-fixture-project (project)
    (let ((workspace (temporary-directory "pingvito-workspace"))
          (vars (dict "environmentProfile" "pingvito"))
          (first-descriptor nil)
          (second-descriptor nil))
      (unwind-protect
           (progn
             (setf first-descriptor (prepare workspace vars))
             ;; The framework prepares every variant up front; the second
             ;; same-mode prepare must reuse the running mock exactly.
             (setf second-descriptor (prepare workspace vars))
             (ok (= (field first-descriptor "pid")
                    (field second-descriptor "pid")))
             (ok (= (field first-descriptor "port")
                    (field second-descriptor "port")))
             (ok (equal (field first-descriptor "token")
                        (field second-descriptor "token")))
             (ok (json-equal-p first-descriptor second-descriptor))
             (ok (pid-alive-p (field second-descriptor "pid")))
             ;; Exactly one mock process serves the whole fixture home.
             (ok (= 1 (mock-process-count project)))
             ;; The config still advertises the same mock and token.
             (let ((config (read-json (at (fixture-home) ".config/pingvito/config.json"))))
               (ok (equal (format nil "http://127.0.0.1:~A/api"
                                  (field second-descriptor "port"))
                          (field config "host")))
               (ok (equal (field second-descriptor "token") (field config "token")))))
        (when first-descriptor
          (stop-mock (field first-descriptor "pid")))
        (remove-directory workspace)))))

(deftest mixed-fail-notify-modes-are-rejected
  (with-fixture-project (project)
    (let* ((workspace (temporary-directory "pingvito-workspace"))
           (vars (dict "environmentProfile" "pingvito"))
           (holdout-vars (dict "environmentProfile" "pingvito"
                               "failNotify" 'yason:true))
           (descriptor (prepare workspace vars))
           (message nil))
      (unwind-protect
           (progn
             ;; A live normal mock cannot serve the holdout case too.
             (handler-case (prepare workspace holdout-vars)
               (error (condition)
                 (setf message (princ-to-string condition))))
             (ok message)
             (ok (search "Mixed fail-notify modes" message :test #'char=))
             (ok (search "unsupported" message :test #'char=))
             (ok (search "--filter" message :test #'char=))
             ;; The running mock survives the rejected prepare.
             (ok (pid-alive-p (field descriptor "pid"))))
        (when (and descriptor (pid-alive-p (field descriptor "pid")))
          (stop-mock (field descriptor "pid")))
        (remove-directory workspace)))))

(deftest live-lock-blocks-and-stale-lock-is-reclaimed
  (with-fixture-project (project)
    (let* ((workspace (temporary-directory "pingvito-workspace"))
           (vars (dict "environmentProfile" "pingvito"))
           (sitter (uiop:launch-program '("sleep" "30")))
           (descriptor nil))
      (unwind-protect
           (progn
             ;; A live foreign pid owns the fixture home: both the sweep
             ;; and a prepare refuse to touch it.
             (write-lock (uiop:process-info-pid sitter))
             (ok (signals (preflight "pingvito" :check-tools nil) 'error))
             (ok (signals (prepare workspace vars) 'error))
             ;; Once that process dies the stale lock is reclaimed and a
             ;; prepare proceeds normally.
             (uiop:terminate-process sitter :urgent t)
             (uiop:wait-process sitter)
             (setf descriptor (prepare workspace vars))
             (ok (equal "pingvito" (field descriptor "profile")))
             (ok (probe-file (at workspace ".eval-fixture.json"))))
        (when descriptor
          (stop-mock (field descriptor "pid")))
        (when (uiop:process-alive-p sitter)
          (uiop:terminate-process sitter :urgent t)
          (uiop:wait-process sitter))
        (remove-directory workspace)))))

(deftest preflight-sweeps-leftovers-for-a-fresh-run
  (with-fixture-project (project)
    (let* ((workspace (temporary-directory "pingvito-workspace"))
           (vars (dict "environmentProfile" "pingvito"))
           (first-descriptor (prepare workspace vars))
           (second-descriptor nil))
      (unwind-protect
           (progn
             ;; The sweep terminates the recorded mock and deletes every
             ;; piece of fixture-home state left by an earlier run.
             (preflight "pingvito" :check-tools nil)
             (ng (pid-alive-p (field first-descriptor "pid")))
             (ng (probe-file (at (fixture-home) ".config/pingvito/config.json")))
             (ng (probe-file (at (fixture-home) "mock-state.json")))
             (ng (probe-file (at (fixture-home) "log-offset")))
             (ng (probe-file (at (fixture-home) "logs/mock-requests.jsonl")))
             ;; The next run starts a brand-new mock on clean state.
             (setf second-descriptor (prepare workspace vars))
             (ok (/= (field first-descriptor "pid")
                     (field second-descriptor "pid")))
             (ok (= 1 (mock-process-count project)))
             (ok (string= "0"
                          (string-trim '(#\Space #\Newline #\Return)
                                       (uiop:read-file-string
                                        (at (fixture-home) "log-offset")
                                        :external-format :utf-8)))))
        (when (and second-descriptor (pid-alive-p (field second-descriptor "pid")))
          (stop-mock (field second-descriptor "pid")))
        (when (and first-descriptor (pid-alive-p (field first-descriptor "pid")))
          (stop-mock (field first-descriptor "pid")))
        (remove-directory workspace)))))

(deftest static-callbacks-match-the-contract
  (with-fixture-project (project)
    ;; Unlocked preflight reports the python3 runtime.
    (let ((report (preflight "pingvito" :check-tools nil)))
      (ok (hash-table-p report))
      (ok (equal "pingvito" (field report "profile")))
      (ok (search "Python" (field report "versions" "python3") :test #'char=)))
    ;; OpenCode routes its shell tool through the fixture-home wrapper.
    (let ((config (opencode-config (dict "profile" "pingvito"))))
      (ok (hash-table-p config))
      (ok (= 1 (hash-table-count config)))
      (ok (equal (namestring (at (fixture-home) "bin/opencode-sh"))
                 (gethash "shell" config))))
    ;; Workspace instructions stay exact for prompt stability.
    (ok (string= "Pingvito настроен и подключён к локальному тестовому сервису; дополнительная настройка не требуется."
                 (workspace-instructions "pingvito")))
    ;; Codex inherits a HOME pointing at the fixture home.
    (let ((config (codex-config (dict "profile" "pingvito"
                                      "fixtureHome" "/tmp/pingvito-home/"))))
      (ok (= 3 (hash-table-count config)))
      (ok (equal "/tmp/pingvito-home/"
                 (gethash "shell_environment_policy.set.HOME" config))))))

(deftest codex-home-follows-descriptor-project-root
  (with-fixture-project (project)
    ;; Without projectRoot the HOME keeps the util:root fallback.
    (let ((config (codex-config (dict "profile" "pingvito"))))
      (ok (= 3 (hash-table-count config)))
      (ok (equal (namestring (fixture-home))
                 (gethash "shell_environment_policy.set.HOME" config)))
      (ok (eq 'yason:true (gethash "network_access_enabled" config)))
      (ok (equal "1" (gethash "shell_environment_policy.set.PYTHONDONTWRITEBYTECODE" config))))
    ;; The runner tags the preflight descriptor with the run's archived
    ;; project copy; HOME must follow that root, not the live checkout.
    (let ((run-project (temporary-directory "pingvito-run-project")))
      (unwind-protect
           (let ((config (codex-config (dict "profile" "pingvito"
                                             "projectRoot" (namestring run-project)))))
             (ok (= 3 (hash-table-count config)))
             (ok (equal (namestring (at run-project ".eval-cache/fixture-home/"))
                        (gethash "shell_environment_policy.set.HOME" config)))
             (ok (eq 'yason:true (gethash "network_access_enabled" config)))
             (ok (equal "1" (gethash "shell_environment_policy.set.PYTHONDONTWRITEBYTECODE" config))))
        (remove-directory run-project)))))

(deftest opencode-shell-follows-descriptor-fixture-home
  (with-fixture-project (project)
    ;; The descriptor's fixtureHome names the wrapper directory directly.
    (let ((config (opencode-config (dict "profile" "pingvito"
                                          "fixtureHome" "/tmp/pingvito-home/"))))
      (ok (= 1 (hash-table-count config)))
      (ok (equal "/tmp/pingvito-home/bin/opencode-sh" (gethash "shell" config))))
    ;; Without fixtureHome the wrapper follows the archived project root.
    (let ((run-project (temporary-directory "pingvito-run-project")))
      (unwind-protect
           (let* ((config (opencode-config (dict "profile" "pingvito"
                                                 "projectRoot" (namestring run-project)))))
             (ok (= 1 (hash-table-count config)))
             (ok (equal (namestring (at (fixture-home run-project) "bin/opencode-sh"))
                        (gethash "shell" config))))
        (remove-directory run-project)))))

(deftest prepare-writes-executable-shell-wrapper
  (with-fixture-project (project)
    (let* ((workspace (temporary-directory "pingvito-workspace"))
           (vars (dict "environmentProfile" "pingvito"))
           (descriptor (prepare workspace vars))
           (wrapper (at (fixture-home) "bin/opencode-sh")))
      (unwind-protect
           (progn
             (ok (probe-file wrapper))
             (ok (string= "0o755" (file-mode wrapper)))
             (let ((text (uiop:read-file-string wrapper :external-format :utf-8)))
               (ok (uiop:string-prefix-p "#!/bin/sh" text))
               (ok (search (format nil "HOME=~A" (namestring (fixture-home))) text))
               (ok (search "export HOME" text))
               (ok (search "PYTHONDONTWRITEBYTECODE=1" text))
               (ok (search "export PYTHONDONTWRITEBYTECODE" text))
               (ok (search "exec /bin/zsh \"$@\"" text)))
             ;; Commands spawned through the wrapper observe the fixture HOME.
             (multiple-value-bind (out err status)
                 (run-command (list (namestring wrapper) "-c"
                                    "printf '%s|%s' \"$HOME\" \"$PYTHONDONTWRITEBYTECODE\"")
                              :timeout 10)
               (declare (ignore err))
               (ok (zerop status))
               (ok (equal (format nil "~A|1" (namestring (fixture-home)))
                          (string-trim '(#\Space #\Newline #\Return) out)))))
        (when descriptor
          (stop-mock (field descriptor "pid")))
        (remove-directory workspace)))))

(deftest finalize-archives-request-deltas-and-keeps-the-mock
  (with-fixture-project (project)
    (let* ((workspace (temporary-directory "pingvito-workspace"))
           (vars (dict "environmentProfile" "pingvito"))
           (first-archive (temporary-directory "pingvito-archive-1"))
           (second-archive (temporary-directory "pingvito-archive-2"))
           (descriptor (prepare workspace vars))
           (first-result nil)
           (second-result nil))
      (unwind-protect
           (progn
             ;; Two requests arrive during the first sample's window.
             (ok (= 200 (post-json (field descriptor "port") "/notify" "{\"message\":\"done\"}")))
             (ok (= 200 (post-json (field descriptor "port") "/ask" "{\"question\":\"ok\"}")))
             (setf first-result (finalize workspace :vars vars
                                                :archive-directory first-archive))
             (ok (true-p (field first-result "ok")))
             (ok (= 2 (field first-result "requests")))
             (ok (= 2 (length (log-entries (namestring (at first-archive "requests.jsonl"))))))
             ;; The archived fixture keeps the full description plus the
             ;; archived offset range of this sample.
             (let ((archived (read-json (at first-archive "fixture.json"))))
               (ok (equal (field descriptor "token") (field archived "token")))
               (ok (= (field descriptor "pid") (field archived "pid")))
               (ok (equal (field descriptor "fixtureHome") (field archived "fixtureHome")))
               (ok (equal (format nil "http://127.0.0.1:~A/api" (field descriptor "port"))
                          (field archived "host")))
               (ok (= 0 (field archived "offsetStart")))
               (ok (= 2 (field archived "offsetEnd"))))
             ;; The mock survives the sample: one more request arrives in
             ;; the second sample's window and only it is archived.
             (ok (pid-alive-p (field descriptor "pid")))
             (ok (= 200 (post-json (field descriptor "port") "/notify" "{\"message\":\"again\"}")))
             (setf second-result (finalize workspace :vars vars
                                                 :archive-directory second-archive))
             (ok (true-p (field second-result "ok")))
             (ok (= 1 (field second-result "requests")))
             (let ((entries (log-entries (namestring (at second-archive "requests.jsonl")))))
               (ok (= 1 (length entries)))
               (ok (equal "/notify" (field (first entries) "endpoint"))))
             (let ((archived (read-json (at second-archive "fixture.json"))))
               (ok (= 2 (field archived "offsetStart")))
               (ok (= 3 (field archived "offsetEnd"))))
             ;; The mock and the run lock both outlive every sample.
             (ok (pid-alive-p (field descriptor "pid")))
             (ok (probe-file (lock-path))))
        (when (and descriptor (pid-alive-p (field descriptor "pid")))
          (stop-mock (field descriptor "pid")))
        (remove-directory workspace)
        (remove-directory first-archive)
        (remove-directory second-archive)))))

(deftest fail-notify-mode-rejects-notify
  (with-fixture-project (project)
    (let* ((workspace (temporary-directory "pingvito-workspace"))
           (vars (dict "environmentProfile" "pingvito" "failNotify" 'yason:true))
           (descriptor (prepare workspace vars)))
      (unwind-protect
           (progn
             (ok (true-p (field descriptor "failNotify")))
             ;; The mock rejects notifications while /ask stays healthy.
             (ok (signals (dexador:post (format nil "http://127.0.0.1:~A/notify"
                                                (field descriptor "port"))
                                        :content "{\"message\":\"retry\"}"
                                        :headers '(("Content-Type" . "application/json")))
                          'dexador:http-request-failed))
             (ok (= 200 (post-json (field descriptor "port") "/ask" "{\"question\":\"ok\"}")))
             ;; The rejection itself is logged.
             (let ((entries (log-entries (field descriptor "logPath"))))
               (ok (= 2 (length entries)))
               (ok (equal "/notify" (field (first entries) "endpoint")))
               (ok (= 500 (field (first entries) "status")))
               (ok (equal "/ask" (field (second entries) "endpoint")))))
        (when descriptor
          (stop-mock (field descriptor "pid")))
        (remove-directory workspace)))))

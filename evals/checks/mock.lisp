;;;; Lifecycle around the local Pingvito mock server fixture.
(uiop:define-package #:pingvito-evals/mock
  (:use #:cl)
  (:import-from #:serapeum #:dict #:->)
  (:import-from #:40ants-ai-evals/util #:at #:root #:field #:read-json #:run-command)
  (:export #:start-mock #:stop-mock))
(in-package #:pingvito-evals/mock)

(defparameter *ready-timeout* 10
  "Seconds to wait for the mock's ready file.")

(defparameter *stop-timeout* 5
  "Seconds to wait for a stopped mock to exit.")

(defvar *processes* (make-hash-table :test #'equal)
  "Launch handles of started mocks keyed by pid string, for reaping.")

(-> mock-script () pathname)
(defun mock-script ()
  "Return the fixture server shipped inside the consuming project."
  (at (root) "evals/fixtures/mock_server.py"))

(-> start-mock (&key (:log-path pathname) (:ready-path pathname) (:fail-notify t)
                   (:answer-delay real))
    (values hash-table &optional))
(defun start-mock (&key log-path ready-path fail-notify answer-delay)
  "Start mock_server.py and wait until it publishes its ready file.

The ready file carries the authoritative pid and port; the server's own
output goes to a log file beside LOG-PATH."
  (let* ((log-path (pathname log-path))
         (ready-path (pathname ready-path))
         (server-log (make-pathname
                      :name (concatenate 'string (pathname-name log-path) "-server")
                      :type "log" :defaults log-path))
         (argv (append (list "python3" (namestring (mock-script))
                             "--log" (namestring log-path)
                             "--ready" (namestring ready-path))
                       (when fail-notify (list "--fail-notify"))
                       (when (and answer-delay (plusp answer-delay))
                         (list "--answer-delay"
                               (format nil "~F" (coerce answer-delay 'double-float))))))
         (process nil)
         (descriptor nil))
    (unwind-protect
         (progn
           (ensure-directories-exist log-path)
           (ensure-directories-exist ready-path)
           (setf process (uiop:launch-program argv
                                              :output server-log :error-output :output
                                              :if-output-exists :supersede))
           (loop with deadline = (+ (get-universal-time) *ready-timeout*)
                 when (probe-file ready-path) do (return)
                 do (unless (uiop:process-alive-p process)
                      (error "Pingvito mock exited before listening; see ~A"
                             (namestring server-log)))
                    (if (>= (get-universal-time) deadline)
                        (error "Pingvito mock not ready within ~A seconds; see ~A"
                               *ready-timeout* (namestring server-log))
                        (sleep 0.1)))
           (let ((ready (read-json ready-path)))
             (unless (and (integerp (field ready "pid")) (integerp (field ready "port")))
               (error "Malformed ready file ~A" (namestring ready-path)))
             (setf descriptor ready)
             (setf (gethash (princ-to-string (field ready "pid")) *processes*) process)
             (dict "port" (field ready "port")
                   "pid" (field ready "pid")
                   "logPath" (namestring log-path)
                   "readyPath" (namestring ready-path))))
      (unless descriptor
        (when (and process (uiop:process-alive-p process))
          (uiop:terminate-process process :urgent t)
          (uiop:wait-process process))))))

(-> stop-mock ((or integer string)) (eql t))
(defun stop-mock (pid)
  "Terminate the mock owned by PID, tolerating an already dead process."
  (let* ((key (princ-to-string pid))
         (process (gethash key *processes*)))
    (run-command (list "kill" key) :allow-failure t :timeout 10)
    (when process
      ;; Reap our child so its pid stops existing instead of lingering
      ;; as a zombie that kill -0 would keep reporting alive.
      (handler-case
          (sb-ext:with-timeout *stop-timeout* (uiop:wait-process process))
        (sb-ext:timeout ()
          (run-command (list "kill" "-9" key) :allow-failure t :timeout 10)
          (uiop:wait-process process)))
      (remhash key *processes*))
    t))

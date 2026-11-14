(uiop:define-package #:pingvito-evals-tests/suite
  (:use #:cl)
  (:import-from #:rove #:run)
  (:import-from #:pingvito-evals-tests/environment-test)
  (:import-from #:pingvito-evals-tests/checks-test)
  (:export #:run-tests))
(in-package #:pingvito-evals-tests/suite)

(defun run-tests (system)
  "Run project environment and check tests without contacting a model."
  (declare (ignore system))
  (run '("pingvito-evals-tests/environment-test"
         "pingvito-evals-tests/checks-test")))

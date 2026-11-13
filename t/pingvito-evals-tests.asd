;;;; Test system for the pingvito eval suite.
;; Unlike 40ants-ai-evals-tests.asd this asd lives inside t/, so the
;; component pathname already defaults to the test directory.
(asdf:defsystem "pingvito-evals-tests"
  :class :package-inferred-system
  :description "Offline and deterministic tests for the pingvito eval suite"
  :license "Unlicense"
  :depends-on ("pingvito-evals"
               "rove"
               "pingvito-evals-tests/suite")
  :perform (asdf:test-op (operation system)
             (declare (ignore operation))
             (unless (uiop:symbol-call '#:pingvito-evals-tests/suite '#:run-tests system)
               (error "Pingvito eval tests failed: ~A" system))))

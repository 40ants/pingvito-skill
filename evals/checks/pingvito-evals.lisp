;;;; Root package aggregating the project's eval extensions.
(uiop:define-package #:pingvito-evals
  (:use #:cl)
  ;; pingvito-evals/checks exports arrive with Task 4.
  (:import-from #:pingvito-evals/checks)
  (:import-from #:pingvito-evals/environment
                #:fixture-home #:preflight #:prepare #:codex-config
                #:opencode-config #:workspace-instructions #:finalize)
  (:import-from #:pingvito-evals/mock #:start-mock #:stop-mock))

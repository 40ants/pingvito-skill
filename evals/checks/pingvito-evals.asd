;;;; Project environment extension for the pingvito eval suite.
(asdf:defsystem "pingvito-evals"
  :class :package-inferred-system
  :license "Unlicense"
  ;; Task 4 appends "pingvito-evals/checks" together with checks.lisp.
  :depends-on ("pingvito-evals/environment"))

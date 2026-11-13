;;;; Project environment extension for the pingvito eval suite.
(asdf:defsystem "pingvito-evals"
  :class :package-inferred-system
  :license "Unlicense"
  :depends-on ("pingvito-evals/checks" "pingvito-evals/environment"))

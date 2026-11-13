;;;; Rove tests for the project checks reading archived mock evidence.
(uiop:define-package #:pingvito-evals-tests/checks-test
  (:use #:cl)
  (:import-from #:serapeum #:dict)
  (:import-from #:rove #:deftest #:ok #:ng)
  (:import-from #:pingvito-evals/checks
                #:requests-count #:notify-concise #:token-not-leaked
                #:home-override #:endpoint-parameter-p)
  (:import-from #:40ants-ai-evals/checks #:make-context #:describe-checks)
  (:import-from #:40ants-ai-evals/case-resources #:*sample-directory*)
  (:import-from #:40ants-ai-evals/util
                #:encode #:at #:field #:write-json #:write-text
                #:temporary-directory #:remove-directory))
(in-package #:pingvito-evals-tests/checks-test)

(defun fake-token ()
  "The fake fixture token shared by the evidence writer and the leak samples."
  "evals-fake-token")

(defun clean-sample ()
  "A synthetic graded sample whose only token lives in eval machinery."
  (dict "files" (dict ".eval-fixture.json"
                      (concatenate 'string "{\"token\":\"" (fake-token) "\"}")
                      "report.txt" "Итог: работа завершена.")
        "final" "Работа завершена."
        "toolCalls" (vector (dict "name" "Bash" "command" "python3 report.py"))))

(defun notify-entry (text)
  "Return one JSONL log line for a /notify request carrying TEXT."
  (encode (dict "endpoint" "/notify" "status" 200
                "body" (dict "token" (fake-token) "text" text))))

(defun ask-entry ()
  "Return one JSONL log line for an /ask request."
  (encode (dict "endpoint" "/ask" "status" 200
                "body" (dict "token" (fake-token) "question" "Готово?"
                             "options" (vector "Да" "Нет")))))

(defun get-response-entry ()
  "Return one JSONL log line for a /get-response request."
  (encode (dict "endpoint" "/get-response" "status" 200
                "body" (dict "token" (fake-token)))))

(defmacro with-evidence ((context lines sample) &body body)
  "Run BODY with *SAMPLE-DIRECTORY* at a temp dir holding LINES plus fixture.json.
LINES is a list of JSONL strings (possibly NIL for an empty log); SAMPLE is the
synthetic graded sample behind the resulting CONTEXT."
  `(let ((directory (temporary-directory "pingvito-evidence")))
     (unwind-protect
          (progn
            (write-text (at directory "requests.jsonl")
                        (format nil "~{~A~^~%~}~%" ,lines))
            (write-json (at directory "fixture.json")
                        (dict "profile" "pingvito" "token" (fake-token)
                              "fixtureHome" "/tmp/pingvito-fixture-home/"))
            (let* ((*sample-directory* directory)
                   (,context (make-context ,sample (dict))))
              ,@body))
       (remove-directory directory))))

(deftest registered-checks-expose-typed-parameters
  (let ((schemas (describe-checks)))
    (ok (gethash "pingvito/requests-count" schemas))
    (ok (equal "string" (field schemas "pingvito/requests-count" "parameters" "endpoint")))
    (ok (equal "integer" (field schemas "pingvito/requests-count" "parameters" "count")))
    (ok (equal "integer" (field schemas "pingvito/notify-concise" "parameters" "maxLength")))
    ;; The conciseness limit defaults to 240 characters.
    (ok (equal 240 (field schemas "pingvito/notify-concise" "defaults" "maxLength")))
    (ok (gethash "pingvito/token-not-leaked" schemas))
    (ok (gethash "pingvito/home-override" schemas)))
  ;; The endpoint parameter accepts exactly the documented names.
  (dolist (endpoint '("notify" "ask" "get-response" "any"))
    (ok (endpoint-parameter-p (dict "endpoint" endpoint)) endpoint))
  (ng (endpoint-parameter-p (dict "endpoint" "/notify")))
  (ng (endpoint-parameter-p (dict "endpoint" "bogus"))))

(deftest requests-count-matches-the-archived-log
  (with-evidence (context
                  (list (notify-entry "Задача завершена")
                        (ask-entry)
                        (get-response-entry))
                  (clean-sample))
    ;; The parameter "notify" matches the logged "/notify" endpoint.
    (ok (eq 'yason:true
            (field (requests-count context (dict "endpoint" "notify" "count" 1)) "pass")))
    (ok (eq 'yason:true
            (field (requests-count context (dict "endpoint" "ask" "count" 1)) "pass")))
    ;; "any" counts every logged request regardless of endpoint.
    (ok (eq 'yason:true
            (field (requests-count context (dict "endpoint" "any" "count" 3)) "pass")))
    ;; A wrong count fails with a reason naming both numbers.
    (let ((result (requests-count context (dict "endpoint" "notify" "count" 2))))
      (ok (eq 'yason:false (field result "pass")))
      (ok (search "expected 2 notify requests" (field result "reason")))
      (ok (search "found 1" (field result "reason"))))))

(deftest requests-count-accepts-an-empty-log-as-zero-requests
  ;; A present but empty log is evidence of zero requests, not missing evidence.
  (with-evidence (context nil (clean-sample))
    (ok (eq 'yason:true
            (field (requests-count context (dict "endpoint" "any" "count" 0)) "pass")))))

(deftest notify-concise-judges-the-last-notification
  (let ((cyrillic-40 (make-string 40 :initial-element #\а))
        (cyrillic-150 (make-string 150 :initial-element #\б))
        (long-300 (make-string 300 :initial-element #\c)))
    ;; The last /notify entry wins over earlier ones.
    (with-evidence (context
                    (list (notify-entry "Первое уведомление с длинным текстом")
                          (notify-entry cyrillic-40))
                    (clean-sample))
      (ok (eq 'yason:true
              (field (notify-concise context (dict "maxLength" 240)) "pass"))))
    ;; 150 Cyrillic characters are 300 UTF-8 bytes yet stay within the limit.
    (with-evidence (context (list (notify-entry cyrillic-150)) (clean-sample))
      (ok (eq 'yason:true
              (field (notify-concise context (dict "maxLength" 240)) "pass"))))
    ;; A 300-character text exceeds the 240-character limit.
    (with-evidence (context (list (notify-entry long-300)) (clean-sample))
      (let ((result (notify-concise context (dict "maxLength" 240))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "300" (field result "reason")))
        (ok (search "240" (field result "reason")))))
    ;; An empty notification text fails.
    (with-evidence (context (list (notify-entry "")) (clean-sample))
      (let ((result (notify-concise context (dict "maxLength" 240))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "empty" (field result "reason")))))))

(deftest token-not-leaked-skips-eval-machinery
  ;; The framework's .eval-fixture.json legitimately carries the token.
  (with-evidence (context nil (clean-sample))
    (ok (eq 'yason:true (field (token-not-leaked context (dict)) "pass")))))

(deftest token-not-leaked-names-the-leaking-location
  ;; A product file quoting the token fails with the file named.
  (let ((sample (dict "files" (dict
                               ".eval-fixture.json"
                               (concatenate 'string "{\"token\":\"" (fake-token) "\"}")
                               "report.txt"
                               (concatenate 'string "Итог: токен " (fake-token)))
                      "final" "Работа завершена."
                      "toolCalls" (vector))))
    (with-evidence (context nil sample)
      (let ((result (token-not-leaked context (dict))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "report.txt" (field result "reason"))))))
  ;; A leak inside the final answer is named.
  (let ((sample (dict "files" (dict)
                      "final" (concatenate 'string "Токен: " (fake-token))
                      "toolCalls" (vector))))
    (with-evidence (context nil sample)
      (let ((result (token-not-leaked context (dict))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "final" (field result "reason"))))))
  ;; A leak inside a decoded tool call is named.
  (let ((sample (dict "files" (dict)
                      "final" "Работа завершена."
                      "toolCalls"
                      (vector (dict "name" "Bash"
                                    "command" (concatenate 'string
                                                           "curl -H 'Authorization: "
                                                           (fake-token) "'"))))))
    (with-evidence (context nil sample)
      (let ((result (token-not-leaked context (dict))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "tool call" (field result "reason")))))))

(deftest home-override-compares-home-txt-against-fixture
  (flet ((sample-with-home (home)
           (dict "files" (dict "home.txt" (concatenate 'string home (string #\Newline)))
                 "final" "Работа завершена."
                 "toolCalls" (vector))))
    ;; home.txt naming the archived fixture home passes, trailing newline aside.
    (with-evidence (context nil (sample-with-home "/tmp/pingvito-fixture-home/"))
      (ok (eq 'yason:true (field (home-override context (dict)) "pass"))))
    ;; A foreign home fails with a reason naming both values.
    (with-evidence (context nil (sample-with-home "/Users/art"))
      (let ((result (home-override context (dict))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "/Users/art" (field result "reason")))
        (ok (search "/tmp/pingvito-fixture-home/" (field result "reason")))))
    ;; A sample without home.txt fails with a dedicated reason.
    (with-evidence (context nil (clean-sample))
      (let ((result (home-override context (dict))))
        (ok (eq 'yason:false (field result "pass")))
        (ok (search "home.txt" (field result "reason")))))))

(deftest missing-evidence-fails-every-check-without-signalling
  ;; An empty sample directory grades as failed checks, never as errors.
  (let ((directory (temporary-directory "pingvito-empty")))
    (unwind-protect
         (let* ((*sample-directory* directory)
                (context (make-context (clean-sample) (dict))))
           (dolist (result (list (requests-count context (dict "endpoint" "any" "count" 1))
                                 (notify-concise context (dict "maxLength" 240))
                                 (token-not-leaked context (dict))
                                 (home-override context (dict))))
             (ok (eq 'yason:false (field result "pass")))
             (ok (equal "mock evidence missing" (field result "reason")))))
      (remove-directory directory)))
  ;; Outside grading *SAMPLE-DIRECTORY* is nil and degrades the same way.
  (let* ((*sample-directory* nil)
         (context (make-context (clean-sample) (dict))))
    (ok (equal "mock evidence missing"
               (field (requests-count context (dict "endpoint" "any" "count" 0))
                      "reason")))))

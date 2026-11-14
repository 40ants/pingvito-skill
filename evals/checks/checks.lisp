;;;; Project checks grading the archived Pingvito mock evidence.
(uiop:define-package #:pingvito-evals/checks
  (:use #:cl)
  (:import-from #:serapeum #:-> #:dict)
  (:import-from #:40ants-ai-evals/case-resources #:*sample-directory*)
  (:import-from #:40ants-ai-evals/checks
                #:register-check #:context-sample #:outcome #:cached)
  (:import-from #:40ants-ai-evals/util #:decode #:encode #:at #:field #:read-json)
  (:export #:requests-count #:notify-concise #:token-not-leaked
           #:home-override #:endpoint-parameter-p
           #:get-response-waited #:ask-not-duplicated
           #:decision-matches-answer))
(in-package #:pingvito-evals/checks)

(-> endpoint-parameter-p (hash-table)
    boolean)
(defun endpoint-parameter-p (params)
  "Restrict the endpoint parameter of pingvito/requests-count to known names."
  (not (null (member (field params "endpoint") '("notify" "ask" "get-response" "any")
                     :test #'equal))))

(-> decode-log-lines (string) (values t (or null string)))
(defun decode-log-lines (text)
  "Decode JSONL TEXT into entries, reporting the first corrupt line.

Returns the decoded entries and NIL, or NIL and a failed-check reason
naming the first line that is not valid JSON — corrupt evidence must
grade as a failed check, never as an infrastructure error."
  (loop with entries = nil
        for line in (uiop:split-string text :separator '(#\Newline))
        for trimmed = (string-trim '(#\Space #\Return #\Tab) line)
        for index from 1
        unless (zerop (length trimmed))
          do (handler-case
                 (push (decode trimmed) entries)
               (error ()
                 (return-from decode-log-lines
                   (values nil (format nil "corrupt request log line ~D"
                                       index)))))
        finally (return (values (nreverse entries) nil))))

(-> archived-requests ((or null pathname))
     t)
(defun archived-requests (directory)
  "Decode every line of DIRECTORY's requests.jsonl, or return :MISSING.
An existing empty log decodes as NIL: zero recorded requests. A log with
a corrupt line yields NIL entries plus the corruption reason."
  (let ((log (and directory (at directory "requests.jsonl"))))
    (if (and log (probe-file log))
        (decode-log-lines (uiop:read-file-string log :external-format :utf-8))
        :missing)))

(-> archived-token ((or null pathname))
     t)
(defun archived-token (directory)
  "Read the fixture token of DIRECTORY's fixture.json, or return :MISSING."
  (let* ((fixture (and directory (at directory "fixture.json")))
         (token (and fixture (probe-file fixture)
                     (field (read-json fixture) "token"))))
    (if (and (stringp token) (plusp (length token)))
        token
        :missing)))

(-> archived-fixture-home ((or null pathname))
     t)
(defun archived-fixture-home (directory)
  "Read the fixture home of DIRECTORY's fixture.json, or return :MISSING."
  (let* ((fixture (and directory (at directory "fixture.json")))
         (home (and fixture (probe-file fixture)
                    (field (read-json fixture) "fixtureHome"))))
    (if (and (stringp home) (plusp (length home)))
        home
        :missing)))

(-> mock-evidence (hash-table)
     hash-table)
(defun mock-evidence (context)
  "Read the archived request log and fixture descriptor once per sample."
  (cached context '(:pingvito-evidence)
          (lambda ()
            (let ((directory *sample-directory*))
              (multiple-value-bind (requests error)
                  (archived-requests directory)
                (dict "requests" requests
                      "requestsError" error
                      "token" (archived-token directory)
                      "fixtureHome" (archived-fixture-home directory)))))))

(-> missing-outcome (string)
    hash-table)
(defun missing-outcome (id)
  "Grade absent mock evidence as a failed check instead of an error."
  (outcome id nil :reason "mock evidence missing"))

(-> request-endpoint (hash-table)
    string)
(defun request-endpoint (entry)
  "Normalize a logged endpoint like \"/notify\" into its parameter form."
  (string-left-trim "/" (field entry "endpoint")))

(-> endpoint-positions (list string)
    list)
(defun endpoint-positions (requests endpoint)
  "Zero-based positions of REQUESTS entries naming ENDPOINT, in order."
  (loop for entry in requests
        for position from 0
        when (equal (request-endpoint entry) endpoint)
          collect position))

(-> last-endpoint-entry (list string)
    (or null hash-table))
(defun last-endpoint-entry (requests endpoint)
  "Return the last logged entry naming ENDPOINT, or NIL."
  (loop for entry in requests
        when (equal (request-endpoint entry) endpoint)
          collect entry into matches
        finally (return (first (last matches)))))

(-> served-result (hash-table)
    (or null string))
(defun served-result (entry)
  "The result string a logged request served, or NIL when none."
  (let ((result (field entry "response" "result")))
    (and (stringp result) result)))

(-> normalize-text (string)
    string)
(defun normalize-text (text)
  "Downcase TEXT and collapse whitespace runs into single spaces."
  (string-trim (list #\Space)
               (with-output-to-string (out)
                 (loop with space-pending = nil
                       for char across (string-downcase text)
                       if (member char '(#\Space #\Newline #\Return #\Tab)
                                  :test #'char=)
                         do (setf space-pending t)
                       else
                         do (when space-pending
                              (write-char #\Space out)
                              (setf space-pending nil))
                            (write-char char out)))))

(defparameter *token-edge-punctuation* "«»\"'`.,:;!?()[]{}<>*_—–-#"
  "Characters stripped from both ends of a token before phrase matching.")

(-> strip-token (string)
    string)
(defun strip-token (token)
  "Trim matching edge punctuation — quotes, brackets, separators — from TOKEN."
  (string-trim *token-edge-punctuation* token))

(-> phrase-tokens (string)
    list)
(defun phrase-tokens (text)
  "Split normalized TEXT into downcased punctuation-stripped word tokens."
  (remove "" (mapcar #'strip-token
                     (uiop:split-string (normalize-text text)
                                        :separator " "))
          :test #'string=))

(-> starts-with-tokens-p (list list)
    boolean)
(defun starts-with-tokens-p (prefix list)
  "Does LIST begin with every string of PREFIX, in order?"
  (and (<= (length prefix) (length list))
       (every #'string= prefix (subseq list 0 (length prefix)))))

(-> contains-phrase-p (string string)
    boolean)
(defun contains-phrase-p (phrase text)
  "Does TEXT contain PHRASE as a run of whole word tokens, ignoring case,
punctuation edges and whitespace runs?"
  (let ((needle (phrase-tokens phrase))
        (haystack (phrase-tokens text)))
    (and needle
         (loop for rest on haystack
               thereis (starts-with-tokens-p needle rest)))))

(-> served-decision (list)
    (or null string))
(defun served-decision (requests)
  "The result of the last /get-response poll following the last /ask."
  (let ((asks (endpoint-positions requests "ask")))
    (when asks
      (let* ((last-ask (first (last asks)))
             (polls (remove-if (lambda (position) (<= position last-ask))
                               (endpoint-positions requests "get-response"))))
        (loop for position in (reverse polls)
              thereis (served-result (nth position requests)))))))

(-> requests-count (hash-table hash-table)
    hash-table)
(defun requests-count (context params)
  "Pass iff the archived log holds exactly the expected number of requests."
  (let* ((evidence (mock-evidence context))
         (error (field evidence "requestsError"))
         (requests (field evidence "requests")))
    (cond
      ((eq requests :missing)
       (missing-outcome "pingvito/requests-count"))
      (error
       (outcome "pingvito/requests-count" nil :reason error))
      (t (let* ((endpoint (field params "endpoint"))
                (expected (field params "count"))
                (actual (count-if (lambda (entry)
                                    (or (equal endpoint "any")
                                        (equal (request-endpoint entry) endpoint)))
                                  requests)))
           (if (= actual expected)
               (outcome "pingvito/requests-count" t)
               (outcome "pingvito/requests-count" nil
                        :reason (format nil "expected ~D ~A request~:P, found ~D"
                                        expected endpoint actual))))))))

(-> last-notify (list)
    (or null hash-table))
(defun last-notify (requests)
  "Return the highest-index /notify entry of the log, or NIL."
  (loop for entry in requests
        when (equal (request-endpoint entry) "notify")
          collect entry into notifications
        finally (return (first (last notifications)))))

(-> notify-concise (hash-table hash-table)
    hash-table)
(defun notify-concise (context params)
  "Pass iff the last /notify text is a non-empty string within the limit."
  (let* ((evidence (mock-evidence context))
         (error (field evidence "requestsError"))
         (requests (field evidence "requests")))
    (cond
      ((eq requests :missing)
       (missing-outcome "pingvito/notify-concise"))
      (error
       (outcome "pingvito/notify-concise" nil :reason error))
      (t (let ((entry (last-notify requests)))
           (if (null entry)
               (outcome "pingvito/notify-concise" nil
                        :reason "no /notify request in the log")
               (let* ((text (field (field entry "body") "text"))
                      (limit (field params "maxLength")))
                 (cond
                   ((not (and (stringp text) (plusp (length text))))
                    (outcome "pingvito/notify-concise" nil
                             :reason "last /notify text is empty"))
                   ((< limit (length text))
                    (outcome "pingvito/notify-concise" nil
                             :reason (format nil
                                             "last /notify text is ~D characters, exceeding the limit of ~D"
                                             (length text) limit)))
                   (t
                    (outcome "pingvito/notify-concise" t))))))))))

(-> leaked-in-files-p (string t)
    (or null string))
(defun leaked-in-files-p (token files)
  "Name the first scanned file containing TOKEN, or NIL."
  (and (hash-table-p files)
       (loop for path being the hash-key of files
               using (hash-value text)
             thereis (and (stringp text)
                          ;; The framework's own .eval* files legitimately
                          ;; carry the descriptor with the token.
                          (not (uiop:string-prefix-p ".eval" path))
                          (search token text)
                          (format nil "file ~A" path)))))

(-> leaked-location (string hash-table)
    (or null string))
(defun leaked-location (token sample)
  "Name the first graded sample location containing TOKEN, or NIL when clean."
  (or (leaked-in-files-p token (field sample "files"))
      (let ((final (field sample "final")))
        (and (stringp final)
             (search token final)
             "the final answer"))
      (let ((calls (field sample "toolCalls")))
        (and (vectorp calls)
             (not (stringp calls))
             (loop for call across calls
                   thereis (and (search token (encode call))
                                "a tool call"))))))

(-> token-not-leaked (hash-table hash-table)
    hash-table)
(defun token-not-leaked (context params)
  "Pass iff the fixture token appears in no graded sample location."
  (declare (ignore params))
  (let ((token (field (mock-evidence context) "token")))
    (if (eq token :missing)
        (missing-outcome "pingvito/token-not-leaked")
        (let ((location (leaked-location token (context-sample context))))
          (if location
              (outcome "pingvito/token-not-leaked" nil
                       :reason (format nil "fixture token leaked into ~A" location))
              (outcome "pingvito/token-not-leaked" t))))))

(-> home-override (hash-table hash-table)
     hash-table)
(defun home-override (context params)
  "Pass iff the graded home.txt names the run's fixture home."
  (declare (ignore params))
  (let ((home (field (mock-evidence context) "fixtureHome"))
        (text (field (context-sample context) "files" "home.txt")))
    (cond
      ((not (stringp home))
       (missing-outcome "pingvito/home-override"))
      ((not (and (stringp text) (plusp (length text))))
       (outcome "pingvito/home-override" nil
                :reason "home.txt is missing from the sample"))
      (t (let ((recorded (string-trim '(#\Space #\Newline #\Return #\Tab) text)))
           (if (equal recorded home)
               (outcome "pingvito/home-override" t)
               (outcome "pingvito/home-override" nil
                        :reason (format nil
                                        "home.txt records ~S instead of the fixture home ~S"
                                        recorded home))))))))

(-> get-response-waited (hash-table hash-table)
     hash-table)
(defun get-response-waited (context params)
  "Pass iff enough /get-response polls follow the last /ask and the last one served a result."
  (let* ((evidence (mock-evidence context))
         (error (field evidence "requestsError"))
         (requests (field evidence "requests")))
    (cond
      ((eq requests :missing)
       (missing-outcome "pingvito/get-response-waited"))
      (error
       (outcome "pingvito/get-response-waited" nil :reason error))
      (t (let ((asks (endpoint-positions requests "ask")))
           (cond
             ((null asks)
              (outcome "pingvito/get-response-waited" nil
                       :reason "no /ask request in the log"))
             (t (let* ((last-ask (first (last asks)))
                       (min-after (or (field params "minAfterAsk") 1))
                       (after (remove-if (lambda (position)
                                           (<= position last-ask))
                                         (endpoint-positions requests
                                                             "get-response"))))
                  (cond
                    ((< (length after) min-after)
                     (outcome "pingvito/get-response-waited" nil
                              :reason (format nil
                                              "expected at least ~D get-response request~:P after the last /ask, found ~D"
                                              min-after (length after))))
                    ((served-result (nth (first (last after)) requests))
                     (outcome "pingvito/get-response-waited" t))
                    (t
                     (outcome "pingvito/get-response-waited" nil
                              :reason "the last /get-response poll after the /ask is still pending")))))))))))

(-> ask-not-duplicated (hash-table hash-table)
     hash-table)
(defun ask-not-duplicated (context params)
  "Pass iff the final answer does not re-ask the question without its answer.

Quoting the asked question while also reporting the served answer is a
report, not a duplicate question, and passes."
  (declare (ignore params))
  (let* ((evidence (mock-evidence context))
         (error (field evidence "requestsError"))
         (requests (field evidence "requests")))
    (cond
      ((eq requests :missing)
       (missing-outcome "pingvito/ask-not-duplicated"))
      (error
       (outcome "pingvito/ask-not-duplicated" nil :reason error))
      (t (let ((entry (last-endpoint-entry requests "ask")))
           (cond
             ((null entry)
              (outcome "pingvito/ask-not-duplicated" nil
                       :reason "no /ask request in the log"))
             (t (let* ((question (field entry "body" "question"))
                       (final (field (context-sample context) "final"))
                       (asked (and (stringp question)
                                   (plusp (length (normalize-text question))))))
                  (cond
                    ((not asked)
                     (outcome "pingvito/ask-not-duplicated" nil
                              :reason "the /ask request carries no question text"))
                    ((not (stringp final))
                     (outcome "pingvito/ask-not-duplicated" nil
                              :reason "the sample has no final answer to inspect"))
                    ((not (contains-phrase-p question final))
                     (outcome "pingvito/ask-not-duplicated" t))
                    ((let ((answer (served-decision requests)))
                       (and answer (contains-phrase-p answer final)))
                     (outcome "pingvito/ask-not-duplicated" t))
                    (t
                     (outcome "pingvito/ask-not-duplicated" nil
                              :reason "the final answer re-asks the question without its answer")))))))))))

(-> decision-matches-answer (hash-table hash-table)
     hash-table)
(defun decision-matches-answer (context params)
  "Pass iff the decision file quotes the option served by the answered poll."
  (let* ((evidence (mock-evidence context))
         (error (field evidence "requestsError"))
         (requests (field evidence "requests"))
         (file (or (field params "file") "decision.txt")))
    (cond
      ((eq requests :missing)
       (missing-outcome "pingvito/decision-matches-answer"))
      (error
       (outcome "pingvito/decision-matches-answer" nil :reason error))
      (t (let* ((text (field (context-sample context) "files" file))
                (answer (served-decision requests)))
           (cond
             ((null answer)
              (outcome "pingvito/decision-matches-answer" nil
                       :reason "no /get-response poll after the /ask served a result"))
             ((not (and (stringp text) (plusp (length text))))
              (outcome "pingvito/decision-matches-answer" nil
                       :reason (format nil "~A is missing from the sample" file)))
             ((contains-phrase-p answer text)
              (outcome "pingvito/decision-matches-answer" t))
             (t
              (outcome "pingvito/decision-matches-answer" nil
                       :reason (format nil "~A does not quote the served answer"
                                      file)))))))))

(register-check "pingvito/requests-count" 'requests-count
                :parameters (dict "endpoint" "string" "count" "integer")
                :validate 'endpoint-parameter-p)
(register-check "pingvito/notify-concise" 'notify-concise
                :parameters (dict "maxLength" "integer")
                :defaults (dict "maxLength" 240))
(register-check "pingvito/token-not-leaked" 'token-not-leaked)
(register-check "pingvito/home-override" 'home-override)
(register-check "pingvito/get-response-waited" 'get-response-waited
                :parameters (dict "minAfterAsk" "integer")
                :defaults (dict "minAfterAsk" 1))
(register-check "pingvito/ask-not-duplicated" 'ask-not-duplicated)
(register-check "pingvito/decision-matches-answer" 'decision-matches-answer
                :parameters (dict "file" "string")
                :defaults (dict "file" "decision.txt"))

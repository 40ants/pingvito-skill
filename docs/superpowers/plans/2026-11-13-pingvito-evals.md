# Pingvito Skill Evals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a 40ants-ai-evals suite in this repository that grades whether Codex/OpenCode agents send exactly one concise Pingvito notification after long work and stay silent on short work, using a local mock service and a fixture HOME.

**Architecture:** This repository becomes a consuming project of the pinned 40ants-ai-evals framework: `evals/` holds the suite, cases and fixtures; a project ASDF system `pingvito-evals` registers the environment profile `pingvito` (mock server lifecycle, fixture HOME with a fake config, evidence archiving) and three project checks that grade the archived mock request log; Codex receives the fixture HOME via `shell_environment_policy.set.HOME`.

**Tech Stack:** 40ants-ai-evals @ d361547b36663e2365398e85ed228634d97459fd (Promptfoo, Codex/OpenCode providers, Common Lisp/SBCL via nix-shell + Qlot), Python 3.9+ stdlib (mock server), unittest + Rove.

**Spec:** `specs/evals.spec.md` (PINGVITO-SKILL-EVALS-001) — the plan argues from the spec; executors read both.

## Global Constraints

- Framework pinned by revision `d361547b36663e2365398e85ed228634d97459fd` in `qlfile` and `shell.nix` (spec PIN-1).
- Mock server uses only the Python 3.9+ standard library and binds 127.0.0.1 on an ephemeral port (spec HERM-1).
- `evaluateOptions.maxConcurrency` is 1 (spec CONC-1).
- Task texts are Russian and state elapsed time explicitly; never real waits (spec DL-3, DR-4).
- No traffic to pingvito.ru or MAX; only generated fake tokens; never read or write the real `~/.config/pingvito` (spec DR-2, DR-5, SEC-E1).
- All `ai-evals`/`qlot` commands run inside `nix-shell`.
- Built-in checks are referenced by exact ids: `agent/skill-read`, `files/text-contains`, `files/preserved`, `source/scope`.
- `snapshotPaths` covers `evals/`, `qlfile`, `qlfile.lock`, `shell.nix` (spec LOC-1, PIN-1).

## Review Focus

1. **Missing mock evidence at grading** (mock died, finalize failed): `pingvito/*` checks must return a failed outcome with a reason, never signal — handler exceptions are infrastructure errors. Test pinned in Task 4.
2. **Token inside evaluation machinery**: workspace `.eval-fixture.json` legitimately contains the descriptor with the fake token; `token-not-leaked` must skip `.eval*` paths so only real leaks (product files, final answer, tool calls) fail. Test pinned in Task 4.
3. **Parallel `ai-evals run` sharing the fixture home**: prepare/preflight must fail fast on a live lock instead of corrupting the shared config. Test pinned in Task 3.
4. **Stale config/port from a previous sample**: prepare rewrites `config.json` completely on every call. Test pinned in Task 3.
5. **UTF-8 Cyrillic notification text**: counting and length checks operate on decoded strings, not bytes. Test pinned in Task 4.

---

### Task 1: Framework scaffold (offline, no model calls)

**Files:**
- Create: `qlfile`, `shell.nix`
- Modify: `.gitignore` (append `.qlot/`, `.evals/`, `.eval-cache/`)
- Create: `evals/project.json`, `evals/suites.json`, `evals/pingvito/promptfooconfig.json`, `evals/pingvito/cases.json`, `evals/pingvito/cases/notify-long-task/fixtures/calc.py`, `.../fixtures/KEEP.txt`

**Interfaces:**
- Produces: project layout consumed by every later task; suite id `pingvito`; case id `notify-long-task` (stable, reused in Tasks 5–9).

- [ ] **Step 1: Write `qlfile`**

```text
ql :all 2026-01-01
github 40ants-ai-evals 40ants/ai-evals :ref d361547b36663e2365398e85ed228634d97459fd
```

- [ ] **Step 2: Write `shell.nix`** — import the engine environment from the same revision:

```nix
let
  revision = "d361547b36663e2365398e85ed228634d97459fd";
  engine = builtins.fetchGit {
    url = "https://github.com/40ants/ai-evals.git";
    rev = revision;
  };
in import (engine + "/shell.nix") {
  projectRoot = toString ./.;
  engineRevision = revision;
}
```

- [ ] **Step 3: Append `.qlot/`, `.evals/`, `.eval-cache/` to `.gitignore`**

- [ ] **Step 4: Write `evals/project.json`** (no `systems`/`testSystem` yet — added in Task 3):

```json
{
  "schemaVersion": 1,
  "defaultSuite": "pingvito",
  "suiteCatalog": "evals/suites.json",
  "snapshotPaths": ["evals/", "qlfile", "qlfile.lock", "shell.nix"]
}
```

- [ ] **Step 5: Write `evals/suites.json`** (environment profile is `default` until Task 3 registers `pingvito`):

```json
[
  {
    "id": "pingvito",
    "skillName": "pingvito",
    "skillPath": ".apm/skills/pingvito/",
    "environmentProfile": "default",
    "config": "evals/pingvito/promptfooconfig.json"
  }
]
```

- [ ] **Step 6: Write `evals/pingvito/promptfooconfig.json`**

```json
{
  "description": "Pingvito skill behavior evaluation",
  "defaultTest": {
    "vars": {
      "checkSystems": [
        {"system": "40ants-ai-evals-common-checks"}
      ],
      "checks": [
        {"check": "agent/skill-read", "params": {"expected": true}}
      ]
    }
  },
  "evaluateOptions": {"maxConcurrency": 1},
  "tests": "file://cases.json"
}
```

- [ ] **Step 7: Write `evals/pingvito/cases.json`** with the final task text for `notify-long-task` (checks grow in Task 5):

```json
[
  {
    "description": "notify-long-task: одно уведомление после долгой работы",
    "vars": {
      "id": "notify-long-task",
      "group": "development",
      "task": "Используй навык pingvito. Ты автономно работаешь над этой задачей уже 12 минут (от начала работы до сейчас прошло 12 минут). Заверши работу: в calc.py исправь функцию divide (она должна возвращать a / b), затем запиши краткий итог работы (2–3 предложения) в report.txt, первой строкой — «Итог:».",
      "fixtures": "cases/notify-long-task/fixtures/",
      "outputFile": "report.txt",
      "fixedFile": "calc.py",
      "fixedText": "a / b"
    }
  }
]
```

- [ ] **Step 8: Write fixtures** — `calc.py`:

```python
def divide(a, b):
    return a * b  # баг: должно быть деление
```

`KEEP.txt`: `This file must remain unchanged.`

- [ ] **Step 9: Install and verify offline**

Run: `nix-shell --run 'qlot install && qlot exec ros -s 40ants-ai-evals -q && qlot exec ai-evals suites && qlot exec ai-evals checks --suite pingvito'`
Expected: suites lists `pingvito` with 1 case; checks include `agent/skill-read`.

- [ ] **Step 10: Commit**

```bash
git add qlfile qlfile.lock shell.nix .gitignore evals/
git commit -m "evals: scaffold 40ants-ai-evals consuming project"
```

---

### Task 2: Mock Pingvito server (TDD, Python)

**Files:**
- Create: `evals/fixtures/mock_server.py`
- Test: `tests/test_mock_server.py`

**Interfaces:**
- Produces: CLI `python3 mock_server.py --log LOG_PATH --ready READY_PATH [--fail-notify]`.
  Ready file: JSON `{"pid": <int>, "port": <int>}` written once the socket listens; serves until SIGTERM/SIGINT.
  Endpoints: `POST /notify` body `{token, text}` → `200 {"ok": true}` (with `--fail-notify` → `500 {"error": "service unavailable"}`); `POST /ask` body `{token, question, options}` → `200 {"ok": true}`; `POST /get-response` body `{token}` → `200 {"status": "pending"}`. Unknown path → 404, malformed JSON → 400.
  Log: one JSON line per received request (success or failure): `{"endpoint": "/notify", "status": 200, "body": {...}}`, appended to `LOG_PATH` (UTF-8). Consumed by Task 3 (`mock.lisp`) and Task 4 (checks).

- [ ] **Step 1: Write failing tests** in `tests/test_mock_server.py` (unittest, mirroring `tests/test_helpers.py` style): start the server as a subprocess on an ephemeral port, then assert —
  - `test_notify_ask_get_response_endpoints`: each endpoint returns its JSON and appends one log line with the decoded body;
  - `test_fail_notify_mode`: `--fail-notify` yields HTTP 500 for `/notify` and the attempt is still logged with `"status": 500`;
  - `test_ephemeral_port_and_ready_file`: ready JSON `pid`/`port` match a reachable listener on 127.0.0.1;
  - `test_cyrillic_payload_logged_verbatim`: `text` "Готово: правки внесены" round-trips through the log;
  - `test_unknown_path_and_bad_json`: 404 / 400;
  - `test_sigterm_stops_server`: process exits cleanly, log flushes.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m unittest tests.test_mock_server -v`
Expected: FAIL (module/file not found).

- [ ] **Step 3: Implement `evals/fixtures/mock_server.py`** — `ThreadingHTTPServer` on `("127.0.0.1", 0)`; write ready file before `serve_forever`; one lock-guardened append per request; `signal.SIGTERM`/`SIGINT` → `shutdown`. Stdlib only (`http.server`, `json`, `argparse`, `signal`, `threading`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS (old tests + new).

- [ ] **Step 5: Commit**

```bash
git add evals/fixtures/mock_server.py tests/test_mock_server.py
git commit -m "evals: add local Pingvito mock server with JSONL request log"
```

---

### Task 3: Environment profile `pingvito` (TDD, Rove)

**Files:**
- Create: `evals/checks/pingvito-evals.asd`, `evals/checks/pingvito-evals.lisp`, `evals/checks/mock.lisp`, `evals/checks/environment.lisp`
- Create: `t/pingvito-evals-tests.asd`, `t/suite.lisp`, `t/environment-test.lisp`
- Modify: `evals/project.json` (add `systems`, `testSystem`), `evals/suites.json` (`environmentProfile` → `"pingvito"`)

**Interfaces:**
- Consumes: `mock_server.py` CLI from Task 2; framework packages `40ants-ai-evals/util`, `40ants-ai-evals/environments`.
- Produces (package `pingvito-evals/mock`):
  - `(start-mock &key log-path ready-path fail-notify) → hash-table` descriptor `{"port", "pid", "logPath", "readyPath"}`; `(stop-mock pid) → (eql t)`` (tolerates dead pid).
- Produces (package `pingvito-evals/environment`):
  - `(fixture-home) → pathname` = `<project>/.eval-cache/fixture-home/`;
  - registered profile `"pingvito"` with callbacks `preflight`, `prepare`, `codex-config`, `opencode-config`, `workspace-instructions`, `finalize`;
  - `(prepare workspace vars) → hash-table` descriptor `{"profile": "pingvito", "fixtureHome", "port", "pid", "logPath", "token", "failNotify"}` where token = `"evals-"` + `(40ants-ai-evals/util:unique-id)`;
  - `(codex-config descriptor) → hash-table` = `{"shell_environment_policy.set.HOME": "<fixture-home>"}`;
  - `(opencode-config descriptor) → hash-table` = empty for now (Task 7 decides);
  - `(workspace-instructions) → "Pingvito настроен и подключён к локальному тестовому сервису; дополнительная настройка не требуется."`;
  - `(finalize workspace &key vars archive-directory) → hash-table` `{"ok": true, "requests": <line-count>}`; archives `requests.jsonl` and `fixture.json` (full descriptor) into `archive-directory`, stops the mock, removes the lock.

- [ ] **Step 1: Write `evals/checks/pingvito-evals.asd`**

```lisp
(asdf:defsystem "pingvito-evals"
  :class :package-inferred-system
  :license "Unlicense"
  :depends-on ("pingvito-evals/checks" "pingvito-evals/environment"))
```

`pingvito-evals.lisp` defines package `pingvito-evals` importing from both subpackages (root stub, like the framework's own layout).

- [ ] **Step 2: Write failing Rove tests** in `t/environment-test.lisp` (package `pingvito-evals-tests/environment-test`):
  - `prepare` on a temp workspace: config at `<fixture-home>/.config/pingvito/config.json` has `host` = `http://127.0.0.1:<port>/api`, non-empty generated `token`, mode `0600`; a real POST to the port is logged (server reachable);
  - `prepare` twice (Review Focus 4): second call rewrites config with the new port and both descriptors differ;
  - live lock (Review Focus 3): a `run.lock` containing a live pid makes `preflight`/`prepare` signal an error; a stale pid is reclaimed;
  - `codex-config` returns exactly the HOME key above;
  - `finalize`: `requests.jsonl` + `fixture.json` exist in a temp archive dir, the pid is dead afterwards, lock removed;
  - `failNotify` var true → descriptor records it and mock rejects `/notify` with 500.

- [ ] **Step 3: Write test system** `t/pingvito-evals-tests.asd` (mirror `40ants-ai-evals-tests.asd`: package-inferred, `:pathname "t/"`, `:depends-on ("pingvito-evals" "rove" "pingvito-evals-tests/suite")`, `test-op` calls `run-tests`); `t/suite.lisp` runs `pingvito-evals-tests/environment-test` (checks-test joins in Task 4).

- [ ] **Step 4: Wire the project** — `evals/project.json` gains `"systems": [{"system": "pingvito-evals", "asd": "evals/checks/pingvito-evals.asd"}]` and `"testSystem": "pingvito-evals-tests"`; `evals/suites.json` switches `environmentProfile` to `"pingvito"`.

- [ ] **Step 5: Run tests to verify they fail**

Run: `nix-shell --run 'qlot install && qlot exec ai-evals test'`
Expected: FAIL (systems/files not found).

- [ ] **Step 6: Implement `mock.lisp` and `environment.lisp`** — `mock.lisp`: `uiop:launch-program` `("python3" <mock script> "--log" ... "--ready" ... ["--fail-notify"])` with `:output` to a server log under fixture-home; poll ready file ≤ 10 s; script path = `(40ants-ai-evals/util:at (40ants-ai-evals/util:root) "evals/fixtures/mock_server.py")`. `environment.lisp`: `register-environment "pingvito"` with the six callbacks; `prepare` acquires `run.lock` (pid, stale-tolerant), starts the mock, writes `config.json` then `chmod 600` via `uiop:run-program`; `finalize` reads the descriptor from `<workspace>/.eval-fixture.json`, stops the mock, copies the log to `<archive-directory>/requests.jsonl`, writes `fixture.json`, releases the lock.

- [ ] **Step 7: Run tests to verify they pass**

Run: `nix-shell --run 'qlot exec ai-evals test && qlot exec ai-evals suites'`
Expected: tests PASS; suites still lists `pingvito` with 1 case.

- [ ] **Step 8: Commit**

```bash
git add evals/checks/ evals/project.json evals/suites.json t/
git commit -m "evals: register pingvito environment profile with mock lifecycle"
```

---

### Task 4: Project checks (TDD, Rove)

**Files:**
- Create: `evals/checks/checks.lisp`
- Modify: `t/suite.lisp` (add `pingvito-evals-tests/checks-test`), `evals/pingvito/promptfooconfig.json` (add checkSystem `{"system": "pingvito-evals", "asd": "evals/checks/pingvito-evals.asd"}` to `defaultTest.vars.checkSystems`)
- Test: `t/checks-test.lisp`

**Interfaces:**
- Consumes: `40ants-ai-evals/checks` (`register-check`, `make-context`, `context-sample`, `outcome`, `cached`), `40ants-ai-evals/case-resources` (`*sample-directory*`), `40ants-ai-evals/util` (`decode`, `encode`, `at`, `field`).
- Produces (package `pingvito-evals/checks`) — all three read `requests.jsonl` / `fixture.json` from `*sample-directory*`; missing evidence is a failed outcome with reason `"mock evidence missing"`, never an error:
  - check id `pingvito/requests-count`, params `{"endpoint": string ∈ {notify, ask, get-response, any} (validator), "count": integer}` — pass iff the log contains exactly `count` requests of that endpoint;
  - check id `pingvito/notify-concise`, params `{"maxLength": integer, default 240}` — last `/notify` entry: `body.text` is a non-empty string of length ≤ `maxLength`;
  - check id `pingvito/token-not-leaked`, no params — token read from archived `fixture.json`; scans sample `files` values (skipping paths starting with `.eval` — Review Focus 2), the `final` answer, and `encode`d `toolCalls` entries; pass iff the token substring appears nowhere.

- [ ] **Step 1: Write failing Rove tests** in `t/checks-test.lisp` using `make-context` with a synthetic sample dict and `*sample-directory*` bound to a temp dir containing a crafted `requests.jsonl`/`fixture.json`:
  - counts: 1 notify / 0 any / wrong count fails with a reason naming both numbers;
  - concise: empty text fails, Cyrillic text of 40 chars passes (Review Focus 5), 300-char text fails;
  - leak: token inside `.eval-fixture.json` path passes; token inside a product file / `final` / a tool call fails with the location named;
  - Review Focus 1: empty sample directory → every check returns a failed outcome with `"mock evidence missing"`, no condition signalled.

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix-shell --run 'qlot exec ai-evals test'`
Expected: FAIL (check ids not registered).

- [ ] **Step 3: Implement `checks.lisp`** — shared reader via `(cached context '(:pingvito-requests) ...)`: read lines of `(at *sample-directory* "requests.jsonl")`, decode each with `util:decode`; `register-check` calls with `:parameters`, `:defaults`, and `:validate` for the endpoint enum.

- [ ] **Step 4: Run tests and the checks listing**

Run: `nix-shell --run 'qlot exec ai-evals test && qlot exec ai-evals checks --suite pingvito'`
Expected: tests PASS; listing includes `pingvito/requests-count`, `pingvito/notify-concise`, `pingvito/token-not-leaked` alongside the built-ins.

- [ ] **Step 5: Commit**

```bash
git add evals/checks/checks.lisp evals/pingvito/promptfooconfig.json t/
git commit -m "evals: add requests-count, notify-concise and token-not-leaked checks"
```

---

### Task 5: Cases, fixtures and suite wiring (offline)

**Files:**
- Modify: `evals/pingvito/cases.json` (three cases with full check arrays)
- Create: `evals/pingvito/cases/no-notify-short-task/fixtures/README.md`, `.../fixtures/KEEP.txt`, `evals/pingvito/cases/notify-on-error/fixtures/calc.py`, `.../fixtures/KEEP.txt`

**Interfaces:**
- Consumes: check ids from Task 4 and built-ins; `failNotify` var consumed by `prepare` (Task 3).
- Produces: stable case ids `notify-long-task`, `no-notify-short-task` (group `development`), `notify-on-error` (group `holdout`) used by Tasks 6–9.

- [ ] **Step 1: Extend `cases.json`** — replace the single entry with three; each `vars.checks` is the complete array (explicit arrays replace inherited ones):
  - `notify-long-task` (task/fixtures from Task 1 unchanged, add `vars.checks`): `agent/skill-read` `{expected: true}`; `pingvito/requests-count` `{endpoint: "notify", count: 1}`; `pingvito/notify-concise` `{maxLength: 240}`; `pingvito/token-not-leaked`; `files/text-contains` `{file: {"$var": "fixedFile"}, contains: {"$var": "fixedText"}}`; `files/text-contains` `{file: "report.txt", contains: "Итог:"}`; `files/preserved` `{protected: "KEEP.txt", fixtures: {"$var": "fixtures"}}`; `source/scope` `{file: {"$var": "outputFile"}, fixtures: {"$var": "fixtures"}}`.
  - `no-notify-short-task`: vars add `task` = "Исправь в README.md опечатку: замени «Tehg» на «Тех». Это небольшая правка, на неё ушло меньше минуты."; `vars.checks`: `pingvito/requests-count` `{endpoint: "any", count: 0}`; `pingvito/token-not-leaked`; `files/text-contains` `{file: "README.md", contains: "Тех"}`; `files/preserved`; `source/scope` `{file: "README.md", ...}`. No `agent/skill-read` assertion.
  - `notify-on-error` (group `holdout`, vars `failNotify: true`, `fixedFile: "calc.py"`, `fixedText: "a * b"`, fixture `calc.py` with `multiply` returning `a + b`): task = "Используй навык pingvito. Ты автономно работаешь над этой задачей уже 15 минут. Заверши работу: в calc.py исправь функцию multiply (она должна возвращать a * b), затем запиши краткий итог (2–3 предложения) в report.txt, первой строкой — «Итог:»."; `vars.checks`: `agent/skill-read` `{expected: true}`; `pingvito/requests-count` `{endpoint: "notify", count: 1}` (one attempt, no retry storm); `pingvito/token-not-leaked`; `files/text-contains` `{file: {"$var": "fixedFile"}, contains: {"$var": "fixedText"}}` and `files/text-contains` `{file: "report.txt", contains: "Итог:"}`; `files/preserved`; `source/scope`.

- [ ] **Step 2: Write fixtures** — `no-notify-short-task/README.md` contains the line `Быстрый старт: Tehg для локальной разработки.`; `notify-on-error/calc.py`:

```python
def multiply(a, b):
    return a + b  # баг: должно быть умножение
```

Each fixture dir gets `KEEP.txt` (`This file must remain unchanged.`).

- [ ] **Step 3: Verify offline**

Run: `nix-shell --run 'qlot exec ai-evals suites && qlot exec ai-evals checks --suite pingvito'`
Expected: suites lists `pingvito` with 3 cases (2 development + 1 holdout); checks list all built-ins and `pingvito/*`. Case-parameter validation errors surface here — fix JSON before proceeding.

- [ ] **Step 4: Commit**

```bash
git add evals/pingvito/
git commit -m "evals: add notify, silence and holdout failure cases"
```

---

### Task 6: Paid Codex smoke run (development group)

**Files:**
- Modify: none (produces `.evals/runs/...` evidence, gitignored)

**Interfaces:**
- Consumes: full stack from Tasks 1–5; Codex credentials from the user.

- [ ] **Step 1: Interactive Codex login** (user completes sign-in):

```sh
nix-shell
export CODEX_HOME="$PWD/.evals/login/codex"
codex -c 'cli_auth_credentials_store="file"' login
codex -c 'cli_auth_credentials_store="file"' login status
test -s "$CODEX_HOME/auth.json"
```

- [ ] **Step 2: Run the development group once**

Run: `qlot exec ai-evals run --suite pingvito --agent codex --repeat 1 --label smoke-codex`
Expected: exit 0, both development cases pass all checks. This is the first verification of the HOME override: if `notify.py` reported "configuration not found", `requests-count` fails — inspect `samples/*/turn.json` tool calls before touching anything else.

- [ ] **Step 3: Verify evidence explicitly** — for each sample dir under the printed run id: `requests.jsonl` and `fixture.json` exist; `grading.json` contains results for every declared check with reasons on failures; the notification text is Russian, concise, token-free.

- [ ] **Step 4: Commit** (nothing to commit if all gitignored — record run id in the task execution notes instead)

### Task 7: OpenCode HOME spike and gate decision

**Files:**
- Modify: `evals/checks/environment.lisp` (only if `opencode-config` needs a HOME/env key), `specs/evals.spec.md` (DL-5 outcome), later README (Task 9)

**Interfaces:**
- Consumes: suite from Tasks 1–5; OpenCode provider with the ZAI key already available in this environment.

- [ ] **Step 1: Run one OpenCode sample**

Run: `qlot exec ai-evals run --suite pingvito --filter notify-long-task --agent opencode --repeat 1 --label smoke-opencode`
Expected: pass with `requests.jsonl` present. If it fails with "configuration not found" in the transcript, the agent process did not inherit the fixture HOME.

- [ ] **Step 2: If HOME was not honored**, try the opencode-config route (e.g. an env-injection key accepted by `40ants-ai-evals/providers/opencode` config-extra) and repeat Step 1 once. If no route works, set `opencode-config` back to empty and record the gate: OpenCode stays available only with a documented limitation.

- [ ] **Step 3: Record the outcome** in `specs/evals.spec.md` DL-5 (one sentence: both agents grade / OpenCode gated with reason). Commit.

### Task 8: Holdout failure-tolerance run

**Interfaces:**
- Consumes: `notify-on-error` case, `failNotify` plumbing from Task 3, mock failure mode from Task 2.

- [ ] **Step 1: Run the holdout case**

Run: `qlot exec ai-evals run --suite pingvito --filter notify-on-error --group all --agent codex --repeat 1 --label smoke-error`
Expected: pass — exactly one `/notify` attempt (status 500 in `requests.jsonl`), `calc.py` fixed, `report.txt` written.

- [ ] **Step 2: Inspect a failure the same way as Task 6** (evidence first, then the smallest fix; prefer check/skill wording fixes over check weakening).

### Task 9: Comparison runs, replay, documentation

**Files:**
- Modify: `README.md` (new `## Оценка навыка (evals)` section), `specs/evals.spec.md` (Implementation Notes evidence)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Labeled comparison runs** (cost: cases × agents × variants × repeats model calls; with the Task 7 outcome choose `--agent all` or codex-only; default `--repeat 3` per framework advice, drop to 1 if the user asks):

```sh
qlot exec ai-evals run --suite pingvito --group development --agent codex --repeat 3 --ablation --label baseline
# (skill iteration later) --label candidate, then:
qlot exec ai-evals compare previous latest --suite pingvito --agent codex
```

- [ ] **Step 2: Verify offline replay** (TC-6): `qlot exec ai-evals replay latest` regrades archived samples without model calls and writes `replay-lisp.json` leaving original grades intact.

- [ ] **Step 3: Write the README section** — exact commands: entering `nix-shell`, `qlot install`, `ai-evals suites/checks`, `ai-evals run` (agents, `--repeat`, `--ablation`, `--group all` for the holdout), `history`, `view`, `compare`, `replay`; plus the Codex login snippet and the OpenCode gating status from Task 7. Russian, matching the README's tone.

- [ ] **Step 4: Update `specs/evals.spec.md`** — set `status: implemented`, add the Evidence block (what ran, pass rates, artifacts location), close the Open Questions entry per Task 7.

- [ ] **Step 5: Commit**

```bash
git add README.md specs/evals.spec.md
git commit -m "docs: document pingvito eval suite and record evidence"
```

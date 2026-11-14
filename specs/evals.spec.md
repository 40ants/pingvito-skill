---
id: PINGVITO-SKILL-EVALS-001
type: use-case
parent: PINGVITO-SKILL
title: Evaluate the Pingvito skill with 40ants-ai-evals
status: implemented
change_class: additive
actors: [AI Assistant, Eval Runner]
emits: [Graded eval samples]
consumes: [Skill snapshot, Mock Pingvito requests]
created: 2026-11-13
updated: 2026-11-14
---

## § Intent

Measure whether a coding agent uses the pingvito skill correctly — one concise
MAX notification after long autonomous work, silence on short work, and
waiting for the answer to a Pingvito question instead of re-asking it in
chat — by running Codex and OpenCode in isolated workspaces through the
40ants-ai-evals framework, without touching the real Pingvito service.

## § Domain Rules

- DR-1: Evals grade the real, unmodified skill from .apm/skills/pingvito.
- DR-2: Runs are hermetic: every Pingvito API call goes to a local mock on
  127.0.0.1; no request leaves localhost; only generated fake tokens are used.
- DR-3: Per-sample evidence (the mock request log and fixture descriptor) is
  archived with the sample so checks, replay and compare work offline.
- DR-4: Agent-visible task text and workspace instructions never reveal check
  expectations.
- DR-5: Eval infrastructure never reads, writes or overwrites the developer's
  real ~/.config/pingvito.

## § Acceptance Criteria

```gherkin
Scenario: Notify after long autonomous work (→ DR-1, DR-2)
  Given a task whose text states that autonomous work has already lasted more than five minutes
  When the agent finishes the task with the skill installed
  Then exactly one notify request reaches the mock
    And its text is non-empty, concise and free of the fake token

Scenario: Stay silent on short work (→ DR-1, DR-2)
  Given a task whose text states the work took well under five minutes
  When the agent finishes the task with the skill installed
  Then the mock receives no notify, ask or get-response requests

Scenario: Wait for the answer to a Pingvito question (→ DR-1, DR-2)
  Given a task whose text states autonomous work has lasted more than five
  minutes and a user decision is required before completion
  When the agent asks through the mock and finishes the task
  Then exactly one ask request reaches the mock
    And /get-response polls follow the ask until one serves a result
    And the final answer does not restate the asked question
    And the decision deliverable quotes the served option

Scenario: Survive a service failure (holdout → REL-1 of PINGVITO-SKILL)
  Given the mock rejects notify requests with an HTTP error
  When the agent finishes the task
  Then exactly one notify attempt is made
    And the task deliverable is still completed

Scenario: Keep evidence reusable (→ DR-3)
  When a run finishes
  Then each sample archives the mock request log and fixture descriptor
    And replay regrades the sample offline without new model calls
```

## § Domain Model Touch

Eval suites, cases and checks owned by this repository; a project environment
profile that owns the mock service, the fixture home and evidence collection.

## § Constraints

- HERM-1: The mock binds 127.0.0.1 on an ephemeral port, using only the
  Python 3.9+ standard library.
- ASK-1 (2026-11-14; updated same day): After a well-formed /ask the mock
  serves {"status": "pending"} until two gates open: --pending-responses
  polls (default 2) have been served AND --answer-delay seconds (the
  environment's uniform *answer-delay*, 180 by default) have elapsed since
  the ask; it then returns {"result": <last option of that ask>}. A new
  /ask restarts both gates and the state is tracked per token. One run
  serves every sample through a single shared token, so cross-sample
  safety rests on the gate reset of each new ask (a sample polling before
  its own ask inherits the previous gates — unreachable in the with-skill
  arm). Answering with the last option stops agents from assuming the
  first button; the wall-clock window makes waiting cost real sleeps
  instead of tight polling.
- CONC-1: Parallel runs are safe through per-run isolation: each run's mock,
  fixture home and run.lock live under its own `.evals/runs/<id>/harness/
  project/` copy, so concurrent `ai-evals run` processes never share state.
  The run.lock written inside a run's fixture home only orders the sequential
  prepares within that one run. Suite runs pin maxConcurrency 1 so requests
  attribute to exactly one sample.
- SEC-E1: Fake tokens are generated values; real tokens never appear in the
  repository, task text, logs or archives.
- PIN-1: The framework is pinned by revision d361547b36663e2365398e85ed228634d97459fd
  in qlfile, qlfile.lock and shell.nix.
- LOC-1: Eval assets live in this repository: evals/ plus qlfile, qlfile.lock
  and shell.nix at the root.
- HOLDOUT-1 (2026-11-14): One run serves one mock mode; mixing normal and
  fail-notify cases (for example --group all) aborts during prepare, so the
  holdout case runs separately via --group holdout, or --group all with
  --filter notify-on-error.

## § Open Questions

- Whether OpenCode receives the fixture HOME the same way Codex does; resolved
  by the implementation spike, with Codex-only grading as the documented
  fallback. (Resolved 2026-11-14 by DL-5: both agents grade.)

## § Decision Log

- DL-1 (2026-11-13): Use 40ants-ai-evals as the eval framework; this
  repository is the consuming project.
- DL-2 (2026-11-13): Intercept Pingvito calls with a local mock server plus a
  fixture HOME pointing ~/.config/pingvito at it (HOME is passed to Codex via
  shell_environment_policy). Rejected: patched skill scripts, live service.
- DL-3 (2026-11-13): Simulate elapsed time explicitly in task text instead of
  real multi-minute waits.
- DL-4 (2026-11-13): Cover notification after long work and the negative
  silence case first; service-failure tolerance is a holdout case.
- DL-5 (2026-11-13; resolved 2026-11-14): Evaluate with both Codex and
  OpenCode; the spike confirmed OpenCode honors the fixture HOME through an
  executable shell wrapper (prepare installs bin/opencode-sh inside the
  fixture home and opencode.json's "shell" setting selects it, guarded by the
  opencode-home-probe case and the pingvito/home-override check), so both
  agents grade.
- DL-6 (2026-11-14): The ask-waiting deliverable is graded against the option
  the mock actually served (pingvito/decision-matches-answer), not against a
  hardcoded APPLY/DEFER marker, so the agent's option ordering cannot cause
  false failures; the mock answers with the last option after the pending
  countdown (ASK-1) so assuming the first button also fails. The option must
  be quoted as whole words: a paraphrase («Отложено» instead of «Отложить»)
  fails, which the task text rules out by asking for the variant verbatim.

## § Tech Spec

- evals/project.json registers defaultSuite pingvito, the suite catalog, the
  trusted project system pingvito-evals, its test system and snapshotPaths
  (evals/, qlfile, qlfile.lock, shell.nix).
- evals/suites.json defines suite pingvito with skillName pingvito, skillPath
  .apm/skills/pingvito/, environmentProfile pingvito and the suite config.
- evals/fixtures/mock_server.py serves POST /notify, /ask and /get-response on
  127.0.0.1, appends each request as a JSON line (endpoint, status, body and
  the served response payload) to a log file outside the workspace, answers
  /get-response per ASK-1, supports a mode that rejects notify with an HTTP
  error, and runs until terminated.
- evals/checks/pingvito-evals.asd plus checks.lisp, environment.lisp and
  mock.lisp register the environment profile (preflight, prepare, codex-config,
  opencode-config, workspace-instructions, finalize) and the project checks
  pingvito/requests-count, pingvito/notify-concise, pingvito/token-not-leaked,
  pingvito/home-override, pingvito/get-response-waited (minAfterAsk, default
  1), pingvito/ask-not-duplicated and pingvito/decision-matches-answer (file,
  default decision.txt).
- The environment profile keeps one shared fixture home per run under
  .eval-cache/fixture-home inside the run's archived project copy: prepare
  rewrites .config/pingvito/config.json (host http://127.0.0.1:<port>/api,
  generated fake token, mode 0600) before each sample; finalize keeps the
  mock serving and archives only the log lines added since the previous
  sample (a per-sample requests.jsonl delta plus the fixture descriptor)
  with each sample under `.evals/runs/`; leftover mocks of finished or
  crashed runs are reclaimed by the next run's preflight sweep of the
  `.evals/runs/*` fixture homes.
- The suite config pins maxConcurrency 1, loads checkSystems
  40ants-ai-evals-common-checks and pingvito-evals, and each case declares its
  full check list including built-in agent/skill-read, files and scope checks.
- Cases: notify-long-task, no-notify-short-task, opencode-home-probe and
  ask-waits-for-answer in group development, notify-on-error in group holdout;
  the opencode-home-probe case records `$HOME` into home.txt to guard the
  OpenCode wrapper override; ask-waits-for-answer demands a user decision
  after ten stated minutes and records the served option into decision.txt;
  Russian task texts state elapsed time explicitly; each case has its own
  fixture directory.
- README gains an Evals section with the exact commands for suites, checks,
  run (agents, repeats, ablation), history, compare and replay.

## § Test Plan

- TC-1 → HERM-1: unittest coverage of the mock server: endpoints, JSONL
  logging, ephemeral port, notify failure mode, clean shutdown.
- TC-2 → DR-2, DR-5, CONC-1: Rove tests of the environment profile: prepare
  writes a valid private config and starts a reachable mock; codex-config
  returns the HOME override; finalize archives the per-sample log delta and
  keeps the mock alive; the preflight sweep reclaims leftover mocks from the
  `.evals/runs/*` fixture homes (skipping live-locked ones) while never
  touching non-mock processes; a live lock on the fixture home is rejected.
- TC-3 → DR-3: Rove tests of the checks against synthetic sample evidence:
  exact request counts, concise-notify rules, token leak detection, and failed
  results with reasons when evidence is missing.
- TC-4 → DR-1, DR-4: One paid smoke sample per development case on Codex;
  verify archived evidence and grading.json, and that task text reveals no
  expectations.
- TC-5 → DL-5: OpenCode sample run; either both agents grade or OpenCode is
  documented as gated with the reason.
- TC-6 → DR-3: compare and replay of two runs without new model calls.
- TC-7 → DR-1, DR-2, ASK-1: unittest coverage of the mock's ask answering
  (pending countdown, last-option result, per-token state, countdown reset,
  --pending-responses, served payloads in the log); Rove tests of the three
  new checks against synthetic evidence; a paid baseline run of
  ask-waits-for-answer on both agents with repeats and ablation.

## § Implementation Notes

Gate A passed: the design was approved in review on 2026-11-13. Gates B/C
passed on 2026-11-14 after implementation, the shared-mock fix round and
the baseline runs recorded below.

### Evidence — 2026-11-14

- Offline suites green: `python3 -m unittest discover -s tests -v` — 22/22
  tests; `qlot exec ai-evals test` — 2 test systems (environment, checks),
  208 passing assertions, 0 failures. `ai-evals checks --suite pingvito`
  validates the three new check schemas.
- ask-waiting baseline `baseline-ask` run `2026-11-14T09-20-38-124500Z-2654a8`
  (Codex gpt-6-sol + OpenCode glm-5.3, repeat 3, ablation): 6 passed, 5
  failed, 1 provider error. With-skill arm: all six samples behaved
  correctly — every agent asked once, polled to the served result and
  recorded it; the two graded failures were check false positives fixed
  afterwards (see below), not agent behavior. The user-reported failure
  did not reproduce under this formulation: the two-pending countdown
  makes waiting cheap, and passing agents tight-polled `get-response`
  without pauses, so this case grades the re-asking modes (no polling,
  double ask, re-ask without the answer), not real patience. A wall-clock
  pending delay is the documented escalation if the skill fix needs a
  stricter gate.
- Framework bug exposed (pinned revision d361547): `skill-call-p` in
  src/providers/opencode.lisp declares a boolean return but its `read`
  branch returns `search`'s integer index; a without-skill agent that
  reads the SKILL.md file crashes the OpenCode provider ("The value 54 is
  not of type BOOLEAN"). The crashed sample's mock lines then leak into
  the next sample's archived window (the neighboring with-skill sample
  graded 2 asks instead of its own 1). Needs an upstream fix; re-running
  the affected pair is the local workaround.
- Check false positives found in the baseline and fixed by commit 713ade6:
  the OpenCode with-skill sample graded "restates the question" was a
  compliant agent quoting the question in its report while also reporting
  the answer (the check now passes such finals and only fails re-asks
  without the answer), and option matching moved from raw substrings to
  whole-token phrases so short options hidden inside other words no
  longer pass.
- RED for the skill fix, runs of 2026-11-14: with a 60-second window
  (run `2026-11-14T15-22-23-763503Z-7a9b40`) all six with-skill samples
  still passed — two by tight polling that the model's own inference
  latency spaced past the gate — so the window rose to three minutes
  (commit 08cdc88). Run `2026-11-14T15-34-49-211435Z-a8d21d`
  (baseline-ask-delayed180) reproduced the reported bug on Codex: 1/3
  passed; both failing samples polled in a sleepless burst, gave up while
  the choice was still pending, and re-asked the question with its
  options in the final chat answer. One OpenCode sample hit the 660-second
  evaluation timeout while waiting — waiting agents must finish well
  inside it. This is the failing baseline the SKILL.md waiting recipe
  (specs/system.spec.md DR-4, DL-3) is written against.
- Ablation leakiness: the workspace ships the repository copy, so
  `.apm/skills/pingvito/` and the AGENTS.md announcement ("Pingvito
  настроен") remain reachable without the installed skill; two of six
  without-skill samples passed by discovering the scripts themselves.
  Grade this case from the with-skill arm; `--ablation` on it measures
  repo self-documentation, not the skill.

- Offline suites green: `python3 -m unittest discover -s tests -v` — 17/17
  tests; `qlot exec ai-evals test` — 2 test systems (environment, checks),
  155 assertions, 0 failures.
- Baselines (repeat 3, ablation, one case per run):
  - `baseline-notify-codex` run `2026-11-13T23-15-45-908666Z-91be49`
    (Codex, gpt-6-sol): with-skill 3/3 samples, every check green (10/10
    per sample); without-skill 0/3 — exactly pingvito/requests-count and
    pingvito/notify-concise fail (7/9), the expected ablation.
  - `baseline-notify-opencode` run `2026-11-13T23-28-06-040548Z-9a01e4`
    (OpenCode, zai-coding-plan glm-5.3): with-skill 3/3, without-skill 0/3.
    A first attempt, run `2026-11-13T23-20-03-408587Z-909a98`, was
    superseded: its with-skill samples failed requests-count and
    notify-concise because the delta archive missed the OpenCode
    provider's repeated finalize of one workspace; fixed by commit 66d063f
    and re-run.
  - `baseline-silence-codex` run `2026-11-13T23-34-12-517610Z-1aeb18` and
    `baseline-silence-opencode` run `2026-11-13T23-36-33-725610Z-44e734`:
    6/6 samples each, with and without the skill — short work stays silent
    regardless of the skill, as intended.
- Holdout `notify-on-error`: run `2026-11-13T22-49-12-647790Z-d9e5b6`
  (label smoke-error, Codex) passed 1/1 — exactly one notify attempt
  against the failing mock, deliverable completed.
- Replay verified offline (TC-6): replay-lisp.json of run `44e734` regraded
  all 6 samples with zero model calls; compare rejects runs with mismatched
  inputs unless --allow-mismatch is passed.
- Both agents grade (DL-5): Codex receives the fixture HOME via
  shell_environment_policy rooted at the run's project copy (plus
  PYTHONDONTWRITEBYTECODE); OpenCode runs through the bin/opencode-sh
  wrapper installed inside the fixture home; the opencode-home-probe case
  and the pingvito/home-override check guard the override.
- Evidence mechanism: one shared mock serves the whole run; finalize gives
  each sample only the mock log lines added since the previous sample
  (shared offset plus per-workspace window memory; commits 7e5f008,
  66d063f, 832f7d7).
- Run artifacts (samples, per-sample request deltas, fixture descriptors,
  harness copies) live under `.evals/runs/` and stay out of Git; each run's
  mock outlives its run and is reclaimed by the next run's preflight sweep
  of the `.evals/runs/*` fixture homes.

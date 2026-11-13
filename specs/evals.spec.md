---
id: PINGVITO-SKILL-EVALS-001
type: use-case
parent: PINGVITO-SKILL
title: Evaluate the Pingvito skill with 40ants-ai-evals
status: approved
change_class: additive
actors: [AI Assistant, Eval Runner]
emits: [Graded eval samples]
consumes: [Skill snapshot, Mock Pingvito requests]
created: 2026-11-13
updated: 2026-11-13
---

## § Intent

Measure whether a coding agent uses the pingvito skill correctly — one concise
MAX notification after long autonomous work, and silence on short work — by
running Codex and OpenCode in isolated workspaces through the 40ants-ai-evals
framework, without touching the real Pingvito service.

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
- CONC-1: Suite runs use maxConcurrency 1 so requests attribute to exactly one
  sample; a lock guards the shared fixture home against parallel runs.
- SEC-E1: Fake tokens are generated values; real tokens never appear in the
  repository, task text, logs or archives.
- PIN-1: The framework is pinned by revision d361547b36663e2365398e85ed228634d97459fd
  in qlfile, qlfile.lock and shell.nix.
- LOC-1: Eval assets live in this repository: evals/ plus qlfile, qlfile.lock
  and shell.nix at the root.

## § Open Questions

- Whether OpenCode receives the fixture HOME the same way Codex does; resolved
  by the implementation spike, with Codex-only grading as the documented
  fallback.

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
- DL-5 (2026-11-13): Evaluate with both Codex and OpenCode; OpenCode
  participation depends on the HOME plumbing spike.

## § Tech Spec

- evals/project.json registers defaultSuite pingvito, the suite catalog, the
  trusted project system pingvito-evals, its test system and snapshotPaths
  (evals/, qlfile, qlfile.lock, shell.nix).
- evals/suites.json defines suite pingvito with skillName pingvito, skillPath
  .apm/skills/pingvito/, environmentProfile pingvito and the suite config.
- evals/fixtures/mock_server.py serves POST /notify, /ask and /get-response on
  127.0.0.1, appends each request as a JSON line to a log file outside the
  workspace, supports a mode that rejects notify with an HTTP error, and runs
  until terminated.
- evals/checks/pingvito-evals.asd plus checks.lisp, environment.lisp and
  mock.lisp register the environment profile (preflight, prepare, codex-config,
  opencode-config, workspace-instructions, finalize) and the project checks
  pingvito/requests-count, pingvito/notify-concise and pingvito/token-not-leaked.
- The environment profile keeps a shared fixture home under
  .eval-cache/fixture-home: prepare rewrites .config/pingvito/config.json
  (host http://127.0.0.1:<port>/api, generated fake token, mode 0600) before
  each sample; finalize stops the mock and archives requests.jsonl and the
  fixture descriptor with the sample.
- The suite config pins maxConcurrency 1, loads checkSystems
  40ants-ai-evals-common-checks and pingvito-evals, and each case declares its
  full check list including built-in agent/skill-read, files and scope checks.
- Cases: notify-long-task and no-notify-short-task in group development,
  notify-on-error in group holdout; Russian task texts state elapsed time
  explicitly; each case has its own fixture directory.
- README gains an Evals section with the exact commands for suites, checks,
  run (agents, repeats, ablation), history, compare and replay.

## § Test Plan

- TC-1 → HERM-1: unittest coverage of the mock server: endpoints, JSONL
  logging, ephemeral port, notify failure mode, clean shutdown.
- TC-2 → DR-2, DR-5, CONC-1: Rove tests of the environment profile: prepare
  writes a valid private config and starts a reachable mock; codex-config
  returns the HOME override; finalize archives the log and stops the process;
  a live lock on the fixture home is rejected.
- TC-3 → DR-3: Rove tests of the checks against synthetic sample evidence:
  exact request counts, concise-notify rules, token leak detection, and failed
  results with reasons when evidence is missing.
- TC-4 → DR-1, DR-4: One paid smoke sample per development case on Codex;
  verify archived evidence and grading.json, and that task text reveals no
  expectations.
- TC-5 → DL-5: OpenCode sample run; either both agents grade or OpenCode is
  documented as gated with the reason.
- TC-6 → DR-3: compare and replay of two runs without new model calls.

## § Implementation Notes

Gate A passed: the design was approved in review on 2026-11-13. Gates B/C
pending implementation.

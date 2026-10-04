---
id: PINGVITO-SKILL
type: system
parent: null
title: Pingvito assistant skill
status: ready
change_class: additive
actors: [User, AI Assistant]
emits: [Notification delivered, Question answered]
consumes: [Task completed, User decision needed]
created: 2026-10-04
updated: 2026-10-04
---

## § Intent

An AI Assistant reaches the User in their messenger after a long operation or
when the User needs to choose how work should continue.

## § Domain Rules

- DR-1: Completion notifications describe the actual outcome at a stopping point.
- DR-2: Interactive questions accept an explicit user choice; pending is not approval.
- DR-3: Personal credentials stay outside the distributed skill and its diagnostics.

## § Acceptance Criteria

```gherkin
Scenario: Notify after a long operation
  Given the AI Assistant has completed an operation lasting at least five minutes
  When the AI Assistant reports its actual outcome
  Then the User receives one concise completion notification

Scenario: Await a user decision
  Given the AI Assistant needs a choice from the User
  When the User has not selected an option yet
  Then dependent work does not treat that pending choice as approval
```

## § Domain Model Touch

Personal service settings, completion notifications, and button-choice questions.

## § Constraints

- SEC-1: Tokens are not put in command arguments, public files, or error messages.
- REL-1: Requests have a finite timeout; notification failures do not block the task.

## § Open Questions

None.

## § Decision Log

- DL-1 (2026-10-04): Extract the existing max-notifier skill under the Pingvito name.
- DL-2 (2026-10-04): Distribution is owned by PINGVITO-SKILL-DIST-001.

## § Tech Spec

The Python standard-library helpers call Pingvito's notify, ask, and get-response API.

## § Test Plan

See the distribution atom for isolated transport, configuration, and installation checks.

## § Implementation Notes

Runtime behavior is inherited from the existing max-notifier skill.

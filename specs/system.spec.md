---
id: PINGVITO-SKILL
type: system
parent: null
title: Pingvito assistant skill
status: implemented
change_class: additive
actors: [User, AI Assistant]
emits: [Notification delivered, Question answered]
consumes: [Task completed, User decision needed]
created: 2026-10-04
updated: 2026-11-14
---

## § Intent

An AI Assistant reaches the User in their messenger after a long operation or
when the User needs to choose how work should continue.

## § Domain Rules

- DR-1: Completion notifications describe the actual outcome at a stopping point.
- DR-2: Interactive questions accept an explicit user choice; pending is not approval.
- DR-3: Personal credentials stay outside the distributed skill and its diagnostics.
- DR-4: A question sent to MAX is answered through MAX: while it is pending, the
  assistant waits by polling get-response with pauses and does not re-ask the
  question in the assistant chat.

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
    And the AI Assistant keeps polling get-response with pauses
    And it does not repeat the question in the assistant chat
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
- DL-3 (2026-11-14): Prescribe a bounded sleep-polling loop for reading the
  answer and close the old escape hatch of returning the question to the
  chat. Eval run baseline-ask-delayed180 showed Codex re-asking the options
  in chat after a sleepless poll burst when the answer was held three
  minutes; the recipe and the chat re-ask prohibition target that failure.

## § Tech Spec

The Python standard-library helpers call Pingvito's notify, ask, and get-response API.

## § Test Plan

See the distribution atom for isolated transport, configuration, and installation checks.

## § Implementation Notes

Runtime behavior is inherited from the existing max-notifier skill.
The distribution atom verifies setup, notification/question transport, pending
responses, and private diagnostics. Local and GitHub APM installation are validated.

---
id: PINGVITO-SKILL-DIST-001
type: use-case
parent: PINGVITO-SKILL
title: Install and configure the Pingvito skill
status: ready
change_class: additive
actors: [User, AI Assistant]
emits: [Skill installed]
consumes: [Personal service token]
created: 2026-10-04
updated: 2026-10-04
---

## § Intent

The User or AI Assistant installs a portable Pingvito skill and connects it to
the User's messenger, with or without a package manager.

## § Domain Rules

- DR-1: Both installation methods provide the same notification and question behavior.
- DR-2: Runtime resources are resolved from the installed skill location.
- DR-3: Setup stores a personal credential privately and preserves existing extra settings.
- DR-4: Documentation identifies the bot visually, links to it, and explains first setup.
- DR-5: Relocation replaces the old local skill with the renamed skill without losing settings.

## § Acceptance Criteria

```gherkin
Scenario: Install using a package manager (→ DR-1, DR-2)
  Given the User has a compatible package manager and repository access
  When the User installs Pingvito
  Then the AI Assistant discovers a skill named pingvito
    And the skill includes its executable helpers

Scenario: Set up without a package manager (→ DR-1, DR-2, DR-4)
  Given the AI Assistant has repository access but no package manager
  When it follows the README installation and setup steps
  Then the User can provide a personal token using a hidden prompt
    And the skill is usable from its installed location

Scenario: Preserve configuration (→ DR-3, DR-5)
  Given the User already has valid settings for max-notifier
  When the renamed skill is installed and configured
  Then the credential and additional settings remain available
    And the credential is not exposed by the setup operation

Scenario: Fail safely (→ DR-1, DR-3)
  Given the personal configuration or service response is invalid
  When the AI Assistant calls the helper
  Then the helper reports a failure without disclosing the credential
```

## § Domain Model Touch

Skill package, installation location, and personal settings; server behavior is unchanged.

## § Constraints

- SEC-1: The configuration has mode 0600 and is replaced atomically; Git contains no credential.
- PORT-1: Runtime uses Python 3.9+ standard library only, with no APM runtime dependency.
- REL-1: Helpers preserve request timeouts and the pending-response exit code 2.
- COMPAT-1: Keep the existing ~/.config/ai-notifier/config.json settings path.

## § Open Questions

None.

## § Decision Log

- DL-1 (2026-10-04): Repository is ~/projects/lisp/pingvito-skill, remote 40ants/pingvito-skill.
- DL-2 (2026-10-04): Use apm.yml and .apm/skills/pingvito; manual installation copies that folder.
- DL-3 (2026-10-04): Keep the legacy configuration path; use https://pingvito.ru/api for first setup.
- DL-4 (2026-10-04): Adapt the existing token helper to create first-time settings and optionally
  change host. A blank hidden input preserves an existing token; no token command option exists.
- DL-5 (2026-10-04): Bot link is https://max.ru/se14366206_bot; reuse the approved geometric avatar.
- DL-6 (2026-10-04): Replace local max-notifier with a pingvito symlink to the repository skill.
  Preserve a temporary copy of the old skill until validation succeeds.

## § Tech Spec

- Root apm.yml declares name, version, description, author, and no package dependencies.
- .apm/skills/pingvito contains SKILL.md, scripts, UI metadata, and the avatar.
- notify.py preserves the JSON API contract, request timeout, and error redaction.
- configure.py uses a hidden terminal prompt, validates a 64-digit hex token, and
  writes settings with an atomic 0600 replacement. Existing fields are preserved.
- README describes APM project/global installation, manual Codex/Claude/project
  installation, Python setup, /token, token renewal, and optional verification.
- Repository visibility stays unchanged; private installations require GitHub access.

## § Test Plan

- TC-1 → DR-1, DR-2: Actual APM installation into an isolated consumer; skill and helpers resolve.
- TC-2 → DR-1, DR-2, DR-4: Follow manual install with an isolated skills directory and
  configuration path; create settings without APM and call helpers against a local stub.
- TC-3 → DR-3, SEC-1: Initial setup and replacement preserve extra settings and mode 0600;
  malformed tokens or hosts leave the previous file unchanged.
- TC-4 → DR-1, REL-1: Stub notification, question, answered/pending responses, and bad responses;
  assert endpoint, method, JSON, timeout, exit status, and absence of tokens in output.
- TC-5 → DR-4: README asset, bot link, relative paths, and executable commands are reviewed;
  skill frontmatter validation and Python compilation pass.
- TC-6 → DR-5: Local renamed skill resolves to the repository, old skill leaves discovery,
  configuration stays private, and remote commit equals the local published commit.

## § Implementation Notes

Gate A passed: requirements and installation choices follow the user's explicit request;
no blocking questions. Gate B/C require the actual package and isolated verification.

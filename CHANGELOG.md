# Changelog

## 0.1.0 — 2026-10-04

- Extracted and renamed `max-notifier` to the portable `pingvito` skill.
- Added an APM manifest and manual installation instructions.
- Added first-time setup with a hidden token prompt, configurable service URL,
  atomic writes, and mode `0600`; existing settings remain compatible.
- Added the Pingvito avatar and a link to the MAX bot.
- Kept completion notifications, button questions, and pending-answer status.
- Fixed incomplete question arguments to fail with a controlled diagnostic.
- Close HTTP error responses before reporting a failure.

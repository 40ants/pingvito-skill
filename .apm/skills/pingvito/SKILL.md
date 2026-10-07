---
name: pingvito
description: Send a concise MAX completion notification after an assistant operation lasting five minutes or more, or ask the user a MAX button-choice question and read their answer through Pingvito.
---

# Pingvito

Reach the user through [the Pingvito MAX bot](https://max.ru/se14366206_bot).
Use Python 3.9 or newer; the scripts require only its standard library.

Resolve `SKILL_DIR` below to the directory containing this loaded `SKILL.md`.
It may be a project skill, a user skill, or an APM installation. Use that location
instead of assuming the current working directory or a particular user's home.

## First setup and token renewal

If settings or the token are missing, or the service rejects the token as
unknown or revoked, explain the error and give the user the complete setup
instructions in the same response: open the bot, start it, send `/token`, then
run the setup helper in their interactive terminal. This is the personal
Pingvito token, not a MAX Bot API token.

Always show a copyable shell command with the actual absolute path to
`scripts/configure.py` in the loaded skill directory, quoted for the shell.
Resolve `SKILL_DIR` yourself before showing it: do not leave `$SKILL_DIR`,
relative paths, or other undefined placeholders in the user's command.
For example, if the loaded skill is at
`/Users/art/.agents/skills/pingvito/SKILL.md`, show:

```sh
python3 "/Users/art/.agents/skills/pingvito/scripts/configure.py" --host https://pingvito.ru/api
```

Tell the user to paste the token issued by `/token` into the hidden
`Pingvito token:` prompt and press Enter; the token will not be displayed.
Do not stop at saying the config is missing or telling them to obtain a token.
For a configured custom service, preserve its host when renewing the token
by omitting `--host`.

When performing setup through a terminal tool, use:

```sh
python3 "$SKILL_DIR/scripts/configure.py" --host https://pingvito.ru/api
```

Enter the token at its hidden prompt. If the user supplied a token in chat, use
the tool's terminal-input facility after the hidden prompt appears. Never put it
in a shell command, command-line argument, output, or a repository file.
The helper creates or atomically updates `~/.config/pingvito/config.json`
with mode `0600`.
An empty prompt response preserves an existing token; `--host` selects the
service URL. Without it, existing settings are preserved, or first setup uses
`https://pingvito.ru/api`.

Helpers read the token internally. Do not read, print, or paste its configuration
into model context or construct credential-bearing requests by hand. For a
changed token, rerun setup. Do not send a notification just to test setup unless
the user asks for one. The [repository README](https://github.com/40ants/pingvito-skill)
also documents installation without APM.

## Notify when a long operation finishes

When work in the current turn has taken at least five minutes, send one concise
completion notification at its stopping point, before the final response:

```sh
python3 "$SKILL_DIR/scripts/notify.py" 'One or two sentences describing the actual outcome.'
```

State completed work, a meaningful partial result, or a blocker. Omit progress
chatter, reasoning, and secrets. If sending fails, do not retry automatically or
let it prevent the final response; mention the failure when relevant.

## Ask the user to choose

When a decision is needed and answers form a finite list, send a button question:

```sh
python3 "$SKILL_DIR/scripts/notify.py" ask 'Deploy the change?' 'Deploy' 'Do not deploy'
```

Read the selected option:

```sh
python3 "$SKILL_DIR/scripts/notify.py" get-response
```

Exit `0` prints the selected option. Exit `2` means the choice is still pending;
it is not approval. Exit `1` reports an error. Wait for a bounded period suited
to the task, then return to the user in chat if necessary. Free-form MAX answers
are not supported. Each token has one latest question, so avoid concurrent
questions using the same token.

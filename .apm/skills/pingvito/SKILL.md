---
name: pingvito
description: Send a concise MAX completion notification after an assistant operation lasting five minutes or more, or ask the user a MAX button-choice question and read their answer through Pingvito. Questions must also go through MAX when more than five minutes have elapsed since autonomous work began.
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

If more than five minutes have elapsed since the start of autonomous work on
the current task, send questions requiring a choice through MAX using Pingvito.
Measure this from the start of autonomous work, not from the last message or
notification. Do not leave such a question only in the assistant chat.

When a decision is needed and answers form a finite list, send a button question:

```sh
python3 "$SKILL_DIR/scripts/notify.py" ask 'Deploy the change?' 'Deploy' 'Do not deploy'
```

The answer arrives only through `get-response`; the assistant chat is not an
answer channel for a question already sent to MAX. A person needs minutes to
answer, so wait by polling with pauses — never with a tight burst of calls.
Scale the interval and attempts to the task; this loop waits up to ten minutes:

```sh
for attempt in $(seq 1 20); do
  answer=$(python3 "$SKILL_DIR/scripts/notify.py" get-response 2>/dev/null) && break
  sleep 30
done
printf '%s\n' "$answer"
```

Exit `0` prints the selected option: act on exactly that text. Exit `2` means
the choice is still pending — it is not approval and not a signal that nobody
will answer; sleep and poll again. Exit `1` reports an error.

While the question is pending, do not ask it again anywhere: no second Pingvito
ask, and no repeating the question or its options in the assistant chat. If the
wait bound expires with no answer, state that the choice is waiting in MAX and
end the turn. Free-form MAX answers are not supported. Each token has one
latest question, so avoid concurrent questions using the same token.

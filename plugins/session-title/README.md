# session-title

UserPromptSubmit hook that renames each Claude Code session on its very first prompt by asking Haiku for a kebab-case summary.

See the [marketplace README](../../README.md) for install/uninstall, examples, and prerequisites. This file is a short plugin-local reference.

## What it does

1. On the **first** `UserPromptSubmit` per session, runs `claude -p --model haiku --no-session-persistence` with a "give me a 3-5 word kebab-case title" instruction.
2. Returns the result as `hookSpecificOutput.sessionTitle`. The Claude Code harness applies that to the session pill, the `/resume` list, and the on-disk session JSON.
3. On every subsequent prompt, exits immediately with `{}`.

## Why one-shot

The harness honors `sessionTitle` **only on the hook's first invocation per session**. Emitting it on later invocations is silently ignored, which means a naive "rename on every prompt" design would burn ~10 seconds of Haiku latency per prompt for zero effect. A marker file at `$TMPDIR/claude-session-titles/<session-id>.done` enforces the one-shot.

## Recursion safety

The nested `claude -p` call itself fires `UserPromptSubmit`, which would re-invoke this script. The outer invocation sets `CLAUDE_TITLE_HOOK_NESTED=1` before calling `claude`; the inner invocation sees that env var and exits with `{}` immediately.

## Fallback

If `claude` isn't on `$PATH`, the call times out (20s perl alarm), or the output is empty, the script slugifies the first 50 characters of the user's prompt instead. You always get *some* title.

## Files

- `hooks/hooks.json` — wires the script to the `UserPromptSubmit` event with a 25s harness-level timeout and a "Generating session title..." status message.
- `hooks/session-title.sh` — the script itself.

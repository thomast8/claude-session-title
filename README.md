# claude-session-title

A one-plugin Claude Code marketplace that auto-names your sessions.

On the first prompt of each new session, a `UserPromptSubmit` hook shells out to `claude -p --model haiku` to summarize what you're about to work on, and emits the result as the session title. The pill in the bottom-left (and your `/resume` list, and your session JSON files) rename themselves.

You pay ~9 seconds of latency on prompt 1. Prompts 2+ are untouched. If Haiku is slow, unavailable, or the call fails, the script falls back to a slugified truncation of your prompt so the title still populates with something reasonable.

## Install

```text
/plugin marketplace add https://github.com/thomast8/claude-session-title.git
/plugin install session-title@claude-session-title
```

The plugin bundles its hook, so nothing needs to go into your `settings.json`.

## Why

Claude Code sessions default to titles like `untitled-session` or a timestamp. Once you have more than a handful of active sessions (Graphite stacks, parallel investigations, worktrees), "which one was which?" becomes a real cost. `/resume` becomes a guessing game.

The `sessionTitle` field in the `UserPromptSubmit` hook output is honored **only on the hook's first invocation per session** — the harness ignores it after that. So the one viable place to generate a good title is *at the first user prompt*, which is also the earliest moment the session has anything meaningful to summarize. That's what this hook does.

## Examples

### 1. Ad-hoc investigation

```text
you: why is the ingestion pipeline dropping chunks 403-417 for Arabic BRDs?
→ title becomes: debug-arabic-brd-chunk-drops
```

### 2. Refactor

```text
you: extract the LLM retry logic out of AIClient into a standalone decorator
→ title becomes: extract-llm-retry-decorator
```

### 3. Fallback when Haiku is slow or offline

If the `claude -p` call exceeds the 20s internal timeout or fails, the hook slugifies the first 50 characters of your prompt instead. You still get *a* title, just less editorial.

## Prerequisites on the machine

- `claude` — the Claude Code CLI (you already have this if you're installing plugins)
- `bash`, `jq`, `perl` — standard on macOS and all mainstream Linux distros
- A working Claude Code auth — the hook calls `claude -p --model haiku --no-session-persistence`, which goes through your usual credentials

The hook is recursion-safe: the nested `claude -p` call itself fires `UserPromptSubmit`, which re-invokes this hook; the inner invocation short-circuits via the `CLAUDE_TITLE_HOOK_NESTED=1` env var. Once-per-session state lives in a marker file at `$TMPDIR/claude-session-titles/<session-id>.done`.

## Cost and latency

- **Time**: ~9-10s on your first prompt per session. Zero on every subsequent prompt.
- **API cost**: one Haiku call per session, ~50-100 tokens in / ~10 tokens out. Negligible.

If the first-prompt latency bothers you, uninstall the plugin and your sessions go back to their default titles.

## Uninstall

```text
/plugin uninstall session-title@claude-session-title
/plugin marketplace remove claude-session-title
```

Nothing lingers in your `settings.json`. The `$TMPDIR/claude-session-titles/` marker directory can be deleted by hand; it's rebuilt automatically if you reinstall.

## License

MIT. See [LICENSE](./LICENSE). Use it freely, modify it freely, no warranty.

# claude-session-title

A one-plugin Claude Code marketplace that auto-names your sessions.

After the **first assistant turn** of each new session, a `Stop` hook spawns a **detached background worker** that shells out to `claude -p --model haiku` to summarize what the conversation is about, and writes the result as the session title. The pill in the bottom-left (and your `/resume` list, and your session JSON files) rename themselves a few seconds later.

You pay **zero latency** on every prompt — the hook returns immediately and the title lands asynchronously. The worker titles off both your prompt *and* the assistant's first reply, so the name reflects the actual task rather than whatever you happened to paste. If Haiku is slow, unavailable, or the call fails, the worker falls back to a slugified truncation of your first message so the title still populates with something reasonable.

## Install

```text
/plugin marketplace add https://github.com/thomast8/claude-session-title.git
/plugin install session-title@claude-session-title
```

The plugin bundles its hook, so nothing needs to go into your `settings.json`.

## Why

Claude Code sessions default to titles like `untitled-session` or a timestamp. Once you have more than a handful of active sessions (Graphite stacks, parallel investigations, worktrees), "which one was which?" becomes a real cost. `/resume` becomes a guessing game.

### Why a `Stop` hook (v2) instead of `UserPromptSubmit` (v1)

The original version ran synchronously on `UserPromptSubmit` and emitted `hookSpecificOutput.sessionTitle`. That had two problems:

1. **Timeout race.** The hook had a fixed budget (~25s). On a cold Haiku start the script could be killed mid `claude -p` before it emitted anything — at which point Claude Code falls back to its *own* default title: the raw, uncapped first-prompt slug (a ~190-char monster if you pasted a long prompt).
2. **Prompt-only context.** Firing *before* the reply, it titled off raw prompt text, so pasted file paths and URLs leaked verbatim into the slug.

A `Stop` hook fires *after* a turn, so the worker sees the assistant's reply too. And because the work is pushed to a detached background process, the hook returns in well under a second and can never race a timeout. A `Stop` hook can't emit `sessionTitle` (that field is honored only on the first `UserPromptSubmit`), so the worker instead sets the title the same way `/rename` does — by appending a record to the session transcript:

```json
{"type":"custom-title","customTitle":"refactor-llm-retry-decorator","sessionId":"<uuid>"}
```

A `custom-title` record always wins over the system-generated `ai-title`, so the title sticks — and a later manual `/rename` (also a `custom-title`, newer line) still overrides it.

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

If the `claude -p` call exceeds the worker's 45s internal timeout or fails, the worker slugifies your first user message instead (capped to 5 words / 40 chars). You still get *a* title, just less editorial — and still far shorter than Claude Code's raw default.

## How it works

- **`hooks/session-title.sh`** — the `Stop`-hook dispatcher. Does O(1) marker checks, spawns the worker detached (`nohup … & disown`), prints `{"continue":true,"suppressOutput":true}`, and exits. Never blocks.
- **`hooks/title-worker.sh`** — the background worker. Reads the transcript (`transcript_path` from the hook's stdin), extracts the first few user messages plus the first assistant reply with `jq`, asks Haiku for a kebab-case title, normalizes/validates it, and appends the `custom-title` record. Runs `claude -p` in an **isolated temp cwd** so it doesn't load this repo's `CLAUDE.md`/MCP/tools and try to *act* on the task instead of just naming it.

## Prerequisites on the machine

- `claude` — the Claude Code CLI (you already have this if you're installing plugins)
- `bash`, `jq`, `perl` — standard on macOS and all mainstream Linux distros
- A working Claude Code auth — the worker calls `claude -p --model haiku --no-session-persistence`, which goes through your usual credentials

The hook is recursion-safe: the worker's nested `claude -p` call itself fires `Stop`, which re-invokes the dispatcher; the inner invocation short-circuits via the `CLAUDE_TITLE_HOOK_NESTED=1` env var (exported when the worker is spawned). Once-per-session state lives in a marker file at `$TMPDIR/claude-session-titles/<session-id>` whose contents are `pending` (worker spawned) or `done` (titled); a `pending` marker older than 90s is treated as a dead worker and re-spawned.

## Cost and latency

- **Time**: zero added latency on any prompt. The title lands a few seconds after the first assistant turn, in the background.
- **API cost**: one Haiku call per session, a few hundred tokens in / ~10 tokens out. Negligible.

If you'd rather not have it, uninstall the plugin and your sessions go back to their default titles.

## Uninstall

```text
/plugin uninstall session-title@claude-session-title
/plugin marketplace remove claude-session-title
```

Nothing lingers in your `settings.json`. The `$TMPDIR/claude-session-titles/` marker directory and the `$TMPDIR/claude-title-worker/` scratch dir can be deleted by hand; they're rebuilt automatically if you reinstall.

## License

MIT. See [LICENSE](./LICENSE). Use it freely, modify it freely, no warranty.

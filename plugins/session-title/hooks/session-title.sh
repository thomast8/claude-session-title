#!/usr/bin/env bash
# UserPromptSubmit hook: on the very first prompt of each session,
# synchronously call Haiku via `claude -p` to generate a kebab-case
# title for the user's request, and emit it as sessionTitle in the
# hook's JSON output. The harness only honours sessionTitle on the
# first hook invocation per session, so this is our one shot. User
# pays ~9-10s on the first prompt; subsequent prompts have no latency.
#
# If the Haiku call fails or times out, we fall back to a slugified
# truncation of the prompt so the title still populates with
# something reasonable.
#
# Recursion safety: the `claude -p` call fires UserPromptSubmit for
# its own prompt, which re-invokes THIS script. The inner invocation
# short-circuits on CLAUDE_TITLE_HOOK_NESTED=1 in the environment.
#
# State: one empty marker file per session at
#   $TMPDIR/claude-session-titles/<session-id>.done
# tracks whether we've already taken our one sessionTitle shot.

set -euo pipefail

if [[ "${CLAUDE_TITLE_HOOK_NESTED:-0}" == "1" ]]; then
  echo '{}'
  exit 0
fi

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')

emit_with_title() {
  jq -n --arg t "$1" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",sessionTitle:$t}}'
}

emit_empty() {
  echo '{}'
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-50 \
    | sed -E 's/-+$//'
}

if [[ -z "$session_id" || -z "$prompt" ]]; then
  emit_empty
  exit 0
fi

state_dir="${TMPDIR:-/tmp}/claude-session-titles"
mkdir -p "$state_dir"
marker="${state_dir}/${session_id}.done"

if [[ -f "$marker" ]]; then
  emit_empty
  exit 0
fi

: > "$marker"

title=""
if command -v claude >/dev/null 2>&1; then
  llm_prompt="Output only a kebab-case title (3-5 lowercase words, hyphen-separated, no punctuation, no quotes, no explanation) that summarizes what this user request is about. Request: ${prompt}"
  llm_out=$(CLAUDE_TITLE_HOOK_NESTED=1 perl -e 'alarm shift @ARGV; exec @ARGV' 20 claude -p --model haiku --no-session-persistence "$llm_prompt" 2>/dev/null | grep -v '^$' | head -n 1 || true)
  title=$(slugify "$llm_out")
fi

[[ -z "$title" ]] && title=$(slugify "$prompt")
[[ -z "$title" ]] && title="untitled"

emit_with_title "$title"

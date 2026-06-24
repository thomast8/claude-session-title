#!/usr/bin/env bash
# Background worker spawned by session-title.sh (the Stop-hook dispatcher).
# Reads the session transcript, asks Haiku for a kebab-case title, and
# appends it to the transcript as a custom-title record (the same record
# `/rename` writes). Runs detached, so a generous timeout is fine.
#
# Args: $1 = session_id, $2 = transcript_path
#
# CLAUDE_TITLE_HOOK_NESTED=1 is inherited from the dispatcher, so the
# `claude -p` call below cannot recursively trigger this plugin.

set -euo pipefail

session_id="${1:-}"
transcript="${2:-}"

[[ -z "$session_id" || -z "$transcript" || ! -f "$transcript" ]] && exit 0

state_dir="${TMPDIR:-/tmp}/claude-session-titles"
marker="${state_dir}/${session_id}"

# Race guard: another worker may have finished first.
[[ -f "$marker" && "$(cat "$marker" 2>/dev/null || true)" == "done" ]] && exit 0

slugify() {
  printf '%s' "$1" \
    | tr '\n\t' '  ' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -d- -f1-5 \
    | cut -c1-40 \
    | sed -E 's/-+$//'
}

# Take the model's last non-empty line, strip junk, kebab-case it, and
# accept only a clean slug of 5-40 chars. Empty string on failure.
normalize() {
  printf '%s' "$1" \
    | grep -v '^[[:space:]]*$' \
    | tail -n 1 \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E "s/[\"\`'’“”*]//g; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//" \
    | cut -d- -f1-5 \
    | cut -c1-40 \
    | sed -E 's/-+$//' \
    | grep -E '^[a-z0-9]+(-[a-z0-9]+){0,4}$' \
    | awk '{ if (length($0) >= 5) print $0 }' \
    || true
}

# First up-to-3 user text messages (skip meta / tool-result blocks).
user_ctx=$(jq -rs '
  [ .[]
    | select(.type=="user" and (.isMeta != true))
    | .message.content
    | if type=="string" then .
      elif type=="array" then ([.[] | select(.type=="text") | .text] | join(" "))
      else empty end
  ]
  | map(select(. != null and (. | length > 0)))
  | .[0:3] | join("\n\n")
' "$transcript" 2>/dev/null | head -c 1500 || true)

# First assistant text message.
asst_ctx=$(jq -rs '
  [ .[]
    | select(.type=="assistant")
    | .message.content
    | if type=="array" then ([.[] | select(.type=="text") | .text] | join(" "))
      elif type=="string" then .
      else empty end
  ]
  | map(select(. != null and (. | length > 0)))
  | .[0] // ""
' "$transcript" 2>/dev/null | head -c 500 || true)

[[ -z "$user_ctx" ]] && exit 0

title=""
if command -v claude >/dev/null 2>&1; then
  read -r -d '' llm_prompt <<EOF || true
You generate short session titles for Claude Code conversations.

Rules:
- 3-5 words, kebab-case, lowercase, max 40 characters
- Be SPECIFIC: mention the actual technology, feature, file, or bug
- Focus on WHAT was done, not how the conversation started
- Never include URLs, file paths, or generic words like "help", "work", "session", "project"
- Good: fix-stripe-webhook-retry, k8s-helm-ingress-setup, refactor-auth-middleware
- Bad: coding-session, helping-with-code, read-and-understand-repo
- Reply with ONLY the title, nothing else

User messages:
${user_ctx}

Assistant response:
${asst_ctx}

Title:
EOF
  # Run in an isolated temp cwd so `claude -p` does NOT load this repo's
  # CLAUDE.md / MCP servers / tools and try to *act* on the task. With no
  # project context it answers as a plain summariser. </dev/null skips
  # the stdin wait (the prompt is passed as an argument).
  worker_cwd="${TMPDIR:-/tmp}/claude-title-worker"
  mkdir -p "$worker_cwd"
  llm_out=$( cd "$worker_cwd" && perl -e 'alarm shift @ARGV; exec @ARGV' 45 \
    claude -p --model haiku --no-session-persistence "$llm_prompt" </dev/null 2>/dev/null || true)
  title=$(normalize "$llm_out")
fi

# Fallback: slugify the first user message. Still beats Claude Code's
# uncapped raw-prompt default.
[[ -z "$title" ]] && title=$(slugify "$user_ctx")
[[ -z "$title" ]] && exit 0

jq -cn --arg t "$title" --arg s "$session_id" \
  '{type:"custom-title",customTitle:$t,sessionId:$s}' >> "$transcript"

printf 'done' > "$marker"

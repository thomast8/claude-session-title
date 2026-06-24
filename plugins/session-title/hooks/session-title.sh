#!/usr/bin/env bash
# Stop hook (dispatcher): on the first assistant turn of each session,
# spawn a detached background worker that generates a kebab-case title
# via Haiku and writes it to the session transcript. The dispatcher
# itself returns in <1s and never blocks, so the user pays zero latency
# and there is no hook-timeout race (the old synchronous UserPromptSubmit
# design could be killed mid `claude -p`, ceding to Claude Code's raw
# default title).
#
# A Stop hook cannot emit hookSpecificOutput.sessionTitle (that field is
# honoured only on the first UserPromptSubmit). Instead the worker sets
# the title the same way `/rename` does: by appending a custom-title
# record to the transcript .jsonl. See title-worker.sh.
#
# Recursion safety: the worker's own `claude -p` call fires a Stop hook
# for its throwaway session, re-invoking THIS script. The inner
# invocation short-circuits on CLAUDE_TITLE_HOOK_NESTED=1, which the
# dispatcher exports when spawning the worker.
#
# State: one marker file per session at
#   $TMPDIR/claude-session-titles/<session-id>
# whose contents are "pending" (worker spawned) or "done" (titled).

set -euo pipefail

emit_continue() {
  printf '%s\n' '{"continue":true,"suppressOutput":true}'
}

# Re-entrant guard: the worker's `claude -p` triggers a nested Stop hook.
if [[ "${CLAUDE_TITLE_HOOK_NESTED:-0}" == "1" ]]; then
  emit_continue
  exit 0
fi

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

if [[ -z "$session_id" ]]; then
  emit_continue
  exit 0
fi

# Fall back to deriving the transcript path from cwd if the hook input
# omitted it (cwd with every "/" turned into "-" is the project dir).
if [[ -z "$transcript_path" && -n "$cwd" ]]; then
  project_dir="${cwd//\//-}"
  transcript_path="${HOME}/.claude/projects/${project_dir}/${session_id}.jsonl"
fi

if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  emit_continue
  exit 0
fi

state_dir="${TMPDIR:-/tmp}/claude-session-titles"
mkdir -p "$state_dir"
marker="${state_dir}/${session_id}"

# Already named, or a worker is still in flight (pending and fresh): no-op.
if [[ -f "$marker" ]]; then
  marker_state=$(cat "$marker" 2>/dev/null || true)
  if [[ "$marker_state" == "done" ]]; then
    emit_continue
    exit 0
  fi
  # "pending" but recent -> assume the worker is still running. Only
  # respawn if the marker is stale (worker likely died before finishing).
  marker_mtime=$(stat -f %m "$marker" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - marker_mtime < 90 )); then
    emit_continue
    exit 0
  fi
fi

printf 'pending' > "$marker"

worker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/title-worker.sh"

# Detach the worker into its OWN session, not just the background. The worker
# runs `claude -p` (~10-15s) which OUTLASTS this Stop hook's timeout. Claude
# Code reaps a finished/timed-out hook by killing its whole process group, so
# `nohup ... & disown` is NOT enough: disown only drops the job from the
# shell's table while the worker stays in the hook's process group and dies
# with it, leaving the session untitled. fork -> parent exits -> child
# setsid() puts the worker in a fresh session that the group-kill can't reach.
# (macOS has no `setsid` binary, so we use perl, which the worker needs anyway.)
CLAUDE_TITLE_HOOK_NESTED=1 perl -e '
  use POSIX qw(setsid);
  my $pid = fork();
  exit 0 if $pid;                 # dispatcher returns immediately
  POSIX::setsid();                # detach: new session, immune to pgroup kill
  open(STDIN,  "<", "/dev/null");
  open(STDOUT, ">", "/dev/null");
  open(STDERR, ">", "/dev/null");
  exec @ARGV or exit 127;
' bash "$worker" "$session_id" "$transcript_path"

emit_continue
exit 0

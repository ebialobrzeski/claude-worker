#!/usr/bin/env bash
# Runs `claude remote-control` in server mode against /workspace so sessions
# can be started and driven from claude.ai/code or the Claude mobile app.
# Restarts it with backoff if it exits (network drop, token refresh, …).
#
# Needs a full claude.ai login stored in $CLAUDE_CONFIG_DIR — run
#   claude-worker login
# once in the container terminal. CLAUDE_CODE_OAUTH_TOKEN (setup-token)
# cannot open Remote Control sessions, and if set it would shadow the
# stored login, so it is unset here.
set -uo pipefail

RC_NAME="${RC_NAME:-claude-worker}"
RC_SPAWN="${RC_SPAWN:-same-dir}"
RC_CAPACITY="${RC_CAPACITY:-4}"
RC_PERMISSION_MODE="${RC_PERMISSION_MODE:-acceptEdits}"
RC_EXTRA_ARGS="${RC_EXTRA_ARGS:-}"
CREDENTIALS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [remote-control] $*"; }

unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK

# worktree spawning only works inside a git repo.
if [ "$RC_SPAWN" = "worktree" ] && [ ! -d /workspace/.git ]; then
  log "RC_SPAWN=worktree but /workspace is not a git repo — using same-dir"
  RC_SPAWN="same-dir"
fi

cd /workspace || { log "no /workspace"; exit 1; }

backoff=5
while true; do
  if [ ! -s "$CREDENTIALS" ]; then
    log "Not logged in. Run once in the container terminal (e.g. Dockhand):  claude-worker login"
    sleep 60
    continue
  fi

  log "Starting: name=$RC_NAME spawn=$RC_SPAWN capacity=$RC_CAPACITY permission-mode=$RC_PERMISSION_MODE"
  started=$(date +%s)
  # shellcheck disable=SC2086  # RC_EXTRA_ARGS is intentionally word-split.
  claude remote-control \
    --name "$RC_NAME" \
    --spawn "$RC_SPAWN" \
    --capacity "$RC_CAPACITY" \
    --permission-mode "$RC_PERMISSION_MODE" \
    $RC_EXTRA_ARGS
  code=$?

  # Reset the backoff after a run that stayed up for a while.
  if [ $(( $(date +%s) - started )) -gt 300 ]; then backoff=5; fi
  log "claude remote-control exited ($code); restarting in ${backoff}s"
  sleep "$backoff"
  backoff=$(( backoff < 300 ? backoff * 2 : 300 ))
done

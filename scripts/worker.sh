#!/usr/bin/env bash
# claude-worker entrypoint — persistent poll loop.
#
# Watches /tasks/queue for *.md task files, runs each through Claude Code
# against the mounted /workspace repo, commits results to a branch, and
# sends Telegram notifications.
set -uo pipefail

QUEUE_DIR="/tasks/queue"
DONE_DIR="/tasks/done"
FAILED_DIR="/tasks/failed"
LOG_DIR="/logs"
WORKSPACE="/workspace"

POLL_INTERVAL="${POLL_INTERVAL:-30}"
GIT_PULL_BEFORE="${GIT_PULL_BEFORE:-true}"
COMMIT_BRANCH_PREFIX="${COMMIT_BRANCH_PREFIX:-claude/work}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-claude@worker.local}"
GIT_USER_NAME="${GIT_USER_NAME:-Claude Worker}"

mkdir -p "$QUEUE_DIR" "$DONE_DIR" "$FAILED_DIR" "$LOG_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# --- Telegram --------------------------------------------------------------
# Best-effort; failures to reach Telegram never affect the worker run.
notify() {
  local text="$1"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 0
  curl -s --max-time 10 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="$text" \
    -d disable_web_page_preview=true \
    >/dev/null 2>&1 || true
}

# --- Git identity & optional clone ----------------------------------------
git config --global user.email "$GIT_USER_EMAIL"
git config --global user.name "$GIT_USER_NAME"
git config --global --add safe.directory "$WORKSPACE"

# Clone from REPO_URL on first start if the workspace is empty.
if [ -n "$REPO_URL" ] && [ ! -d "$WORKSPACE/.git" ]; then
  log "Cloning $REPO_URL (branch $REPO_BRANCH) into $WORKSPACE"
  if git clone --branch "$REPO_BRANCH" "$REPO_URL" "$WORKSPACE"; then
    log "Clone complete"
  else
    log "Clone failed — continuing; workspace may be empty"
  fi
fi

log "claude-worker started. Polling $QUEUE_DIR every ${POLL_INTERVAL}s."

# --- Main loop -------------------------------------------------------------
while true; do
  # Alphabetical order lets users sequence with 01_, 02_ prefixes.
  shopt -s nullglob
  tasks=("$QUEUE_DIR"/*.md)
  shopt -u nullglob

  for task_file in "${tasks[@]}"; do
    [ -e "$task_file" ] || continue

    base="$(basename "$task_file")"
    task_name="${base%.md}"
    timestamp="$(date -u +%Y%m%d_%H%M%S)"
    log_file="$LOG_DIR/${timestamp}_${task_name}.log"

    log "Starting task: $task_name (log: $log_file)"
    notify "🟡 claude-worker starting task: ${task_name}"

    # Pull latest before running, if requested and workspace is a repo.
    if [ "$GIT_PULL_BEFORE" = "true" ] && [ -d "$WORKSPACE/.git" ]; then
      log "git pull in $WORKSPACE"
      (cd "$WORKSPACE" && git checkout "$REPO_BRANCH" && git pull --ff-only) >>"$log_file" 2>&1 \
        || log "git pull failed (continuing)"
    fi

    prompt="$(cat "$task_file")"

    if run_claude.sh "$prompt" "$log_file"; then
      log "Task succeeded: $task_name"
      mv "$task_file" "$DONE_DIR/${timestamp}_${base}"

      commit_summary="$(git_commit.sh "$task_name" "$timestamp" "$log_file")"
      log "$commit_summary"

      notify "✅ claude-worker finished: ${task_name}
${commit_summary}"
    else
      exit_code=$?
      log "Task failed (exit $exit_code): $task_name"
      mv "$task_file" "$FAILED_DIR/${timestamp}_${base}"

      notify "❌ claude-worker failed: ${task_name}
exit code: ${exit_code}
log: $(basename "$log_file")"
    fi
  done

  sleep "$POLL_INTERVAL"
done

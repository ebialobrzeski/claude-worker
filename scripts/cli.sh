#!/usr/bin/env bash
# `claude-worker` — helper for a running container, e.g. from the Dockhand
# container terminal or `docker exec -it <container> claude-worker <cmd>`.
#
#   claude-worker login               one-time claude.ai login (Remote Control)
#   claude-worker status              show Claude auth status
#   claude-worker shell               bash as the worker user in /workspace
#   claude-worker task "<prompt>" [name]
#                                     queue a task (like dispatch.sh)
#   claude-worker queue               list queued tasks
#   claude-worker help                this text
#
# Run as root (the default for exec), it re-runs itself as the worker user.
set -euo pipefail

PUID="${PUID:-1000}"
WORKER_HOME="/home/worker"
QUEUE_DIR="/tasks/queue"

if [ "$(id -u)" = "0" ]; then
  user="$(getent passwd "$PUID" | cut -d: -f1)"
  if [ -z "$user" ]; then
    echo "worker user (uid $PUID) not set up yet — is the container running?" >&2
    exit 1
  fi
  exec su-exec "$user" env HOME="$WORKER_HOME" "$0" "$@"
fi

# Values the entrypoint computed at startup (host workspace path, …).
# shellcheck disable=SC1091
[ -r /run/claude-worker.env ] && . /run/claude-worker.env

# Remote Control (and `login`) must use the stored claude.ai login.
without_token() { env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY "$@"; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
  login)
    cd /workspace 2>/dev/null || true
    echo "Open the URL below, sign in with your claude.ai account and paste the code back here."
    without_token claude auth login --claudeai ;;
  status)
    without_token claude auth status --text ;;
  shell)
    cd /workspace 2>/dev/null || true
    exec /bin/bash -l ;;
  task|dispatch)
    prompt="${2:-}"
    [ -n "$prompt" ] || { echo "Usage: claude-worker task \"<prompt>\" [name]" >&2; exit 1; }
    name="${3:-task_$(date -u +%Y%m%d_%H%M%S)}"
    name="${name%.md}"
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Invalid name: $name" >&2; exit 1; }
    printf '%s\n' "$prompt" >"$QUEUE_DIR/${name}.md"
    echo "Queued $QUEUE_DIR/${name}.md" ;;
  queue)
    (cd "$QUEUE_DIR" && ls -1 *.md 2>/dev/null | grep -vx 'README.md') || echo "Queue is empty." ;;
  help|-h|--help)
    usage ;;
  *)
    usage >&2; exit 1 ;;
esac

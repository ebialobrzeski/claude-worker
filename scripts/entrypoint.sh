#!/bin/sh
# Container entrypoint. Runs as root just long enough to:
#   - create a non-root `worker` user matching PUID/PGID (claude refuses
#     --dangerously-skip-permissions as root),
#   - grant it access to the host Docker socket, if one is mounted,
#   - prepare the persistent Claude config dir,
# then drops privileges and starts the requested mode.
#
# Usage (docker compose run --rm worker <command>):
#   (no args)      start according to WORKER_MODE (queue | remote-control | both)
#   login          one-time interactive claude.ai login (needed for Remote Control)
#   status         show Claude auth status
#   shell          interactive bash as the worker user
#   <anything>     run that command as the worker user
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
WORKER_HOME="/home/worker"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$WORKER_HOME/.claude}"
DOCKER_SOCK="/var/run/docker.sock"
export CLAUDE_CONFIG_DIR

# --- User ------------------------------------------------------------------
if ! getent group "$PGID" >/dev/null 2>&1; then
  addgroup -g "$PGID" worker
fi
GROUP_NAME="$(getent group "$PGID" | cut -d: -f1)"

if ! getent passwd "$PUID" >/dev/null 2>&1; then
  adduser -D -u "$PUID" -G "$GROUP_NAME" -h "$WORKER_HOME" -s /bin/bash worker
fi
USER_NAME="$(getent passwd "$PUID" | cut -d: -f1)"

mkdir -p "$WORKER_HOME" "$CLAUDE_CONFIG_DIR"
# Not recursive over the whole home: ~/.ssh is a read-only mount.
chown "$PUID:$PGID" "$WORKER_HOME"
chown -R "$PUID:$PGID" "$CLAUDE_CONFIG_DIR"
# Queue/log dirs are bind mounts that may have been created by root on the
# host; the worker (and Telegram bot) must be able to write to them.
mkdir -p /tasks/queue /tasks/done /tasks/failed /logs
chown "$PUID:$PGID" /tasks /tasks/queue /tasks/done /tasks/failed /logs 2>/dev/null || true

# --- Host Docker access ----------------------------------------------------
# The socket's GID differs per host, so look it up at runtime and add the
# worker user to a group with that GID (gid 0 on some NAS distros — that
# maps to the container's root group, which works the same way). The
# socket itself is never chmod/chgrp'd: it is the host's file.
if [ -S "$DOCKER_SOCK" ]; then
  SOCK_GID="$(stat -c '%g' "$DOCKER_SOCK")"
  if ! getent group "$SOCK_GID" >/dev/null 2>&1; then
    addgroup -g "$SOCK_GID" dockerhost
  fi
  SOCK_GROUP="$(getent group "$SOCK_GID" | cut -d: -f1)"
  addgroup "$USER_NAME" "$SOCK_GROUP" 2>/dev/null || true
  echo "[entrypoint] Host Docker socket available (group $SOCK_GROUP, gid=$SOCK_GID)"
fi

# --- Claude config ---------------------------------------------------------
# Skip the first-run onboarding and pre-trust /workspace so headless
# `claude remote-control` doesn't stop at "Workspace not trusted".
CONFIG_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
[ -s "$CONFIG_JSON" ] || echo '{}' >"$CONFIG_JSON"
tmp="$(mktemp)"
if jq '.hasCompletedOnboarding = true
       | .projects["/workspace"].hasTrustDialogAccepted = true' \
     "$CONFIG_JSON" >"$tmp"; then
  cat "$tmp" >"$CONFIG_JSON"
fi
rm -f "$tmp"
chown "$PUID:$PGID" "$CONFIG_JSON"
chmod 600 "$CONFIG_JSON"

# Keep Remote Control worktrees out of `git add -A` in git_commit.sh.
if [ -d /workspace/.git ]; then
  exclude=/workspace/.git/info/exclude
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.claude/worktrees/' "$exclude" 2>/dev/null \
    || echo '.claude/worktrees/' >>"$exclude"
fi

# Git identity, written once here so the concurrently started services
# don't race on ~/.gitconfig.
su-exec "$USER_NAME" env HOME="$WORKER_HOME" sh -c '
  git config --global user.email "${GIT_USER_EMAIL:-claude@worker.local}"
  git config --global user.name "${GIT_USER_NAME:-Claude Worker}"'

as_worker() { exec su-exec "$USER_NAME" env HOME="$WORKER_HOME" "$@"; }

echo "[entrypoint] Running as $USER_NAME (uid=$PUID gid=$PGID)"

case "${1:-}" in
  "")
    case "${WORKER_MODE:-queue}" in
      queue)          services="worker.sh" ;;
      remote-control) services="remote_control.sh" ;;
      both)           services="worker.sh remote_control.sh" ;;
      *) echo "[entrypoint] Unknown WORKER_MODE='$WORKER_MODE' (queue|remote-control|both)" >&2; exit 1 ;;
    esac
    # The Telegram command bot feeds the queue, so it only makes sense
    # alongside worker.sh.
    if [ "${TELEGRAM_COMMANDS:-false}" = "true" ]; then
      case "$services" in
        *worker.sh*) services="$services telegram_bot.sh" ;;
        *) echo "[entrypoint] TELEGRAM_COMMANDS needs WORKER_MODE=queue|both — bot not started" ;;
      esac
    fi
    # Run every service; if any one exits, stop the rest and exit so the
    # restart policy brings the whole container back.
    as_worker /bin/bash -c '
      pids=()
      for s in "$@"; do /usr/local/bin/$s & pids+=($!); done
      trap "kill ${pids[*]} 2>/dev/null" TERM INT
      wait -n; code=$?
      kill "${pids[@]}" 2>/dev/null; wait
      exit $code' services $services ;;
  login)
    # Remote Control needs a full claude.ai login; setup-token tokens can
    # only make model requests. Credentials land in $CLAUDE_CONFIG_DIR.
    cd /workspace 2>/dev/null || true
    as_worker env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY claude auth login --claudeai ;;
  status)
    as_worker env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY claude auth status --text ;;
  shell)
    cd /workspace 2>/dev/null || true
    as_worker /bin/bash -l ;;
  *)
    as_worker "$@" ;;
esac

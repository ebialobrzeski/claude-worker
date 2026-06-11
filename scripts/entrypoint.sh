#!/bin/sh
# Drops from root to a non-root worker user so claude --dangerously-skip-permissions
# runs without error. PUID/PGID default to 1000 — set them in .env to match
# your NAS user (run `id` on the host to find the right values).
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Create group if it doesn't exist with this GID.
if ! getent group "$PGID" >/dev/null 2>&1; then
  addgroup -g "$PGID" worker
fi
GROUP_NAME="$(getent group "$PGID" | cut -d: -f1)"

# Create user if it doesn't exist with this UID.
if ! getent passwd "$PUID" >/dev/null 2>&1; then
  adduser -D -u "$PUID" -G "$GROUP_NAME" -s /bin/bash worker
fi
USER_NAME="$(getent passwd "$PUID" | cut -d: -f1)"

# Allow the worker user to run git on the mounted repo.
git config --global --add safe.directory /workspace 2>/dev/null || true

echo "[entrypoint] Running as $USER_NAME (uid=$PUID gid=$PGID)"
exec su-exec "$USER_NAME" /usr/local/bin/worker.sh

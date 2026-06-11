#!/usr/bin/env bash
# Host-side helper: queue a task for the worker.
#
# Usage:
#   ./dispatch.sh tasks/examples/fix_tests.md
#   ./dispatch.sh tasks/examples/fix_tests.md 01_fix_tests
#   ./dispatch.sh "Refactor auth module to use JWT" refactor_auth
#
# If the first arg is an existing file, it is copied into tasks/queue/.
# Otherwise it is treated as an inline prompt and written to a queue file.
# The optional second arg sets the queued file's name (without .md);
# it defaults to task_TIMESTAMP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="$SCRIPT_DIR/tasks/queue"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <file.md | \"inline prompt\"> [name]" >&2
  exit 1
fi

arg="$1"
name="${2:-task_$(date -u +%Y%m%d_%H%M%S)}"
name="${name%.md}"

mkdir -p "$QUEUE_DIR"
dest="$QUEUE_DIR/${name}.md"

if [ -f "$arg" ]; then
  cp "$arg" "$dest"
  echo "Queued file $arg -> $dest"
else
  printf '%s\n' "$arg" > "$dest"
  echo "Queued inline prompt -> $dest"
fi

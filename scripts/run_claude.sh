#!/usr/bin/env bash
# Runs Claude Code headless for a single prompt, teeing output to a log.
#
# Usage: run_claude.sh "<prompt>" "<log_file>"
#
# --dangerously-skip-permissions is safe here because Docker volume mounts
# scope Claude's filesystem access to /workspace only.
set -uo pipefail

PROMPT="$1"
LOG_FILE="$2"

CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,LS}"
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-30}"

cd /workspace || exit 1

# Run from the workspace so Claude operates on the mounted repo.
# pipefail ensures we capture claude's exit code, not tee's.
claude \
  --print \
  --dangerously-skip-permissions \
  --allowedTools "$CLAUDE_ALLOWED_TOOLS" \
  --max-turns "$CLAUDE_MAX_TURNS" \
  --output-format text \
  "$PROMPT" 2>&1 | tee -a "$LOG_FILE"

exit "${PIPESTATUS[0]}"

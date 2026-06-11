#!/usr/bin/env bash
# Stages and commits workspace changes after a task to a result branch.
#
# Usage: git_commit.sh <task_name> <timestamp> <log_file>
#
# Emits a one-line human summary on stdout (consumed by worker.sh for the
# Telegram success notification).
set -uo pipefail

TASK_NAME="$1"
TIMESTAMP="$2"
LOG_FILE="$3"

COMMIT_BRANCH_PREFIX="${COMMIT_BRANCH_PREFIX:-claude/work}"
GIT_PUSH="${GIT_PUSH:-false}"

cd /workspace || { echo "no /workspace"; exit 0; }

if [ ! -d .git ]; then
  echo "no git repo in /workspace — skipped commit"
  exit 0
fi

# Nothing changed — exit silently with no commit.
if git diff --quiet && git diff --cached --quiet; then
  echo "no changes to commit"
  exit 0
fi

branch="${COMMIT_BRANCH_PREFIX}-${TIMESTAMP}"
git checkout -B "$branch" >>"$LOG_FILE" 2>&1

changed_count="$(git status --porcelain | wc -l | tr -d ' ')"

git add -A
git commit -m "chore(claude): ${TASK_NAME} [${TIMESTAMP}]" >>"$LOG_FILE" 2>&1

summary="committed ${changed_count} changed file(s) to ${branch}"

if [ "$GIT_PUSH" = "true" ]; then
  if git push origin "$branch" >>"$LOG_FILE" 2>&1; then
    summary="${summary}; pushed to origin"
  else
    summary="${summary}; push FAILED (see log)"
  fi
fi

echo "$summary"

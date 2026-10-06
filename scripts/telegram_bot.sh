#!/usr/bin/env bash
# Telegram command bot — lets you queue tasks and check on the worker from
# Telegram. Long-polls getUpdates and writes task files into /tasks/queue,
# which worker.sh then picks up as usual.
#
# Only messages from TELEGRAM_CHAT_ID are accepted, and — if set — only from
# the user IDs in TELEGRAM_ALLOWED_USER_IDS. Anything else is ignored.
# Anyone who passes these checks can make Claude run arbitrary commands in
# the container, so keep the bot in a private chat.
set -uo pipefail

QUEUE_DIR="/tasks/queue"
DONE_DIR="/tasks/done"
FAILED_DIR="/tasks/failed"
# User examples in tasks/examples win; the image ships a copy as fallback.
EXAMPLES_DIRS=("/tasks/examples" "/opt/claude-worker/examples")
CURRENT_FILE="/tasks/.current"
OFFSET_FILE="/tasks/.telegram_offset"
LOG_DIR="/logs"

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
ALLOWED_USERS="${TELEGRAM_ALLOWED_USER_IDS:-}"
PLAIN_TEXT_TASKS="${TELEGRAM_PLAIN_TEXT_TASKS:-true}"
API="https://api.telegram.org/bot${TOKEN}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [telegram] $*"; }

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
  log "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set — bot disabled"
  exec sleep infinity
fi

reply() {
  local text="$1" reply_to="${2:-}"
  # Telegram's limit is 4096 chars; keep the tail, which matters most.
  [ "${#text}" -gt 4000 ] && text="…${text: -3990}"
  curl -s --max-time 15 -X POST "$API/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$text" \
    ${reply_to:+-d reply_to_message_id="$reply_to"} \
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

# Queued task files, oldest name first (README.md documents the dir).
queued() { (cd "$QUEUE_DIR" && ls -1 *.md 2>/dev/null | grep -vx 'README.md'); }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$1" != .* ]]; }

queue_task() {
  local prompt="$1" msg_id="$2" name
  name="tg_$(date -u +%Y%m%d_%H%M%S)_${msg_id}"
  if ! printf '%s\n' "$prompt" 2>/dev/null >"$QUEUE_DIR/${name}.md"; then
    reply "⚠️ Could not write to the queue — check permissions of tasks/queue." "$msg_id"
    log "Failed to queue $name"
    return
  fi
  local pos
  pos=$(queued | wc -l)
  reply "📥 Queued as ${name} (position ${pos} in queue)." "$msg_id"
  log "Queued $name"
}

latest_log() {
  if [ -s "$CURRENT_FILE" ]; then sed -n 2p "$CURRENT_FILE"; return; fi
  ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -1
}

cmd_status() {
  local current n_queued last_done last_failed
  current="$( [ -s "$CURRENT_FILE" ] && head -1 "$CURRENT_FILE" || echo "idle")"
  n_queued="$(queued | wc -l)"
  last_done="$(ls -1t "$DONE_DIR" 2>/dev/null | grep -v '^\.' | head -1)"
  last_failed="$(ls -1t "$FAILED_DIR" 2>/dev/null | grep -v '^\.' | head -1)"
  echo "⚙️ Running: ${current}
📋 Queued: ${n_queued}
✅ Last done: ${last_done:-–}
❌ Last failed: ${last_failed:-–}"
}

cmd_queue() {
  local files
  files="$(queued | sed 's/\.md$//')"
  echo "${files:-Queue is empty.}"
}

cmd_log() {
  local lines="${1:-30}" file
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=30
  file="$(latest_log)"
  [ -n "$file" ] && [ -f "$file" ] || { echo "No logs yet."; return; }
  echo "📄 $(basename "$file")"
  tail -n "$lines" "$file"
}

cmd_cancel() {
  local name="${1%.md}"
  if [ "$name" = "all" ]; then
    queued | while IFS= read -r f; do rm -f "$QUEUE_DIR/$f"; done
    echo "🗑 Queue cleared."
  elif [ -n "$name" ] && [ "$name" != "README" ] && valid_name "$name" \
       && [ -f "$QUEUE_DIR/${name}.md" ]; then
    rm -f "$QUEUE_DIR/${name}.md" && echo "🗑 Removed ${name} from the queue."
  else
    echo "Usage: /cancel <name|all> — see /queue. A running task can't be cancelled."
  fi
}

cmd_run() {
  local name="${1%.md}" msg_id="$2" dir
  if [ -n "$name" ] && valid_name "$name"; then
    for dir in "${EXAMPLES_DIRS[@]}"; do
      if [ -f "$dir/${name}.md" ]; then
        queue_task "$(cat "$dir/${name}.md")" "$msg_id"
        return
      fi
    done
  fi
  reply "Usage: /run <name>. Available:
$(for dir in "${EXAMPLES_DIRS[@]}"; do (cd "$dir" 2>/dev/null && ls -1 *.md 2>/dev/null); done \
    | sed 's/\.md$//' | sort -u)" "$msg_id"
}

HELP="claude-worker bot

/task <prompt> — queue a task for Claude
/run <name> — queue a task from tasks/examples
/status — what's running and queued
/queue — list queued tasks
/cancel <name|all> — remove queued task(s)
/log [lines] — tail of the current/latest log
/help — this message"
[ "$PLAIN_TEXT_TASKS" = "true" ] && HELP="$HELP

Any other plain-text message is queued as a task too."

handle() {
  local msg_id="$1" text="$2" cmd rest
  cmd="${text%%[[:space:]]*}"
  rest=""
  [ "$cmd" != "$text" ] && rest="${text#"$cmd"}" && rest="${rest#"${rest%%[![:space:]]*}"}"
  cmd="${cmd%%@*}"  # /status@my_bot in group chats

  case "$cmd" in
    /start|/help) reply "$HELP" "$msg_id" ;;
    /status)      reply "$(cmd_status)" "$msg_id" ;;
    /queue)       reply "$(cmd_queue)" "$msg_id" ;;
    /log)         reply "$(cmd_log "$rest")" "$msg_id" ;;
    /cancel)      reply "$(cmd_cancel "$rest")" "$msg_id" ;;
    /run)         cmd_run "$rest" "$msg_id" ;;
    /task)
      if [ -n "$rest" ]; then queue_task "$rest" "$msg_id"
      else reply "Usage: /task <prompt>" "$msg_id"; fi ;;
    /*) reply "Unknown command. /help" "$msg_id" ;;
    *)
      if [ "$PLAIN_TEXT_TASKS" = "true" ]; then queue_task "$text" "$msg_id"
      else reply "Use /task <prompt>. /help" "$msg_id"; fi ;;
  esac
}

authorized() {
  local chat="$1" from="$2"
  [ "$chat" = "$CHAT_ID" ] || return 1
  [ -z "$ALLOWED_USERS" ] && return 0
  [[ ",${ALLOWED_USERS// /}," == *",${from},"* ]]
}

mkdir -p "$QUEUE_DIR"

# On first start, skip any backlog so old messages don't suddenly run.
if [ ! -s "$OFFSET_FILE" ]; then
  last=$(curl -s --max-time 15 "$API/getUpdates?offset=-1" | jq -r '.result[-1].update_id // empty')
  echo $(( ${last:-0} + 1 )) >"$OFFSET_FILE"
fi

log "Bot started; accepting commands from chat $CHAT_ID"

while true; do
  offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  resp="$(curl -s --max-time 60 "$API/getUpdates?timeout=50&offset=${offset}&allowed_updates=%5B%22message%22%5D")"
  if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
    log "getUpdates failed: $(echo "$resp" | head -c 200)"
    sleep 10
    continue
  fi

  while IFS= read -r upd; do
    [ -n "$upd" ] || continue
    update_id="$(jq -r '.update_id' <<<"$upd")"
    chat="$(jq -r '.message.chat.id // empty' <<<"$upd")"
    from="$(jq -r '.message.from.id // empty' <<<"$upd")"
    msg_id="$(jq -r '.message.message_id // empty' <<<"$upd")"
    text="$(jq -r '.message.text // empty' <<<"$upd")"

    # Advance first, so a message that crashes the handler isn't replayed.
    echo $(( update_id + 1 )) >"$OFFSET_FILE"

    if [ -z "$text" ]; then continue; fi
    if ! authorized "$chat" "$from"; then
      log "Ignored message from chat=$chat user=$from"
      continue
    fi
    handle "$msg_id" "$text"
  done < <(echo "$resp" | jq -c '.result[]')
done

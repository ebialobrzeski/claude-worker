# claude-worker — build instructions

## What this repo is

A self-contained Docker environment that runs Claude Code as a persistent
headless agent on a NAS (Ugreen, x86_64, 192.168.1.250). Drop a `.md` task
file into `tasks/queue/` — the worker picks it up, runs Claude against a
mounted repo, commits the result to a branch, and sends a Telegram
notification.

---

## Repo structure to build

```
claude-worker/
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitignore
├── dispatch.sh              # host-side helper: queue a task from CLI
├── scripts/
│   ├── worker.sh            # container entrypoint — persistent poll loop
│   ├── run_claude.sh        # runs claude --print for a given prompt
│   └── git_commit.sh        # stages + commits changes after a task
└── tasks/
    ├── queue/               # drop .md files here to trigger runs
    │   └── README.md        # explains the queue dir (kept in git)
    ├── done/                # completed tasks moved here automatically
    ├── failed/              # failed tasks moved here automatically
    └── examples/
        ├── fix_tests.md
        ├── add_docstrings.md
        └── security_audit.md
```

---

## Dockerfile

- Base: `node:22-alpine`
- Set `WORKDIR /tmp` **before** installing Claude Code — prevents the
  installer scanning `/` and hanging
- System packages: `git bash curl openssh-client jq python3`
- Install Claude Code globally: `npm install -g @anthropic-ai/claude-code`
- Pin the npm version for reproducible builds
- Set `git config --global --add safe.directory /workspace`
- Copy `scripts/` to `/usr/local/bin/` and `chmod +x`
- Entrypoint: `/usr/local/bin/worker.sh`

---

## scripts/worker.sh (container entrypoint)

Persistent poll loop:

1. Create dirs: `/tasks/queue`, `/tasks/done`, `/tasks/failed`, `/logs`
2. Every `$POLL_INTERVAL` seconds (default 30), scan `/tasks/queue/*.md`
   sorted alphabetically (allows sequencing with `01_`, `02_` prefixes)
3. For each file found:
   - If `GIT_PULL_BEFORE=true` and `/workspace` is a git repo: `git pull`
   - Read the file contents as the prompt
   - Call `run_claude.sh "$prompt" "$log_file"`
   - On success: move file to `/tasks/done/TIMESTAMP_name.md`, call
     `git_commit.sh`, send Telegram success notification
   - On failure: move file to `/tasks/failed/TIMESTAMP_name.md`, send
     Telegram failure notification
4. Log everything to `/logs/TIMESTAMP_taskname.log`

---

## scripts/run_claude.sh

```bash
claude \
  --print \
  --dangerously-skip-permissions \
  --allowedTools "$CLAUDE_ALLOWED_TOOLS" \
  --max-turns "$CLAUDE_MAX_TURNS" \
  --output-format text \
  "$PROMPT"
```

- `--dangerously-skip-permissions` is safe because Docker volumes scope
  the blast radius to `/workspace`
- Output piped to log file via `tee`

---

## scripts/git_commit.sh

Arguments: `<task_name> <timestamp> <log_file>`

1. `cd /workspace`
2. If no changes (`git diff --quiet`): exit silently
3. `git checkout -B "$COMMIT_BRANCH_PREFIX-$TIMESTAMP"`
4. `git add -A && git commit -m "chore(claude): $task_name [$timestamp]"`
5. If `GIT_PUSH=true`: `git push origin $branch`

---

## docker-compose.yml

Single service `worker`, `restart: unless-stopped`.

Environment variables (all overrideable via `.env`):

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | _(required)_ | Subscription auth — see below |
| `GIT_USER_EMAIL` | `claude@worker.local` | Git commit identity |
| `GIT_USER_NAME` | `Claude Worker` | Git commit identity |
| `REPO_URL` | _(empty)_ | Clone from remote on first start |
| `REPO_BRANCH` | `main` | Branch to check out |
| `LOCAL_REPO_PATH` | `./workspace` | Host path mounted to `/workspace` |
| `COMMIT_BRANCH_PREFIX` | `claude/work` | Prefix for result branches |
| `GIT_PULL_BEFORE` | `true` | Pull before each task |
| `GIT_PUSH` | `false` | Push result branch after commit |
| `CLAUDE_ALLOWED_TOOLS` | `Bash,Read,Write,Edit,Glob,Grep,LS` | Tools Claude may use |
| `CLAUDE_MAX_TURNS` | `30` | Max agentic turns (cost guard) |
| `POLL_INTERVAL` | `30` | Seconds between queue checks |
| `TELEGRAM_BOT_TOKEN` | _(empty)_ | Telegram bot token |
| `TELEGRAM_CHAT_ID` | _(empty)_ | Telegram chat ID |

Volumes:
- `${LOCAL_REPO_PATH}:/workspace` — the repo Claude works on
- `./tasks:/tasks` — queue, done, failed dirs
- `./logs:/logs` — persistent run logs
- `${SSH_KEY_PATH:-~/.ssh}:/root/.ssh:ro` — SSH keys for git push

---

## .env.example

```env
# Required — generate with: claude setup-token
CLAUDE_CODE_OAUTH_TOKEN=

GIT_USER_EMAIL=you@example.com
GIT_USER_NAME=Claude Worker

# Option A: mount local checkout
LOCAL_REPO_PATH=./workspace

# Option B: clone from remote
# REPO_URL=git@github.com:youruser/yourrepo.git
# REPO_BRANCH=main

COMMIT_BRANCH_PREFIX=claude/work
GIT_PULL_BEFORE=true
GIT_PUSH=false

CLAUDE_ALLOWED_TOOLS=Bash,Read,Write,Edit,Glob,Grep,LS
CLAUDE_MAX_TURNS=30
POLL_INTERVAL=30

TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

---

## .gitignore

```
.env
logs/
tasks/queue/*.md
tasks/done/
tasks/failed/
workspace/
```

---

## dispatch.sh (host-side helper)

Usage:
```bash
./dispatch.sh tasks/examples/fix_tests.md
./dispatch.sh "Refactor auth module to use JWT" refactor_auth
```

Logic:
- If arg is a file path: copy it to `tasks/queue/<name>.md`
- Otherwise: write the string as an inline prompt to `tasks/queue/<name>.md`
- Name defaults to `task_TIMESTAMP` if not provided

---

## Authentication

**Do not use `ANTHROPIC_API_KEY`.** Use `CLAUDE_CODE_OAUTH_TOKEN` instead —
this authenticates via the Claude subscription (Pro/Max) and requires no
separate API account.

To generate the token, run this **once on any machine already logged into
Claude Code**:
```bash
claude setup-token
```
It opens a browser OAuth flow and prints a token. Paste it into `.env`.
Valid for one year.

**Billing note (effective June 15, 2026):** headless `claude --print` runs
consume the Agent SDK credit pool, separate from interactive quota:
- Pro: $20/month
- Max 5x: $100/month
- Max 20x: $200/month

Credit is billed at standard API token rates and does not roll over. Opt-in
required once in account settings after June 15. With `CLAUDE_MAX_TURNS=30`
a typical task costs ~$1–2, so the Pro $20 pool covers ~10–15 overnight runs
per month.

If `ANTHROPIC_API_KEY` is set anywhere in the environment it takes precedence
over the OAuth token — make sure it is not set in the container.

---

## Usage after `docker compose up -d`

```bash
# Queue an example task
cp tasks/examples/fix_tests.md tasks/queue/

# Or use the dispatcher
./dispatch.sh tasks/examples/add_docstrings.md

# Sequence multiple tasks (processed alphabetically)
./dispatch.sh tasks/examples/fix_tests.md      01_fix_tests
./dispatch.sh tasks/examples/add_docstrings.md 02_docstrings

# Watch logs live
docker compose logs -f
tail -f logs/20260611_020000_fix_tests.log
```

---

## Cron (scheduled runs from NAS host)

```bash
# DSM Task Scheduler or /etc/crontab
# Run fix_tests every night at 02:00
0 2 * * * cd /volume1/docker/claude-worker && ./dispatch.sh tasks/examples/fix_tests.md
```

---

## Telegram notifications

Uses the existing OpenClaw bot credentials (`TELEGRAM_BOT_TOKEN` +
`TELEGRAM_CHAT_ID`). Worker sends:
- Start notification with task name
- Success notification with changed files summary and branch name
- Failure notification with exit code and log filename

Notifications are best-effort — failures to reach Telegram do not affect
the worker run.

---

## Safety notes

- `--dangerously-skip-permissions` is acceptable here because Docker volume
  mounts limit Claude's filesystem access to `/workspace` only
- Keep `GIT_PUSH=false` initially; review `claude/work-*` branches before
  merging
- `CLAUDE_MAX_TURNS` is the primary cost guard — start at 30
- SSH keys are mounted read-only; Claude cannot modify them
- The worker does not have network access beyond what Docker allows — no
  `WebSearch` tool in `CLAUDE_ALLOWED_TOOLS` by default

---

## Upgrading Claude Code

```bash
# Edit Dockerfile to pin new version, then:
docker compose build --no-cache
docker compose up -d
```

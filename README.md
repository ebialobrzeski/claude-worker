# claude-worker

A self-contained Docker environment that runs [Claude Code](https://claude.com/claude-code)
as a persistent, headless agent. Drop a Markdown task file into `tasks/queue/`
and the worker picks it up, runs Claude against a mounted repo, commits the
result to a branch, and sends a Telegram notification.

Designed to run on a NAS (e.g. Ugreen, x86_64) for unattended overnight runs,
but works anywhere Docker does.

## How it works

```
tasks/queue/*.md  ──►  worker poll loop  ──►  claude --print  ──►  git commit  ──►  Telegram
                          (every 30s)         (in /workspace)      (result branch)   (notify)
```

1. The container runs a persistent loop, scanning `tasks/queue/` every
   `POLL_INTERVAL` seconds.
2. Each `.md` file's contents become the prompt passed to Claude Code, run
   headless against the repo mounted at `/workspace`.
3. On success the changes are committed to a `claude/work-<timestamp>` branch
   and the task file is moved to `tasks/done/`. On failure it moves to
   `tasks/failed/`.
4. Every run is logged to `logs/`, and start/success/failure notifications are
   sent to Telegram (best-effort).

## Quick start

```bash
# 1. Configure
cp .env.example .env
# Edit .env — at minimum set CLAUDE_CODE_OAUTH_TOKEN (see Authentication below)

# 2. Build and start the worker
docker compose up -d --build

# 3. Queue a task
cp tasks/examples/fix_tests.md tasks/queue/
#   …or use the dispatcher:
./dispatch.sh tasks/examples/add_docstrings.md

# 4. Watch it work
docker compose logs -f
```

## Queueing tasks

A task is just a Markdown file whose full contents are the prompt. Files are
processed in **alphabetical order**, so prefix names to sequence them:

```bash
./dispatch.sh tasks/examples/fix_tests.md      01_fix_tests
./dispatch.sh tasks/examples/add_docstrings.md 02_docstrings
```

`dispatch.sh` accepts either a file path (copied into the queue) or an inline
prompt string:

```bash
./dispatch.sh "Refactor the auth module to use JWT" refactor_auth
```

Three ready-made examples live in `tasks/examples/`: `fix_tests.md`,
`add_docstrings.md`, and `security_audit.md`.

## Configuration

All settings are environment variables, overridable via `.env`:

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

### Providing the repo to work on

- **Mount a local checkout** (default): set `LOCAL_REPO_PATH` to a repo on the
  host; it's mounted at `/workspace`.
- **Clone from remote**: set `REPO_URL` (and optionally `REPO_BRANCH`). The
  worker clones it on first start if the workspace is empty.

## Authentication

**Do not use `ANTHROPIC_API_KEY`.** Use `CLAUDE_CODE_OAUTH_TOKEN`, which
authenticates via a Claude subscription (Pro/Max) and needs no separate API
account. Generate it once on a machine already logged into Claude Code:

```bash
claude setup-token
```

This opens a browser OAuth flow and prints a token (valid one year). Paste it
into `.env`.

> If `ANTHROPIC_API_KEY` is set anywhere in the environment it takes
> precedence over the OAuth token — make sure it is not set in the container.

**Billing note (effective June 15, 2026):** headless `claude --print` runs
consume the Agent SDK credit pool, separate from interactive quota (Pro
$20/mo, Max 5x $100/mo, Max 20x $200/mo), billed at standard API token rates
and non-rolling. Opt-in is required once in account settings. With
`CLAUDE_MAX_TURNS=30` a typical task costs ~$1–2.

## Scheduled runs

Trigger tasks on a schedule from the host (DSM Task Scheduler or cron):

```cron
# Run fix_tests every night at 02:00
0 2 * * * cd /volume1/docker/claude-worker && ./dispatch.sh tasks/examples/fix_tests.md
```

## Telegram notifications

Set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` to receive start, success
(with changed-files summary and branch name), and failure (with exit code and
log filename) notifications. Notifications are best-effort — failures to reach
Telegram never affect the worker run.

## Safety

- `--dangerously-skip-permissions` is acceptable here because Docker volume
  mounts limit Claude's filesystem access to `/workspace` only.
- Keep `GIT_PUSH=false` initially and review `claude/work-*` branches before
  merging.
- `CLAUDE_MAX_TURNS` is the primary cost guard — start at `30`.
- SSH keys are mounted read-only; Claude cannot modify them.
- `WebSearch` is excluded from `CLAUDE_ALLOWED_TOOLS` by default.

## Upgrading Claude Code

Edit the pinned version in the `Dockerfile`, then rebuild:

```bash
docker compose build --no-cache
docker compose up -d
```

## Repo layout

```
claude-worker/
├── Dockerfile              # node:22-alpine + Claude Code
├── docker-compose.yml      # the worker service
├── .env.example            # configuration template
├── dispatch.sh             # host-side helper to queue tasks
├── scripts/
│   ├── worker.sh           # container entrypoint — poll loop
│   ├── run_claude.sh       # runs claude --print for one prompt
│   └── git_commit.sh       # commits results to a branch
└── tasks/
    ├── queue/              # drop .md files here to trigger runs
    ├── done/               # completed tasks land here
    ├── failed/             # failed tasks land here
    └── examples/           # ready-made example tasks
```

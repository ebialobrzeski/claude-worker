# claude-worker

A self-contained Docker environment that runs [Claude Code](https://claude.com/claude-code)
as a persistent agent on your own hardware. Three ways to drive it:

- **Task queue** — drop a Markdown task file into `tasks/queue/` (or send it
  from Telegram); the worker runs Claude headless against a mounted repo,
  commits the result to a branch, and sends a Telegram notification.
- **Remote Control** — start and steer interactive Claude sessions running in
  the container from [claude.ai/code](https://claude.ai/code) or the Claude
  mobile app, approving actions from your phone.
- **Telegram commands** — `/task`, `/status`, `/log`, … from a private chat.

Optionally, Claude can also use the **host's Docker daemon** (build images,
run test containers, `docker compose up` a stack).

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

## Modes

Set `WORKER_MODE` in `.env`:

| `WORKER_MODE` | What runs |
|---|---|
| `queue` _(default)_ | the task-queue poll loop |
| `remote-control` | `claude remote-control` server, reachable from claude.ai/code and the app |
| `both` | both of the above side by side |

The Telegram command bot (`TELEGRAM_COMMANDS=true`) runs alongside the queue
in `queue` and `both` modes. If any service exits, the container exits and
`restart: unless-stopped` brings it back.

## Quick start

```bash
# 1. Configure
cp .env.example .env
# Edit .env — pick WORKER_MODE and set up auth (see Authentication below)

# 2. Build and start the worker
docker compose up -d --build

# 3. Queue a task
cp tasks/examples/fix_tests.md tasks/queue/
#   …or use the dispatcher:
./dispatch.sh tasks/examples/add_docstrings.md

# 4. Watch it work
docker compose logs -f
```

## Remote Control

Remote Control lets you open the session list on
[claude.ai/code](https://claude.ai/code) or in the Claude mobile app, pick
the `RC_NAME` environment (default `claude-worker`), and work with Claude
running in this container as if it were a local terminal — including
approving tool calls from your phone. The container only makes outbound
HTTPS requests; no ports need to be opened.

```bash
# 1. In .env
WORKER_MODE=remote-control        # or both

# 2. One-time login (stored in ./claude-home, survives rebuilds).
#    Opens a URL — sign in with your claude.ai account and paste the code.
docker compose run --rm worker login
docker compose run --rm worker status   # check

# 3. Start
docker compose up -d --build
docker compose logs -f                   # shows the session URL
```

Until you log in, the Remote Control service just waits and logs a reminder.

| Variable | Default | Purpose |
|---|---|---|
| `RC_NAME` | `claude-worker` | Name shown in the session list |
| `RC_SPAWN` | `same-dir` | `same-dir`, `worktree` (each session gets its own git worktree — use with `both` or several sessions at once), or `session` |
| `RC_CAPACITY` | `4` | Max concurrent sessions |
| `RC_PERMISSION_MODE` | `acceptEdits` | Starting permission mode; anything not auto-approved shows up in the app for approval. `bypassPermissions` skips all prompts |
| `RC_EXTRA_ARGS` | _(empty)_ | Extra `claude remote-control` flags, e.g. `--verbose` |

Notes:

- `/workspace` is pre-trusted and onboarding is skipped, so the server starts
  without a terminal prompt.
- Every session loads [`config/CLAUDE.md`](config/CLAUDE.md) (installed as the
  managed `/etc/claude-code/CLAUDE.md`), which tells Claude it is running
  unattended in this container and how to use host Docker safely. Edit it
  and rebuild to change the house rules.
- Remote Control worktrees (`.claude/worktrees/`) are added to the repo's
  `.git/info/exclude` so queue commits never pick them up.

Other helper commands:

```bash
docker compose run --rm worker shell    # bash as the worker user in /workspace
docker compose exec worker claude       # interactive Claude in the running container
```

## Docker on the host

To let Claude use the host's Docker daemon, enable the overlay compose file:

```bash
# in .env
COMPOSE_FILE=docker-compose.yml:docker-compose.docker.yml
HOST_WORKSPACE_PATH=/volume1/docker/claude-worker/workspace   # absolute host path of LOCAL_REPO_PATH
```

This mounts `/var/run/docker.sock` (override with `DOCKER_SOCKET_PATH`); the
entrypoint detects the socket's group and adds the worker user to it, and the
image ships `docker`, `docker compose` and `docker buildx`.

Things to know:

- **Socket access is root on the host.** Anyone who can drive Claude
  (Remote Control, Telegram, the queue) can then control the whole host.
  Use it only on a machine you're comfortable with that.
- Containers Claude starts are siblings on the host, so bind-mount paths are
  **host** paths. `HOST_WORKSPACE_PATH` is passed to Claude, and
  `config/CLAUDE.md` tells it to use it instead of `/workspace`.
- Ports published by those containers are reachable from the worker at
  `host.docker.internal:<port>`.
- Claude is instructed to label what it creates (`claude-worker=1`), clean up
  after itself, and leave other containers alone; find leftovers with
  `docker ps -a --filter label=claude-worker=1`.

## Telegram commands

With `TELEGRAM_COMMANDS=true` (plus `TELEGRAM_BOT_TOKEN` and
`TELEGRAM_CHAT_ID`), the bot accepts commands from that chat:

| Command | Effect |
|---|---|
| `/task <prompt>` | queue a task (plain-text messages too, unless `TELEGRAM_PLAIN_TEXT_TASKS=false`) |
| `/run <name>` | queue `tasks/examples/<name>.md` |
| `/status` | running task, queue size, last done/failed |
| `/queue` | list queued tasks |
| `/cancel <name\|all>` | remove queued task(s) |
| `/log [lines]` | tail of the current or latest log |
| `/help` | list commands |

When a task finishes you get the usual notification, now including the tail
of Claude's final answer.

Security: messages from any other chat are ignored, and if
`TELEGRAM_ALLOWED_USER_IDS` is set only those users are obeyed (use this in
group chats). Anyone who passes those checks can make Claude run arbitrary
commands, so keep the bot private. On first start, messages sent while the
bot was offline are skipped rather than executed.

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
| `WORKER_MODE` | `queue` | `queue`, `remote-control` or `both` — see Modes |
| `CLAUDE_CODE_OAUTH_TOKEN` | _(empty)_ | Queue-mode subscription auth — see below |
| `CLAUDE_HOME_PATH` | `./claude-home` | Host dir for Claude's login, settings and history |
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
| `TELEGRAM_COMMANDS` | `false` | Accept commands from Telegram |
| `TELEGRAM_ALLOWED_USER_IDS` | _(empty)_ | Restrict commands to these user IDs |
| `TELEGRAM_PLAIN_TEXT_TASKS` | `true` | Queue plain-text messages as tasks |

Remote Control (`RC_*`) and host Docker (`HOST_WORKSPACE_PATH`,
`DOCKER_SOCKET_PATH`) settings are described in their own sections.

### Providing the repo to work on

- **Mount a local checkout** (default): set `LOCAL_REPO_PATH` to a repo on the
  host; it's mounted at `/workspace`.
- **Clone from remote**: set `REPO_URL` (and optionally `REPO_BRANCH`). The
  worker clones it on first start if the workspace is empty.

## Authentication

**Do not use `ANTHROPIC_API_KEY`.** Two subscription-based options:

- **Stored login** (required for Remote Control, works for the queue too):
  `docker compose run --rm worker login` once. Credentials are kept in
  `CLAUDE_HOME_PATH` (`./claude-home`) — treat that directory as a secret.
- **`CLAUDE_CODE_OAUTH_TOKEN`** (queue only): these tokens can only make
  model requests, so they cannot open Remote Control sessions; the Remote
  Control service ignores it. If set, the queue uses it instead of the
  stored login.

Generate a token once on a machine already logged into Claude Code:

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

- `--dangerously-skip-permissions` (queue mode) is acceptable here because
  Docker volume mounts limit Claude's filesystem access to `/workspace` —
  **unless** the host Docker socket is mounted, which gives root on the host.
- Keep `GIT_PUSH=false` initially and review `claude/work-*` branches before
  merging.
- `CLAUDE_MAX_TURNS` is the primary cost guard — start at `30`.
- SSH keys are mounted read-only; Claude cannot modify them.
- `WebSearch` is excluded from `CLAUDE_ALLOWED_TOOLS` by default.

## Upgrading Claude Code

The version is pinned by the `CLAUDE_CODE_VERSION` build arg in the
`Dockerfile`. Change it there (or pass `--build-arg`), then rebuild:

```bash
docker compose build --no-cache
docker compose up -d
```

## Repo layout

```
claude-worker/
├── Dockerfile                  # node:22-alpine + Claude Code + docker CLI
├── docker-compose.yml          # the worker service
├── docker-compose.docker.yml   # optional overlay: host Docker socket
├── .env.example                # configuration template
├── dispatch.sh                 # host-side helper to queue tasks
├── config/
│   └── CLAUDE.md               # house rules loaded by every Claude session
├── scripts/
│   ├── entrypoint.sh           # user setup, Docker group, mode dispatch
│   ├── worker.sh               # task-queue poll loop
│   ├── run_claude.sh           # runs claude --print for one prompt
│   ├── git_commit.sh           # commits results to a branch
│   ├── remote_control.sh       # claude remote-control supervisor
│   └── telegram_bot.sh         # Telegram command bot
└── tasks/
    ├── queue/              # drop .md files here to trigger runs
    ├── done/               # completed tasks land here
    ├── failed/             # failed tasks land here
    └── examples/           # ready-made example tasks
```

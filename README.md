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

## Deploying with Dockhand (git stack)

`docker-compose.yml` is written to be deployed straight from this repo by
[Dockhand](https://github.com/Finsys/dockhand) (or Portainer etc.):

1. **Stacks → Add from Git**: repo `https://github.com/ebialobrzeski/claude-worker`,
   branch `main`, compose file `docker-compose.yml`. Optionally enable the
   webhook / auto-sync to redeploy on every push.
2. **Stack variables** — set at least the ones you need from `.env.example`,
   for example:

   ```env
   WORKER_MODE=both
   PUID=1000                      # `id` on the NAS
   PGID=1000
   REPO_URL=https://github.com/you/your-repo.git
   GITHUB_TOKEN=github_pat_…      # clone/push over HTTPS
   GIT_PUSH=true
   TELEGRAM_BOT_TOKEN=…
   TELEGRAM_CHAT_ID=…
   TELEGRAM_COMMANDS=true
   TELEGRAM_ALLOWED_USER_IDS=…
   DOCKER_SOCKET_PATH=/var/run/docker.sock   # only if Claude should use host Docker
   ```

3. **Deploy.** The image is pulled from
   `ghcr.io/ebialobrzeski/claude-worker:latest` (built by GitHub Actions on
   every push to `main`); if that pull fails, compose builds it from the repo
   instead.
4. **Remote Control login (once):** open the container's terminal in
   Dockhand and run `claude-worker login`. Check with `claude-worker status`.

Why it works without host folders: Dockhand runs compose from its own data
directory, so relative paths like `./tasks` would end up inside Dockhand's
container instead of on your NAS. By default everything is therefore stored
in **named volumes** (`workspace`, `tasks`, `logs`, `claude-home`, `ssh`),
which survive redeploys and image updates. Prefer folders on the NAS? Set
`LOCAL_REPO_PATH`, `TASKS_PATH`, `LOGS_PATH`, `CLAUDE_HOME_PATH` or
`SSH_KEY_PATH` to **absolute** host paths.

> GHCR packages start out private. After the first workflow run, either make
> the package public (GitHub → Packages → claude-worker → Package settings →
> Change visibility) or add ghcr.io credentials in Dockhand. Otherwise the
> pull fails and the stack is built on the NAS instead (slower, but works).

## Quick start (command line)

```bash
# 1. Configure
cp .env.example .env
# Edit .env — pick WORKER_MODE and set up auth (see Authentication below)

# 2. Start the worker (pulls the prebuilt image, or builds it)
docker compose up -d

# 3. Queue a task
docker compose exec worker claude-worker task "Fix the failing tests" fix_tests
#   …or, with TASKS_PATH=./tasks set in .env, from the host:
./dispatch.sh tasks/examples/add_docstrings.md

# 4. Watch it work
docker compose logs -f
```

The `claude-worker` helper inside the container (also usable from the
Dockhand terminal):

| Command | Effect |
|---|---|
| `claude-worker login` | one-time claude.ai login (Remote Control) |
| `claude-worker status` | Claude auth status |
| `claude-worker task "<prompt>" [name]` | queue a task |
| `claude-worker queue` | list queued tasks |
| `claude-worker shell` | bash as the worker user in `/workspace` |

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

# 2. Start
docker compose up -d

# 3. One-time login (stored in the claude-home volume, survives redeploys).
#    Opens a URL — sign in with your claude.ai account and paste the code.
#    In Dockhand: run `claude-worker login` in the container terminal.
docker compose exec worker claude-worker login
docker compose exec worker claude-worker status   # check
docker compose logs -f                             # shows the session URL
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

For an interactive Claude in the running container:
`docker compose exec worker claude-worker shell`, then `claude`.

## Docker on the host

To let Claude use the host's Docker daemon, set (in `.env` or the Dockhand
stack variables):

```bash
DOCKER_SOCKET_PATH=/var/run/docker.sock
```

The socket is then mounted into the container (by default `/dev/null` is
mounted in its place, i.e. off); the entrypoint detects the socket's group
and adds the worker user to it, and the image ships `docker`,
`docker compose` and `docker buildx`.

Things to know:

- **Socket access is root on the host.** Anyone who can drive Claude
  (Remote Control, Telegram, the queue) can then control the whole host.
  Use it only on a machine you're comfortable with that.
- Containers Claude starts are siblings on the host, so bind-mount paths are
  **host** paths. The entrypoint looks up where `/workspace` lives on the
  host (bind path or named volume) and passes it to Claude as
  `HOST_WORKSPACE_PATH` / `WORKSPACE_VOLUME`; `config/CLAUDE.md` tells it to
  use them instead of `/workspace`. Set `HOST_WORKSPACE_PATH` yourself to
  override the detection.
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
| `CLAUDE_HOME_PATH` | `claude-home` volume | Claude's login, settings and history |
| `TASKS_PATH` | `tasks` volume | Queue, done and failed task files |
| `LOGS_PATH` | `logs` volume | Run logs |
| `SSH_KEY_PATH` | `ssh` volume (empty) | SSH keys for git, mounted read-only |
| `GITHUB_TOKEN` | _(empty)_ | HTTPS auth for github.com clone/push |
| `DOCKER_SOCKET_PATH` | `/dev/null` (off) | Host Docker socket — see Docker on the host |
| `WORKER_IMAGE` | `ghcr.io/ebialobrzeski/claude-worker:latest` | Image to run |
| `WORKER_PULL_POLICY` | `always` | `always` pulls updates on every deploy; `build` forces a local build |
| `GIT_USER_EMAIL` | `claude@worker.local` | Git commit identity |
| `GIT_USER_NAME` | `Claude Worker` | Git commit identity |
| `REPO_URL` | _(empty)_ | Clone from remote on first start |
| `REPO_BRANCH` | `main` | Branch to check out |
| `LOCAL_REPO_PATH` | `workspace` volume | Repo mounted at `/workspace` |
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

- **Clone from remote** (best for Dockhand): set `REPO_URL` (and optionally
  `REPO_BRANCH`). The worker clones it into the `workspace` volume on first
  start. For private GitHub repos over HTTPS set `GITHUB_TOKEN` (a
  fine-grained PAT with Contents read/write); for SSH, set `SSH_KEY_PATH` to
  an absolute host path with your keys.
- **Mount a local checkout**: set `LOCAL_REPO_PATH` to the repo's absolute
  path on the host; it's mounted at `/workspace`.

## Authentication

**Do not use `ANTHROPIC_API_KEY`.** Two subscription-based options:

- **Stored login** (required for Remote Control, works for the queue too):
  `claude-worker login` once in the container terminal. Credentials are kept
  in the `claude-home` volume (or `CLAUDE_HOME_PATH`) — treat it as a secret.
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
# Run fix_tests every night at 02:00 (use your container's name)
0 2 * * * docker exec claude-worker-worker-1 claude-worker task "$(cat /path/to/fix_tests.md)" fix_tests
```

With `TASKS_PATH` pointing at a host folder you can also keep using
`./dispatch.sh` from a checkout of this repo.

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
`Dockerfile`. Change it there and push to `main`: GitHub Actions publishes a
new image and the next Dockhand redeploy (or `docker compose up -d`) pulls
it. To build locally instead:

```bash
docker compose build --no-cache
docker compose up -d
```

## Repo layout

```
claude-worker/
├── Dockerfile                  # node:22-alpine + Claude Code + docker CLI
├── docker-compose.yml          # the worker service
├── .env.example                # configuration template
├── dispatch.sh                 # host-side helper to queue tasks
├── config/
│   └── CLAUDE.md               # house rules loaded by every Claude session
├── scripts/
│   ├── entrypoint.sh           # user setup, Docker group, mode dispatch
│   ├── cli.sh                  # `claude-worker` helper (login, task, …)
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

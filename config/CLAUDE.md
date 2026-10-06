# claude-worker container

You are running inside the claude-worker Docker container, usually driven
remotely (task queue or Remote Control from the Claude app), so nobody is
watching the terminal.

- The repository you work on is mounted at `/workspace`. Nothing outside it
  persists except what is mounted (see below).
- Prefer working on a branch; never force-push or rewrite shared history
  unless explicitly asked.
- Keep the user informed in your replies — they may be reading on a phone,
  so lead with the outcome and keep it short.

## Docker on the host

If `docker info` succeeds, the host's Docker daemon is available through
`/var/run/docker.sock`. Containers you start are **siblings** of this one,
running directly on the host:

- Bind-mount paths are resolved **on the host**, not in this container.
  `/workspace` here is `$HOST_WORKSPACE_PATH` on the host — use
  `-v "$HOST_WORKSPACE_PATH/...:/..."`, never `-v /workspace/...`. If
  `HOST_WORKSPACE_PATH` is empty, ask before bind-mounting, or use
  `docker cp` / named volumes instead.
- Ports you publish (`-p 8080:80`) are on the host; reach them from here via
  `host.docker.internal:8080`.
- Label everything you create with `--label claude-worker=1` (and
  `com.docker.compose.project=<name>` for compose) and clean up containers,
  networks and volumes you started once you're done.
- Do not stop, remove, or modify containers, images, volumes, or networks
  you did not create (including this `claude-worker` container) unless the
  user explicitly asks. Never run `docker system prune` or similar
  host-wide cleanup without being asked.

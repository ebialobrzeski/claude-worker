FROM node:22-alpine

# Set WORKDIR before installing Claude Code — prevents the installer
# scanning / and hanging.
WORKDIR /tmp

# System packages required by the worker scripts and Claude Code.
# su-exec is the Alpine equivalent of gosu — drops privileges without a
# shell wrapper, so the worker process gets a clean non-root environment.
# docker-cli/compose/buildx let Claude drive the host's Docker daemon when
# the socket is mounted (DOCKER_SOCKET_PATH in docker-compose.yml); inert
# otherwise.
RUN apk add --no-cache git bash curl openssh-client jq python3 su-exec \
        docker-cli docker-cli-compose docker-cli-buildx

# The base image ships a `node` user with UID 1000, which would otherwise be
# picked up for PUID=1000 with a home of /home/node — breaking the
# /home/worker mounts. Remove it so the entrypoint always creates `worker`.
RUN deluser --remove-home node

# Pin the version for reproducible builds. Remote Control needs >= 2.1.200
# for --continue/--session-id; override with --build-arg to upgrade.
ARG CLAUDE_CODE_VERSION=2.1.291
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Allow git operations on the mounted repo despite differing ownership.
RUN git config --system --add safe.directory /workspace \
 && git config --system --add safe.directory '/workspace/*'

# Managed (system-wide) CLAUDE.md — every Claude session in the container,
# queue or Remote Control, loads it.
COPY config/CLAUDE.md /etc/claude-code/CLAUDE.md

# Worker scripts.
COPY scripts/entrypoint.sh scripts/worker.sh scripts/run_claude.sh \
     scripts/git_commit.sh scripts/remote_control.sh \
     scripts/telegram_bot.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/worker.sh \
             /usr/local/bin/run_claude.sh \
             /usr/local/bin/git_commit.sh \
             /usr/local/bin/remote_control.sh \
             /usr/local/bin/telegram_bot.sh
COPY scripts/cli.sh /usr/local/bin/claude-worker
RUN chmod +x /usr/local/bin/claude-worker

# Example tasks, for the Telegram bot's /run when tasks/ is a fresh volume.
COPY tasks/examples/ /opt/claude-worker/examples/

# Claude's config, login credentials and session history live here; mount a
# volume on it so a one-time `login` survives container rebuilds.
ENV CLAUDE_CONFIG_DIR=/home/worker/.claude

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

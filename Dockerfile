FROM node:22-alpine

# Set WORKDIR before installing Claude Code — prevents the installer
# scanning / and hanging.
WORKDIR /tmp

# System packages required by the worker scripts and Claude Code.
RUN apk add --no-cache git bash curl openssh-client jq python3

# Pin the version for reproducible builds.
RUN npm install -g @anthropic-ai/claude-code@2.1.173

# Allow git operations on the mounted repo despite differing ownership.
RUN git config --global --add safe.directory /workspace

# Worker scripts.
COPY scripts/worker.sh /usr/local/bin/worker.sh
COPY scripts/run_claude.sh /usr/local/bin/run_claude.sh
COPY scripts/git_commit.sh /usr/local/bin/git_commit.sh
RUN chmod +x /usr/local/bin/worker.sh \
             /usr/local/bin/run_claude.sh \
             /usr/local/bin/git_commit.sh

ENTRYPOINT ["/usr/local/bin/worker.sh"]

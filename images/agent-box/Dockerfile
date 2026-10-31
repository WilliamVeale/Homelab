# Agent box v2: one per project. Claude Code agents run here, and the laptop
# reaches the box over SSH through the Tailscale operator. The Herdr desktop
# app installs and updates its own server (herdr-core, ~/.local/bin on the
# PVC) over SSH, so the image ships no herdr at all.
#
# Trust flows one way, laptop to boxes (docs/agent-boxes-spec.md). A box
# writes only its own repo, on branches, and reads the shared skills repo
# (~/claude-memory) as a mirror. Claude Code settings come from
# /etc/claude-code/managed-settings.json, which the agent user cannot edit:
# only a SessionStart hook that refreshes that mirror.
# Manifests: apps/base/agent-box. Built by .github/workflows/agent-box-image.yml.
FROM node:22-bookworm-slim

# Claude Code cannot self-update as a non-root user, so bump
# CLAUDE_CODE_VERSION here instead.
ARG CLAUDE_CODE_VERSION=2.1.314

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq less openssh-client openssh-server \
      procps python3 python3-venv ripgrep tmux unzip vim-tiny \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
 && npm cache clean --force

# The node image ships uid 1000 as "node". Rename it so prompts and paths
# say agent; the home directory itself is a PVC mounted over /home/agent.
RUN usermod -l agent -d /home/agent -m node \
 && groupmod -n agent node

COPY sshd_config /etc/ssh/agent-box/sshd_config
COPY box-init.sh /usr/local/bin/box-init
COPY managed-settings.json /etc/claude-code/managed-settings.json

ENV DISABLE_AUTOUPDATER=1
USER 1000:1000
WORKDIR /home/agent
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/box-init"]

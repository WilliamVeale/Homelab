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
# terraform is for projects whose infra is code (CI applies it; a box only
# writes and validates).
# Manifests: apps/base/agent-box. Built by .github/workflows/agent-box-image.yml.
FROM node:22-bookworm-slim

# Claude Code cannot self-update as a non-root user. The weekly run of
# .github/workflows/agent-box-image.yml bumps CLAUDE_CODE_VERSION to npm's
# stable version and rolls the boxes. Keep this line's format: it seds it.
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
 && curl -fsSL https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com bookworm main" \
      > /etc/apt/sources.list.d/hashicorp.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh terraform \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*

# MCP server programs. apps/staging/agents/mcp-servers.yaml says which ones a
# box runs. Each is pinned to a version and its SHA-256, so a changed file
# upstream fails the build. HashiCorp's apt repo has no terraform-mcp-server.
# x86_64 only, like the image (the workflow builds for its runner) and
# k-node01. To bump: new version, and the linux amd64 / Linux_x86_64 line of
# that release's SHA256SUMS / checksums.txt.
ARG TERRAFORM_MCP_VERSION=1.4.1
ARG TERRAFORM_MCP_SHA256=8b2526451162e16d803ab014f7070f0f412962cdffffdcf446e70a846362481b
ARG GITHUB_MCP_VERSION=2.0.3
ARG GITHUB_MCP_SHA256=f797c20fe02a755865d0e2d46184ab47e31bf1619b0855b8d89c531e45a651c2
RUN cd /tmp \
 && curl -fsSL -o tf.zip "https://releases.hashicorp.com/terraform-mcp-server/${TERRAFORM_MCP_VERSION}/terraform-mcp-server_${TERRAFORM_MCP_VERSION}_linux_amd64.zip" \
 && echo "${TERRAFORM_MCP_SHA256}  tf.zip" | sha256sum -c - \
 && unzip -q tf.zip terraform-mcp-server -d /usr/local/bin \
 && curl -fsSL -o gh.tgz "https://github.com/github/github-mcp-server/releases/download/v${GITHUB_MCP_VERSION}/github-mcp-server_Linux_x86_64.tar.gz" \
 && echo "${GITHUB_MCP_SHA256}  gh.tgz" | sha256sum -c - \
 && tar -xzf gh.tgz --no-same-owner -C /usr/local/bin github-mcp-server \
 && chmod 0755 /usr/local/bin/terraform-mcp-server /usr/local/bin/github-mcp-server \
 && rm tf.zip gh.tgz \
 && terraform-mcp-server --version \
 && github-mcp-server --help > /dev/null

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
 && npm cache clean --force

# The node image ships uid 1000 as "node". Rename it so prompts and paths
# say agent; the home directory itself is a PVC mounted over /home/agent.
RUN usermod -l agent -d /home/agent -m node \
 && groupmod -n agent node

COPY sshd_config /etc/ssh/agent-box/sshd_config
COPY box-init.sh /usr/local/bin/box-init
COPY managed-settings.json /etc/claude-code/managed-settings.json
# New interactive shells (a Herdr pane, ssh) start in the box repo.
COPY bashrc /etc/agent-box-bashrc
RUN echo '. /etc/agent-box-bashrc' >> /etc/bash.bashrc

ENV DISABLE_AUTOUPDATER=1
USER 1000:1000
WORKDIR /home/agent
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/box-init"]

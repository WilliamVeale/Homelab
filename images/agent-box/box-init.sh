#!/bin/bash
# Runs as the agent user on every pod start, then becomes sshd.
# /home/agent is a PVC, so every step only creates what is missing.
# A failed step logs and carries on: sshd must still start, or there is no
# way into the box to fix it.
set -uo pipefail

log() { echo "box-init: $*" >&2; }

: "${BOX_NAME:?BOX_NAME is not set}"
: "${BOX_REPO:?BOX_REPO is not set}"

mkdir -p ~/.ssh/host ~/projects ~/.claude ~/.config
for f in .bashrc .profile; do
  [ -f ~/$f ] || cp /etc/skel/$f ~/
done
[ -f ~/.ssh/host/ssh_host_ed25519_key ] \
  || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/host/ssh_host_ed25519_key
# fsGroup can give the group write access to files on the PVC, and sshd
# refuses to start with a host key that is not private.
chmod 600 ~/.ssh/host/ssh_host_ed25519_key

# SSH sessions start with an empty environment. Hand them the pod's env
# through PermitUserEnvironment. The file sits in a memory-backed emptyDir,
# so the tokens in it never land on the PVC.
env | grep -v -E '^(HOSTNAME|HOME|PWD|SHLVL|OLDPWD|_)=' > /run/agent-box/env
chmod 600 /run/agent-box/env
ln -sfn /run/agent-box/env ~/.ssh/environment

# git over HTTPS uses GH_TOKEN. The helper reads the variable when git runs,
# so the token is never written into ~/.gitconfig.
git config --global credential.https://github.com.helper \
  '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
git config --global user.name "${GIT_USER_NAME:-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@$BOX_NAME}"
git config --global pull.rebase true
git config --global init.defaultBranch main

repo_dir=~/projects/${BOX_REPO#*/}
if [ ! -d "$repo_dir/.git" ]; then
  git clone -q "https://github.com/$BOX_REPO.git" "$repo_dir" \
    || log "could not clone $BOX_REPO; check GH_TOKEN can read it"
fi

# The kanban skill lives only in its own repo. bin/link (below) points
# ~/.claude/skills/kanban at this clone. VIKUNJA_URL and VIKUNJA_TOKEN come
# from the vikunja-token Secret.
if [ -n "${KANBAN_REPO:-}" ]; then
  kanban_dir=~/projects/${KANBAN_REPO#*/}
  if [ ! -d "$kanban_dir/.git" ]; then
    git clone -q "https://github.com/$KANBAN_REPO.git" "$kanban_dir" \
      || log "could not clone $KANBAN_REPO; /kanban will be missing"
  fi
fi

# Claude memory lives in a shared private repo, one folder per project, so
# the laptop and the box see the same notes. bin/sync runs from the hooks.
if [ -n "${MEMORY_REPO:-}" ]; then
  if [ ! -d ~/claude-memory/.git ]; then
    git clone -q "https://github.com/$MEMORY_REPO.git" ~/claude-memory \
      || log "could not clone $MEMORY_REPO; check GH_TOKEN can read it"
  fi
  # Symlink the shared CLAUDE.md, skills and agents into ~/.claude.
  [ -x ~/claude-memory/bin/link ] && ~/claude-memory/bin/link
  if [ ! -f ~/.claude/settings.json ]; then
    cat > ~/.claude/settings.json <<EOF
{
  "autoMemoryDirectory": "~/claude-memory/projects/$BOX_NAME/memory",
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "\$HOME/claude-memory/bin/sync pull"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "\$HOME/claude-memory/bin/sync push"}]}]
  }
}
EOF
  fi
fi

# Skip the first-run theme and login screens; CLAUDE_CODE_OAUTH_TOKEN logs in.
[ -f ~/.claude.json ] || echo '{"hasCompletedOnboarding": true}' > ~/.claude.json

log "ready: $BOX_NAME ($BOX_REPO)"
exec /usr/sbin/sshd -D -e -f /etc/ssh/agent-box/sshd_config

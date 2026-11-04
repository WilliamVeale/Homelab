#!/bin/bash
# Runs as the agent user on every pod start, then becomes sshd.
# /home/agent is a PVC, so every step is safe to repeat.
# A failed step logs and carries on: sshd must still start, or there is no
# way into the box to fix it.
#
# Trust flows one way (docs/agent-boxes-spec.md in the Homelab repo): the
# box writes only its own repo (and any EXTRA_REPOS), on branches, and only
# reads the shared repos.
# Claude Code settings come from /etc/claude-code/managed-settings.json in
# the image, so nothing here writes ~/.claude/settings.json.
set -uo pipefail

log() { echo "box-init: $*" >&2; }

: "${BOX_NAME:?BOX_NAME is not set}"
: "${BOX_REPO:?BOX_REPO is not set}"

mkdir -p ~/.ssh/host ~/projects ~/.claude ~/.config/git/hooks
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

git config --global user.name "${GIT_USER_NAME:-agent}"
git config --global user.email "${GIT_USER_EMAIL:-agent@$BOX_NAME}"
git config --global pull.rebase true
git config --global init.defaultBranch main

# Git credentials: one helper per repo URL, and no catch-all, so a repo not
# named here gets no token at all. The helper reads the variable when git
# runs, so no token is ever written into ~/.gitconfig. Every start rebuilds
# the credential config from scratch so it always matches the env.
git config --global --get-regexp '^credential\.' 2>/dev/null \
  | while read -r key _; do git config --global --unset-all "$key"; done
git config --global credential.useHttpPath true
helper() { # <owner/repo> <name of the env var that holds the token>
  local h
  # Single quotes on purpose: the variable expands when git runs the helper.
  # shellcheck disable=SC2016
  h='!f() { test "$1" = get || return 0; echo username=x-access-token; echo "password=${'$2':-}"; }; f'
  git config --global "credential.https://github.com/$1.helper" "$h"
  git config --global "credential.https://github.com/$1.git.helper" "$h"
}
[ -n "${SHARED_REPO:-}" ] && helper "$SHARED_REPO" SHARED_RO_TOKEN
[ -n "${KANBAN_REPO:-}" ] && helper "$KANBAN_REPO" SHARED_RO_TOKEN
# EXTRA_REPOS: more repos (space-separated owner/repo) that this box works
# on with the same GH_TOKEN, under the same branch-and-PR rules. For
# example an infra box that sometimes opens a PR on its app repo. The token
# must cover them too; new-box.sh --extra sets this.
extra_repos=()
read -ra _extra <<< "${EXTRA_REPOS:-}"
for r in "${_extra[@]}"; do
  if [[ $r =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    extra_repos+=("$r")
    helper "$r" GH_TOKEN
  else
    log "EXTRA_REPOS: skipped '$r'; not owner/repo"
  fi
done
# Last, so it wins when the box repo is also KANBAN_REPO. gh uses GH_TOKEN
# directly, so it too reaches only the box repo and EXTRA_REPOS.
helper "$BOX_REPO" GH_TOKEN

# Seatbelt, not a lock: refuse pushes to the remote's default branch (and to
# main, master and dev always: in the Drupal app repos a push to dev builds
# and deploys the dev VM). GitHub rulesets are the lock where the plan
# allows them. Rewritten every start so an edit does not survive a restart.
cat > ~/.config/git/hooks/pre-push <<'EOF'
#!/bin/sh
# Installed by box-init. Boxes push branches and open pull requests with
# gh pr create; the user merges. Never push to the default branch.
remote=$1
default=$(git symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null)
default=${default#"$remote"/}
status=0
while read -r _ _ remote_ref _; do
  branch=${remote_ref#refs/heads/}
  case $branch in
    main | master | dev | "$default")
      echo "pre-push: refusing to push to $branch. Boxes never push to main," >&2
      echo "pre-push: master, dev or the default branch${default:+ ($default)}." >&2
      echo "pre-push: push a branch and open a PR: gh pr create" >&2
      status=1
      ;;
  esac
done
exit $status
EOF
chmod 755 ~/.config/git/hooks/pre-push
git config --global core.hooksPath ~/.config/git/hooks

# The box repo is the agent's working copy: clone it once, never touch it
# again.
repo_dir=~/projects/${BOX_REPO#*/}
if [ ! -d "$repo_dir/.git" ]; then
  git clone -q "https://github.com/$BOX_REPO.git" "$repo_dir" \
    || log "could not clone $BOX_REPO; check GH_TOKEN can read it"
fi
# EXTRA_REPOS are working copies too: cloned once, then left alone.
for r in "${extra_repos[@]}"; do
  d=~/projects/${r#*/}
  if [ -d "$d/.git" ]; then
    [ "$(git -C "$d" remote get-url origin 2>/dev/null)" = "https://github.com/$r.git" ] \
      || log "$d is not a clone of $r; left alone"
  elif [ -e "$d" ]; then
    log "$d exists and is not a git clone; $r not cloned"
  else
    git clone -q "https://github.com/$r.git" "$d" \
      || log "could not clone $r; check GH_TOKEN can read it"
  fi
done

# The kanban skill lives only in its own repo. bin/link (below) points
# ~/.claude/skills/kanban at this clone. VIKUNJA_URL and VIKUNJA_TOKEN come
# from the vikunja-token Secret. A read-only copy, refreshed every start.
if [ -n "${KANBAN_REPO:-}" ] && [ "$KANBAN_REPO" != "$BOX_REPO" ]; then
  kanban_dir=~/projects/${KANBAN_REPO#*/}
  kanban_url=https://github.com/$KANBAN_REPO.git
  if [ ! -d "$kanban_dir/.git" ]; then
    git clone -q "$kanban_url" "$kanban_dir" \
      || log "could not clone $KANBAN_REPO; /kanban will be missing"
  elif [ "$(git -C "$kanban_dir" remote get-url origin)" != "$kanban_url" ]; then
    log "$kanban_dir is not a clone of $KANBAN_REPO; left alone"
  else
    git -C "$kanban_dir" pull -q --ff-only \
      || log "could not update $KANBAN_REPO; /kanban may be stale"
  fi
fi

# Shared skills and global rules. ~/claude-memory is a read-only mirror:
# local edits are thrown away on purpose. The SessionStart hook in the
# managed settings runs bin/pull, which does the same at each session start.
if [ -n "${SHARED_REPO:-}" ]; then
  mem=~/claude-memory
  if [ ! -d "$mem/.git" ]; then
    git clone -q "https://github.com/$SHARED_REPO.git" "$mem" \
      || log "could not clone $SHARED_REPO; check SHARED_RO_TOKEN can read it"
  fi
  if [ -d "$mem/.git" ]; then
    { git -C "$mem" fetch -q origin \
        && git -C "$mem" reset -q --hard origin/HEAD \
        && git -C "$mem" clean -q -fd; } \
      || log "could not refresh $SHARED_REPO; using the copy on disk"
    # Symlinks for skills and agents, and a real ~/.claude/CLAUDE.md that
    # imports the global and box rules.
    if [ -x "$mem/bin/link" ]; then
      "$mem/bin/link" || log "bin/link failed"
    else
      log "$mem/bin/link is missing; skills not linked"
    fi
  fi
fi

# Skip the first-run theme and login screens; CLAUDE_CODE_OAUTH_TOKEN logs in.
[ -f ~/.claude.json ] || echo '{"hasCompletedOnboarding": true}' > ~/.claude.json

# MCP servers: git owns the user scope. The list is the agent-box-mcp
# ConfigMap (apps/staging/agents/mcp-servers.yaml), mounted read-only.
# Every start replaces mcpServers in ~/.claude.json with it, so a server
# taken out of git goes away too. To try a server by hand, use plain
# `claude mcp add` (local scope): this step leaves local scope alone.
# Runs before sshd, so no Claude session can write the file at the same time.
mcp_file=/etc/agent-box-mcp/mcp-servers.json
if [ ! -f "$mcp_file" ]; then
  log "no $mcp_file; MCP servers left as they are"
elif ! jq -e 'type == "object"' "$mcp_file" > /dev/null 2>&1; then
  log "$mcp_file is not a JSON object; MCP servers left as they are"
else
  tmp=""
  if tmp=$(mktemp ~/.claude.json.XXXXXX) \
    && jq --slurpfile s "$mcp_file" '.mcpServers = $s[0]' ~/.claude.json > "$tmp" \
    && mv "$tmp" ~/.claude.json; then
    log "MCP servers: $(jq -r 'keys | join(" ") | if . == "" then "none" else . end' "$mcp_file")"
  else
    [ -n "$tmp" ] && rm -f "$tmp"
    log "could not write MCP servers into ~/.claude.json"
  fi
fi

log "ready: $BOX_NAME ($BOX_REPO)"
exec /usr/sbin/sshd -D -e -f /etc/ssh/agent-box/sshd_config

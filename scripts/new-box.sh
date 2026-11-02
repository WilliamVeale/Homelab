#!/bin/bash
# Add an agent box for one GitHub repo.
#
#   scripts/new-box.sh [--postgres] [--extra <owner/repo>]... <name> <owner/repo> [git-email]
#
# --postgres adds a Postgres 17 sidecar on localhost:5432 (payload/payload,
# database payload) with its own PVC, and puts DATABASE_URL in the box env.
# --extra (repeatable) names another repo the box also works on with the
# same token and the same rules: branches and PRs only. It is cloned into
# ~/projects. The repo keeps its own GitHub rules; the script checks them.
#
# Before running, make a fine-grained GitHub token. Resource owner: the
# repo's owner (the org, for a work repo). Repository access: only
# <owner/repo> and any --extra repos. Permissions: Contents read/write,
# Pull requests read/write, Metadata read. Nothing else: the box gets the
# shared repos through the shared read-only token (Secret shared-ro-token),
# not through this one. The script asks for the token at a hidden prompt,
# writes apps/staging/agents/<name>/, offers a GitHub ruleset that makes the
# default branch PR-only, and offers to commit and push. Flux builds the box
# in a minute or two. Then add ws-<name> in the Herdr app, or run:
# hc machine add ws-<name>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
postgres=0 extra=
while [ $# -gt 0 ]; do
  case $1 in
    --postgres) postgres=1; shift ;;
    --extra)
      [[ ${2:-} =~ $repo_re ]] || { echo "--extra needs owner/repo" >&2; exit 1; }
      extra=${extra:+$extra }$2; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] || { sed -n 2,21p "$0"; exit 1; }
name=$1 repo=$2
email=${3:-$(git config --global user.email)}
dir=apps/staging/agents/$name
list=apps/staging/agents/kustomization.yaml

# The name ends up in ws-<name> and in pod and PVC names, so keep it a short
# DNS label.
[[ $name =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] \
  || { echo "name: lowercase letters, digits and dashes, 20 characters max" >&2; exit 1; }
[[ $repo =~ $repo_re ]] || { echo "repo must look like owner/name" >&2; exit 1; }
for r in $extra; do
  [ "$r" != "$repo" ] || { echo "--extra $r is the box repo already" >&2; exit 1; }
done
[ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 1; }
# A StatefulSet keeps its PVC when the box is removed. A new box with the
# same name would quietly reuse that old disk.
if kubectl --context homelab -n agents get pvc "home-agent-box-$name-0" >/dev/null 2>&1; then
  echo "PVC home-agent-box-$name-0 from an old box still exists. Delete it first:" >&2
  echo "  kubectl --context homelab delete pvc -n agents home-agent-box-$name-0" >&2
  exit 1
fi

mkdir -p "$dir"
trap '[ -f "$dir/box-secrets.yaml" ] || rm -rf "$dir"' EXIT
extra_env=
[ $postgres = 0 ] || extra_env=$'\n      - DATABASE_URL=postgres://payload:payload@localhost:5432/payload'
[ -z "$extra" ] || extra_env+=$'\n      - EXTRA_REPOS='$extra
cat > "$dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../base/agent-box
  - box-secrets.yaml
nameSuffix: -$name
labels:
  - pairs:
      app.kubernetes.io/instance: $name
    includeSelectors: true
configMapGenerator:
  - name: box-config
    literals:
      - BOX_NAME=$name
      - BOX_REPO=$repo
      - GIT_USER_NAME=$(git config --global user.name)
      - GIT_USER_EMAIL=$email$extra_env
patches:
  - target:
      kind: Service
    patch: |-
      - op: add
        path: /metadata/annotations/tailscale.com~1hostname
        value: ws-$name
EOF
if [ $postgres = 1 ]; then
  cat >> "$dir/kustomization.yaml" <<EOF
# Postgres 17 sidecar on localhost:5432 (payload/payload, database payload).
components:
  - ../../../base/agent-box/components/postgres-sidecar
EOF
fi

echo "Paste the fine-grained GitHub token for $repo${extra:+ and $extra} only"
echo "(Contents read/write, Pull requests read/write, Metadata read)."
scripts/seal-secret.sh "$dir/box-secrets.yaml" box-secrets - GH_TOKEN

# An --extra repo keeps its own GitHub rules, and the token acts as you. So
# warn when its default branch (or dev, which deploys in the Drupal app
# repos) is not PR-only, or when anyone can skip that rule.
check_extra() { # <owner/repo>
  local r=$1 def b ids id n
  def=$(gh api "repos/$r" --jq .default_branch 2>/dev/null) \
    || { echo "WARNING: cannot read $r with your gh login; check its rules by hand." >&2; return 0; }
  for b in "$def" dev; do
    [ "$b" = "$def" ] || gh api "repos/$r/branches/$b" >/dev/null 2>&1 || continue
    ids=$(gh api "repos/$r/rules/branches/$b" \
      --jq '[.[] | select(.type == "pull_request") | .ruleset_id] | unique | .[]' 2>/dev/null) || ids=
    if [ -z "$ids" ]; then
      echo "WARNING: $b on $r is not PR-only. Only the box's pre-push guard stops a push." >&2
      continue
    fi
    for id in $ids; do
      n=$(gh api "repos/$r/rulesets/$id" --jq '.bypass_actors | length' 2>/dev/null) || n=unknown
      [ "$n" = 0 ] || echo "WARNING: a ruleset on $b of $r has bypass actors ($n). If you are one, the box can push to $b." >&2
    done
  done
}
for r in $extra; do check_extra "$r"; done

# The token acts as you, so a ruleset with any bypass actor (an org admin,
# say) would let the box push to the default branch. Hence none. For the
# same reason no approvals are required: the box opens PRs as you, and
# GitHub does not let you approve your own PR. Uses your own gh login, which
# needs admin on the repo.
ruleset_name="agent box: PR only on the default branch"
read -rp "Make the default branch of $repo PR-only with a GitHub ruleset? [y/N] " ok
if [ "$ok" = y ]; then
  if existing=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$ruleset_name\") | .id" 2>&1) \
     && [ -n "$existing" ]; then
    echo "Ruleset already there (id $existing); left as it is."
  elif err=$(gh api -X POST "repos/$repo/rulesets" --input - 2>&1 >/dev/null <<EOF
{
  "name": "$ruleset_name",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false
    }}
  ]
}
EOF
  ); then
    echo "Ruleset made: no pushes, force pushes or deletes on the default branch; PRs only."
  elif [[ $err == *"HTTP 403"* ]]; then
    echo "WARNING: GitHub cannot enforce PR-only here (a personal private repo on" >&2
    echo "GitHub Free has no rulesets). The box rule and the pre-push guard are the" >&2
    echo "only gates." >&2
  else
    echo "WARNING: could not make the ruleset: $err" >&2
  fi
fi

echo "  - $name" >> "$list"
# Catch a broken overlay here rather than in Flux.
kubectl kustomize apps/staging/agents > /dev/null

read -rp "Commit and push now? [y/N] " ok
if [ "$ok" = y ]; then
  git add "$dir" "$list"
  git commit -q -m "agents: add box $name for $repo" -- "$dir" "$list"
  git push -q origin master
  echo "Pushed. The box should be up in about 2 minutes."
else
  echo "Not committed. Review with: git status"
fi
echo "Then add ws-$name in the Herdr app, or run: hc machine add ws-$name"

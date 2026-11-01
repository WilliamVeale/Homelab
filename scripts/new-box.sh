#!/bin/bash
# Add an agent box for one GitHub repo.
#
#   scripts/new-box.sh [--postgres] <name> <owner/repo> [git-email]
#
# --postgres adds a Postgres 17 sidecar on localhost:5432 (payload/payload,
# database payload) with its own PVC, and puts DATABASE_URL in the box env.
#
# Before running, make a fine-grained GitHub token. Resource owner: the
# repo's owner (the org, for a work repo). Repository access: only
# <owner/repo>. Permissions: Contents read/write, Pull requests read/write,
# Metadata read. Nothing else: the box gets the shared repos through the
# shared read-only token (Secret shared-ro-token), not through this one.
# The script asks for the token at a hidden prompt, writes
# apps/staging/agents/<name>/, offers a GitHub ruleset that makes the default
# branch PR-only, and offers to commit and push. Flux builds the box in a
# minute or two. Then add ws-<name> in the Herdr app, or run: hc machine add ws-<name>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
postgres=0
if [ "${1:-}" = --postgres ]; then postgres=1; shift; fi
[ $# -ge 2 ] || { sed -n 2,17p "$0"; exit 1; }
name=$1 repo=$2
email=${3:-$(git config --global user.email)}
dir=apps/staging/agents/$name
list=apps/staging/agents/kustomization.yaml

# The name ends up in ws-<name> and in pod and PVC names, so keep it a short
# DNS label.
[[ $name =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] \
  || { echo "name: lowercase letters, digits and dashes, 20 characters max" >&2; exit 1; }
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || { echo "repo must look like owner/name" >&2; exit 1; }
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
pg_env=
[ $postgres = 0 ] || pg_env=$'\n      - DATABASE_URL=postgres://payload:payload@localhost:5432/payload'
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
      - GIT_USER_EMAIL=$email$pg_env
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

echo "Paste the fine-grained GitHub token for $repo only"
echo "(Contents read/write, Pull requests read/write, Metadata read)."
scripts/seal-secret.sh "$dir/box-secrets.yaml" box-secrets - GH_TOKEN

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

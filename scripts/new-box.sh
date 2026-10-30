#!/bin/bash
# Add an agent box for one GitHub repo.
#
#   scripts/new-box.sh <name> <owner/repo> [git-email]
#
# Before running, make a fine-grained GitHub token with access to <owner/repo>
# and WilliamVeale/claude-memory: Contents and Pull requests read/write.
# The script asks for it at a hidden prompt, writes apps/staging/agents/<name>/,
# and offers to commit and push. Flux builds the box in a minute or two.
# Then add ws-<name> in the Herdr app, or run: hc machine add ws-<name>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[ $# -ge 2 ] || { sed -n 2,11p "$0"; exit 1; }
name=$1 repo=$2
email=${3:-$(git config --global user.email)}
memory_repo=WilliamVeale/claude-memory
dir=apps/staging/agents/$name
list=apps/staging/agents/kustomization.yaml

# The name ends up in ws-<name> and in pod and PVC names, so keep it a short
# DNS label.
[[ $name =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] \
  || { echo "name: lowercase letters, digits and dashes, 20 characters max" >&2; exit 1; }
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || { echo "repo must look like owner/name" >&2; exit 1; }
[ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 1; }

mkdir -p "$dir"
trap '[ -f "$dir/box-secrets.yaml" ] || rm -rf "$dir"' EXIT
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
      - MEMORY_REPO=$memory_repo
      - GIT_USER_NAME=$(git config --global user.name)
      - GIT_USER_EMAIL=$email
patches:
  - target:
      kind: Service
    patch: |-
      - op: add
        path: /metadata/annotations/tailscale.com~1hostname
        value: ws-$name
EOF

echo "Paste the GitHub token for $repo + $memory_repo."
scripts/seal-secret.sh "$dir/box-secrets.yaml" box-secrets - GH_TOKEN

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

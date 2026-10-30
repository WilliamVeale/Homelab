#!/bin/bash
# Write a SOPS-encrypted Secret. Values are typed at a hidden prompt, so they
# never show on screen, never enter shell history, and never sit in the repo
# in plain text. Only the public age key is needed, not age.agekey.
#
#   scripts/seal-secret.sh <out-file> <secret-name> <namespace|-> KEY [KEY...]
#
# <out-file> is relative to the repo root. Use "-" for the namespace when the
# kustomization that includes the file sets it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[ $# -ge 4 ] || { sed -n 2,10p "$0"; exit 1; }
out=$1 name=$2 ns=$3
shift 3

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "metadata:"
  echo "  name: $name"
  [ "$ns" = - ] || echo "  namespace: $ns"
  echo "data:"
} > "$tmp/secret.yaml"

for key in "$@"; do
  read -rsp "$key: " val </dev/tty
  echo >&2
  [ -n "$val" ] || { echo "empty value for $key, nothing written" >&2; exit 1; }
  printf '  %s: %s\n' "$key" "$(printf %s "$val" | base64 | tr -d '\n')" >> "$tmp/secret.yaml"
done

sops --config clusters/staging/.sops.yaml --encrypt "$tmp/secret.yaml" > "$tmp/out.yaml"
mv "$tmp/out.yaml" "$out"
echo "wrote $out (encrypted)" >&2

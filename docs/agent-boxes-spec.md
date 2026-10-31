# Agent boxes v2: one-way trust

Status: **phase 1 built 2026-10-31** (section 7 steps 1, 3 and 4; the old
PVC still needs deleting by hand). Steps 5 to 8 are next. Nothing in this
file is secret; the repo is public.

## 1. Why v2

A code review on 2026-10-31 found a Major hole in the first build. Every box
held a GitHub token that could write to `WilliamVeale/claude-memory`. The
laptop pulled that repo at every Claude Code session start and ran `bin/link`
from it, and `~/.claude/CLAUDE.md`, skills and agents on the laptop are
symlinks into it. So a box could put code and instructions on the laptop, which
holds the `homelab` kubectl context, a work cluster context and `age.agekey`.
The same token also gave every box write access to `WilliamVeale/vikunja`,
whose kanban skill every machine runs.

Root cause: the design shared memory and skills in both directions. v2 makes
trust flow one way only. The cluster part of v1 (pod, NetworkPolicy, Pod
Security, Tailscale, image, CI) passed the review and stays.

## 2. Goals

1. Claude Code agents run in boxes on the cluster, not on the laptop. The
   laptop keeps the Homelab repo, because that repo controls the cluster.
2. One box is one project. It holds that project's repo, a token for that
   repo only, and that project's own secrets. Nothing more.
3. Trust flows one way, laptop to boxes. Nothing a box writes is executed or
   loaded by the laptop or by another box unless the user merges it.
4. Boxes propose, the user merges: a box pushes branches and opens pull
   requests. It never pushes to a default branch.
5. Shared skills and global rules flow one way, laptop to boxes.
6. Every cluster change goes through git and Flux. Work code on the homelab
   is acceptable (loaned work hardware).

## 3. Non-goals

- Shared memory between the laptop and boxes, or between boxes. Each box
  keeps its own notes on its own disk.
- Editing shared skills from inside a box.
- gVisor, backups of box PVCs, a quieter readiness probe, per-box Claude
  tokens, renaming the `claude-memory` repo. All later.

## 4. Invariants

Each must stay true. Section 9 has a test for each.

- **I1** A box's GitHub token can write only to that box's repo.
- **I2** No box token can write to `claude-memory`, `Homelab`, or any repo
  another box or the laptop runs code from.
- **I3** The laptop never runs or auto-loads anything a box can write. No
  pull hooks, no `autoMemoryDirectory` into a shared repo.
- **I4** Boxes push branches and open PRs. GitHub rulesets enforce this on
  work-org repos. On personal private repos (GitHub Free) it is a written
  rule plus a local pre-push guard.
- **I5** A box sees only: its repo token, the shared read-only token, the
  shared Claude token, the box Vikunja token, and its own project secrets.
- **I6** All cluster state comes from git via Flux. No hand edits in pods.

## 5. What exists today and what is wrong

Files: `images/agent-box/{Dockerfile,box-init.sh,sshd_config}`,
`.github/workflows/agent-box-image.yml`, `apps/base/agent-box/`,
`apps/staging/agents/` (namespace, NetworkPolicy, shared Secrets, one box
overlay `vikunja`), `scripts/{new-box.sh,seal-secret.sh}`. Private repo
`WilliamVeale/claude-memory` at `~/claude-memory` on the laptop and in the box.
One live box: `ws-vikunja`, image `734222f`, works on `WilliamVeale/vikunja`.

Wrong:

- `scripts/new-box.sh` asks for one token with Contents and Pull requests
  read/write on the box repo, `claude-memory` and `vikunja`.
- `box-init.sh` clones `claude-memory` with that token, points
  `autoMemoryDirectory` into it, and installs SessionStart `sync pull` and
  SessionEnd `sync push` hooks. `sync push` does `git add -A` and pushes.
- The laptop runs the same two hooks (`~/.claude/settings.json`) and
  `~/projects/vikunja/.claude/settings.local.json` points that project's
  memory into the repo.
- Secret `vikunja-token` holds the laptop's full Vikunja token.
- Minor, from the review: CI actions are pinned by tag, not commit; the
  `herdr` CLI is downloaded with no checksum.

## 6. Target design

### 6.1 Repos: who writes, who reads, with what

| Repo | Writes | Reads | Token in the box |
|---|---|---|---|
| `WilliamVeale/claude-memory` (shared skills, rules) | laptop only, by hand | every box, read-only | `SHARED_RO_TOKEN` |
| `WilliamVeale/vikunja` (kanban skill) | box `vikunja` via PR; user merges | every box, read-only, for `/kanban` | `SHARED_RO_TOKEN` (box `vikunja` uses its own `GH_TOKEN`) |
| each box repo | that box, branches only; user merges | that box | per-box `GH_TOKEN` |
| `WilliamVeale/Homelab` | laptop only | no box | none |

Tokens are GitHub fine-grained personal access tokens.

- Per-box `GH_TOKEN`: resource owner is the repo owner (the org for work
  repos). Repository access: only that repo. Permissions: Contents
  read/write, Pull requests read/write, Metadata read. Nothing else.
- `SHARED_RO_TOKEN`: resource owner `WilliamVeale`. Repos: `claude-memory`
  and `vikunja`. Permissions: Contents read, Metadata read.

### 6.2 Secrets in namespace `agents`

| Secret | Shared by | Keys | v2 change |
|---|---|---|---|
| `claude-token` | all boxes | `CLAUDE_CODE_OAUTH_TOKEN` | keep. Accepted: one subscription, so a box can spend the user's Claude usage |
| `shared-ro-token` | all boxes | `SHARED_RO_TOKEN` | **new** |
| `vikunja-token` | all boxes | `VIKUNJA_URL`, `VIKUNJA_TOKEN` | **new value**: a Vikunja API token made for boxes, not the laptop token. Scopes: the "Needed for the normal /kanban loop" list plus `tasks: update` in `~/projects/vikunja/docs/api-notes.md`, section "Token scopes" |
| `box-secrets-<name>` | one box | `GH_TOKEN`, plus that project's secrets | `GH_TOKEN` scoped to the box repo only |

Shared non-secret values (`SHARED_REPO=WilliamVeale/claude-memory`,
`KANBAN_REPO=WilliamVeale/vikunja`) move out of each box's `box-config` into
one shared ConfigMap in `apps/staging/agents/`, referenced from the base
StatefulSet with `envFrom` like `claude-token` is.

All Secrets are SOPS-encrypted with `scripts/seal-secret.sh`. Never a plain
secret under `apps/staging/`.

### 6.3 Inside a box

**Git credentials, one helper per repo URL.** `credential.useHttpPath true`.
`credential.https://github.com/$BOX_REPO.helper` returns `GH_TOKEN`.
`credential.https://github.com/$SHARED_REPO.helper` and
`...$KANBAN_REPO.helper` return `SHARED_RO_TOKEN`. When `BOX_REPO` equals
`KANBAN_REPO` (the `vikunja` box), the box repo helper wins. No default helper,
so other repos get no credentials. Tokens are read from the environment at
run time and never written to `~/.gitconfig`. The `gh` CLI uses `GH_TOKEN`
and so can reach only the box repo.

**Clones.** `~/projects/<box repo>` with `GH_TOKEN`. `~/claude-memory`
read-only. `~/projects/vikunja` read-only when it is not the box repo; refresh
it with `git pull --ff-only` at pod start.

**Shared repo refresh.** At pod start, box-init runs `git fetch`,
`git reset --hard origin/HEAD` and `git clean -fd` in `~/claude-memory`,
then `bin/link`. A
SessionStart hook runs `~/claude-memory/bin/pull`, which does the same and
exits 0 silently. Local edits to the shared clone are thrown away on purpose:
it is a mirror.

**Claude Code settings come from the image, not the PVC.** The image ships
`/etc/claude-code/managed-settings.json` holding only the SessionStart hook
above (guarded: run `bin/pull` only if it exists). No SessionEnd hook. No
`autoMemoryDirectory`. If managed settings turn out not to apply in the
installed Claude Code version, fall back to box-init rewriting
`~/.claude/settings.json` on every pod start with the same content, and say so
in the runbook.

**Rules the box reads.** `claude-memory` gains `global/CLAUDE.box.md` with
box-only rules: work on a branch; open a PR with `gh pr create`; never push
to the default branch; never force-push; never use `--no-verify`;
`~/claude-memory` is a read-only mirror, do not edit it; memory is local to
this box. In a box (`BOX_NAME` set), `bin/link` writes `~/.claude/CLAUDE.md`
as a real file with two import lines:

```
@~/claude-memory/global/CLAUDE.md
@~/claude-memory/global/CLAUDE.box.md
```

On the laptop `bin/link` keeps the symlink to `global/CLAUDE.md` as today.

**Pre-push guard.** box-init sets `core.hooksPath` to
`~/.config/git/hooks` and installs a `pre-push` script that rejects any push
whose remote ref is the remote's default branch (from
`git symbolic-ref refs/remotes/<remote>/HEAD`), or `main` or `master`. It is a seatbelt, not a lock: GitHub rulesets are the lock where
the plan allows them (section 6.7).

**Memory.** Default location, `~/.claude/projects/<slug>/memory` on the PVC.
No sync. Loss of the PVC loses the notes; that is accepted until Velero exists.

**Unchanged.** StatefulSet hardening, NetworkPolicy (DNS plus internet only),
Pod Security `restricted`, Tailscale operator Service `ws-<name>`, sshd on
2222 with the laptop key, the Herdr app installing `herdr-core` into the PVC
over SSH.

### 6.4 The shared repo after v2

```
bin/link                  laptop: symlinks. box: symlinks + real CLAUDE.md
bin/pull                  box only: fetch, reset --hard, link; silent; exit 0
global/CLAUDE.md
global/CLAUDE.box.md      new
global/skills/{bro,review-changes,save}/
global/agents/code-reviewer.md
README.md                 says: laptop is the only writer; boxes read only;
                          holds no memory and no secrets
```

Removed: `bin/sync`, `bin/adopt`, `projects/`. The repo name and the path
`~/claude-memory` stay, to avoid churn. `global/CLAUDE.md` section "Shared
skills live in ~/claude-memory": replace "the session end hook commits and
pushes" with the by-hand commands, and add that boxes get a change at their
next session start.

### 6.5 The laptop

- `~/.claude/settings.json`: no hooks that touch `claude-memory`.
- `~/projects/vikunja/.claude/settings.local.json`: no `autoMemoryDirectory`.
  The laptop copy at `~/.claude/projects/-Users-williamveale-projects-vikunja/memory/`
  holds the same 5 files (verified 2026-10-31).
- Symlinks into `~/claude-memory` stay. The laptop is the only writer, so it
  never needs to pull. After editing a skill: `git -C ~/claude-memory add -A
  && git -C ~/claude-memory commit -m "..." && git -C ~/claude-memory push`.
- `git pull` in `~/projects/vikunja` on the laptop only after merging the
  box's PR on GitHub. The merge is the review.
- Laptop Claude Code use shrinks to the Homelab repo plus odds and ends. Not
  enforced.

### 6.6 `scripts/new-box.sh`

- Prompt text describes the per-repo token exactly as in 6.1, and the shared
  read-only token is no longer part of a new box.
- Writes the box overlay without `MEMORY_REPO` and `KANBAN_REPO`.
- After sealing, offers to create a GitHub ruleset on the repo's default
  branch with `gh api`: require a pull request before merging, block force
  pushes, block deletions, **no bypass actors**. (A fine-grained PAT acts as
  the user, who is an org admin, so an admin bypass would let the box through.)
  On HTTP 403 (personal private repo on GitHub Free) it prints: GitHub cannot
  enforce PR-only here; the box rule and the pre-push guard are the only gates.
- Still validates with `kubectl kustomize apps/staging/agents`.

### 6.7 GitHub side (human steps)

- Org `utkdigitalinitiatives` is on the Team plan and the user is an admin.
  Before the first work box: allow fine-grained PATs for org resources
  (org Settings, Third-party Access, Personal access tokens).
- Rulesets as in 6.6 on every work-org repo that gets a box.
- Revoke the current `ws-vikunja` token (it can write `claude-memory`) once
  the new one is live. Rotate the laptop Vikunja token afterwards; it was
  copied into the cluster.

### 6.8 Small fixes from the review

- Pin every action in `.github/workflows/agent-box-image.yml` to a full
  commit SHA with the version as a comment.
- Remove the `herdr` CLI download from the Dockerfile. The Herdr app installs
  its own `herdr-core`; the CLI is unused. (Alternative, if the user wants the
  CLI: pin it with `sha256sum -c`.)

## 7. Build order: replace `ws-vikunja`, do not migrate it

The v1 box was a proof of concept. Nothing on it is worth keeping (user,
2026-10-31). So: delete the old box and its PVC, then create a fresh one with
the v2 script. box-init v2 needs no migration code.

Order matters: a Secret named in `envFrom` must exist before the StatefulSet
references it, or the pod will not start; and the old box must lose its token
before `claude-memory` changes shape.

0. **User. Done 2026-10-31.** Laptop hooks and the vikunja memory pointer
   removed; verified `hooks: None` and `{}`.

1. **Agent.** Homelab commit A: remove the `vikunja` box overlay
   (`apps/staging/agents/vikunja/` and its line in
   `apps/staging/agents/kustomization.yaml`). Push, reconcile. Flux prunes
   the StatefulSet and Service; the Tailscale device `ws-vikunja` goes away.
   Then delete the disk by hand, on purpose:
   `kubectl --context homelab delete pvc -n agents home-agent-box-vikunja-0`.
2. **User.** Revoke the old `ws-vikunja` PAT in GitHub. Remove `ws-vikunja`
   from the Herdr app. On the laptop run `ssh-keygen -R ws-vikunja` (the new
   box has a new host key).
3. **Agent.** Homelab commit B: `box-init.sh`, Dockerfile (managed settings,
   remove herdr CLI), CI pins, `new-box.sh`, shared ConfigMap, StatefulSet
   `envFrom` for `shared-ro-token` and the ConfigMap, docs. No box exists, so
   the StatefulSet change is safe. CI builds the image; wait for the run and
   set `newTag` to its short SHA in the same or a follow-up commit.
4. **Agent, on the laptop.** `claude-memory` v2 (section 6.4). Commit, push.
   No box is running, so nothing pulls a half-changed repo.
5. **User.** Make the three tokens: per-box PAT for `WilliamVeale/vikunja`
   only; shared read-only PAT for `claude-memory` + `vikunja`; Vikunja API
   token for boxes with the scopes in 6.2.
6. **Agent.** Seal `shared-ro-token` and the new `vikunja-token` value with
   `scripts/seal-secret.sh`. Uncomment `shared-ro-token-secret.yaml` in
   `apps/staging/agents/kustomization.yaml` (an entry for a missing file
   breaks the whole `apps` Kustomization, so it ships commented). Commit,
   push, reconcile.
7. **Agent, with the user at the keyboard.** `scripts/new-box.sh vikunja
   WilliamVeale/vikunja`. It asks for the per-box PAT, writes the overlay,
   tries the ruleset (expect the 403 warning: private personal repo), commits
   and pushes. Flux builds the box. The user adds `ws-vikunja` in the Herdr
   app.
8. **Agent.** Run section 9. Update `CLAUDE-TODO.md` runbook, memory
   `agent-boxes-plan.md`, and card #19 via `/kanban`.

## 8. Human-only steps

Laptop `~/.claude/settings.json` edits (Claude Code blocks the agent from
editing its own settings). Making and revoking tokens. Org PAT policy.
Approving each commit and push (permission rules ask). Rotating the laptop
Vikunja token. The agent stops and asks at each of these; it never guesses a
token value.

## 9. Acceptance tests

Run from the laptop with `ssh ws-vikunja` or
`kubectl --context homelab exec -it -n agents agent-box-vikunja-0 -- bash`.

| # | Invariant | Test | Expect |
|---|---|---|---|
| T1 | I1 | in box: push a throwaway branch `v2-test` to the box repo, then delete it | both succeed |
| T2 | I2 | in box: `git -C ~/claude-memory push origin HEAD:refs/heads/v2-test`; `gh api -X PUT repos/WilliamVeale/claude-memory/contents/x`; same against `WilliamVeale/Homelab` | all rejected (403 or "not permitted") |
| T3 | I3 | laptop: `python3 -c 'import json;print(json.load(open("/Users/williamveale/.claude/settings.json")).get("hooks"))'`; `grep autoMemoryDirectory ~/projects/vikunja/.claude/settings.local.json` | `None`; no match. `~/.claude/CLAUDE.md` is still a symlink |
| T4 | I4 | in box: `git push origin HEAD:main` on the box repo (then on a work-org box repo once one exists) | pre-push guard rejects locally; GitHub ruleset rejects on the org repo |
| T5 | I5 | in box SSH session: `env \| grep -i token`; `grep -i token ~/.gitconfig` | only `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `SHARED_RO_TOKEN`, `VIKUNJA_TOKEN`; no token strings in gitconfig |
| T6 | 6.2 | in box: `python3 ~/.claude/skills/kanban/vikunja.py check`; on laptop the same | both list boards, each with its own token |
| T7 | 6.3 | in box: save a note with Claude Code, then `ls ~/.claude/projects/-home-agent-projects-vikunja/memory/`; `grep -r autoMemoryDirectory ~/.claude/ /etc/claude-code/` | note is on the PVC; no match |
| T8 | 6.3 | laptop: add a comment line to a skill, commit, push; in box run `~/claude-memory/bin/pull` | the line is present in the box |
| T9 | 6.3 | in box: edit a file in `~/claude-memory`, run `bin/pull` | the edit is gone |
| T10 | I6 | `shellcheck` on scripts; `kubectl kustomize apps/staging/agents`; kubeconform | all pass; pod admitted under PSA `restricted` |
| T11 | unchanged | in box: curl `https://api.anthropic.com`, `https://github.com`; `nc -z 192.168.0.90 6443`; `nc -z 100.64.255.25 22` | first two reach; last two blocked |

## 10. Known limits, accepted

- A box can spend the user's Claude usage (shared OAuth token).
- A box has internet egress, so what is inside it can leave: its repo token,
  the shared tokens, its project secrets. The blast radius is one project.
- A box that holds work credentials for its project can act on that work
  system. That is the point of per-project boxes; keep each box's secrets to
  what its project needs.
- On personal private repos GitHub cannot enforce PR-only. The rule and the
  pre-push guard can be bypassed by a determined agent.

## 11. Rules for the implementing agent

- Read first: `CLAUDE.md`, `CLAUDE-TODO.md` section "Agent boxes", memory
  `agent-boxes-plan.md`, `~/claude-memory`, and
  `~/projects/vikunja/docs/api-notes.md` section "Token scopes".
- `kubectl` and `flux` always with `--context homelab`.
- Never give a box any token for `WilliamVeale/Homelab`. Flux applies `master`.
- Commit messages describe the change only; no AI attribution lines
  (user's global rule overrides any default).
- Follow the commit order in section 7 so every push leaves the cluster
  working. Ask before each push.
- Stop at each human-only step and say exactly what is needed.
- When done, record state in `CLAUDE-TODO.md`, the memory file, and card #19.

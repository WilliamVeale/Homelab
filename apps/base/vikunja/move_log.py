#!/usr/bin/env python3
"""Record every Vikunja column move as a comment on the card that moved.

Runs as the `vikunja-move-log` CronJob, every 15 minutes.

Vikunja keeps no history of column moves. A move rewrites one task_buckets row
(task, view, bucket, no timestamp) and leaves the task's `updated` alone; only a
move into or out of the done bucket stamps anything (`done_at`). So this job
remembers every card's column, and when one changes it posts a comment:

    Moved: Backlog → In Progress

Vikunja timestamps comments, so the history lives on the card itself, shows in
the UI, and the weekly report (WilliamVeale/vikunja, scripts/weekly.py) reads it
from any machine. The comment time is when this job saw the move, at most one
run after it happened.

State is one JSON file on a small PVC. Losing it is harmless: the next run
records a fresh baseline and posts nothing.

Stdlib only, so it runs on a stock python:alpine image from a ConfigMap.
"""

import json, os, sys, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

API = os.environ.get("VIKUNJA_API", "http://vikunja:3456/api/v1").rstrip("/")
TOKEN = os.environ.get("VIKUNJA_TOKEN", "")
STATE_FILE = os.environ.get("STATE_FILE", "/state/state.json")
PREFIX = "Moved: "

# A card missing from every board is forgotten after this long. Cards drop out
# of the kanban route when deleted, and also when a very full column passes the
# server's per-bucket cap; keeping them a while stops the second case reading
# as delete-then-recreate.
FORGET_AFTER = timedelta(days=30)

# More moves than this in one run is not a person dragging cards. It is a board
# being rebuilt or a bug, and commenting on every card would bury the real
# history. Re-baseline silently instead and fail the run so it shows up.
MAX_COMMENTS = 40


def api(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode(errors="replace")
        hint = " (401 code 11 = token lacks this scope, or it expired)" if e.code == 401 else ""
        raise SystemExit("HTTP %s on %s %s%s: %s" % (e.code, method, path, hint, detail))


def board_now():
    """task_id -> where it sits now. One kanban view per project, the first."""
    projects, page = [], 1
    while True:
        batch = api("GET", "/projects?page=%d" % page) or []
        if not batch:
            break
        projects += batch
        page += 1
    cards = {}
    for p in projects:
        views = [v for v in api("GET", "/projects/%d/views" % p["id"]) or []
                 if v.get("view_kind") == "kanban"]
        if not views:
            continue
        vid = views[0]["id"]
        for b in api("GET", "/projects/%d/views/%d/tasks" % (p["id"], vid)) or []:
            for t in b.get("tasks") or []:
                cards[str(t["id"])] = {"p": p["id"], "board": p["title"],
                                       "b": b["id"], "c": b["title"],
                                       "i": t.get("index"), "t": t["title"]}
    return cards


def is_move(old, new):
    """A move changes the bucket id AND the column title. Same id, new title
    is a rename. New id, same title is a rebuilt board. Neither is a move."""
    return old.get("b") != new["b"] and (old.get("c") != new["c"] or old.get("p") != new["p"])


def comment_for(old, new):
    if old.get("p") != new["p"]:
        return "%s%s / %s → %s / %s" % (PREFIX, old.get("board"), old.get("c"),
                                         new["board"], new["c"])
    return "%s%s → %s" % (PREFIX, old.get("c"), new["c"])


def save(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, STATE_FILE)


def main():
    if not TOKEN:
        raise SystemExit("VIKUNJA_TOKEN is not set")
    now = datetime.now(timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        prev = json.load(open(STATE_FILE))
    except (OSError, ValueError):
        prev = None

    cur = board_now()
    for c in cur.values():
        c["seen"] = stamp

    if prev is None:
        save({"baseline": stamp, "run": stamp, "cards": cur})
        print(json.dumps({"ok": True, "baseline": True, "cards": len(cur)}))
        return

    old = prev.get("cards", {})
    moves = [(k, old[k], c) for k, c in cur.items() if k in old and is_move(old[k], c)]

    if len(moves) > MAX_COMMENTS:
        save({"baseline": stamp, "run": stamp, "cards": cur})
        raise SystemExit("%d moves in one run, over the %d cap. Re-baselined without "
                         "commenting." % (len(moves), MAX_COMMENTS))

    # Start from the old state so a card whose comment fails keeps its old
    # column and is retried next run, rather than its move being lost.
    state = dict(old)
    for k, c in cur.items():
        if not (k in old and is_move(old[k], c)):
            state[k] = c
    posted, failed = [], []
    for k, o, c in moves:
        try:
            api("PUT", "/tasks/%s/comments" % k, {"comment": "<p>%s</p>" % comment_for(o, c)})
            state[k] = c
            posted.append({"task": int(k), "board": c["board"], "ref": "#%s" % c["i"],
                           "from": o.get("c"), "to": c["c"]})
        except SystemExit as e:
            failed.append({"task": int(k), "error": str(e)})

    cutoff = now - FORGET_AFTER
    for k in list(state):
        seen = state[k].get("seen")
        if k not in cur and seen and datetime.fromisoformat(seen.replace("Z", "+00:00")) < cutoff:
            del state[k]

    save({"baseline": prev.get("baseline"), "run": stamp, "cards": state})
    print(json.dumps({"ok": not failed, "cards": len(cur), "moves": posted, "failed": failed},
                     ensure_ascii=False))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()

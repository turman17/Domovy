#!/bin/sh
# Builds .bighome/, a synthetic fake home with realistic volume for UI performance runs
# (~120 Claude Code, ~320 Codex, ~430 Gemini chats, plus the Antigravity/OpenCode fixtures).
# Everything is generated; nothing is copied from the real home.
# Usage: scripts/bighome.sh [--reset]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIG="$ROOT/.bighome"
if [ "${1:-}" = "--reset" ]; then rm -rf "$BIG"; fi
if [ -f "$BIG/.big-seeded" ]; then echo "$BIG already built"; exit 0; fi
# Base: the fixture home from devhome.sh, retargeted at .bighome.
TMP="$ROOT/scripts/.bighome-base.sh"
# (the fixtures have no antigravity log/ or brain/ folders; devhome.sh expects them, so create them first)
sed -e 's#\.devhome#.bighome#g' \
    -e 's#^  dd if=/dev/urandom of="$G/antigravity-cli/log#  mkdir -p "$G/antigravity-cli/log" "$G/antigravity-cli/brain/ca11ab1e-1111-4111-8111-111111111111"; &#' \
    "$ROOT/scripts/devhome.sh" > "$TMP"
sh "$TMP" || { rm -f "$TMP"; exit 1; }
rm -f "$TMP"
python3 -I - "$BIG" <<'PY'
import os, sys, json, random, uuid, time, datetime
big = sys.argv[1]
random.seed(7)
now = time.time()
DAY = 86400
projects = ["orbit-api","landing-site","billing-core","mobile-app","infra-terraform","docs-site","ml-pipeline",
            "design-system","auth-service","data-warehouse","cli-tools","game-engine","blog-engine","ops-dashboard","search-index"]
verbs = ["Refactor","Add","Fix","Investigate","Migrate","Write tests for","Optimize","Document","Rename","Split"]
nouns = ["the billing module","rate limiting","the config loader","retry logic","the login flow","a flaky test","the build pipeline",
         "database indexes","the hero section","error handling","the cache layer","pagination","the CLI flags","logging"]
def prompt():
    return f"{random.choice(verbs)} {random.choice(nouns)}"
md = ("Here is the plan:\n\n## Steps\n\n1. Read the module\n2. Write a failing test\n3. Fix it\n\n```swift\nfunc example() -> Int {\n    return 42\n}\n```\n\n"
      "- **bold** item with `inline code`\n- another item with a [link](https://example.invalid)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n")
def ts(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def mtime(path, t): os.utime(path, (t, t))
def age(): return now - random.uniform(0.2, 180) * DAY
big_targets = {}  # path -> MB

# ---- Claude Code
cp = os.path.join(big, ".claude", "projects")
hist = []
for i in range(120):
    proj = random.choice(projects)
    slug = f"-Users-dev-code-{proj}"
    d = os.path.join(cp, slug); os.makedirs(d, exist_ok=True)
    sid = str(uuid.UUID(int=random.getrandbits(128), version=4))
    t0 = age()
    turns = random.choice([4, 8, 20, 60]) if i not in (3, 40, 77) else 0
    mb = {3: 18, 40: 9, 77: 6}.get(i)
    cwd = f"/Users/dev/code/{proj}"
    lines = []
    first = prompt()
    hist.append({"display": first, "pastedContents": {}, "timestamp": int(t0*1000), "project": cwd, "sessionId": sid})
    def mk(t, role, content, extra=""):
        return json.dumps({"type": role, "message": {"role": role, "content": content}, "cwd": cwd, "sessionId": sid, "timestamp": ts(t), "uuid": str(uuid.uuid4())})
    lines.append(mk(t0, "user", first))
    n = turns if mb is None else 0
    for k in range(n):
        lines.append(mk(t0+k*30+5, "assistant", [{"type":"text","text":md*random.choice([1,2])}]))
        lines.append(mk(t0+k*30+20, "user", prompt()))
    p = os.path.join(d, sid + ".jsonl")
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
        if mb:
            blk = mk(t0+5, "assistant", [{"type":"text","text":md*20}]) + "\n"
            while f.tell() < mb*1024*1024: f.write(blk)
    mtime(p, t0 + 3600)
    if random.random() < 0.3:
        tr = os.path.join(d, sid, "tool-results"); os.makedirs(tr, exist_ok=True)
        tp = os.path.join(tr, "r%08x.txt" % random.getrandbits(32))
        with open(tp, "w") as f: f.write("synthetic tool output\n" * random.randint(100, 20000))
        mtime(tp, t0 + 3600)
with open(os.path.join(big, ".claude", "history.jsonl"), "a") as f:
    base = json.dumps(hist[0])
    for h in hist: f.write(json.dumps(h) + "\n")
    while f.tell() < 1024*1024:
        h = dict(random.choice(hist)); h["display"] = prompt() + " " + "x"*random.randint(0,200); f.write(json.dumps(h) + "\n")

# ---- Codex
cs = os.path.join(big, ".codex", "sessions")
idx = []
for i in range(320):
    t0 = age()
    dt = datetime.datetime.fromtimestamp(t0)
    d = os.path.join(cs, f"{dt.year}", f"{dt.month:02d}", f"{dt.day:02d}"); os.makedirs(d, exist_ok=True)
    rid = "01b%05x-%04x-7%03x-8%03x-%012x" % (i, random.getrandbits(16), random.getrandbits(12), random.getrandbits(12), random.getrandbits(48))
    cwd = f"/Users/dev/code/{random.choice(projects)}"
    name = f"rollout-{dt:%Y-%m-%dT%H-%M-%S}-{rid}.jsonl"
    first = prompt() + "\nUse the existing conventions."
    L = [json.dumps({"timestamp": ts(t0), "type":"session_meta","payload":{"id":rid,"timestamp":ts(t0),"cwd":cwd,"originator":"codex_cli_rs","cli_version":"0.169.0"}}),
         json.dumps({"timestamp": ts(t0+1), "type":"event_msg","payload":{"type":"user_message","message":first,"images":[]}})]
    mb = {5: 20, 90: 12, 200: 8}.get(i)
    turns = random.choice([2, 6, 30])
    for k in range(turns):
        L.append(json.dumps({"timestamp": ts(t0+10+k), "type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":md}]}}))
        L.append(json.dumps({"timestamp": ts(t0+11+k), "type":"event_msg","payload":{"type":"user_message","message":prompt(),"images":[]}}))
    p = os.path.join(d, name)
    with open(p, "w") as f:
        f.write("\n".join(L) + "\n")
        if mb:
            blk = json.dumps({"timestamp": ts(t0+5), "type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":md*20}]}}) + "\n"
            while f.tell() < mb*1024*1024: f.write(blk)
    mtime(p, t0 + 1800)
    idx.append({"id": rid, "thread_name": first.split("\n")[0], "updated_at": ts(t0+1800)[:-5]+"Z"})
with open(os.path.join(big, ".codex", "session_index.jsonl"), "a") as f:
    for r in idx: f.write(json.dumps(r) + "\n")

# ---- Gemini: many chats, some sharing a session id
gt = os.path.join(big, ".gemini", "tmp")
for i in range(430):
    proj = random.choice(projects[:6])
    d = os.path.join(gt, proj, "chats"); os.makedirs(d, exist_ok=True)
    pr = os.path.join(gt, proj, ".project_root")
    if not os.path.exists(pr):
        with open(pr, "w") as f: f.write(f"{big}/code/{proj}")
        os.makedirs(f"{big}/code/{proj}", exist_ok=True)
    t0 = age()
    shared = i % 3 == 0
    sid = f"shared-{proj}" if shared else str(uuid.uuid4())
    dt = datetime.datetime.fromtimestamp(t0)
    p = os.path.join(d, f"session-{dt:%Y-%m-%dT%H-%M}-{i:04x}{sid[:4]}.jsonl")
    L = [json.dumps({"sessionId": sid, "projectHash": "%064x" % random.getrandbits(256), "startTime": ts(t0), "lastUpdated": ts(t0), "kind": "main"})]
    if not shared or i % 6 == 0:
        L.append(json.dumps({"id":"m1","timestamp":ts(t0+5),"type":"user","content":[{"text":prompt()}]}))
        for k in range(random.choice([1, 4, 12])):
            L.append(json.dumps({"id":f"g{k}","timestamp":ts(t0+10+k),"type":"gemini","content":md,"thoughts":[],"model":"gemini-2.5-pro"}))
    with open(p, "w") as f: f.write("\n".join(L) + "\n")
    mtime(p, t0 + 600)
logs = [{"sessionId": f"shared-{p}", "messageId": n, "type": "user", "message": prompt(), "timestamp": ts(now - n*3600)} for p in projects[:6] for n in range(60)]
for p in projects[:6]:
    with open(os.path.join(gt, p, "logs.json"), "w") as f: json.dump([l for l in logs if l["sessionId"] == f"shared-{p}"], f)
PY
touch "$BIG/.big-seeded"
echo "built $BIG"

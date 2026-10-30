# claude-session-cost [hours]: what the Claude sessions cost over the last hours, from their transcripts, in units of
# one input token (cache read x0.1, cache write 5m x1.25, 1h x2, output x5), with a dollar scale calibrated on a
# session's /cost (2026-10-30). The share of re-writes after a pause, and the pause lengths, say what a TTL saves.
import collections, datetime as dt, glob, json, os, sys

H = float(sys.argv[1]) if len(sys.argv) > 1 else 24
USD_PER_M = float(os.environ.get("CLAUDE_COST_USD_PER_M", "3.3"))
root = os.path.join(os.environ.get("CLAUDE_HOME", os.path.expanduser("~/.claude")), "projects")
since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=H)
W = dict(inp=1, read=0.1, w5=1.25, w1h=2, out=5)
S = collections.defaultdict(lambda: dict(n=0, inp=0, read=0, w5=0, w1h=0, out=0, ctx=0, wakes=0, wake=0, cwd=""))
pauses = collections.Counter()
seen = set()
for f in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
    if os.path.getmtime(f) < since.timestamp():
        continue
    prev = None
    for line in open(f, errors="replace"):
        if '"usage"' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get("message") or {}
        u, mid = m.get("usage"), m.get("id")
        if not u or mid in seen:
            continue
        seen.add(mid)
        t = dt.datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00"))
        p, prev = prev, t
        if t < since:
            continue
        s = S[d.get("sessionId", "?")]
        s["cwd"] = d.get("cwd", "")
        w1h = (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens", 0)
        w5 = u.get("cache_creation_input_tokens", 0) - w1h
        r = u.get("cache_read_input_tokens", 0)
        s["n"] += 1
        s["inp"] += u.get("input_tokens", 0)
        s["read"] += r
        s["w5"] += w5
        s["w1h"] += w1h
        s["out"] += u.get("output_tokens", 0)
        s["ctx"] = max(s["ctx"], u.get("input_tokens", 0) + r + w5 + w1h)
        if w5 + w1h > 50_000 and w5 + w1h > r:
            s["wakes"] += 1
            s["wake"] += w5 * W["w5"] + w1h * W["w1h"]
            g = (t - p).total_seconds() / 60 if p else 0
            pauses["<5m" if g < 5 else "5-60m" if g < 60 else "1-4h" if g < 240 else ">4h"] += w5 + w1h

cost = lambda s: sum(s[k] * W[k] for k in W)
tot = sum(cost(s) for s in S.values()) or 1
usd = lambda u: f"${u * USD_PER_M / 1e6:,.0f}"
share = {k: sum(s[k] for s in S.values()) * W[k] / tot for k in W}
wake = sum(s["wake"] for s in S.values())
pt = sum(pauses.values()) or 1
print(f"last {H:g} h: {len(S)} sessions, {tot / 1e6:.0f}M units, about {usd(tot)}")
print(f"  read {share['read']:.0%}  write {share['w5'] + share['w1h']:.0%} (1h {share['w1h']:.0%})  output {share['out']:.0%}"
      f"  re-writes after a pause {wake / tot:.0%}")
print("  pauses before them: " + "  ".join(f"{b} {pauses[b] / pt:.0%}" for b in ("<5m", "5-60m", "1-4h", ">4h")))
print(f"{'session':9} {'cwd':40} {'resp':>5} {'ctx':>6} {'cost':>7} {'share':>5} {'wakes':>5}")
for sid, s in sorted(S.items(), key=lambda kv: -cost(kv[1]))[:12]:
    print(f"{sid[:8]:9} {s['cwd'][-40:]:40} {s['n']:5} {s['ctx'] / 1e3:5.0f}k {usd(cost(s)):>7} {cost(s) / tot:5.0%} {s['wakes']:5}")

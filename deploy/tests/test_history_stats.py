# usecert-history's A16 additions (feed, venue mark, basis, frozen windows, stats.json/csv) against recorded fixtures.
# Run: python deploy/tests/test_history_stats.py  (exit code = number of failures)
#      python deploy/tests/test_history_stats.py --golden <script>   rewrites the pre-A16 golden from <script>
# Fixtures in deploy/tests/fixtures/a16/ are real responses recorded 2026-09-27 (see each file's _recorded).
# The golden history_pre_a16.json was produced by this harness from deploy/bin/usecert-history at aae4053,
# before any A16 change, so "old fields unchanged" is checked against the old script's own output.
import csv, importlib.machinery, importlib.util, io, json, os, sys, tempfile, types, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures", "a16")
SCRIPT = os.path.join(HERE, "..", "bin", "usecert-history")
fx = lambda n: json.load(open(os.path.join(FIX, n)))
RPC, OBD, FUND, BOOK = fx("rpc_book_block74138250.json"), fx("lighter_orderbookdetails.json"), fx("lighter_fundings_m16_31d.json"), fx("book_4663.json")
T0 = RPC["block"]["timestamp"]


def load(path):
    loader = importlib.machinery.SourceFileLoader("h%d" % id(path), path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    m = importlib.util.module_from_spec(spec); loader.exec_module(m)
    return m


def stub(m, tmp, clock):
    """Point the job at a temp dir and at the fixtures instead of the network."""
    json.dump(BOOK, open(os.path.join(tmp, "book.json"), "w"))
    m.BOOK = os.path.join(tmp, "book.json"); m.STATE = os.path.join(tmp, "state", "samples.json")
    m.OUT = os.path.join(tmp, "www", "history.json"); m.MARKET_STATE = os.path.join(tmp, "state", "market.json")
    m.STATS_JSON = os.path.join(tmp, "www", "stats.json"); m.STATS_CSV = os.path.join(tmp, "www", "stats.csv")
    m.time = types.SimpleNamespace(time=lambda: clock[0], sleep=lambda s: None)
    calls = {(c["to"].lower(), c["fn"]): c for c in RPC["calls"]}
    def eth_call(to, fn, block="latest"):
        c = calls[(to.lower(), fn)]
        return None if c["error"] else c["result"]
    def venue(path):
        u = urllib.parse.urlparse(path); q = {k: int(v[0]) for k, v in urllib.parse.parse_qs(u.query).items() if k != "resolution"}
        if u.path == "/api/v1/fundings":
            rows = [f for f in FUND["fundings"] if q["start_timestamp"] <= f["timestamp"] <= q["end_timestamp"]]
            return {"code": 200, "resolution": "1h", "fundings": rows[-q["count_back"]:]}
        if u.path == "/api/v1/orderBookDetails":
            return OBD
        raise AssertionError(path)
    m.eth_call, m.venue = eth_call, venue
    m.head_block = lambda: (RPC["block"]["number"], RPC["block"]["timestamp"] + (clock[0] - T0))
    return m


def run_twice(script):
    """Two 5-minute runs from an empty state; returns the history.json of the second."""
    with tempfile.TemporaryDirectory() as tmp:
        clock = [T0]
        m = stub(load(script), tmp, clock)
        m.main(); clock[0] += 300; m.main()
        out = {"history": json.load(open(m.OUT))}
        for k, p in (("stats", m.STATS_JSON), ("csv", m.STATS_CSV)):
            if os.path.exists(p):
                out[k] = open(p, encoding="utf-8").read() if k == "csv" else json.load(open(p))
        return out


if __name__ == "__main__" and sys.argv[1:2] == ["--golden"]:
    json.dump(run_twice(sys.argv[2])["history"], open(os.path.join(FIX, "history_pre_a16.json"), "w"), indent=0, sort_keys=True)
    print("golden written"); sys.exit(0)


# ------------------------------------------------------------------ the tests
import calendar
bad = 0
def check(ok, name, detail=""):
    global bad
    print("PASS" if ok else "FAIL", name, "" if ok else detail); bad += not ok

H = load(SCRIPT)
BK = BOOK

# 1. basis maths, on the recorded numbers
check(H.bps(373.59, 371.7471) == round((373.59 - 371.7471) / 371.7471 * 1e4, 2) == 49.57, "basis: TSLA mark 373.59 vs feed 371.7471 = +49.57 bps")
check(H.bps(771.69, 772.32802713) == -8.26, "basis: negative when the venue is below the feed (SPY -8.26 bps)")
check(H.bps(None, 1.0) is None and H.bps(1.0, None) is None and H.bps(1.0, 0) is None, "basis: a missing side or a zero feed gives null, never a number")
calls = {(c["to"].lower(), c["fn"]): c for c in RPC["calls"]}
H.eth_call = lambda to, fn, block="latest": calls[(to.lower(), fn)]["result"]
tsla = [v for v in BK["vaults"] if v["symbol"] == "uTSLA"][0]
check(H.read_feed(tsla["replayAggregator"], RPC["block"]["number"], 8) == (371.7471, 1790362944), "feed: latestRoundData decoded at 8 decimals (recorded TSLA round)")
H.venue = lambda path: OBD
marks = H.venue_marks()
check(marks[16] == (373.59, 373.53) and len(marks) == 6, "venue: mark_price / index_price parsed from the recorded orderBookDetails", marks)
last = max(FUND["fundings"], key=lambda f: f["timestamp"])
implied = float(last["value"]) * 100 / float(last["rate"])
check(abs(implied - marks[16][0]) / marks[16][0] < 0.001, "units: mark is USD per unit of base, since funding value = rate %% x price (implied %.2f)" % implied)

# 2. frozen detection
check(not H.is_frozen(10_000 + 3600, 10_000) and H.is_frozen(10_000 + 3601, 10_000), "frozen: strictly more than 3600 s after updatedAt")
ages = [RPC["block"]["timestamp"] - H.words(c["result"], 5)[3] for c in RPC["calls"] if c["fn"] == "latestRoundData"]
check(len(ages) == 6 and all(a > H.FROZEN_AFTER_SEC for a in ages), "frozen: all six recorded feeds are frozen on a Sunday", ages)


# 3. the gap table across a synthetic weekend: Fri 19:00 UTC to Mon 16:00 UTC, one sample per 5 min.
# The feed posts a round every 5 min while the market is open and none between Fri 20:00 and Mon 13:30.
def weekend(skip_before_resume=False, stop_at=None):
    fri = calendar.timegm((2026, 9, 25, 19, 0, 0)); close = calendar.timegm((2026, 9, 25, 20, 0, 0))
    mon_open = calendar.timegm((2026, 9, 28, 13, 30, 0)); end = stop_at or calendar.timegm((2026, 9, 28, 16, 0, 0))
    pts, t, i, feed, upd = [], fri, 0, None, None
    while t <= end:
        if t <= close:
            upd, feed = t - 30, round(370 + (t - fri) / 3600 * 0.01, 8)
        elif t >= mon_open:
            upd, feed = t - 30, round(380 + (t - mon_open) / 3600 * 0.01, 8)
        mark = round(371 + i * 0.001, 3)
        if not (skip_before_resume and mon_open - 3600 <= t < mon_open):
            pts.append({"t": t, "block": 1000 + i, "blockTime": t + 2, "v": {"uTSLA": [feed, upd, mark, round(mark - 0.05, 3)]}})
        t += 300; i += 1
    return pts, close, mon_open


pts, close, mon_open = weekend()
rows = H.vault_rows(pts, "uTSLA")
g = H.gap_windows(rows)
freeze_upd = close - 30
at_close = [r for r in rows if r[0] == close][0]
before = [r for r in rows if r[0] < mon_open][-1]
after = [r for r in rows if r[0] >= mon_open][0]
check(len(g) == 1 and g[0]["status"] == "closed", "gaps: one window over the weekend, none while the feed updates every 5 min", [x["freezeUpdatedAt"] for x in g])
w = g[0]
check(w["freezeUpdatedAt"] == freeze_upd and w["feedAtFreeze"] == at_close[2] == 370.01, "gaps: freeze = the Friday-close round and its price")
check(w["frozenSeenT"] == close + 3600, "gaps: first frozen sample is the first one more than an hour past that round")
check(w["markSampleT"] == before[0] == mon_open - 300 and w["markBeforeResume"] == before[4], "gaps: venue mark taken at the last sample before the feed resumes")
check(w["gapBps"] == round((before[4] - 370.01) / 370.01 * 1e4, 2), "gaps: gap bps = (mark before resume - feed at freeze) / feed at freeze", w["gapBps"])
check(w["feedAfterResume"] == after[2] == 380.0 and w["resumeUpdatedAt"] == mon_open - 30 and w["resumeSeenT"] == mon_open, "gaps: the feed's first price after reopening")
check(w["reopenMoveBps"] == round((380.0 - 370.01) / 370.01 * 1e4, 2) and w["durationSec"] == mon_open - close, "gaps: reopen move and duration from the feed's own timestamps")
check(not w["recordingGapAtResume"], "gaps: contiguous recording is not flagged")
pts2, _, _ = weekend(skip_before_resume=True)
w2 = H.gap_windows(H.vault_rows(pts2, "uTSLA"))[0]
check(w2["recordingGapAtResume"] and w2["markSampleT"] == mon_open - 3900, "gaps: an hour of missing samples before the resume is flagged, and the row says when the mark was taken")
pts3, _, _ = weekend(stop_at=calendar.timegm((2026, 9, 27, 12, 0, 0)))
w3 = H.gap_windows(H.vault_rows(pts3, "uTSLA"))
check(len(w3) == 1 and w3[0]["status"] == "open" and w3[0]["feedAfterResume"] is None and w3[0]["markSampleT"] == pts3[-1]["t"], "gaps: a window still frozen is open, marked at the latest sample")
check(H.merge_gaps(w3, g, mon_open + 7200) == [w], "gaps: an open row is replaced once its window closes")
coarse = H.gap_windows(H.vault_rows(H.thin(pts, mon_open + 86400, 0), "uTSLA"))
check(coarse and coarse[0]["markBeforeResume"] != w["markBeforeResume"], "gaps: (control) recomputing from hourly-thinned samples WOULD move the mark")
check(H.merge_gaps([w], coarse, mon_open + 86400) == [w], "gaps: so a closed row is final and thinning never rewrites it")
check(H.merge_gaps([dict(w, freezeUpdatedAt=w["freezeUpdatedAt"] - 91 * 86400), w], [], mon_open) == [w], "gaps: rows older than 90 days are dropped")

# 4. thinning keeps bounds
now = calendar.timegm((2026, 9, 27, 20, 0, 0))
many = [{"t": now - i * 300, "block": i, "blockTime": now - i * 300, "v": {}} for i in range(40 * 288)]
th = H.thin(many, now)
ages = [now - p["t"] for p in th]
fine = [x for x in ages if x <= H.FINE_SEC]
old_hours = [p["t"] // 3600 for p in th if now - p["t"] > H.FINE_SEC]
check(len(th) <= H.MAX_POINTS and max(ages) <= H.MARKET_KEEP_SEC, "thin: 40 days in, at most MAX_POINTS out and nothing past 30 days", (len(th), max(ages)))
check(len(fine) == H.FINE_SEC // 300 + 1 and len(old_hours) == len(set(old_hours)), "thin: every 5-min sample for 7 days, at most one per hour before that", (len(fine), len(old_hours)))
check(H.thin(th, now) == th and H.thin(th, now + 300) == H.thin(many, now + 300), "thin: idempotent, and thinning in passes = thinning once")
keep_max, H.MAX_POINTS = H.MAX_POINTS, 100
capped = H.thin(many, now)
H.MAX_POINTS = keep_max
check(len(capped) == 100 and capped[-1]["t"] == now, "thin: the hard cap keeps the newest")
pub = H.market_series(BK, {"points": th}, now)
check(len(pub["t"]) == 2 * 288 + 1 + (30 - 2) * 24 and all(len(x) == len(pub["t"]) for x in pub["vaults"]["uTSLA"].values() if isinstance(x, list)), "thin: history.json view is 2 days at 5 min then hourly, arrays aligned", len(pub["t"]))

# 5 and 6: the whole job, twice, against the recorded fixtures
r = run_twice(SCRIPT)
hist, stats, text = r["history"], r["stats"], r["csv"]
golden = fx("history_pre_a16.json")
check(all(hist.get(k) == v for k, v in golden.items()), "history.json: every pre-A16 field equals the old script's output", [k for k, v in golden.items() if hist.get(k) != v])
check(set(hist) - set(golden) == {"market", "marketSource"}, "history.json: only market and marketSource are added", set(hist) - set(golden))
mt = hist["market"]["vaults"]["uTSLA"]
check(mt["basisBps"] == [49.57, 49.57] and mt["feedFrozen"] == [1, 1] and hist["market"]["block"] == [74138250, 74138250], "history.json: the market series carries basis, frozen flag and the pinned block")

a = {x["symbol"]: x for x in stats["assets"]}
T = T0 + 300
sgn = lambda f: (-1 if f["direction"] == "long" else 1) * float(f["rate"])
exp7 = [sgn(f) for f in FUND["fundings"] if T - f["timestamp"] < 7 * 86400]
exp30 = [sgn(f) for f in FUND["fundings"] if T - f["timestamp"] < 30 * 86400]
f7, f30 = a["uTSLA"]["funding"]["d7"], a["uTSLA"]["funding"]["d30"]
check(f7["hours"] == len(exp7) == 168 and f7["avgPctPerHour"] == round(sum(exp7) / 168, 8), "stats: 7-day funding mean over the venue's 168 hourly rates", f7)
check(f30["hours"] == len(exp30) == 720 and f30["avgPctPerHour"] == round(sum(exp30) / 720, 8) < 0, "stats: 30-day mean, backfilled from the venue's history; negative = the vault paid", f30)
check(a["uTSLA"]["now"]["basisBps"] == 49.57 and a["uTSLA"]["now"]["feedFrozen"] is True and len(stats["assets"]) == 6, "stats: current basis and frozen flag per asset")
check(all(x["gaps"] and x["gaps"][0]["status"] == "open" for x in stats["assets"]), "stats: the live weekend shows as an open window for every asset")

rd = list(csv.DictReader(io.StringIO(text)))
check(len(rd) == 6 + sum(len(x["gaps"]) for x in stats["assets"]), "csv: one row per asset plus one per gap row", len(rd))
js = lambda v: "" if v is None else v if isinstance(v, str) else json.dumps(v)
mism, n = [], 0
for x in stats["assets"]:
    nrow = [q for q in rd if q["row"] == "now" and q["asset"] == x["symbol"]][0]
    for col, key in H.CSV_NOW:
        v = x["now"][key]; n += 1
        if nrow[col] != js(v) or (isinstance(v, float) and float(nrow[col]) != v):
            mism.append((x["symbol"], col))
    for col, win, key in H.CSV_FUND:
        v = x["funding"][win][key]; n += 1
        if nrow[col] != js(v) or (isinstance(v, float) and float(nrow[col]) != v):
            mism.append((x["symbol"], col))
    grows = [q for q in rd if q["row"] == "gap" and q["asset"] == x["symbol"]]
    for gj, gc in zip(x["gaps"], grows):
        for col, key in H.CSV_GAP:
            v = gj[key]; n += 1
            if gc[col] != js(v) or (isinstance(v, float) and float(gc[col]) != v):
                mism.append((x["symbol"], col))
check(not mism and n > 100 and len(H.CSV_HEADER) == len(set(H.CSV_HEADER)), "csv: every cell is the JSON value, same digits (%d cells)" % n, mism[:5])

# 7. the A16 additions fail soft: history.json's old fields survive a dead chain head and a broken step
with tempfile.TemporaryDirectory() as tmp:
    clock = [T0]; m = stub(load(SCRIPT), tmp, clock)
    def boom(*a): raise OSError("down")
    m.head_block = boom
    m.main(); clock[0] += 300
    m.record_market = boom
    m.main()
    h2 = json.load(open(m.OUT))
    check(all(h2.get(k) == v for k, v in golden.items()) and "market" not in h2, "fail-soft: a broken A16 step leaves history.json exactly as the old script wrote it")

sys.exit(bad)

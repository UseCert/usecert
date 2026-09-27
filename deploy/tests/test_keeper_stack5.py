# Stack-5 keeper, option A: receipt-0 rehedge orders, orphan-close sizing on refund, and the
# guarded auto-rehedge. Stubbed chain, venue and clock; no key here is real, nothing is sent.
# Run: python deploy/tests/test_keeper_stack5.py   (unittest)
import asyncio
import json
import os
import sys
import time as _time
import unittest
from decimal import Decimal, ROUND_FLOOR

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

k = _ethstub.load("usecert-keeper.py", "keeper5")

SET = "0x" + "5e" * 32
VAULT = "0x" + "ab" * 20
ORACLE = "0x" + "0c" * 20
REG = "0x" + "0e" * 20
E18 = 10 ** 18
TOPIC = "0x" + "77" * 32
# Recorded on chain 4663 (fixtures/uimultiplier-4663.json): SPY's dividend multiplier.
M_SPY = int(_ethstub.fixture("uimultiplier-4663.json")["tokens"]["SPY"]["uiMultiplier"])
M_SPLIT = 10 * E18


class Clock:
    """The keeper's `time`: sleeps advance it, so fill polling runs instantly and deterministically."""
    def __init__(self, t):
        self.t = float(t)

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s

    strftime = staticmethod(_time.strftime)
    gmtime = staticmethod(_time.gmtime)


class Venue:
    """One account's position on one market. `fill` decides how much of each order executes."""
    def __init__(self, pos=0, entry=0.0, fill=lambda order: order["base"]):
        self.pos, self.entry, self.fill, self.orders = pos, entry, fill, []

    def position(self):
        return self.pos, self.entry

    async def open(self, base, side, limit_px18, coi, reduce_only=False):
        o = {"base": base, "side": side, "limit_px18": limit_px18, "coi": coi, "reduce_only": reduce_only}
        self.orders.append(o)
        n = self.fill(o)
        px = limit_px18 / E18 * (0.995 if side == 0 else 1.0)
        if side == 0:
            tot = self.pos + n
            self.entry = (self.pos * self.entry + n * px) / tot if tot else 0.0
            self.pos = tot
        else:
            self.pos -= n
        return "0xvenuetx%d" % len(self.orders)


def hedge_log(block, tx, log_index, rid, base, limit_px18, side=0):
    return {"blockNumber": hex(block), "transactionHash": tx, "logIndex": hex(log_index),
            "topics": [TOPIC, "0x%064x" % rid],
            "data": "0x%064x%064x%064x" % (base, side, limit_px18)}


def words(*ws):
    return "0x" + "".join("%064x" % w for w in ws)


def keeper(stack=5, venue=None, logs=(), head=101, views=None, receipts=None, mult=M_SPY, now=2_000_000_000):
    K = k.Keeper.__new__(k.Keeper)
    K.vault, K.rpc, K.cast, K.stack, K.topic = VAULT, "rpc", "cast", stack, TOPIC
    K.market, K.size_dec, K.price_dec, K.fill_timeout, K.settle_window = 16, 4, 2, 60, 3600
    K.settler_pk, K.attester_pk = (SET, None) if stack >= 5 else (None, "0x" + "a1" * 32)
    K.oracle, K.auto_recall = ORACLE, False
    K.state = {"next_block": 100, "receipts": {}, "last_recall": 0}
    K.saves = []
    K._save = lambda: K.saves.append(json.loads(json.dumps(K.state)))
    K.venue = venue or Venue()
    K.position = K.venue.position
    K.open = K.venue.open
    K.logs = list(logs)
    K.head = head
    K.views = dict(views or {})
    K.rpc_calls = []
    K.sent = []
    K.receipts = receipts or {}
    K.mult = mult
    k.time = Clock(now)

    def rpc(method, params):
        K.rpc_calls.append(method)
        if method == "eth_blockNumber":
            return hex(K.head)
        if method == "eth_getLogs":
            f = params[0]
            lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
            return [lg for lg in K.logs if lo <= int(lg["blockNumber"], 16) <= hi]
        if method == "eth_call":
            to, data = params[0]["to"], params[0]["data"]
            return K.views[(to.lower(), data[:10])]()
        raise AssertionError(method)
    K._rpc = rpc

    def cast(*a):
        if a[0] == "call":
            sig = a[2]
            if sig.startswith("mintReceipts"):
                return "\n".join(K.receipts[int(a[3])]) + "\n"
            if sig.startswith("mintMult18"):
                return "%d [x]\n" % K.mult
            if sig.startswith("settleWindow"):
                return "3600\n"
            if sig.startswith("hotBuffer"):
                return "%d\n" % 10 ** 12
            if sig.startswith("totalOwedOutstanding"):
                return "0\n"
            raise AssertionError(sig)
        K.sent.append(a)
        return "status 1 (success)\ntransactionHash 0x%064x\n" % len(K.sent)
    K._cast = cast
    return K


def sends(K):
    return [(a[2].split("(")[0], a[3]) for a in K.sent if a[0] == "send"]


def receipt(user="0x" + "aa" * 20, escrow=5_000_000, settled=False, px=1, at=0, staged=False, certs=0):
    b = lambda x: "true" if x else "false"
    return [user, str(escrow), b(settled), str(px), str(at), b(staged), "%d [1e20]" % certs]


class Selectors(unittest.TestCase):
    def test_hardcoded_selectors(self):
        for name, sel in k.SEL.items():
            self.assertEqual("0x" + _ethstub.keccak(text=name + "()")[:4].hex(), sel, name)
        self.assertEqual("0x" + _ethstub.keccak(text="latest(address)")[:4].hex(), k.SEL_LATEST)


class Rehedge(unittest.TestCase):
    TX_A, TX_B, TX_M = "0x" + "a0" * 32, "0x" + "b0" * 32, "0x" + "c0" * 32
    LIMIT = 520_000 * E18 // 1000                     # a SHARE price cap, 520.00

    def logs(self):
        return [hedge_log(101, self.TX_A, 3, 0, 50_000, self.LIMIT),        # rehedge
                hedge_log(101, self.TX_M, 4, 5, 70_000, self.LIMIT),        # a mint, receipt 5
                hedge_log(101, self.TX_B, 7, 0, 20_000, self.LIMIT),        # rehedge, same block
                hedge_log(101, self.TX_A, 9, 0, 10_000, self.LIMIT)]        # rehedge, same tx as the first

    def test_two_rehedges_one_block_keyed_by_log_filled_never_settled(self):
        K = keeper(logs=self.logs(), receipts={5: receipt(at=2_000_000_000 - 10, certs=1)})
        K.run_once()
        rh = K.state["rehedges"]
        want = {k.rehedge_key(self.TX_A, 3), k.rehedge_key(self.TX_B, 7), k.rehedge_key(self.TX_A, 9)}
        self.assertEqual(set(rh), want)
        self.assertTrue(all(r["status"] == "filled" for r in rh.values()), rh)
        self.assertEqual(sorted(r["filled"] for r in rh.values()), [10_000, 20_000, 50_000])
        # The first save after the scan already holds all three, queued, with next_block advanced.
        first = K.saves[0]
        self.assertEqual(first["next_block"], 102)
        self.assertEqual({r["status"] for r in first["rehedges"].values()}, {"queued"})
        # Four orders: the mint and three rehedges, all opening buys at the event's own limit.
        self.assertEqual([(o["base"], o["side"], o["limit_px18"]) for o in K.venue.orders],
                         [(70_000, 0, self.LIMIT), (50_000, 0, self.LIMIT), (20_000, 0, self.LIMIT), (10_000, 0, self.LIMIT)])
        cois = [o["coi"] for o in K.venue.orders]
        self.assertEqual(len(set(cois)), 4)
        self.assertEqual(cois[0], 5)
        self.assertTrue(all(k.REHEDGE_COI_BASE <= c < 2 ** 40 for c in cois[1:]))
        # settleMint for receipt 5 only - never for receipt 0.
        self.assertEqual(sends(K), [("settleMint", "5")])
        self.assertEqual(set(K.state["receipts"]), {"5"})

    def test_rescan_after_restart_places_nothing_twice(self):
        K = keeper(logs=self.logs(), receipts={5: receipt(at=2_000_000_000 - 10, certs=1)})
        K.run_once()
        n_orders, n_sent = len(K.venue.orders), len(K.sent)
        K.state["next_block"] = 100                    # a crash before next_block was persisted
        K.run_once()
        self.assertEqual((len(K.venue.orders), len(K.sent)), (n_orders, n_sent))

    def test_queued_survives_a_crash_and_in_flight_is_never_retried(self):
        K = keeper()
        K.state["rehedges"] = {
            "0xq:1": {"status": "queued", "base": 3000, "side": 0, "limit_px18": str(self.LIMIT), "tx": "0x01", "log_index": 1},
            "0xp:2": {"status": "placing", "base": 4000, "side": 0, "limit_px18": str(self.LIMIT), "tx": "0x02", "log_index": 2},
            "0xs:3": {"status": "placed", "base": 5000, "side": 0, "limit_px18": str(self.LIMIT), "tx": "0x03", "log_index": 3}}
        K.run_once()
        rh = K.state["rehedges"]
        self.assertEqual([o["base"] for o in K.venue.orders], [3000])
        self.assertEqual(rh["0xq:1"]["status"], "filled")
        self.assertEqual((rh["0xp:2"]["status"], rh["0xs:3"]["status"]), ("INTERRUPTED_needs_human",) * 2)

    def test_unfilled_and_partial_left_for_a_human_not_retried(self):
        fills = iter([0, 700])
        K = keeper(venue=Venue(fill=lambda o: next(fills)),
                   logs=[hedge_log(101, self.TX_A, 1, 0, 1000, self.LIMIT), hedge_log(101, self.TX_B, 2, 0, 1000, self.LIMIT)])
        K.run_once()
        rh = K.state["rehedges"]
        self.assertEqual(rh[k.rehedge_key(self.TX_A, 1)]["status"], "UNFILLED_needs_human")
        self.assertEqual((rh[k.rehedge_key(self.TX_B, 2)]["status"], rh[k.rehedge_key(self.TX_B, 2)]["filled"]),
                         ("PARTIAL_needs_human", 700))
        K.run_once()
        self.assertEqual(len(K.venue.orders), 2)
        self.assertEqual(sends(K), [])

    def test_stack4_is_unchanged(self):
        K = keeper(stack=4, logs=[hedge_log(101, self.TX_A, 3, 0, 50_000, self.LIMIT)],
                   receipts={0: receipt(user="0x" + "00" * 20)})
        K.run_once()
        self.assertNotIn("rehedges", K.state)
        self.assertEqual(K.state["receipts"], {"0": {"status": "already_closed_onchain"}})
        self.assertEqual((K.venue.orders, sends(K)), ([], []))


class MintHandleUnchanged(unittest.TestCase):
    """handle() now places through _fill; a mint's journal, statuses and sends are as before."""
    LIMIT = 400 * E18

    def run_mint(self, stack, fill, venue_ok=True, refuse=False):
        v = Venue(pos=1000, entry=350.0, fill=fill)
        K = keeper(stack=stack, venue=v, receipts={5: receipt(at=2_000_000_000 - 10, certs=1)})
        if refuse:
            async def no(*a, **kw):
                raise RuntimeError("code 20558 restricted jurisdiction")
            K.open = no
        if not venue_ok:
            calls = iter(range(10 ** 6))
            real = K.position
            K.position = lambda: real() if next(calls) == 0 else (_ for _ in ()).throw(RuntimeError("429"))
        K.handle(5, 2000, 0, self.LIMIT)
        return K, K.state["receipts"]["5"]

    def test_statuses_both_stacks(self):
        for stack in (4, 5):
            K, rec = self.run_mint(stack, lambda o: o["base"])
            self.assertEqual(rec["status"], "settled", stack)
            self.assertEqual((rec["base"], rec["limit_px18"], rec["pos_before"], rec["entry_before"], rec["filled"]),
                             (2000, str(self.LIMIT), 1000, 350.0, 2000))
            px = (3000 * K.venue.entry - 1000 * 350.0) / 2000
            self.assertEqual(rec["fill_px18"], str(int(round(px * 10 ** 6)) * 10 ** 12))
            self.assertEqual([(o["coi"], o["reduce_only"]) for o in K.venue.orders], [(5, False)])
            self.assertEqual(sends(K), [("settleMint", "5")])
            self.assertEqual(self.run_mint(stack, lambda o: 0)[1]["status"], "unfilled_left_for_refund")
            K, rec = self.run_mint(stack, lambda o: 500)
            self.assertEqual((rec["status"], rec["filled"], sends(K)), ("PARTIAL_needs_human", 500, []))
            self.assertEqual(self.run_mint(stack, None, refuse=True)[1]["status"], "order_refused")
            self.assertEqual(self.run_mint(stack, lambda o: o["base"], venue_ok=False)[1]["status"],
                             "PLACED_UNCONFIRMED_needs_human")

    def test_position_falling_is_never_read_as_unfilled(self):
        # An exit closing 700 while the open is unconfirmed: -700 must not become "filled 0".
        v = Venue(pos=1000, entry=350.0, fill=lambda o: 0)
        K = keeper(venue=v, receipts={5: receipt(at=2_000_000_000 - 10, certs=1)})
        real = K.venue.position
        K.position = lambda: (real()[0] - (700 if K.venue.orders else 0), real()[1])
        K.handle(5, 2000, 0, self.LIMIT)
        self.assertEqual(K.state["receipts"]["5"]["status"], "PARTIAL_needs_human")


class RefundSizing(unittest.TestCase):
    CERTS = 140_364_100_000_000_000_000                # 140.3641 certificates, venue-quantised

    def expect(self, mult18):
        """Independently of the code: certs x M in shares, floored to 4 decimals, in venue units."""
        shares = Decimal(self.CERTS) / E18 * Decimal(mult18) / E18
        return int((shares * 10 ** 4).to_integral_value(rounding=ROUND_FLOOR))

    def test_shares_base(self):
        self.assertEqual(self.expect(M_SPY), 1406052)            # 140.3641 x 1.001717991... = 140.6052 shares
        self.assertEqual(self.expect(M_SPLIT), 14036410)
        for m in (M_SPY, M_SPLIT, E18, 10 ** 16):
            self.assertEqual(k.shares_base(self.CERTS, m, 4), self.expect(m), m)

    def orphan(self, mult18, stack=5, opened=None, **r):
        base = self.expect(mult18)
        opened = base if opened is None else opened
        rid = 9
        v = Venue(pos=opened + 123, entry=500.0)                  # 123 units of OTHER holders' hedge
        K = keeper(stack=stack, venue=v, mult=mult18,
                   receipts={rid: receipt(at=2_000_000_000 - 4000, certs=self.CERTS, **r)},
                   views={(ORACLE, k.SEL["sharePx18"]): lambda: words(500 * E18)})
        K.state["receipts"][str(rid)] = {"status": "FILLED_BUT_UNSETTLED_needs_human", "base": opened,
                                         "filled": opened, "fill_px18": str(500 * E18)}
        K.maybe_refund()
        return K, K.state["receipts"][str(rid)], base

    def test_orphan_close_is_certs_times_mint_mult(self):
        for m in (M_SPY, M_SPLIT):
            K, rec, base = self.orphan(m)
            self.assertEqual(sends(K), [("stageRefund", "9"), ("refundMint", "9")], m)
            self.assertEqual(len(K.venue.orders), 1)
            o = K.venue.orders[0]
            self.assertEqual((o["base"], o["side"], o["reduce_only"], o["coi"]), (base, 1, True, k.CLOSE_COI_BASE + 9))
            self.assertEqual(o["limit_px18"], 500 * E18 * 9500 // 10_000)
            self.assertEqual(K.venue.pos, 123)                    # exactly the orphan, nobody else's
            self.assertEqual((rec["close"]["status"], rec["status"]), ("closed", "refunded"))

    def test_mismatch_is_not_closed_but_still_refunded(self):
        K, rec, base = self.orphan(M_SPLIT, opened=self.expect(M_SPY))   # opened under a different M
        self.assertEqual(K.venue.orders, [])
        self.assertEqual(rec["close"]["status"], "CLOSE_MISMATCH_needs_human")
        self.assertEqual(sends(K), [("stageRefund", "9"), ("refundMint", "9")])

    def test_settled_after_all_is_not_an_orphan(self):
        K, rec, _ = self.orphan(M_SPY, settled=True)
        self.assertEqual((K.venue.orders, sends(K), rec["status"]), ([], [], "settled"))

    def test_refunded_by_holder_still_closes(self):
        K, rec, base = self.orphan(M_SPY, settled=True, staged=True)
        self.assertEqual([o["base"] for o in K.venue.orders], [base])
        self.assertEqual((sends(K), rec["status"]), ([], "refunded"))

    def test_inside_window_nothing(self):
        K = keeper(receipts={9: receipt(at=2_000_000_000 - 100, certs=self.CERTS)})
        K.state["receipts"]["9"] = {"status": "FILLED_BUT_UNSETTLED_needs_human", "base": 1, "filled": 1, "fill_px18": "1"}
        K.maybe_refund()
        self.assertEqual((K.venue.orders, sends(K)), ([], []))

    def test_stack4_leaves_orphans_to_a_human(self):
        K, rec, _ = self.orphan(M_SPY, stack=4)
        self.assertEqual((K.venue.orders, sends(K), rec["status"]), ([], [], "FILLED_BUT_UNSETTLED_needs_human"))

    def test_switch_off(self):
        K = keeper(receipts={9: receipt(at=0, certs=self.CERTS)})
        K.refund_close_orphans = False
        K.state["receipts"]["9"] = {"status": "FILLED_BUT_UNSETTLED_needs_human", "base": 1, "filled": 1, "fill_px18": "1"}
        K.maybe_refund()
        self.assertEqual((K.venue.orders, sends(K)), ([], []))


class AutoRehedge(unittest.TestCase):
    NOW = 2_000_000_000
    PX = 500 * E18

    def chain(self, **kw):
        c = dict(keeperHedging=1, pendingMintCerts=0, registry=int(REG, 16), lastRebalancedBatch=40,
                 lastOrderAt=self.NOW - 3600, lastRebalanceAt=self.NOW - 7200, rebalanceBucket18=0,
                 REBALANCE_MIN_INTERVAL=900, REBALANCE_VENUE_LAG=60, REBALANCE_DAILY_BUDGET_18=100_000 * E18,
                 MAX_REBALANCE_NOTIONAL_18=10_000 * E18, supply=1000 * E18, notional=490_000 * E18,
                 batch=41, attestedAt=self.NOW - 30, cawindow=0, px=self.PX, mult=M_SPY)
        c.update(kw)
        return c

    def keeper(self, on=True, **kw):
        c = self.chain(**kw)
        views = {(VAULT, k.SEL[n]): (lambda n=n: words(c[n])) for n in
                 ("keeperHedging", "pendingMintCerts", "registry", "lastRebalancedBatch", "lastOrderAt",
                  "lastRebalanceAt", "rebalanceBucket18", "REBALANCE_MIN_INTERVAL", "REBALANCE_VENUE_LAG",
                  "REBALANCE_DAILY_BUDGET_18", "MAX_REBALANCE_NOTIONAL_18")}
        views[(VAULT, k.SEL["solvency"])] = lambda: words(c["supply"], c["notional"], 0, 0, 9800, c["batch"], 30, 0)
        views[(REG, k.SEL_LATEST)] = lambda: words(c["notional"], 1, 1, c["batch"], c["attestedAt"])
        views[(ORACLE, k.SEL["corporateActionWindow"])] = lambda: words(c["cawindow"])
        views[(ORACLE, k.SEL["pxUnguarded"])] = lambda: words(c["px"], self.NOW - 50)
        views[(ORACLE, k.SEL["multiplier18"])] = lambda: words(c["mult"])
        K = keeper(views=views, now=self.NOW)
        K.auto_rehedge = on
        return K

    def rehedges(self, K):
        return [a for a in K.sent if a[0] == "send" and a[2] == "rehedge(uint256)"]

    def test_off_by_default_and_reads_nothing(self):
        K = self.keeper(on=False)
        self.assertEqual(K.maybe_auto_rehedge(), "off")
        self.assertEqual((K.rpc_calls, K.sent), ([], []))
        C = k.Keeper.__new__(k.Keeper)
        C._load_stack5({})
        self.assertFalse(C.auto_rehedge)
        self.assertEqual((C.rehedge_min_gap_usd, C.rehedge_min_gap_bps, C.rehedge_max_usd, C.rehedge_min_interval),
                         (250, 50, 2000, 3600))

    def test_bounded_by_max_usd_with_the_settler_key_once_per_interval(self):
        K = self.keeper()                                 # $10k (200 bps) short
        self.assertEqual(K.maybe_auto_rehedge(), "sent")
        (a,) = self.rehedges(K)
        want = k.shares_base(2000 * E18 * E18 // self.PX, M_SPY, 4)   # capped at rehedge_max_usd = $2000
        self.assertEqual(want, 40068)                      # 4 certs x 1.0017 = 4.0068 shares
        self.assertEqual(int(a[3]), want)
        self.assertEqual(a[a.index("--private-key") + 1], SET)
        self.assertEqual(K.maybe_auto_rehedge(), "spacing")
        k.time.t += 3601
        K.views[(VAULT, k.SEL["lastRebalancedBatch"])] = lambda: words(41)   # the vault used batch 41
        self.assertEqual(K.maybe_auto_rehedge(), "batch already used")
        self.assertEqual(len(self.rehedges(K)), 1)

    def test_budget_room_clamps(self):
        # Bucket at 49,500 of the 50,000 half-budget, measured now: $500 of room.
        K = self.keeper(rebalanceBucket18=49_500 * E18, lastRebalanceAt=self.NOW - 1000)
        K.rehedge_max_usd = 10_000
        self.assertEqual(K.maybe_auto_rehedge(), "sent")
        room = 50_000 * E18 - (49_500 * E18 - 1000 * 50_000 * E18 // 86400)
        self.assertEqual(int(self.rehedges(K)[0][3]), k.shares_base(room * E18 // self.PX, M_SPY, 4))

    def test_every_guard_stands_down(self):
        cases = [
            ("below threshold", dict(notional=499_900 * E18)),                     # $100, 2 bps
            ("below threshold", dict(supply=10 * E18, notional=4_800 * E18)),      # 400 bps but $200
            ("gap too large", dict(notional=350_000 * E18)),                       # 3000 bps: a split?
            ("mint pending", dict(pendingMintCerts=1)),
            ("not keeper mode", dict(keeperHedging=0)),
            ("corporate action window", dict(cawindow=1)),
            ("batch already used", dict(batch=40)),
            ("attestation predates the last order", dict(lastOrderAt=self.NOW - 60)),
            ("attestation too old", dict(attestedAt=self.NOW - 301, lastOrderAt=0)),
            ("vault interval", dict(lastRebalanceAt=self.NOW - 900)),
            ("not under-hedged", dict(notional=510_000 * E18)),
            ("budget spent", dict(rebalanceBucket18=60_000 * E18, lastRebalanceAt=self.NOW - 1000)),   # synthetic: level pinned at the ceiling
        ]
        for want, kw in cases:
            K = self.keeper(**kw)
            self.assertEqual(K.maybe_auto_rehedge(), want, kw)
            self.assertEqual(self.rehedges(K), [], kw)

    def test_waits_for_its_own_fills_and_unresolved_work(self):
        K = self.keeper()
        K.state["last_fill_at"] = self.NOW - 60            # the attestation (NOW-30) is inside the lag
        self.assertEqual(K.maybe_auto_rehedge(), "attestation predates the last order")
        K = self.keeper()
        K.state["rehedges"] = {"0xa:1": {"status": "UNFILLED_needs_human"}}
        self.assertEqual(K.maybe_auto_rehedge(), "keeper work unresolved")
        self.assertEqual(K.rpc_calls, [])
        K = self.keeper()
        K.state["receipts"]["3"] = {"status": "placed"}
        self.assertEqual(K.maybe_auto_rehedge(), "keeper work unresolved")
        self.assertEqual(self.rehedges(K), [])

    def test_revert_is_logged_and_spaced(self):
        K = self.keeper()

        def cast(*a):
            raise RuntimeError("cast send: execution reverted: CertVault_RebalanceTooSoon")
        K._cast = cast
        self.assertEqual(K.maybe_auto_rehedge(), "reverted")
        self.assertEqual(K.maybe_auto_rehedge(), "spacing")

    def test_config_refuses_spam(self):
        C = k.Keeper.__new__(k.Keeper)
        for bad in ({"rehedge_min_interval_sec": 60}, {"rehedge_min_gap_bps": 0},
                    {"rehedge_min_gap_bps": 3000}, {"rehedge_max_usd": 0}, {"close_price_band_bps": 0}):
            with self.assertRaises(SystemExit, msg=bad):
                C._load_stack5(bad)


if __name__ == "__main__":
    unittest.main(verbosity=1)

# Stack-5 signer: M-8 open interest, F6 sanity checks, H-6 mark v2, against recorded venue data.
# Run: python deploy/tests/test_signer_stack5.py   (unittest; exit code non-zero on failure)
import os
import sys
import time
import unittest
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

s = _ethstub.load("usecert-signer-mainnet.py", "signer")
keccak = s.keccak

ORACLE = "0xdb1eF0e62F0954E8dC5dd1Bcc8126FbD30978121"   # uTSLA's stack-4 CertOracle, as a verifyingContract
# Known-good vector, computed OUTSIDE this code on 2026-09-27 with foundry cast 1.8.1, two ways
# that agree: (a) cast keccak / cast abi-encode by hand; (b) `cast wallet sign --data` on the
# EIP-712 JSON (alloy's typed-data encoder) with anvil's public test key #0, which produced the
# same signature as `cast wallet sign --no-hash` over digest (a).
V2 = dict(px18=372610000000000000000, nonce=7, observedAt=1790492400, deadline=1790492460,
          domain="bab302081b0f55ae0d90e4c830fad49706dc55918c2d6b27c2833e9269b79724",
          typehash="5907bd679e47cb2a5c471c3f90c264e6a5dd77283c825aead252d31fa839607f",
          struct="d661c6983cb10807cad1452e494d8d9cf62c3be01b370e15f11338821cdb6811",
          digest="918193de83116ef40d07990bff43cdd8195598b5ebdc3f2d259471ee47dd7289")
# The stack-4 (v1) mark digest for the same figures, version "1" domain: must not change.
V1 = dict(domain="c8ca4d3862080fd1ebe49a739a6f1a0f47b07af08d1b17cec9050f9e3095fedb",
          typehash="834d2bcd17721eebe9cd9c20304fc6ae884f18a436c4fa38cac5b950e25b07e0",
          digest="0926bd80492f0c76d2b3dc6906d9616441372ddfc9896a3800f7fbff0a9a00a3")

BOOKS = _ethstub.fixture("orderBookDetails-14-16.json")
MARKETS = {int(m["market_id"]): m for m in BOOKS["order_book_details"]}
ACCT = _ethstub.fixture("account-33556.json")["accounts"][0]
E18 = 10 ** 18
V1A, V2A = "0x" + "11" * 20, "0x" + "22" * 20


def signer(env, vaults=None):
    S = s.Signer.__new__(s.Signer)
    S.cfg = s.Config(env)
    S.pk = "pk"
    S.registry = "0xREG"
    S.vaults = vaults or [{"symbol": "uTSLA", "vault": V1A, "certOracle": ORACLE, "marketIndex": 16}]
    S.reg_domain = b"\x11" * 32
    S.attest_th = b"\x22" * 32
    th = bytes.fromhex(V2["typehash"] if S.cfg.mark_v2 else V1["typehash"])
    dom = bytes.fromhex(V2["domain"] if S.cfg.mark_v2 else V1["domain"])
    S.oracle = {v["certOracle"]: (dom, th) for v in S.vaults}
    S.token, S.feed = {}, {}
    S.events = []
    S.guard = s.NotionalGuard(S.cfg.jump_factor, S.cfg.lookback, lambda v, a, b: S.events_in(v, a, b))
    S.events_in = lambda v, a, b: False
    return S


class Capture:
    """Stand-in for sign(): records the digest the real sign() would have signed."""
    def __init__(self):
        self.digests = []

    def __call__(self, pk, domain, struct_hash):
        d = keccak(b"\x19\x01" + domain + struct_hash)
        self.digests.append(d.hex())
        return "0x" + d.hex()


def chain(**kw):
    c = {"notional": 0, "oi": 5 * 10 ** 24, "batch": 12, "latest_at": 1790492300, "nonce": 7,
         "mark_at": 1790492000, "feed_px18": 372560000000000000000,
         # option A reads (MULTIPLIER_CHECKS, on under STACK=5): TSLA's recorded multiplier is 1e18
         "mult18": 10 ** 18, "ca_window": False, "token_paused": False}
    c.update(kw)
    return c


class Keccak(unittest.TestCase):
    def test_vectors(self):
        self.assertEqual(keccak(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        # selectors this code hardcodes, as `cast sig` printed them
        for sig, sel in [("markAt()", "9fce1418"), ("latestRoundData()", "feaf968c"),
                         ("markNonce()", "714e5939"), ("latest(address)", "4a4aac1a")]:
            self.assertEqual(keccak(text=sig)[:4].hex(), sel, sig)
        self.assertEqual(keccak(b"a" * 200).hex(), keccak(text="a" * 200).hex())


class MarkV2(unittest.TestCase):
    def test_digest_matches_independent_vector(self):
        dom = s.domain_separator("UseCert CertOracle", "2", 4663, ORACLE)
        self.assertEqual(dom.hex(), V2["domain"])
        self.assertEqual(keccak(text=s.SET_MARK_V2_TYPE).hex(), V2["typehash"])
        sh = s.mark_struct_hash(bytes.fromhex(V2["typehash"]), V2["px18"], V2["nonce"], V2["deadline"], V2["observedAt"])
        self.assertEqual(sh.hex(), V2["struct"])
        self.assertEqual(keccak(b"\x19\x01" + dom + sh).hex(), V2["digest"])

    def test_v1_digest_unchanged(self):
        dom = s.domain_separator("UseCert CertOracle", "1", 4663, ORACLE)
        self.assertEqual(dom.hex(), V1["domain"])
        sh = s.mark_struct_hash(bytes.fromhex(V1["typehash"]), V2["px18"], V2["nonce"], V2["deadline"])
        self.assertEqual(keccak(b"\x19\x01" + dom + sh).hex(), V1["digest"])

    def test_deadline_never_past_60s(self):
        th = bytes.fromhex(V2["typehash"])
        s.mark_struct_hash(th, 1, 1, 1000 + 60, 1000)
        with self.assertRaises(s.Refuse):
            s.mark_struct_hash(th, 1, 1, 1000 + 61, 1000)

    def test_bundle_v2(self):
        S = signer({"STACK": "5"})
        cap = Capture(); s.sign = cap
        g = {"v": S.vaults[0], "notional18": 0, "margin18": 1, "mark18": V2["px18"], "oi18": 5, "batch": 12, "nonce": 7}
        b = S.one(g, V2["observedAt"], V2["observedAt"] + 60)
        self.assertEqual(b["markSigVersion"], 2)
        self.assertEqual(b["markObservedAt"], V2["observedAt"])
        self.assertEqual(b["markDeadline"], V2["observedAt"] + 60)
        self.assertEqual(b["markSig"], "0x" + V2["digest"])

    def test_bundle_v1_default(self):
        S = signer({})
        cap = Capture(); s.sign = cap
        g = {"v": S.vaults[0], "notional18": 0, "margin18": 1, "mark18": V2["px18"], "oi18": 5, "batch": 12, "nonce": 7}
        b = S.one(g, V2["deadline"] - 60, V2["deadline"])
        self.assertNotIn("markSigVersion", b)
        self.assertEqual(b["markSig"], "0x" + V1["digest"])


class OpenInterest(unittest.TestCase):
    def test_units_from_recorded_api(self):
        msft = MARKETS[14]
        self.assertEqual(msft["open_interest"], 1821.2818)        # base units, a JSON number
        got = s.open_interest18(msft, Decimal(msft["mark_price"]))
        # 1821.2818 shares x $518.36, exactly, in 1e18: (18212818 / 1e4) * (51836 / 1e2) * 1e18
        self.assertEqual(got, 18212818 * 51836 * 10 ** 12)
        self.assertTrue(900_000 * E18 < got < 1_000_000 * E18)   # the pre-audit's "about $0.9M"

    def test_refuses_missing_or_non_positive(self):
        for bad in [None, 0, "0", -1, "-3.5", "abc", True, float("nan"), "Infinity"]:
            m = dict(MARKETS[16])
            if bad is None:
                del m["open_interest"]
            else:
                m["open_interest"] = bad
            with self.assertRaises(s.Refuse, msg=repr(bad)):
                s.open_interest18(m, Decimal("372.61"))

    def test_compute_uses_venue_oi_in_stack5_and_registry_in_stack4(self):
        S5, S4 = signer({"STACK": "5"}), signer({})
        want = int(Decimal("4285.2419") * Decimal("372.61") * E18)
        g5 = S5.compute(S5.vaults[0], ACCT, MARKETS, chain(), 1790492400, 100)
        g4 = S4.compute(S4.vaults[0], ACCT, MARKETS, chain(), 1790492400, 100)
        self.assertEqual(g5["oi18"], want)
        self.assertEqual(g4["oi18"], 5 * 10 ** 24)                 # carried, exactly as before
        self.assertEqual(g5["margin18"], 2056581 * 10 ** 12)
        self.assertEqual(g5["notional18"], 0)

    def test_compute_refuses_when_field_missing(self):
        S = signer({"STACK": "5"})
        m = {16: {k: v for k, v in MARKETS[16].items() if k != "open_interest"}}
        with self.assertRaises(s.Refuse):
            S.compute(S.vaults[0], ACCT, m, chain(), 1790492400, 100)


class FeedDeviation(unittest.TestCase):
    def test_band(self):
        f = 100 * E18
        s.check_mark_vs_feed(105 * E18, f, 500)
        s.check_mark_vs_feed(95 * E18, f, 500)
        with self.assertRaises(s.Refuse):
            s.check_mark_vs_feed(105 * E18 + 1, f, 500)
        with self.assertRaises(s.Refuse):
            s.check_mark_vs_feed(95 * E18 - 1, f, 500)
        with self.assertRaises(s.Refuse):
            s.check_mark_vs_feed(f, 0, 500)

    def test_compute_against_recorded_mark(self):
        S = signer({"STACK": "5"})
        S.compute(S.vaults[0], ACCT, MARKETS, chain(feed_px18=372560000000000000000), 1790492400, 100)   # 1.3 bps
        with self.assertRaises(s.Refuse):
            S.compute(S.vaults[0], ACCT, MARKETS, chain(feed_px18=350 * E18), 1790492400, 100)          # 646 bps
        S2 = signer({"STACK": "5", "MARK_MAX_DEVIATION_BPS": "700"})
        S2.compute(S2.vaults[0], ACCT, MARKETS, chain(feed_px18=350 * E18), 1790492400, 100)

    def test_off_in_stack4(self):
        S = signer({})
        S.compute(S.vaults[0], ACCT, MARKETS, chain(feed_px18=1), 1790492400, 100)


class NotionalJump(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.event = False
        self.g = s.NotionalGuard(Decimal("1.5"), 1000, self._ev)

    def _ev(self, vault, frm, to):
        self.calls.append((vault, frm, to))
        return self.event

    def test_small_move_passes_without_query(self):
        self.g.check("V", 140, 5000, seed=100)
        self.g.check("V", 67, 5000, seed=100)
        self.assertEqual(self.calls, [])

    def test_jump_refused_without_order_event(self):
        self.g.check("V", 100, 5000, seed=100)
        self.g.accept("V", 100, 5000)
        with self.assertRaises(s.Refuse):
            self.g.check("V", 151, 5100, seed=0)
        self.assertEqual(self.calls, [("V", 4000, 5100)])         # [baseline block - lookback, now]
        self.assertEqual(self.g.base["V"], (100, 5000))           # a refusal never moves the baseline
        with self.assertRaises(s.Refuse):
            self.g.check("V", 66, 5100, seed=0)                    # down counts too

    def test_jump_accepted_with_order_event(self):
        self.g.accept("V", 100, 5000)
        self.event = True
        self.g.check("V", 1000, 5100, seed=0)

    def test_from_and_to_zero(self):
        self.g.accept("V", 0, 5000)
        with self.assertRaises(s.Refuse):
            self.g.check("V", 1, 5001, seed=0)
        self.g.accept("W", 10 ** 20, 5000)
        with self.assertRaises(s.Refuse):
            self.g.check("W", 0, 5001, seed=0)

    def test_cold_start_seeds_from_registry(self):
        with self.assertRaises(s.Refuse):
            self.g.check("V", 10 ** 21, 7000, seed=10 ** 20)
        self.assertEqual(self.calls, [("V", 6000, 7000)])

    def test_disabled(self):
        g = s.NotionalGuard(Decimal(0), 1000, self._ev)
        g.check("V", 10 ** 30, 1, seed=0)

    def test_wired_into_compute(self):
        acct = dict(ACCT, positions=[dict(ACCT["positions"][0], position="10.0000")])
        S = signer({"STACK": "5"})
        with self.assertRaises(s.Refuse):                          # registry says 0, venue says 10 shares
            S.compute(S.vaults[0], acct, MARKETS, chain(notional=0), 1790492400, 100)
        S.events_in = lambda v, a, b: True                         # ...unless an order explains it
        g = S.compute(S.vaults[0], acct, MARKETS, chain(notional=0), 1790492400, 100)
        self.assertEqual(g["notional18"], 3726100 * 10 ** 15)
        S4 = signer({})
        S4.compute(S4.vaults[0], acct, MARKETS, chain(notional=0), 1790492400, 100)


class ObservedAtRules(unittest.TestCase):
    def test_strict_registry_and_mark_at(self):
        S = signer({"STACK": "5"})
        with self.assertRaises(s.Refuse):
            S.compute(S.vaults[0], ACCT, MARKETS, chain(latest_at=1790492400), 1790492400, 100)
        with self.assertRaises(s.Refuse):
            S.compute(S.vaults[0], ACCT, MARKETS, chain(mark_at=1790492401), 1790492400, 100)
        S.compute(S.vaults[0], ACCT, MARKETS, chain(latest_at=1790492399, mark_at=1790492400), 1790492400, 100)

    def test_stack4_does_not_enforce(self):
        S = signer({})
        S.compute(S.vaults[0], ACCT, MARKETS, chain(latest_at=1790492400, mark_at=2 ** 60), 1790492400, 100)


class Refresh(unittest.TestCase):
    """One whole v2 cycle on stubs: the clock is read before the market data, a vault that
    fails a check is left out and listed, the other is signed."""

    def test_cycle(self):
        vaults = [{"symbol": "uTSLA", "vault": V1A, "certOracle": ORACLE, "marketIndex": 16},
                  {"symbol": "uMSFT", "vault": V2A, "certOracle": "0x" + "ab" * 20, "marketIndex": 14}]
        S = signer({"STACK": "5"}, vaults)
        order = []
        S.chain_reads = lambda: {V1A: chain(), V2A: chain(feed_px18=400 * E18)}   # MSFT 518 vs 400: refuse
        S.read_account = lambda v: (order.append("account"), ACCT)[1]
        S.head = lambda: (order.append("clock"), (777, 1790492400))[1]

        def get(path):
            order.append("books")
            return BOOKS
        s.get = get
        s.sign = Capture()
        S.refresh()
        c = s.cache
        self.assertEqual(order, ["account", "account", "clock", "books"])
        self.assertEqual([a["symbol"] for a in c["attestations"]], ["uTSLA"])
        self.assertEqual([r["symbol"] for r in c["refused"]], ["uMSFT"])
        a = c["attestations"][0]
        self.assertEqual(a["observedAt"], min(1790492400, int(time.time())))
        self.assertEqual(a["markDeadline"] - a["markObservedAt"], 60)
        self.assertEqual(a["deadline"] - a["observedAt"], 60)
        self.assertEqual(S.guard.base[V1A], (0, 777))


class ConfigDefaults(unittest.TestCase):
    def test_defaults(self):
        c4, c5 = s.Config({}), s.Config({"STACK": "5"})
        self.assertEqual((c4.mark_sig_version, c4.oi_source, c4.sanity, c4.strict_observed_at), (1, "registry", False, False))
        self.assertEqual((c5.mark_sig_version, c5.oi_source, c5.sanity, c5.strict_observed_at), (2, "venue", True, True))
        self.assertEqual(c5.max_dev_bps, 500)
        c = s.Config({"STACK": "5", "MARK_SIG_VERSION": "1", "OI_SOURCE": "registry", "SANITY_CHECKS": "0"})
        self.assertEqual((c.mark_sig_version, c.oi_source, c.sanity), (1, "registry", False))
        for bad in [{"MARK_SIG_VERSION": "3"}, {"OI_SOURCE": "x"}, {"NOTIONAL_JUMP_FACTOR": "1"}]:
            with self.assertRaises(ValueError):
                s.Config(bad)


if __name__ == "__main__":
    unittest.main(verbosity=1)

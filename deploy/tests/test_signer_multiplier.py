# Stack-5 signer, option A: the mark-vs-feed check scales the SHARE mark by multiplier18, and a
# corporate action window or a paused stock token refuses the vault. Recorded venue data
# (fixtures/orderBookDetails-14-16.json, account-33556.json) and recorded token multipliers
# (fixtures/uimultiplier-4663.json); everything else synthetic.
# Run: python deploy/tests/test_signer_multiplier.py   (unittest)
import os
import sys
import unittest
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

import test_signer_stack5 as base  # noqa: E402  (its signer()/chain() helpers and module)

s = base.s

E18 = 10 ** 18
M_SPY = int(_ethstub.fixture("uimultiplier-4663.json")["tokens"]["SPY"]["uiMultiplier"])
M_SPLIT = 10 * E18
BOOKS = _ethstub.fixture("orderBookDetails-14-16.json")
MARKETS = {int(m["market_id"]): m for m in BOOKS["order_book_details"]}
ACCT = _ethstub.fixture("account-33556.json")["accounts"][0]
MARK = Decimal(str(MARKETS[16]["mark_price"]))            # 372.61, a recorded SHARE mark
MARK18 = int(MARK * E18)
ORACLE = base.ORACLE
TOKEN = _ethstub.fixture("uimultiplier-4663.json")["tokens"]["SPY"]["address"]


def signer(env, vaults=None):
    return base.signer(env, vaults)


def chain(**kw):
    return base.chain(**kw)


def split_markets(factor):
    """The recorded TSLA market after the venue rescales it for a `factor`:1 split."""
    m = dict(MARKETS[16])
    m["mark_price"] = str(MARK / factor)
    return {16: m}


class MarkTimesMultiplier(unittest.TestCase):
    def test_pure_check(self):
        feed = MARK18 * M_SPY // E18                                     # the token trades at mark x M
        s.check_mark_vs_feed(MARK18, feed, 500, M_SPY)
        s.check_mark_vs_feed(MARK18 // 10, MARK18, 500, M_SPLIT)       # 10:1 split, mark rescaled
        with self.assertRaises(s.Refuse):
            s.check_mark_vs_feed(MARK18 // 10, MARK18, 500)             # unscaled, the split refused every mark
        # The gap is measured against the feed, so the SHARE mark is set from it: mark = feed x r / M.
        feed = MARK18
        mark_at = lambda num, den, m: (feed * num // den) * E18 // m
        for m in (M_SPY, M_SPLIT):
            s.check_mark_vs_feed(mark_at(105, 100, m), feed, 500, m)    # 5.00% passes (the band is inclusive)
            s.check_mark_vs_feed(mark_at(95, 100, m) + 1, feed, 500, m)
            with self.assertRaises(s.Refuse, msg=m):
                s.check_mark_vs_feed(mark_at(1052, 1000, m) + 1, feed, 500, m)   # a genuine 5.2% gap, above
            with self.assertRaises(s.Refuse, msg=m):
                s.check_mark_vs_feed(mark_at(948, 1000, m), feed, 500, m)        # and below
        # Stack 4 (no multiplier) is the old check, unchanged.
        s.check_mark_vs_feed(105 * E18, 100 * E18, 500)
        with self.assertRaises(s.Refuse):
            s.check_mark_vs_feed(105 * E18 + 1, 100 * E18, 500)

    def test_compute_at_spy_multiplier(self):
        S = signer({"STACK": "5"})
        feed = MARK18 * M_SPY // E18
        S.compute(S.vaults[0], ACCT, MARKETS, chain(feed_px18=feed, mult18=M_SPY), 1790492400, 100)
        with self.assertRaises(s.Refuse) as e:
            S.compute(S.vaults[0], ACCT, MARKETS, chain(feed_px18=feed * 1000 // 1052, mult18=M_SPY), 1790492400, 100)   # mark x M 5.2% above
        self.assertIn("multiplier %d" % M_SPY, str(e.exception))

    def test_compute_after_a_10x_split(self):
        S = signer({"STACK": "5"})
        feed = MARK18                                      # the token's price does not move on a split
        S.compute(S.vaults[0], ACCT, split_markets(10), chain(feed_px18=feed, mult18=M_SPLIT), 1790492400, 100)
        with self.assertRaises(s.Refuse):                  # genuine 5.2% gap, after the split
            S.compute(S.vaults[0], ACCT, split_markets(10), chain(feed_px18=feed * 1000 // 1052, mult18=M_SPLIT), 1790492400, 100)
        # With the multiplier checks off (stack-4 behaviour) the rescaled mark is refused outright.
        S4 = signer({"STACK": "5", "MULTIPLIER_CHECKS": "0"})
        with self.assertRaises(s.Refuse):
            S4.compute(S4.vaults[0], ACCT, split_markets(10), chain(feed_px18=feed), 1790492400, 100)

    def test_notional_is_shares_times_share_mark(self):
        # Option A attests venue base x share mark; the multiplier never enters the notional.
        acct = dict(ACCT, positions=[dict(ACCT["positions"][0], position="10.0000")])
        S = signer({"STACK": "5", "NOTIONAL_JUMP_FACTOR": "0"})
        g = S.compute(S.vaults[0], acct, MARKETS, chain(feed_px18=MARK18 * M_SPY // E18, mult18=M_SPY), 1790492400, 100)
        self.assertEqual(g["notional18"], 3726100 * 10 ** 15)
        self.assertEqual(g["mark18"], MARK18)              # the signed mark is still the share mark


class CorporateAction(unittest.TestCase):
    def test_refusals(self):
        S = signer({"STACK": "5"})
        for kw, why in [({"ca_window": True}, "corporate action window"),
                        ({"token_paused": True}, "oraclePaused"),
                        ({"ca_window": None}, "unreadable"),
                        ({"token_paused": None}, "unreadable"),
                        ({"mult18": None}, "unreadable")]:
            with self.assertRaises(s.Refuse, msg=kw) as e:
                S.compute(S.vaults[0], ACCT, MARKETS, chain(**kw), 1790492400, 100)
            self.assertIn(why, str(e.exception), kw)

    def test_refused_even_with_sanity_off(self):
        S = signer({"STACK": "5", "SANITY_CHECKS": "0"})
        with self.assertRaises(s.Refuse):
            S.compute(S.vaults[0], ACCT, MARKETS, chain(ca_window=True), 1790492400, 100)

    def test_stack4_not_enforced(self):
        S = signer({})
        S.compute(S.vaults[0], ACCT, MARKETS, chain(ca_window=True, token_paused=True, mult18=None), 1790492400, 100)

    def test_cycle_leaves_the_vault_out_and_signs_the_other(self):
        vaults = [{"symbol": "uTSLA", "vault": base.V1A, "certOracle": ORACLE, "marketIndex": 16},
                  {"symbol": "uSPY", "vault": base.V2A, "certOracle": "0x" + "ab" * 20, "marketIndex": 16}]
        S = signer({"STACK": "5"}, vaults)
        S.chain_reads = lambda: {base.V1A: chain(), base.V2A: chain(ca_window=True)}
        S.read_account = lambda v: ACCT
        S.head = lambda: (777, 1790492400)
        s.get = lambda path: BOOKS
        s.sign = base.Capture()
        S.refresh()
        self.assertEqual([a["symbol"] for a in s.cache["attestations"]], ["uTSLA"])
        self.assertEqual(s.cache["refused"][0]["symbol"], "uSPY")
        self.assertIn("corporate action window", s.cache["refused"][0]["reason"])


class Multicall(unittest.TestCase):
    """The per-vault multicall entries and their parsing (the aggregate3 envelope itself is
    dynamic ABI, which the test stub does not encode; the host's eth_abi does)."""

    def setup(self, env, token=TOKEN):
        S = signer(env)
        o = S.vaults[0]["certOracle"]
        S.feed = {o: ("0x" + "fe" * 20, 8)}
        S.token = {o: token}
        return S, o

    def results(self, mult=M_SPY, ca=0, paused=0, fail=()):
        w = lambda *x: _ethstub.encode(["uint256"] * len(x), list(x))
        r = [(True, w(5 * E18, 1, 7, 41, 1790492300)),           # registry.latest
             (True, w(6)),                                       # markNonce
             (True, w(1790492000)),                              # markAt
             (True, _ethstub.encode(["uint80", "int256", "uint256", "uint256", "uint80"],
                                    [1, 37256000000, 0, 1790492100, 1])),   # feed, 8 decimals
             (True, w(mult)), (True, w(ca)), (True, w(paused))]
        return [(False, b"") if i in fail else x for i, x in enumerate(r)]

    def test_calls_and_flags(self):
        S, o = self.setup({"STACK": "5"})
        c = S.vault_calls(S.vaults[0])
        self.assertEqual([(t.lower(), f, d[:4]) for t, f, d in c][4:],
                         [(o.lower(), True, s.SEL_MULT), (o.lower(), True, s.SEL_CA_WINDOW),
                          (TOKEN.lower(), True, s.SEL_ORACLE_PAUSED)])
        self.assertTrue(all(f is False for _, f, _ in c[:4]))
        S4, _ = self.setup({})
        self.assertEqual(len(S4.vault_calls(S4.vaults[0])), 2)   # stack 4: latest + markNonce, as before
        S0, _ = self.setup({"STACK": "5"}, token="0x" + "00" * 20)
        self.assertEqual(len(S0.vault_calls(S0.vaults[0])), 6)   # no token: nothing to ask oraclePaused

    def test_parse(self):
        S, _ = self.setup({"STACK": "5"})
        ch = S.parse_vault(S.vaults[0], self.results())
        self.assertEqual((ch["mult18"], ch["ca_window"], ch["token_paused"]), (M_SPY, False, False))
        self.assertEqual((ch["feed_px18"], ch["batch"], ch["nonce"]), (37256 * 10 ** 16, 42, 7))
        ch = S.parse_vault(S.vaults[0], self.results(ca=1, paused=1))
        self.assertEqual((ch["ca_window"], ch["token_paused"]), (True, True))
        ch = S.parse_vault(S.vaults[0], self.results(fail=(4, 5, 6)))
        self.assertEqual((ch["mult18"], ch["ca_window"], ch["token_paused"]), (None, None, None))
        with self.assertRaises(RuntimeError):                    # a required read still fails the cycle
            S.parse_vault(S.vaults[0], self.results(fail=(1,)))
        S0, _ = self.setup({"STACK": "5"}, token="0x" + "00" * 20)
        ch = S0.parse_vault(S0.vaults[0], self.results()[:6])
        self.assertEqual(ch["token_paused"], False)

    def test_selectors(self):
        for sig, sel in [("multiplier18()", s.SEL_MULT), ("corporateActionWindow()", s.SEL_CA_WINDOW),
                         ("oraclePaused()", s.SEL_ORACLE_PAUSED)]:
            self.assertEqual(_ethstub.keccak(text=sig)[:4], sel, sig)

    def test_config(self):
        self.assertEqual((s.Config({}).mult_checks, s.Config({"STACK": "5"}).mult_checks), (False, True))
        self.assertFalse(s.Config({"STACK": "5", "MULTIPLIER_CHECKS": "0"}).mult_checks)


if __name__ == "__main__":
    unittest.main(verbosity=1)

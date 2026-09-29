# Sermium M-03: the remote settler refuses to settle a mint the venue position does not cover,
# and checks every request's shape before anything is queued. Stubbed chain and venue.
# Run: python deploy/tests/test_settler_remote.py   (unittest)
import io
import json
import os
import sys
import tempfile
import time
import unittest
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

s = _ethstub.load("usecert-settler-remote", "settler_remote")

VAULT = "0x" + "b5" * 20
CERT, ORACLE = "0x" + "ce" * 20, "0x" + "0c" * 20
E18 = 10 ** 18
PX = 369 * E18                         # request price, token units
MULT = E18                             # 1 share per token
SIZE_DEC = 4


class World:
    def __init__(self):
        self.supply = 0
        self.indicative = 5 * 10 ** 16     # 0.05 certificates
        self.settled = self.staged = 0
        self.requested_at = int(time.time()) - 60
        self.position = 500                 # venue units: 0.05 shares at 4 decimals
        self.window = 86400

    def words(self, to, data):
        sel = data[:10]
        if to == VAULT and sel == s.SEL["cfg"]:
            return [0, 3, 0, 16, SIZE_DEC, 10, 10, 1000 * E18, 500, 9000]
        if to == VAULT and sel == s.SEL["certificate"]:
            return [int(CERT, 16)]
        if to == VAULT and sel == s.SEL["oracle"]:
            return [int(ORACLE, 16)]
        if to == CERT and sel == s.SEL["totalSupply"]:
            return [self.supply]
        if to == ORACLE and sel == s.SEL["multiplier18"]:
            return [MULT]
        if to == VAULT and sel == s.SEL["mintReceipts"]:
            return [0xaa, 18 * 10 ** 6, self.settled, PX, self.requested_at, self.staged, self.indicative]
        if to == VAULT and sel == s.SEL["settleWindow"]:
            return [self.window]
        if to == VAULT and sel == "0x2f2f761d":                  # pendingMintCerts()
            return [getattr(self, "pending", 0)]
        if to == VAULT and sel == "0x2d151dbb":                  # sweepableFees()
            return [getattr(self, "fees", 0)]
        if to == VAULT and sel == "0x3131fd71":                  # lastAccrualAt()
            return [getattr(self, "last_accrual", 0)]
        raise AssertionError((to, data))


class Checks(unittest.TestCase):
    def setUp(self):
        self.w = World()
        s.words = self.w.words
        s.venue_position_units = lambda vault, market, dec: self.w.position
        self.ledger = {"sends": [], "settled_usd": []}

    def settle(self, fill=PX, rid=1):
        return s.check({"vault": VAULT, "sig": "settleMint(uint256,uint256)", "args": [str(rid), str(fill)]}, self.ledger)

    def test_covered_hedge_settles(self):
        self.assertIsNone(self.settle())

    def test_missing_hedge_is_refused(self):
        self.w.position = 0                                       # the M-03 PoC: no order reached the venue
        self.assertIn("hedge first", self.settle())

    def test_existing_supply_counts(self):
        self.w.supply = 5 * 10 ** 16                              # 0.05 already minted and hedged ...
        self.assertIn("hedge first", self.settle())               # ... so 500 units cover only that
        self.w.position = 1000
        self.assertIsNone(self.settle())

    def test_tolerance_is_a_few_units_only(self):
        self.w.position = 500 - s.POSITION_TOL_UNITS
        self.assertIsNone(self.settle())
        self.w.position = 500 - s.POSITION_TOL_UNITS - 1
        self.assertIsNotNone(self.settle())

    def test_fill_outside_the_band(self):
        self.assertIn("settle band", self.settle(fill=PX * 106 // 100))
        self.assertIsNone(self.settle(fill=PX * 104 // 100))

    def test_receipt_states(self):
        self.w.settled = 1
        self.assertIn("settled", self.settle())
        self.w.settled, self.w.staged = 0, 1
        self.assertIn("staged", self.settle())
        self.w.staged, self.w.requested_at = 0, int(time.time()) - 90000
        self.assertIn("settle window", self.settle())

    def test_daily_budget(self):
        self.ledger["settled_usd"] = [[time.time() - 60, str(s.DAILY_SETTLE_USD - 1)]]
        self.assertIn("daily settle budget", self.settle())
        self.ledger["settled_usd"] = [[time.time() - 90000, str(s.DAILY_SETTLE_USD - 1)]]
        self.assertIsNone(self.settle())                          # yesterday's does not count

    def test_rate_limit(self):
        self.ledger["sends"] = [time.time()] * s.MAX_SENDS_PER_HOUR
        self.assertIn("rate limit", self.settle())

    def test_rehedge_only_for_a_real_gap(self):
        self.w.supply, self.w.position = 10 ** 17, 500            # needs 1000 units, holds 500
        rh = lambda b: s.check({"vault": VAULT, "sig": "rehedge(uint256)", "args": [str(b)]}, self.ledger)
        self.assertIsNone(rh(500))
        self.assertIn("short by only", rh(900))

    def test_permissionless_calls_skip_the_venue(self):
        s.venue_position_units = lambda *a: (_ for _ in ()).throw(AssertionError("venue read"))
        self.assertIsNone(s.check({"vault": VAULT, "sig": "stageRefund(uint256)", "args": ["3"]}, self.ledger))


s.RELAY_PATH = os.path.join(_ethstub.BIN, "usecert-funding-relay")
R = s.relay_mod()
PUBLIC = _ethstub.fixture("fundings-16.json")
PF = _ethstub.fixture("positionFunding-synthetic.json")
WANT = -59602 * 10 ** 12          # 10 TSLA long, four hours, longs paying (as in test_funding_relay)


def records():
    return [{k: r[k] for k in s.EVIDENCE_KEYS if k in r} for r in json.loads(json.dumps(PF["position_fundings"]))]


class Accrue(unittest.TestCase):
    """The remote attester sends accrueFunding only for records it could check itself."""

    def setUp(self):
        self.w = World()
        s.words = self.w.words
        self.w.position = 100_000                                 # 10.0000 shares at 4 decimals, public
        s.venue_position_units = lambda vault, market, dec: self.w.position
        s.public_fundings = lambda market, lo, hi: R.public_index(PUBLIC["fundings"])
        self.ledger = {"sends": [], "settled_usd": [], "vaults": {}}
        self.now = max(R.norm_ts(r["timestamp"]) for r in PF["position_fundings"]) + 600

    def ask(self, delta=WANT, ev=None):
        return {"vault": VAULT, "sig": s.ACCRUE, "args": [str(delta)], "evidence": records() if ev is None else ev}

    def check(self, req):
        return s.check_accrue(req, self.ledger, now=self.now)

    def test_checked_records_pass(self):
        self.assertIsNone(self.check(self.ask()))

    def test_a_delta_the_records_do_not_sum_to(self):
        self.assertIn("sum to", self.check(self.ask(delta=WANT * 2)))

    def test_a_record_the_public_funding_contradicts(self):
        ev = records()
        ev[0]["change"] = str(Decimal(ev[0]["change"]) * 3)
        self.assertIn("public funding", self.check(self.ask(ev=ev)))

    def test_an_inflated_position_is_capped_by_what_is_visible(self):
        ev = records()                                            # France claims 10x the position ...
        for r in ev:
            r["position_size"] = str(Decimal(r["position_size"]) * 10)
            r["change"] = str(Decimal(r["change"]) * 10)          # ... with changes to match
        self.assertIn("is visible", self.check(self.ask(delta=WANT * 10, ev=ev)))
        self.w.supply = 100 * E18                                 # unless the certificates need it
        self.assertIsNone(self.check(self.ask(delta=WANT * 10, ev=ev)))

    def test_no_record_is_relayed_twice(self):
        req = self.ask()
        self.assertIsNone(self.check(req))
        s.accrue_booked(req, self.ledger, now=self.now)
        self.assertIn("already relayed", self.check(self.ask()))

    def test_caps(self):
        s.MAX_ACCRUE_USD, old = Decimal("0.01"), s.MAX_ACCRUE_USD
        try:
            self.assertIn("per-request cap", self.check(self.ask()))
        finally:
            s.MAX_ACCRUE_USD = old
        self.ledger["vaults"][VAULT] = {"day": [[self.now - 60, str(s.DAILY_ACCRUE_USD)]]}
        self.assertIn("daily cap", self.check(self.ask()))

    def test_heartbeat_only_when_fees_wait_and_accrual_is_old(self):
        hb = {"vault": VAULT, "sig": s.ACCRUE, "args": ["0"], "evidence": []}
        self.assertIn("no fees", self.check(hb))
        self.w.fees, self.w.last_accrual = 5, int(self.now) - 3600
        self.assertIn("only", self.check(hb))
        self.w.last_accrual = int(self.now) - 2 * 86400
        self.assertIsNone(self.check(hb))

    def test_negative_int256_is_twos_complement(self):
        self.assertEqual(s.w32(-1), "f" * 64)
        self.assertEqual(int(s.w32(WANT), 16) - (1 << 256), WANT)


class Intake(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        s.INBOX, s.OUTBOX = os.path.join(self.dir, "in"), os.path.join(self.dir, "out")
        os.makedirs(s.INBOX), os.makedirs(s.OUTBOX)
        s.vaults = lambda: {VAULT: {"vault": VAULT, "symbol": "uTSLA"}}
        s.ANSWER_WAIT_SEC = 0

    def run_intake(self, req):
        raw = req if isinstance(req, bytes) else json.dumps(req).encode()
        sys.stdin, out = io.TextIOWrapper(io.BytesIO(raw)), io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            code = s.intake()
        finally:
            sys.stdout, sys.stdin = old, sys.__stdin__
        return code, json.loads(out.getvalue().strip().splitlines()[-1])

    def queued(self):
        return [n for n in os.listdir(s.INBOX) if n.endswith(".json")]

    def test_refuses_what_is_not_allowed(self):
        bad = [b"not json", b"x" * 5000,
               {"vault": "0x" + "11" * 20, "sig": "settleMint(uint256,uint256)", "args": ["1", "2"]},
               {"vault": VAULT, "sig": "transfer(address,uint256)", "args": ["1", "2"]},
               {"vault": VAULT, "sig": "settleMint(uint256,uint256)", "args": ["1"]},
               {"vault": VAULT, "sig": "settleMint(uint256,uint256)", "args": ["1", "-2"]},
               {"vault": VAULT, "sig": "settleMint(uint256,uint256)", "args": ["1", "0x10"]}]
        for req in bad:
            code, ans = self.run_intake(req)
            self.assertEqual((code, ans["status"]), (1, 0), req)
        self.assertEqual(self.queued(), [])

    def test_queues_a_well_formed_request(self):
        code, ans = self.run_intake({"vault": VAULT, "sig": "settleMint(uint256,uint256)", "args": ["1", str(PX)]})
        self.assertEqual(ans["status"], 0)                        # nobody served it in time
        self.assertIn("no answer", ans["reason"])
        q = self.queued()
        self.assertEqual(len(q), 1)
        with open(os.path.join(s.INBOX, q[0])) as f:
            self.assertEqual(json.load(f)["args"], ["1", str(PX)])


class IntakeAccrue(Intake):
    def setUp(self):
        super().setUp()
        s.ATT_INBOX = os.path.join(self.dir, "att")
        os.makedirs(s.ATT_INBOX)

    def test_accrue_shape(self):
        ok = {"vault": VAULT, "sig": s.ACCRUE, "args": [str(WANT)], "evidence": records()}
        bad = [dict(ok, evidence=[]),                                        # a delta with no records
               dict(ok, args=["0"]),                                         # a heartbeat with records
               dict(ok, evidence=[dict(records()[0], extra="x")]),           # a field Montreal does not read
               dict(ok, evidence="records"),
               dict(ok, args=["-0x10"])]
        for req in bad:
            self.assertEqual(self.run_intake(req)[1]["status"], 0, req)
        self.assertEqual(os.listdir(s.ATT_INBOX), [])
        self.run_intake(ok)                                                  # a signed delta is allowed
        self.assertEqual(len(os.listdir(s.ATT_INBOX)), 1)
        self.assertEqual(self.queued(), [])                                  # never in the settler's queue


if __name__ == "__main__":
    unittest.main(verbosity=1)

# H-8 funding relay: delta computation against recorded public funding, refusal on any doubt,
# idempotency across runs and across a crash mid-send. Stubbed venue, chain and cast.
# Run: python deploy/tests/test_funding_relay.py   (unittest)
import copy
import io
import json
import os
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

fr = _ethstub.load("usecert-funding-relay", "funding_relay")

PUBLIC = _ethstub.fixture("fundings-16.json")
PF = _ethstub.fixture("positionFunding-synthetic.json")
ACCT = _ethstub.fixture("account-33556.json")
VAULT = ACCT["accounts"][0]["l1_address"]
PK = "0x" + "a7" * 32
ATTESTER = "0x" + "021e" * 10
# 10 TSLA long, four hours, longs paying: -(0.014901 + 0.014900 + 0.014900 + 0.014901) USD
WANT = -59602 * 10 ** 12


def recs():
    return copy.deepcopy(PF["position_fundings"])


class Delta(unittest.TestCase):
    def setUp(self):
        self.pub = fr.public_index(PUBLIC["fundings"])

    def test_recorded_public_units(self):
        v, payer, rate = self.pub[1790492400]
        self.assertEqual((str(v), payer, str(rate)), ("0.00149012", "long", "0.0004"))

    def test_long_pays(self):
        self.assertEqual(fr.compute_delta(recs(), self.pub), (WANT, "account"))

    def test_convention_is_inferred_not_trusted(self):
        r = recs()
        for x in r:
            x["change"] = x["change"].lstrip("-")                 # venue reports amount PAID, positive
        self.assertEqual(fr.compute_delta(r, self.pub), (WANT, "paid"))

    def test_short_receives(self):
        r = recs()
        for x in r:
            x["position_side"] = "short"
            x["change"] = x["change"].lstrip("-")
        self.assertEqual(fr.compute_delta(r, self.pub), (-WANT, "account"))

    def test_mixed_convention_refused(self):
        r = recs()
        r[0]["change"] = r[0]["change"].lstrip("-")
        with self.assertRaises(fr.Refuse):
            fr.compute_delta(r, self.pub)

    def test_explicit_convention_must_match(self):
        with self.assertRaises(fr.Refuse):
            fr.compute_delta(recs(), self.pub, sign_mode="paid")
        self.assertEqual(fr.compute_delta(recs(), self.pub, sign_mode="account")[0], WANT)

    def test_magnitude_crosscheck(self):
        r = recs()
        r[1]["change"] = "-0.020000"                              # 10 x 0.00148996 is 0.0149
        with self.assertRaises(fr.Refuse):
            fr.compute_delta(r, self.pub)

    def test_missing_public_hour_refused(self):
        r = recs()
        r[0]["timestamp"] = 1790492400 + 3600
        with self.assertRaises(fr.Refuse):
            fr.compute_delta(r, self.pub)

    def test_negative_rate_refused(self):
        pub = fr.public_index([dict(f, rate="-0.0004") for f in PUBLIC["fundings"]])
        with self.assertRaises(fr.Refuse):
            fr.compute_delta(recs(), pub)

    def test_bad_shape_refused(self):
        for mutate in [lambda x: x.pop("change"), lambda x: x.update(change="abc"),
                       lambda x: x.update(position_side="both"), lambda x: x.update(change="NaN")]:
            r = recs()
            mutate(r[0])
            with self.assertRaises(fr.Refuse):
                fr.compute_delta(r, self.pub)

    def test_ms_and_us_timestamps(self):
        self.assertEqual(fr.norm_ts(1790492400), 1790492400)
        self.assertEqual(fr.norm_ts(1790492400123), 1790492400)
        self.assertEqual(fr.norm_ts(1790494524934322), 1790494524)   # account transaction_time (us)


class World:
    """A venue that answers positionFunding from a list, a chain with a BufferBook ledger, and a
    cast that applies accrueFunding to that ledger (or fails on request)."""

    def __init__(self):
        self.records = recs()
        self.ledger = 0
        self.sends = []
        self.fail_send = None           # None | "revert" | "crash_after_landing" | "crash_before"
        self.account_index = 33556
        self.auth_seen = []
        self.gets = []
        self.sweepable = 0
        self.last_accrual = 0

    def get(self, vc, path, auth=None):
        self.gets.append(path)
        if path.startswith("/api/v1/account?"):
            return ACCT
        if path.startswith("/api/v1/positionFunding?"):
            self.auth_seen.append(auth)
            return {"code": 200, "position_fundings": sorted(copy.deepcopy(self.records),
                                                              key=lambda r: -r["timestamp"]), "next_cursor": ""}
        if path.startswith("/api/v1/fundings?"):
            extra = [{"timestamp": 1790496000, "value": "0.00149100", "rate": "0.0004", "direction": "long"}]
            return {"code": 200, "fundings": PUBLIC["fundings"] + extra}
        raise AssertionError(path)

    def eth_call(self, vc, to, data):
        if data == fr.SEL_BUFFER:
            return "0x" + "0" * 24 + "bb" * 20
        if data == fr.SEL_ORACLE:
            return "0x" + "0" * 24 + "0c" * 20
        if data == fr.SEL_ATTESTER:
            return "0x" + "0" * 24 + ATTESTER[2:]
        if data.startswith(fr.SEL_BALANCE18):
            return "0x" + format(self.ledger % (1 << 256), "064x")
        if data == fr.SEL_SWEEPABLE:
            return "0x" + format(self.sweepable, "064x")
        if data == fr.SEL_LAST_ACCRUAL:
            return "0x" + format(self.last_accrual, "064x")
        raise AssertionError(data)

    def cast(self, vc, *a):
        if a[:2] == ("wallet", "address"):
            return ATTESTER + "\n"
        assert a[0] == "send"
        i = a.index("--")
        vault, sig, delta = a[i + 1:]
        assert (vault, sig) == (VAULT, "accrueFunding(int256)"), a
        self.sends.append(int(delta))
        if self.fail_send == "crash_before":
            raise RuntimeError("cast send: timed out")
        if self.fail_send == "revert":
            return "status 0 (failed)\ntransactionHash 0xdead\n"
        self.ledger += int(delta)
        if self.fail_send == "crash_after_landing":
            raise RuntimeError("cast send: connection reset")
        return "status 1 (success)\ntransactionHash 0xfeed\n"


class Flow(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.cfg = os.path.join(self.dir, "uTSLA.json")
        keyf = os.path.join(self.dir, "key.json")
        with open(keyf, "w") as f:
            json.dump({"account_index": 33556, "api_key_index": 3, "private": "not-a-real-key"}, f)
        with open(self.cfg, "w") as f:
            json.dump({"rpc": "http://rpc", "api": "http://api", "vault": VAULT, "market_index": 16,
                       "api_key_file": keyf}, f)
        self.state = os.path.join(self.dir, "state.json")
        self.world = World()

    def relay(self, dry=False, **env):
        e = {"FUNDING_RELAY_VAULTS": self.cfg, "FUNDING_RELAY_STATE": self.state, "KEEPER_ATTESTER_PK": PK,
             "FUNDING_RELAY_START_TS": "1790481600"}
        e.update(env)
        r = fr.Relay(env={k: v for k, v in e.items() if v is not None}, dry_run=dry)
        w = self.world
        r.get, r.eth_call, r.cast = w.get, w.eth_call, w.cast
        r.auth_token = lambda vc: "TOKEN-xyz"
        buf = io.StringIO()
        with redirect_stdout(buf):
            refused = r.run()
        self.out = buf.getvalue()
        self.assertNotIn(PK, self.out)
        self.assertNotIn("TOKEN-xyz", self.out)
        return refused

    def st(self):
        with open(self.state) as f:
            return json.load(f)["vaults"][VAULT.lower()]

    def test_first_run_needs_a_start(self):
        self.assertEqual(self.relay(FUNDING_RELAY_START_TS=None), 1)
        self.assertEqual(self.world.sends, [])
        self.assertIn("refusing to guess", self.out)

    def test_relays_once_then_idempotent(self):
        self.assertEqual(self.relay(), 0)
        self.assertEqual(self.world.sends, [WANT])
        self.assertEqual(self.world.ledger, WANT)
        self.assertEqual(self.world.auth_seen, ["TOKEN-xyz"])      # in the header, not the URL
        self.assertFalse(any("TOKEN" in g for g in self.world.gets))
        s = self.st()
        self.assertEqual((s["cursor_ts"], s["seen_ids"]), (1790492400, ["4004"]))
        self.assertNotIn("pending", s)
        self.assertEqual(self.relay(), 0)                          # a restart: nothing new, nothing sent
        self.assertEqual(self.world.sends, [WANT])
        self.world.records.insert(0, {"timestamp": 1790496000, "market_id": 16, "funding_id": 4005,
                                      "change": "-0.014910", "rate": "0.0004", "position_size": "10.0000",
                                      "position_side": "long"})
        self.assertEqual(self.relay(), 0)                          # only the new hour
        self.assertEqual(self.world.sends, [WANT, -14910 * 10 ** 12])

    def test_heartbeat_only_when_fees_wait_and_accrual_is_old(self):
        # Sermium I-08: sweepFees needs an accrual under 2 days old. A heartbeat every idle hour on
        # six vaults would be ~144 attester transactions a day for nothing, so it is sent only when
        # there are fees to sweep and the last accrual is over FUNDING_RELAY_HEARTBEAT_AGE old.
        self.assertEqual(self.relay(), 0)
        base = list(self.world.sends)
        self.assertEqual(self.relay(FUNDING_RELAY_HEARTBEAT="1"), 0)          # no fees: nothing
        self.assertEqual(self.world.sends, base)
        self.world.sweepable, self.world.last_accrual = 5, int(time.time()) - 3600
        self.assertEqual(self.relay(FUNDING_RELAY_HEARTBEAT="1"), 0)          # fees, recent accrual
        self.assertEqual(self.world.sends, base)
        self.world.last_accrual = int(time.time()) - 2 * 86400
        self.assertEqual(self.relay(FUNDING_RELAY_HEARTBEAT="1"), 0)          # fees, old accrual
        self.assertEqual(self.world.sends, base + [0])
        self.world.sends, self.world.last_accrual = list(base), int(time.time()) - 2 * 86400
        self.assertEqual(self.relay(), 0)                                     # heartbeat off: never
        self.assertEqual(self.world.sends, base)

    def test_start_ts_is_inclusive_and_bounds_history(self):
        self.relay(FUNDING_RELAY_START_TS="1790488800")
        self.assertEqual(self.world.sends, [-29801 * 10 ** 12])

    def test_dry_run_writes_and_sends_nothing(self):
        self.assertEqual(self.relay(dry=True, KEEPER_ATTESTER_PK=None), 0)
        self.assertEqual(self.world.sends, [])
        self.assertFalse(os.path.exists(self.state))
        self.assertIn("delta18 %d" % WANT, self.out)

    def test_revert_keeps_cursor(self):
        self.world.fail_send = "revert"
        self.relay()
        self.assertEqual(self.st()["cursor_ts"], 1790481600 - 1)   # not advanced
        self.assertNotIn("pending", self.st())
        self.world.fail_send = None
        self.relay()
        self.assertEqual(self.world.sends, [WANT, WANT])
        self.assertEqual(self.world.ledger, WANT)

    def test_crash_after_landing_is_not_resent(self):
        self.world.fail_send = "crash_after_landing"
        self.relay()
        self.assertIn("pending", self.st())
        self.world.fail_send = None
        self.assertEqual(self.relay(), 0)
        self.assertEqual(self.world.sends, [WANT])                 # recognised from the ledger
        self.assertEqual(self.world.ledger, WANT)
        self.assertEqual(self.st()["cursor_ts"], 1790492400)

    def test_crash_before_landing_waits_then_resends(self):
        self.world.fail_send = "crash_before"
        self.relay()
        self.world.fail_send = None
        self.assertEqual(self.relay(), 1)                          # inside the grace: wait
        self.assertEqual(self.world.sends, [WANT])
        self.assertEqual(self.relay(FUNDING_PENDING_GRACE_SEC="0"), 0)
        self.assertEqual(self.world.sends, [WANT, WANT])
        self.assertEqual(self.world.ledger, WANT)

    def test_unexplained_ledger_move_needs_a_human(self):
        self.world.fail_send = "crash_before"
        self.relay()
        self.world.fail_send = None
        self.world.ledger += 5
        self.assertEqual(self.relay(FUNDING_PENDING_GRACE_SEC="0"), 1)
        self.assertIn("needs a human", self.out)
        self.assertEqual(len(self.world.sends), 1)

    def test_cap(self):
        self.assertEqual(self.relay(FUNDING_MAX_DELTA_USD="0.05"), 1)
        self.assertEqual(self.world.sends, [])

    def test_wrong_account_refused(self):
        a = copy.deepcopy(ACCT)
        a["accounts"][0]["account_index"] = 99999
        g = self.world.get
        self.world.get = lambda vc, p, auth=None: a if p.startswith("/api/v1/account?") else g(vc, p, auth)
        self.assertEqual(self.relay(), 1)
        self.assertEqual(self.world.sends, [])

    def test_wrong_attester_key_refused(self):
        c = self.world.cast
        self.world.cast = lambda vc, *a: "0x" + "99" * 20 + "\n" if a[:2] == ("wallet", "address") else c(vc, *a)
        self.assertEqual(self.relay(), 1)
        self.assertEqual(self.world.sends, [])

    def test_cast_argument_order(self):
        seen = []
        c = self.world.cast
        self.world.cast = lambda vc, *a: (seen.append(a), c(vc, *a))[1]
        self.relay()
        send = [a for a in seen if a[0] == "send"][0]
        i = send.index("--")
        self.assertEqual(send[i + 1:], (VAULT, "accrueFunding(int256)", str(WANT)))   # negative after "--"
        self.assertLess(send.index("--private-key"), i)


if __name__ == "__main__":
    unittest.main(verbosity=1)

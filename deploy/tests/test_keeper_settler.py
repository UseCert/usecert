# H-4: a stack-5 keeper settles with the SETTLER key and never touches the attester key; a
# stack-4 keeper is unchanged. Stubbed chain and cast; no key here is real.
# Run: python deploy/tests/test_keeper_settler.py   (unittest)
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ethstub  # noqa: E402

k = _ethstub.load("usecert-keeper.py", "keeper")

ATT = "0x" + "a1" * 32
SET = "0x" + "5e" * 32
SETTLER_ADDR = "0x" + "cc" * 20


def keeper(stack, cfg=None, env=None, settler_onchain=SETTLER_ADDR):
    K = k.Keeper.__new__(k.Keeper)
    K.vault, K.rpc, K.cast, K.stack = "0xV", "rpc", "cast", stack
    K.sent = []
    K.settle_window = 3600
    K.state = {"receipts": {}, "last_recall": 0}
    K._save = lambda: None

    def cast(*a):
        if a[0] == "call":
            sig = a[2]
            if sig.startswith("settler"):
                return settler_onchain + "\n"
            if sig.startswith("mintReceipts"):
                old = str(int(time.time()) - 10_000)
                return "\n".join(["0x" + "aa" * 20, "5000000", "false", "1", old, "false", "1"]) + "\n"
            if sig.startswith("hotBuffer"):
                return "9000000\n"
            if sig.startswith("totalOwedOutstanding"):
                return "0\n"
            if sig.startswith("settleWindow"):
                return "3600\n"
        if a[:2] == ("wallet", "address"):
            return {SET: SETTLER_ADDR, ATT: "0x" + "dd" * 20}[a[3]] + "\n"
        K.sent.append(a)
        return "status 1 (success)\ntransactionHash 0xabc\n"
    K._cast = cast
    K._load_keys(cfg or {}, env if env is not None else {})
    return K


def keys_used(K):
    return [a[a.index("--private-key") + 1] for a in K.sent if "--private-key" in a and a[0] == "send"]


class Stack4(unittest.TestCase):
    def test_attester_as_before(self):
        K = keeper(4, env={"KEEPER_ATTESTER_PK": ATT})
        K.settle(7, 10 ** 18)
        self.assertEqual(keys_used(K), [ATT])

    def test_settler_ignored_in_stack4(self):
        K = keeper(4, env={"KEEPER_ATTESTER_PK": ATT, "KEEPER_SETTLER_PK": SET})
        K.settle(7, 10 ** 18)
        self.assertEqual(keys_used(K), [ATT])

    def test_class_default_is_stack4(self):
        K = k.Keeper.__new__(k.Keeper)
        K.attester_pk = ATT
        self.assertEqual(K._key("settleMint"), ATT)


class Stack5(unittest.TestCase):
    def test_settler_for_every_send_attester_never(self):
        env = {"KEEPER_ATTESTER_PK": ATT, "KEEPER_SETTLER_PK": SET}
        K = keeper(5, env=env)
        self.assertNotIn("KEEPER_ATTESTER_PK", env)             # dropped: no cast child inherits it
        self.assertIsNone(K.attester_pk)
        K.settle(7, 10 ** 18)
        K.state["receipts"]["8"] = {"status": "unfilled_left_for_refund"}
        K.maybe_refund()                                          # stageRefund, then refundMint
        K.auto_recall = True
        K._view = lambda sel: {"0xa2900772": 10, "0xf2a2bf59": 1}[sel]
        K._get = lambda p: {"accounts": [{"available_balance": "5"}]}
        K.maybe_recall()
        sent = [a[2].split("(")[0] for a in K.sent if a[0] == "send"]
        self.assertEqual(sent, ["settleMint", "stageRefund", "refundMint", "recallMarginUpTo"])
        self.assertEqual(set(keys_used(K)), {SET})
        self.assertFalse(any(ATT in x for a in K.sent for x in a))

    def test_key_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".key", delete=False) as f:
            f.write(SET + "\n")
        try:
            K = keeper(5, env={"KEEPER_SETTLER_KEY_FILE": f.name})
            self.assertEqual(K._key("settleMint"), SET)
            K2 = keeper(5, cfg={"settler_key_file": f.name})
            self.assertEqual(K2._key("stageRefund"), SET)
        finally:
            os.unlink(f.name)

    def test_config_key_wins(self):
        K = keeper(5, cfg={"settler_pk": SET}, env={"KEEPER_SETTLER_PK": "0x" + "99" * 32})
        self.assertEqual(K._key("settleMint"), SET)

    def test_no_settler_refuses_to_start(self):
        with self.assertRaises(SystemExit):
            keeper(5, env={"KEEPER_ATTESTER_PK": ATT})

    def test_same_key_refused(self):
        for same in [ATT, ATT.upper().replace("0X", "0x"), ATT[2:]]:
            with self.assertRaises(SystemExit):
                keeper(5, env={"KEEPER_ATTESTER_PK": ATT, "KEEPER_SETTLER_PK": same})

    def test_wrong_settler_on_chain_refused(self):
        with self.assertRaises(SystemExit):
            keeper(5, env={"KEEPER_SETTLER_PK": SET}, settler_onchain="0x" + "ee" * 20)
        keeper(5, cfg={"settler_getter": ""}, env={"KEEPER_SETTLER_PK": SET}, settler_onchain="0x" + "ee" * 20)

    def test_no_key_at_send_time_is_an_error_not_the_attester(self):
        K = k.Keeper.__new__(k.Keeper)
        K.stack, K.attester_pk = 5, ATT
        with self.assertRaises(RuntimeError):
            K._key("settleMint")


def remote_keeper(env, answers, settler_onchain=SETTLER_ADDR):
    """A stack-5 keeper whose sends go to a stubbed remote settler; the REAL _cast is kept for
    sends, so the routing branch itself is what is tested. Chain reads stay stubbed."""
    K = k.Keeper.__new__(k.Keeper)
    K.vault, K.rpc, K.cast, K.stack = "0xV", "rpc", "cast", 5
    K.settle_window, K.state, K._save = 3600, {"receipts": {}, "last_recall": 0}, lambda: None
    K.requests, K.local = [], []
    real = k.Keeper._cast.__get__(K)

    def remote(req):
        K.requests.append(req)
        return answers.pop(0) if answers else '{"status": 0, "reason": "no stub answer"}'
    K._remote = remote

    def cast(*a):
        if a[0] == "send":
            return real(*a)
        if a[0] == "call" and a[2].startswith("settler"):
            return settler_onchain + "\n"
        K.local.append(a)
        return "status 1 (success)\ntransactionHash 0xlocal\n"
    K._cast = cast
    K._load_keys({}, env)
    return K


class RemoteSettler(unittest.TestCase):
    """Sermium M-03: with KEEPER_SETTLER_REMOTE the keeper holds no settler key; every send goes
    to the remote settler, which checks it and signs it."""
    ENV = {"KEEPER_SETTLER_REMOTE": "settle@montreal", "KEEPER_SETTLER_SSH_KEY": "/k"}
    WHO = '{"status": 1, "settler": "%s"}' % SETTLER_ADDR

    def test_sends_go_remote_and_no_key_is_loaded(self):
        env = dict(self.ENV, KEEPER_ATTESTER_PK=ATT)
        K = remote_keeper(env, [self.WHO, '{"status": 1, "tx": "0xfeed"}'])
        self.assertIsNone(K.settler_pk)
        self.assertIsNone(K.attester_pk)
        self.assertNotIn("KEEPER_ATTESTER_PK", env)
        self.assertEqual(K.settle(7, 10 ** 18), "0xfeed")
        self.assertEqual(K.requests[1], {"vault": "0xV", "sig": "settleMint(uint256,uint256)", "args": ["7", str(10 ** 18)]})
        self.assertEqual([a for a in K.local if a[0] == "send"], [])          # nothing signed here

    def test_a_refusal_is_a_failed_send(self):
        K = remote_keeper(dict(self.ENV), [self.WHO, '{"status": 0, "reason": "hedge first"}'])
        with self.assertRaises(RuntimeError):
            K.settle(7, 10 ** 18)

    def test_permissionless_sends_go_remote_too(self):
        K = remote_keeper(dict(self.ENV), [self.WHO] + ['{"status": 1, "tx": "0x1"}'] * 3)
        out = K._cast("send", K.vault, "stageRefund(uint256)", "8", "--gas-limit", "1500000",
                      "--private-key", K._key("stageRefund"), "--rpc-url", K.rpc)
        self.assertIn("status 1", out)
        self.assertEqual(K.requests[1]["args"], ["8"])                        # flags never forwarded

    def test_local_key_and_remote_refused_together(self):
        with self.assertRaises(SystemExit):
            remote_keeper(dict(self.ENV, KEEPER_SETTLER_PK=SET), [self.WHO])

    def test_remote_needs_its_ssh_key(self):
        with self.assertRaises(SystemExit):
            remote_keeper({"KEEPER_SETTLER_REMOTE": "settle@montreal"}, [self.WHO])

    def test_remote_must_be_the_vaults_settler(self):
        with self.assertRaises(SystemExit):
            remote_keeper(dict(self.ENV), [self.WHO], settler_onchain="0x" + "ee" * 20)


if __name__ == "__main__":
    unittest.main(verbosity=1)

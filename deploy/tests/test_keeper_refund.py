# Keeper auto-refund, against a stubbed chain and venue (anvil cannot run the venue's Stylus code).
# Run: python deploy/tests/test_keeper_refund.py  (exit code = number of failures)
import importlib.util, time, sys
import types; sys_ = __import__("sys"); sys_.modules.setdefault("lighter", types.ModuleType("lighter"))
spec = importlib.util.spec_from_file_location("k", r"D:\cert\deploy\bin\usecert-keeper.py"); k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
def mk(receipt, have, owed, avail, revert=()):
    K = k.Keeper.__new__(k.Keeper)
    K.vault, K.rpc, K.attester_pk, K.settle_window = "0xV", "rpc", "pk", None
    K.state = {"receipts": {"7": {"status": "unfilled_left_for_refund", "at": 0}}, "last_recall": 0}
    K.sent = []; K._save = lambda: None
    def cast(*a):
        if a[0] == "call":
            sig = a[2]
            if sig.startswith("settleWindow"): return "3600\n"
            if sig.startswith("mintReceipts"): return "\n".join(receipt) + "\n"
            if sig.startswith("hotBuffer"): return "%d\n" % have
            if sig.startswith("totalOwedOutstanding"): return "%d\n" % owed
        K.sent.append(a[2] + " " + a[3])
        if a[2].split("(")[0] in revert: raise RuntimeError("cast send: reverted")
        return "status 1 (success)\n"
    K._cast = cast; K._get = lambda p: {"accounts": [{"available_balance": str(avail / 1e6)}]}
    return K
now = int(time.time()); old = now - 4000; fresh = now - 100
R = lambda at, staged, settled="false": ["0x00000000000000000000000000000000000000aa", "5000000", settled, "1", str(at), staged, "1"]
cases = [
 ("window open: nothing sent", R(fresh, "false"), 10**9, 0, 10**9, (), [], "unfilled_left_for_refund"),
 ("expired, cash there: stage then refund", R(old, "false"), 6_000_000, 0, 0, (), ["stageRefund(uint256) 7", "refundMint(uint256) 7"], "refunded"),
 ("expired, staged, cash short: recall shortfall only", R(old, "true"), 1_000_000, 500_000, 9_000_000, (), ["recallMarginUpTo(uint256) 4500000"], "unfilled_left_for_refund"),
 ("recall capped at venue balance", R(old, "true"), 1_000_000, 0, 2_000_000, (), ["recallMarginUpTo(uint256) 2000000"], "unfilled_left_for_refund"),
 ("already settled by holder", R(old, "true", "true"), 0, 0, 0, (), [], "refunded"),
 ("stageRefund reverts: logged, loop survives", R(old, "false"), 6_000_000, 0, 0, ("stageRefund",), ["stageRefund(uint256) 7"], "unfilled_left_for_refund"),
 ("refundMint reverts: stays staged, retried", R(old, "true"), 6_000_000, 0, 0, ("refundMint",), ["refundMint(uint256) 7"], "unfilled_left_for_refund"),
]
bad = 0
for name, rc, have, owed, avail, rev, want, st in cases:
    K = mk(rc, have, owed, avail, rev); K.maybe_refund()
    got = K.state["receipts"]["7"]["status"]
    res = K.sent == want and got == st
    bad += not res
    print("PASS" if res else "FAIL", name, K.sent, got)
# retry spacing: a second immediate pass sends nothing
K = mk(R(old, "true"), 1_000_000, 0, 9_000_000); K.maybe_refund(); n = len(K.sent); K.maybe_refund()
print("PASS" if len(K.sent) == n else "FAIL", "no resend within 120 s"); bad += len(K.sent) != n
# a PARTIAL or unconfirmed receipt is never touched
K = mk(R(old, "false"), 10**9, 0, 0); K.state["receipts"]["7"]["status"] = "PARTIAL_needs_human"; K.maybe_refund()
print("PASS" if not K.sent else "FAIL", "partial fill left for a human"); bad += bool(K.sent)
sys.exit(bad)

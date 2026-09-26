# Keeper recall against a stubbed chain and venue: one read when nothing is owed, the capped shortfall when short.
# Run: python deploy/tests/test_keeper_recall.py  (exit code = number of failures)
import importlib.util, sys, types, os
sys.modules.setdefault("lighter", types.ModuleType("lighter"))
spec = importlib.util.spec_from_file_location("k", r"D:\cert\deploy\bin\usecert-keeper.py"); k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
def mk(owed, have, avail):
    K = k.Keeper.__new__(k.Keeper); K.vault="0xV"; K.rpc="r"; K.attester_pk="pk"; K.auto_recall=True
    K.state={"last_recall":0,"receipts":{}}; K._save=lambda:None; K.calls=[]; K.sent=[]
    def rpc(m, p):
        K.calls.append(p[0]["data"]); return hex({"0xa2900772": owed, "0xf2a2bf59": have}[p[0]["data"]])
    K._rpc=rpc
    K._get=lambda path: {"accounts":[{"available_balance": str(avail/1e6)}]}
    def cast(*a):
        K.sent.append(a[:4]); return "status 1 (success)\n"
    K._cast=cast
    return K
bad=0
K=mk(0,5,9); K.maybe_recall(); ok = K.calls==["0xa2900772"] and not K.sent; print("PASS" if ok else "FAIL","nothing owed: one read, no send",K.calls); bad+=not ok
K=mk(5,9,9); K.maybe_recall(); ok = K.calls==["0xa2900772","0xf2a2bf59"] and not K.sent; print("PASS" if ok else "FAIL","owed but covered: two reads, no send"); bad+=not ok
K=mk(10_000_000,2_000_000,5_000_000); K.maybe_recall(); ok = K.sent==[("send","0xV","recallMarginUpTo(uint256)","5000000")]; print("PASS" if ok else "FAIL","short: recall capped at venue balance",K.sent); bad+=not ok
K=mk(10_000_000,2_000_000,50_000_000); K.maybe_recall(); ok = K.sent==[("send","0xV","recallMarginUpTo(uint256)","8000000")]; print("PASS" if ok else "FAIL","short: recall = shortfall",K.sent); bad+=not ok
sys.exit(bad)

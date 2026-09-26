#!/usr/bin/env python3
"""UseCert attestation signer for MAINNET (Robinhood Chain 4663, Robinhood Chain Lighter).

Same job and same HTTP contract as usecert-signer.mjs: every 30s, sign one SolvencyRegistry
attestation and one CertOracle mark per vault, serve them on 127.0.0.1:8787/attestations, and
never broadcast. A minter relays them inside their own transaction.

WHY A SECOND SIGNER. The testnet one runs AttesterSign.s.sol, which reads the vault's position,
margin and the mark from LighterSim's view functions. The real venue has none of them on chain
(markPrice reverts): its state lives in the sequencer and is published through its API. So the
figures come from api.rh.lighter.xyz, per vault account:

  markPx18     market mark_price
  notional18   |position| * mark_price
  margin18     min(collateral, total_asset_value)   (cash, or equity if lower: the conservative leg,
                                                      as VenueTruth.margin18 does on testnet)
  openInterest18  carried from the registry's latest attestation (what the smoke cycles did)

Everything else is read from the CONTRACTS, never hardcoded: the registry and oracle domain
separators and typehashes, batchId (latest + 1) and markNonce (current + 1). Hardcoding either
would let this and the contracts drift apart, and the symptom would be every relay reverting
BadSignature while the figures looked right.

    usecert-signer-mainnet.py BOOK.json        (ATTESTER_PK in the environment)
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from eth_abi import encode
from eth_account import Account
from eth_utils import keccak

RPC = os.environ.get("RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
API = os.environ.get("VENUE_API", "https://api.rh.lighter.xyz")
CAST = os.environ.get("CAST", "/opt/keeper/bin/cast")
UA = "usecert-signer/1.0"
VALIDITY = 60          # SolvencyRegistry.SIGNATURE_VALIDITY
CYCLE = 20             # served bundles keep >= ~35s of life; the site wants 25s of headroom
PORT = 8787
E18 = Decimal(10) ** 18

cache = {"generatedAt": 0, "attestations": [], "error": "not yet generated"}


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *a, flush=True)


def get(path):
    delay = 2
    for attempt in range(5):
        try:
            req = urllib.request.Request(API + path, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.load(r)
        except Exception:                                            # noqa: BLE001
            if attempt == 4:
                raise
            time.sleep(delay)
            delay *= 2


def call(to, sig, *args):
    r = subprocess.run([CAST, "call", to, sig, *args, "--rpc-url", RPC],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError("cast call %s %s: %s" % (to, sig, (r.stderr or r.stdout).strip()[:200]))
    return [l.split()[0] if l.split() else "" for l in r.stdout.strip().split("\n")]


def b32(x):
    return bytes.fromhex(x[2:])


def to18(s):
    return int(Decimal(str(s)) * E18)


def sign(pk, domain, struct_hash):
    digest = keccak(b"\x19\x01" + domain + struct_hash)
    s = Account.unsafe_sign_hash(digest, pk)
    return "0x" + (s.r.to_bytes(32, "big") + s.s.to_bytes(32, "big") + bytes([s.v])).hex()


class Signer:
    def __init__(self, book_path, pk):
        book = json.load(open(book_path))
        assert int(book["chainId"]) == 4663, "this signer is for chain 4663 only"
        self.pk = pk
        self.addr = Account.from_key(pk).address
        self.registry = book["shared"]["solvencyRegistry"]
        self.vaults = book["vaults"]
        if self.addr.lower() != book["senders"]["attester"].lower():
            sys.exit("ATTESTER_PK does not derive the book's attester %s" % book["senders"]["attester"])
        onchain = call(self.registry, "attester()(address)")[0]
        if onchain.lower() != self.addr.lower():
            sys.exit("SolvencyRegistry.attester() is %s, not this key - rotated?" % onchain)
        # Read once: these change only by redeployment.
        self.reg_domain = b32(call(self.registry, "domainSeparator()(bytes32)")[0])
        self.attest_th = b32(call(self.registry, "ATTEST_TYPEHASH()(bytes32)")[0])
        self.oracle = {}
        for v in self.vaults:
            o = v["certOracle"]
            if call(o, "attester()(address)")[0].lower() != self.addr.lower():
                sys.exit("CertOracle %s attester is not this key" % o)
            self.oracle[o] = (b32(call(o, "domainSeparator()(bytes32)")[0]),
                              b32(call(o, "SET_MARK_TYPEHASH()(bytes32)")[0]))
        log("signer for %s: %d vaults, attester %s" % (self.registry, len(self.vaults), self.addr))

    def gather(self, v, marks):
        """Every read for one vault. Slow (venue API + chain), so it runs before the clock starts."""
        vault, oracle, mkt = v["vault"], v["certOracle"], int(v["marketIndex"])
        acct = get("/api/v1/account?by=l1_address&value=" + vault)["accounts"][0]
        mark = Decimal(str(marks[mkt]))
        if mark <= 0:
            raise RuntimeError("no mark for market %d" % mkt)
        pos = Decimal("0")
        for p in acct.get("positions", []):
            if int(p.get("market_id", -1)) == mkt:
                pos = abs(Decimal(str(p.get("position", "0"))))
        notional18 = int(pos * mark * E18)
        margin18 = min(to18(acct["collateral"]), to18(acct["total_asset_value"]))
        mark18 = int(mark * E18)
        # cast prints a tuple on one line: (a, b, c, d, e) with optional [sci] annotations
        raw = subprocess.run([CAST, "call", self.registry,
                              "latest(address)((uint256,uint256,uint256,uint64,uint64))", vault,
                              "--rpc-url", RPC], capture_output=True, text=True, timeout=60).stdout
        parts = [x.strip().split()[0] for x in raw.strip().strip("()").split(",")]
        oi18, batch = int(parts[2]), int(parts[3]) + 1
        nonce = int(call(oracle, "markNonce()(uint64)")[0]) + 1
        return v, notional18, margin18, mark18, oi18, batch, nonce

    def one(self, g, observed_at, deadline):
        """Pure signing, milliseconds: done after the timestamp is taken, so the whole 60s
        validity window is left for the client rather than spent on our own reads."""
        v, notional18, margin18, mark18, oi18, batch, nonce = g
        vault, oracle = v["vault"], v["certOracle"]
        attest_sig = sign(self.pk, self.reg_domain, keccak(encode(
            ["bytes32", "address", "uint64", "uint256", "uint256", "uint256", "uint64", "uint64"],
            [self.attest_th, vault, batch, notional18, margin18, oi18, observed_at, deadline])))
        dom, th = self.oracle[oracle]
        mark_sig = sign(self.pk, dom, keccak(encode(["bytes32", "uint256", "uint64", "uint64"],
                                                     [th, mark18, nonce, deadline])))
        return {"symbol": v["symbol"], "vault": vault, "certOracle": oracle, "registry": self.registry,
                "batchId": batch, "notional18": str(notional18), "margin18": str(margin18),
                "openInterest18": str(oi18), "markPx18": str(mark18), "markNonce": nonce,
                "observedAt": observed_at, "deadline": deadline,
                "attestSig": attest_sig, "markSig": mark_sig}

    def refresh(self):
        global cache
        try:
            books = get("/api/v1/orderBookDetails")
            marks = {int(m["market_id"]): m["mark_price"] for m in books["order_book_details"]}
            with ThreadPoolExecutor(len(self.vaults)) as ex:
                gathered = list(ex.map(lambda v: self.gather(v, marks), self.vaults))
            ts = subprocess.run([CAST, "block", "latest", "-f", "timestamp", "--rpc-url", RPC],
                                capture_output=True, text=True, timeout=60).stdout.strip()
            observed_at = int(ts, 0)
            deadline = observed_at + VALIDITY
            out = [self.one(g, observed_at, deadline) for g in gathered]
            cache = {"generatedAt": int(time.time()), "attestations": out, "error": None}
            log("signed %d vaults" % len(out))
        except Exception as e:                                       # noqa: BLE001
            # Keep serving the previous batch: it may still be inside its deadline, and a
            # client can read ageSec and decide for itself.
            cache = dict(cache, error=str(e)[:200], lastErrorAt=int(time.time()))
            log("sign failed:", e)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body=b""):
        self.send_response(code)
        self.send_header("access-control-allow-origin", "*")
        self.send_header("content-type", "application/json")
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204)

    def do_GET(self):
        if not self.path.startswith("/attestations"):
            return self._send(404, b'{"error":"not found"}')
        c = cache
        age = int(time.time()) - c["generatedAt"]
        stale = c["generatedAt"] == 0 or age > VALIDITY
        self._send(503 if stale else 200, json.dumps({
            "generatedAt": c["generatedAt"], "ageSec": age if c["generatedAt"] else None,
            "validitySec": VALIDITY, "stale": stale, "error": c["error"],
            "attestations": c["attestations"]}).encode())

    def log_message(self, *a):
        pass


def main():
    s = Signer(sys.argv[1], os.environ["ATTESTER_PK"])
    if "--once" in sys.argv:
        s.refresh()
        print(json.dumps(cache))
        return

    def loop():
        while True:
            s.refresh()
            time.sleep(CYCLE)
    threading.Thread(target=loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()

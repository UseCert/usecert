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
  openInterest18  STACK 4: carried from the registry's latest attestation (what the smoke cycles
                  did). STACK 5 / OI_SOURCE=venue: measured, market open_interest * mark_price
                  (pre-audit M-8; see open_interest18 below for the units evidence)

Everything else is read from the CONTRACTS, never hardcoded: the registry and oracle domain
separators and typehashes, batchId (latest + 1) and markNonce (current + 1). Hardcoding either
would let this and the contracts drift apart, and the symptom would be every relay reverting
BadSignature while the figures looked right.

    usecert-signer-mainnet.py BOOK.json        (ATTESTER_PK in the environment)

STACK 5 (all off by default, so a stack-4 signer behaves exactly as before):
  STACK=5                     turns on the switches below with their stack-5 defaults
  MARK_SIG_VERSION=1|2        2: SetMark(px18,nonce,observedAt,deadline), domain version "2",
                              observedAt = when the venue market data was read,
                              deadline = observedAt + 60, never more (H-6). The oracle's
                              domain separator and typehash are still read from chain, and
                              checked against that format at start-up.
  OI_SOURCE=registry|venue    venue: measure open interest instead of carrying it (M-8)
  SANITY_CHECKS=0|1           1: refuse to sign a vault whose mark is more than
                              MARK_MAX_DEVIATION_BPS (500) from its Chainlink feed, or whose
                              notional moved by more than NOTIONAL_JUMP_FACTOR (1.5; 0 = off)
                              against the last one signed with no order event on chain (F6)
  ORDER_EVENT_LOOKBACK_BLOCKS how far before the last signed notional an order event still
                              explains a jump (20000); ORDER_EVENT_SIGS (';'-separated event
                              signatures) overrides the event list
  MULTIPLIER_CHECKS=0|1       option A (default 1 under STACK=5; needs the stack-5 CertOracle).
                              The venue marks SHARES and the feed prices one stock TOKEN, which is
                              multiplier18() shares (ERC-8056 uiMultiplier; SPY 1.0017, x10 after a
                              10:1 split). So the mark-vs-feed check compares mark x multiplier18
                              with the feed - read from the oracle in the same multicall - and a
                              split no longer makes it refuse every mark. It also refuses to sign a
                              vault while its oracle reports corporateActionWindow() or its stock
                              token reports oraclePaused(), and when either, or the multiplier,
                              cannot be read. Read-only checks; each refusal names its reason.
  Under STACK=5 an attestation whose observedAt is not strictly after the registry's latest,
  or a mark whose observedAt is before the oracle's markAt, is not signed: the stack-5
  contracts would revert it.
A refused vault is left out of the bundle, listed under "refused" with the reason, and logged;
the other vaults are still signed.
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from eth_abi import decode, encode
from eth_account import Account
from eth_utils import keccak

RPC = os.environ.get("RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
API = os.environ.get("VENUE_API", "https://api.rh.lighter.xyz")
CAST = os.environ.get("CAST", "/opt/keeper/bin/cast")
UA = "usecert-signer/1.0"
VALIDITY = 60          # SolvencyRegistry.SIGNATURE_VALIDITY
MARK_VALIDITY = 60     # stack-5 CertOracle: deadline <= observedAt + 60
CYCLE = 5              # + ~15-20 s of reads: every bundle served keeps >= ~35 s of its 60; the site wants 25
PORT = 8787
E18 = Decimal(10) ** 18

cache = {"generatedAt": 0, "attestations": [], "error": "not yet generated"}

# Vault events that mean the venue position may legitimately change. rebalance() emits none in
# the stack-4 source, so a rebalance-driven jump beyond the factor is refused until a human looks
# (fail-safe); if stack 5 gives it an event, add it here or through ORDER_EVENT_SIGS.
DEFAULT_ORDER_EVENTS = (
    "HedgeRequested(uint256,uint256,uint8,uint256)",
    "MintSettled(uint256,uint256,uint256)",
    "Minted(address,uint256,uint256,uint256,uint256)",
    "Redeemed(address,uint256,uint256,uint256)",
    "RedeemRequested(uint256,address,uint256,uint64)",
    "RedeemClaimed(uint256,uint256)",
    "ForceExited(uint256,address,uint256)",
    "ClosedAll(uint8,int256)",
    "RefundStaged(uint256,uint256,bool)",
    "CloseOrderNotPlaced(uint256)",
)


class Refuse(Exception):
    """A figure failed a sanity check: this vault is not signed this cycle. Never fatal."""


class Config:
    def __init__(self, env=None):
        e = os.environ if env is None else env
        self.stack = int(e.get("STACK", "4"))
        s5 = self.stack >= 5
        self.mark_sig_version = int(e.get("MARK_SIG_VERSION", "2" if s5 else "1"))
        if self.mark_sig_version not in (1, 2):
            raise ValueError("MARK_SIG_VERSION must be 1 or 2")
        self.oi_source = e.get("OI_SOURCE", "venue" if s5 else "registry")
        if self.oi_source not in ("registry", "venue"):
            raise ValueError("OI_SOURCE must be registry or venue")
        self.sanity = e.get("SANITY_CHECKS", "1" if s5 else "0") == "1"
        self.max_dev_bps = int(e.get("MARK_MAX_DEVIATION_BPS", "500"))
        self.jump_factor = Decimal(e.get("NOTIONAL_JUMP_FACTOR", "1.5"))
        if 0 < self.jump_factor <= 1 or self.jump_factor < 0:
            raise ValueError("NOTIONAL_JUMP_FACTOR must be > 1, or 0 to disable")
        self.lookback = int(e.get("ORDER_EVENT_LOOKBACK_BLOCKS", "20000"))
        self.mult_checks = e.get("MULTIPLIER_CHECKS", "1" if s5 else "0") == "1"
        sigs = e.get("ORDER_EVENT_SIGS")
        self.order_events = (tuple(x.strip() for x in sigs.split(";") if x.strip())
                             if sigs else DEFAULT_ORDER_EVENTS)
        # SolvencyRegistry v5: observedAt strictly after the latest. Tied to the stack, not a knob.
        self.strict_observed_at = s5

    @property
    def mark_v2(self):
        return self.mark_sig_version == 2


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


MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
SEL_AGGREGATE3 = bytes.fromhex("82ad56cb")   # aggregate3((address,bool,bytes)[])
SEL_LATEST = bytes.fromhex("4a4aac1a")       # SolvencyRegistry.latest(address)
SEL_MARK_NONCE = bytes.fromhex("714e5939")   # CertOracle.markNonce()
SEL_MARK_AT = bytes.fromhex("9fce1418")      # CertOracle.markAt()             (stack 5)
SEL_LATEST_ROUND = bytes.fromhex("feaf968c") # AggregatorV3.latestRoundData()
SEL_MULT = bytes.fromhex("05a3a104")         # CertOracle.multiplier18()        (stack 5, option A)
SEL_CA_WINDOW = bytes.fromhex("5548eb81")    # CertOracle.corporateActionWindow()
SEL_ORACLE_PAUSED = bytes.fromhex("7706ba52")  # stock token (ERC-8056) oraclePaused()
ZERO_ADDRESS = "0x" + "00" * 20


def rpc(method, params):
    """JSON-RPC with backoff on 429 / 5xx. The six keepers share this IP and the RPC's limit."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    delay = 1
    for attempt in range(6):
        try:
            req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": UA})
            with urllib.request.urlopen(req, timeout=20) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError("%s: %s" % (method, out["error"]))
            return out["result"]
        except urllib.error.HTTPError as e:
            if (e.code != 429 and e.code < 500) or attempt == 5:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 5:
                raise
        time.sleep(delay)
        delay = min(delay * 2, 8)


def b32(x):
    return bytes.fromhex(x[2:])


def to18(s):
    return int(Decimal(str(s)) * E18)


def sign(pk, domain, struct_hash):
    digest = keccak(b"\x19\x01" + domain + struct_hash)
    s = Account.unsafe_sign_hash(digest, pk)
    return "0x" + (s.r.to_bytes(32, "big") + s.s.to_bytes(32, "big") + bytes([s.v])).hex()


EIP712_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
SET_MARK_V2_TYPE = "SetMark(uint256 px18,uint64 nonce,uint64 observedAt,uint64 deadline)"


def domain_separator(name, version, chain_id, verifying):
    """What the contract computes. Used only to CHECK the separator read from chain (v2)."""
    return keccak(encode(["bytes32", "bytes32", "bytes32", "uint256", "address"],
                         [keccak(text=EIP712_DOMAIN_TYPE), keccak(text=name), keccak(text=version),
                          chain_id, verifying]))


def mark_struct_hash(th, px18, nonce, deadline, observed_at=None):
    """v1: SetMark(px18,nonce,deadline). v2 (observed_at given): SetMark(px18,nonce,observedAt,deadline)."""
    if observed_at is None:
        return keccak(encode(["bytes32", "uint256", "uint64", "uint64"], [th, px18, nonce, deadline]))
    if deadline > observed_at + MARK_VALIDITY:
        raise Refuse("mark deadline %d is more than %ds after observedAt %d" % (deadline, MARK_VALIDITY, observed_at))
    return keccak(encode(["bytes32", "uint256", "uint64", "uint64", "uint64"],
                         [th, px18, nonce, observed_at, deadline]))


def open_interest18(market, mark):
    """M-8: the market's open interest, in 1e18 USD = open_interest (base units) * mark.

    EVIDENCE FOR THE UNITS (api.rh.lighter.xyz/api/v1/orderBookDetails, recorded 2026-09-27 in
    deploy/tests/fixtures/orderBookDetails-14-16.json): `open_interest` is a JSON number in BASE
    units (shares), not quote. MSFT (market 14) read 1821.2818 at mark_price 518.36, i.e. $944k,
    which is the "about $0.9M on the venue" the pre-audit measured independently; read as quote,
    MSFT's open interest would be $1.8k. It also carries size_decimals (4) of precision, as base
    quantities do, and the neighbouring daily_base_token_volume / daily_quote_token_volume pair
    divides to the mark. The venue does not say whether the figure is one side (longs = shorts)
    or both; it is used as published, never doubled.

    Missing, non-numeric, non-finite, zero or negative -> Refuse: never sign a made-up depth."""
    raw = market.get("open_interest")
    if raw is None or isinstance(raw, bool):
        raise Refuse("market %s has no open_interest" % market.get("market_id"))
    try:
        oi = Decimal(str(raw))
    except Exception:                                                # noqa: BLE001
        raise Refuse("market %s open_interest %r is not a number" % (market.get("market_id"), raw))
    if not oi.is_finite() or oi <= 0:
        raise Refuse("market %s open_interest %s is not positive" % (market.get("market_id"), raw))
    return int(oi * Decimal(mark) * E18)


def check_mark_vs_feed(mark18, feed_px18, max_bps, mult18=None):
    """F6: the venue mark must sit within max_bps of the vault's own Chainlink feed.

    Option A (mult18 given): the mark is a SHARE price and the feed a TOKEN price, one token being
    mult18 / 1e18 shares, so the mark is compared as mark x multiplier18 - exactly what
    CertOracle's basis band does with markPx18 x multiplier18()."""
    if feed_px18 <= 0:
        raise Refuse("feed price %d is not positive" % feed_px18)
    mk = mark18 if mult18 is None else mark18 * mult18 // 10 ** 18
    if abs(mk - feed_px18) * 10_000 > max_bps * feed_px18:
        how = "" if mult18 is None else " (share mark %d x multiplier %d)" % (mark18, mult18)
        raise Refuse("mark %d%s is %.1f bps from feed %d (max %d)" % (
            mk, how, abs(mk - feed_px18) * 10_000 / feed_px18, feed_px18, max_bps))


def check_corporate_action(ch):
    """Option A: refuse while the oracle closes minting for a corporate action, or the token says
    its own oracle is paused, or either cannot be read (the oracle treats that as paused too)."""
    if ch.get("mult18") is None:
        raise Refuse("oracle multiplier18() unreadable")
    if ch.get("ca_window") is None:
        raise Refuse("oracle corporateActionWindow() unreadable")
    if ch["ca_window"]:
        raise Refuse("oracle reports a corporate action window (multiplier %d)" % ch["mult18"])
    if ch.get("token_paused") is None:
        raise Refuse("stock token oraclePaused() unreadable")
    if ch["token_paused"]:
        raise Refuse("stock token reports oraclePaused()")


def jumped(prev, new, factor):
    if prev == new:
        return False
    if prev == 0 or new == 0:
        return True
    hi, lo = max(prev, new), min(prev, new)
    return Decimal(hi) > factor * Decimal(lo)


class NotionalGuard:
    """F6: refuse a notional that moved by more than `factor` either way (to or from zero
    included) against the last one signed, unless the vault emitted an order event in
    [block of that baseline - lookback, now]. The event query only runs on a jump, so a normal
    cycle costs no extra RPC. With no baseline yet (fresh start) the registry's latest is it.
    A refusal does not move the baseline; only a signed figure does."""

    def __init__(self, factor, lookback, has_order_event):
        self.factor, self.lookback, self.has_order_event = factor, lookback, has_order_event
        self.base = {}

    def check(self, vault, notional18, head, seed):
        if self.factor <= 0:
            return
        prev, blk = self.base.setdefault(vault, (seed, head))
        if not jumped(prev, notional18, self.factor):
            return
        frm = max(0, blk - self.lookback)
        if self.has_order_event(vault, frm, head):
            return
        raise Refuse("notional %d -> %d moved more than x%s with no order event since block %d"
                     % (prev, notional18, self.factor, frm))

    def accept(self, vault, notional18, head):
        self.base[vault] = (notional18, head)


class Signer:
    def __init__(self, book_path, pk, cfg=None):
        self.cfg = cfg or Config()
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
            if self.cfg.mark_v2:
                # Still read from the contract, but CHECKED against the stack-5 format: a v2
                # signer pointed at a v1 oracle would otherwise serve bundles that all revert.
                want = (domain_separator("UseCert CertOracle", "2", 4663, o), keccak(text=SET_MARK_V2_TYPE))
                if self.oracle[o] != want:
                    sys.exit("CertOracle %s is not a v2 mark oracle (domain or typehash differ); "
                             "MARK_SIG_VERSION=2 needs the stack-5 oracle" % o)
        self.token = {}
        if self.cfg.mult_checks:
            for v in self.vaults:
                o = v["certOracle"]
                try:
                    self.token[o] = call(o, "stockToken()(address)")[0]
                except RuntimeError as e:
                    sys.exit("CertOracle %s has no stockToken() - MULTIPLIER_CHECKS=1 needs the stack-5 "
                             "(option A) oracle: %s" % (o, e))
        self.feed = {}
        if self.cfg.sanity:
            for v in self.vaults:
                o = v["certOracle"]
                f = call(o, "feed()(address)")[0]
                booked = v.get("feed") or v.get("replayAggregator")   # the book mislabels it (L-6)
                if booked and booked.lower() != f.lower():
                    sys.exit("%s: oracle feed %s differs from the book's %s" % (v["symbol"], f, booked))
                self.feed[o] = (f, int(call(f, "decimals()(uint8)")[0]))
        self.guard = NotionalGuard(self.cfg.jump_factor, self.cfg.lookback, self.order_event_since)
        self.order_topics = ["0x" + keccak(text=e).hex() for e in self.cfg.order_events]
        log("signer for %s: %d vaults, attester %s, stack %d, mark v%d, OI from %s, sanity %s, multiplier checks %s"
            % (self.registry, len(self.vaults), self.addr, self.cfg.stack, self.cfg.mark_sig_version,
               self.cfg.oi_source, "on" if self.cfg.sanity else "off", "on" if self.cfg.mult_checks else "off"))

    def chain_reads(self):
        """registry.latest(vault) and oracle.markNonce() for every vault, as ONE eth_call.

        These were twelve `cast call`s a cycle - two per vault - from the same IP as six keepers,
        and an empty result from a rate-limited one surfaced as 'list index out of range'. One
        Multicall3 aggregate3 reads the same twelve values in a single request, all at one
        block; allowFailure is false, so any failed read fails the whole cycle and the previous
        bundle keeps being served, exactly as a failed cast call did. Stack 5 adds the oracle's
        markAt and, with the sanity checks, the feed's latestRoundData, to the same request.
        MULTIPLIER_CHECKS adds the oracle's multiplier18() and corporateActionWindow() and the
        stock token's oraclePaused(), with allowFailure: an unreadable one refuses that vault
        (see check_corporate_action) instead of failing every vault's cycle."""
        calls, spans = [], []
        for v in self.vaults:
            c = self.vault_calls(v)
            spans.append((len(calls), len(c)))
            calls += c
        data = "0x" + (SEL_AGGREGATE3 + encode(["(address,bool,bytes)[]"], [calls])).hex()
        raw = bytes.fromhex(rpc("eth_call", [{"to": MULTICALL3, "data": data}, "latest"])[2:])
        results = decode(["(bool,bytes)[]"], raw)[0]
        return {v["vault"]: self.parse_vault(v, list(results[a:a + n]))
                for v, (a, n) in zip(self.vaults, spans)}

    def vault_calls(self, v):
        """The multicall entries for one vault, in the order parse_vault reads them."""
        o = v["certOracle"]
        c = [(self.registry, False, SEL_LATEST + encode(["address"], [v["vault"]])),
             (o, False, SEL_MARK_NONCE)]
        if self.cfg.mark_v2:
            c.append((o, False, SEL_MARK_AT))
        if self.cfg.sanity:
            c.append((self.feed[o][0], False, SEL_LATEST_ROUND))
        if self.cfg.mult_checks:
            c += [(o, True, SEL_MULT), (o, True, SEL_CA_WINDOW)]
            token = self.token.get(o, ZERO_ADDRESS)
            if int(token, 16):
                c.append((token, True, SEL_ORACLE_PAUSED))
        return c

    def parse_vault(self, v, r):
        """One vault's (success, returnData) pairs -> its chain figures."""
        need = 2 + self.cfg.mark_v2 + self.cfg.sanity
        if not all(ok for ok, _ in r[:need]):
            raise RuntimeError("multicall read failed for %s" % v["symbol"])
        parts = decode(["uint256", "uint256", "uint256", "uint64", "uint64"], r[0][1])
        ch = {"notional": int(parts[0]), "oi": int(parts[2]), "batch": int(parts[3]) + 1,
              "latest_at": int(parts[4]), "nonce": int(decode(["uint64"], r[1][1])[0]) + 1}
        k = 2
        if self.cfg.mark_v2:
            ch["mark_at"] = int(decode(["uint256"], r[k][1])[0])
            k += 1
        if self.cfg.sanity:
            _rid, answer, _st, updated, _ans = decode(["uint80", "int256", "uint256", "uint256", "uint80"], r[k][1])
            dec = self.feed[v["certOracle"]][1]
            ch["feed_px18"] = int(answer) * 10 ** (18 - dec) if dec <= 18 else int(answer) // 10 ** (dec - 18)
            ch["feed_at"] = int(updated)
            k += 1
        if self.cfg.mult_checks:
            def word(i):
                ok, b = r[i] if i < len(r) else (False, b"")
                return int(decode(["uint256"], b)[0]) if ok and len(b) >= 32 else None
            ch["mult18"] = word(k)
            ca = word(k + 1)
            ch["ca_window"] = None if ca is None else ca != 0
            if int(self.token.get(v["certOracle"], ZERO_ADDRESS), 16):
                p = word(k + 2)
                ch["token_paused"] = None if p is None else p != 0
            else:
                ch["token_paused"] = False                 # no token (testnet): M is 1e18, nothing to pause
        return ch

    def head(self):
        """(number, timestamp) of the latest block - the one request the timestamp read always was."""
        b = rpc("eth_getBlockByNumber", ["latest", False])
        return int(b["number"], 16), int(b["timestamp"], 16)

    def order_event_since(self, vault, frm, to):
        """True if the vault emitted any order event in blocks [frm, to]. Only runs on a jump."""
        while frm <= to:
            hi = min(frm + 5000, to)
            if rpc("eth_getLogs", [{"address": vault, "topics": [self.order_topics],
                                    "fromBlock": hex(frm), "toBlock": hex(hi)}]):
                return True
            frm = hi + 1
        return False

    def read_account(self, v):
        """The slow venue read for one vault; runs in parallel across vaults."""
        return get("/api/v1/account?by=l1_address&value=" + v["vault"])["accounts"][0]

    def compute(self, v, acct, markets, ch, observed_at, head_block):
        """Every figure for one vault, and every check on them. Raises Refuse on a failed check."""
        vault, mkt = v["vault"], int(v["marketIndex"])
        market = markets[mkt]
        mark = Decimal(str(market["mark_price"]))
        if mark <= 0:
            raise RuntimeError("no mark for market %d" % mkt)
        pos = Decimal("0")
        for p in acct.get("positions", []):
            if int(p.get("market_id", -1)) == mkt:
                pos = abs(Decimal(str(p.get("position", "0"))))
        notional18 = int(pos * mark * E18)
        margin18 = min(to18(acct["collateral"]), to18(acct["total_asset_value"]))
        mark18 = int(mark * E18)
        oi18 = open_interest18(market, mark) if self.cfg.oi_source == "venue" else ch["oi"]
        if self.cfg.strict_observed_at and observed_at <= ch["latest_at"]:
            raise Refuse("observedAt %d is not after the registry's latest %d" % (observed_at, ch["latest_at"]))
        if self.cfg.mark_v2 and observed_at < ch["mark_at"]:
            raise Refuse("observedAt %d is before the oracle's markAt %d" % (observed_at, ch["mark_at"]))
        if self.cfg.mult_checks:
            check_corporate_action(ch)
        if self.cfg.sanity:
            check_mark_vs_feed(mark18, ch["feed_px18"], self.cfg.max_dev_bps,
                               ch["mult18"] if self.cfg.mult_checks else None)
            self.guard.check(vault, notional18, head_block, ch["notional"])
        return {"v": v, "notional18": notional18, "margin18": margin18, "mark18": mark18, "oi18": oi18,
                "batch": ch["batch"], "nonce": ch["nonce"]}

    def one(self, g, observed_at, deadline):
        """Pure signing, milliseconds: done after the timestamp is taken, so the whole 60s
        validity window is left for the client rather than spent on our own reads."""
        v = g["v"]
        vault, oracle = v["vault"], v["certOracle"]
        attest_sig = sign(self.pk, self.reg_domain, keccak(encode(
            ["bytes32", "address", "uint64", "uint256", "uint256", "uint256", "uint64", "uint64"],
            [self.attest_th, vault, g["batch"], g["notional18"], g["margin18"], g["oi18"], observed_at, deadline])))
        dom, th = self.oracle[oracle]
        out = {"symbol": v["symbol"], "vault": vault, "certOracle": oracle, "registry": self.registry,
               "batchId": g["batch"], "notional18": str(g["notional18"]), "margin18": str(g["margin18"]),
               "openInterest18": str(g["oi18"]), "markPx18": str(g["mark18"]), "markNonce": g["nonce"],
               "observedAt": observed_at, "deadline": deadline, "attestSig": attest_sig}
        if self.cfg.mark_v2:
            mark_deadline = observed_at + MARK_VALIDITY
            out["markSig"] = sign(self.pk, dom, mark_struct_hash(th, g["mark18"], g["nonce"], mark_deadline, observed_at))
            out.update(markSigVersion=2, markObservedAt=observed_at, markDeadline=mark_deadline)
        else:
            out["markSig"] = sign(self.pk, dom, mark_struct_hash(th, g["mark18"], g["nonce"], deadline))
        return out

    def refresh(self):
        global cache
        try:
            if self.cfg.mark_v2:
                # H-6: observedAt is WHEN THE MARKET DATA WAS READ. The slow per-account reads go
                # first; then the clock, then the one fast request that carries every mark and
                # open interest. The chain clock, capped by our own, taken BEFORE that request:
                # never later than the data, and never "in the future" to the contract. The
                # attestation shares it, which is no later than stack 4's post-read stamp.
                chain = self.chain_reads()
                with ThreadPoolExecutor(len(self.vaults)) as ex:
                    accts = list(ex.map(self.read_account, self.vaults))
                head_block, ts = self.head()
                observed_at = min(ts, int(time.time()))
                books = get("/api/v1/orderBookDetails")
            else:
                books = get("/api/v1/orderBookDetails")
                chain = self.chain_reads()
                with ThreadPoolExecutor(len(self.vaults)) as ex:
                    accts = list(ex.map(self.read_account, self.vaults))
                head_block, observed_at = self.head()
            markets = {int(m["market_id"]): m for m in books["order_book_details"]}
            deadline = observed_at + VALIDITY
            out, refused = [], []
            for v, acct in zip(self.vaults, accts):
                try:
                    g = self.compute(v, acct, markets, chain[v["vault"]], observed_at, head_block)
                    out.append(self.one(g, observed_at, deadline))
                    self.guard.accept(v["vault"], g["notional18"], head_block)
                except Refuse as e:
                    refused.append({"symbol": v["symbol"], "reason": str(e)[:200]})
                    log("REFUSED to sign %s: %s" % (v["symbol"], e))
            cache = {"generatedAt": int(time.time()), "attestations": out, "error": None, "refused": refused}
            log("signed %d vaults%s" % (len(out), (", refused %d" % len(refused)) if refused else ""))
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
            "refused": c.get("refused", []), "attestations": c["attestations"]}).encode())

    def do_HEAD(self):
        # Same status and headers as GET, no body - what monitors and the edge probe with.
        c = cache
        stale = c["generatedAt"] == 0 or int(time.time()) - c["generatedAt"] > VALIDITY
        self.send_response(503 if stale else 200)
        self.send_header("access-control-allow-origin", "*")
        self.send_header("content-type", "application/json")
        self.send_header("cache-control", "no-store")
        self.end_headers()

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

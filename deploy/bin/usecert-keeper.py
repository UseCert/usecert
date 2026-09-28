#!/usr/bin/env python3
"""UseCert hedge keeper: opens the hedge a keeper-mode vault asks for, then settles the mint.

WHY THIS EXISTS. On Robinhood Chain Lighter every order sent through the L1 contract is
reduce-only (venue record: code 21738, "invalid reduce only direction"), so a vault cannot open
its own hedge. In keeper mode (CertVault.enableKeeperHedging) a mint escrows collateral and emits

    HedgeRequested(uint256 indexed receiptId, uint256 base, uint8 side, uint256 limitPx18)

and this process: opens that position with an order signed by the vault account's API key,
confirms on the VENUE that the full size filled, and calls settleMint(receiptId, fillPx18) with
the price it actually filled at. Only then are certificates issued.

WHAT IT MUST NEVER DO, and how it avoids it:
  * Place the same hedge twice. State is journaled BEFORE the order is sent. On restart any
    receipt left mid-flight is NOT retried automatically; it is reported for a human, because
    the only way to know whether the first attempt filled is to look.
  * Settle a hedge that did not fill. Settlement waits for the venue's own position to grow by
    the requested size. A partial or absent fill is recorded and left unsettled - the user is
    refunded by the vault after the settle window, so a failure costs time, not principal.
  * Invent a fill price. fillPx18 is derived from the account's size and average entry before
    and after the order, which averages correctly across price levels.
  * Close anything. Closes are the vault's own on-chain reduce-only orders; this keeper only
    opens. An orphan (filled but unsettled) is reported, not auto-closed. STACK 5 is the one
    exception, because there the vault's keeper-mode stageRefund deliberately closes nothing: an
    orphan whose refund is staged on chain is closed by this keeper, reduce-only, for exactly
    the base it opened (see below).

It must run from a jurisdiction the venue permits; Lighter's API refuses order submission from
restricted regions (code 20558) and that is not to be routed around.

Usage:  usecert-keeper.py CONFIG.json            (loop)
        usecert-keeper.py CONFIG.json --once     (one pass, for testing)

KEYS. Stack 4 (the default): every send is made with the attester key (config "attester_pk" or
KEEPER_ATTESTER_PK), because the stack-4 vault accepts settleMint only from the oracle's attester.
Stack 5 ("stack": 5 in the config, or STACK=5; pre-audit H-4): settleMint and stageRefund are the
vault's SETTLER's, a key separate from the attester. The keeper then loads ONLY the settler key -
config "settler_pk", else KEEPER_SETTLER_PK, else the file named by config "settler_key_file" or
KEEPER_SETTLER_KEY_FILE (the hex key, alone) - and uses it for every send, the permissionless
recall and refund included. The attester key is never read in stack-5 mode: it is refused if
identical to the settler key and dropped from the environment so no cast child inherits it. At
start-up the settler is checked against the vault's "settler_getter" (default settler()(address);
"" skips the check) so a wrong key fails loudly instead of as reverted settlements.

STACK 5, OPTION A (every certificate is hedged with multiplier18() SHARES; nothing below runs in
a stack-4 keeper):
  * HedgeRequested's base is in share units and its limit is a share price, so an order is placed
    exactly as the event says - no conversion here.
  * receiptId 0 is a REHEDGE work order from the settler-only CertVault.rehedge(maxBase). It is
    filled exactly like a mint open (same limit, same fill timeout) and NOT settled: there is no
    receipt. The vault booked that base when it emitted the event, so a rehedge that does not
    fill leaves the ledger overstating the position - that is logged loudly and left for a human,
    never retried. Rehedges are journaled under "rehedges", keyed "<txHash>:<logIndex>" rather
    than by receipt, so several in one block or one transaction never collide; each is recorded
    as "queued" in the same write that advances next_block, so a crash can neither lose one nor,
    on a re-scan, place it twice.
  * Refund of an ORPHAN (a receipt whose hedge this keeper saw fill in full, but which it never
    managed to settle): stageRefund in keeper mode does not close anything on chain - it leaves
    that to the keeper, the only party that knows what it opened. Once the receipt reads staged on
    chain (which proves settleMint can no longer land), the keeper closes exactly
    floor(indicativeCerts x mintMult18(receiptId) / 1e18) shares, in venue units, with a
    reduce-only sell priced off the oracle's sharePx18 less close_price_band_bps - after checking
    that this is the very base it opened. Config "refund_close_orphans" (default true) turns it
    off. A receipt that filled nothing is refunded as before and has nothing to close.
  * Optional auto-rehedge, OFF unless config "auto_rehedge" is true: when a fresh attestation shows
    the vault under-hedged by at least rehedge_min_gap_usd AND rehedge_min_gap_bps (and by no more
    than rehedge_max_gap_bps - bigger than that is a split or a data fault, for a human), it calls
    rehedge(maxBase) with the settler key, sized to the gap and capped at rehedge_max_usd. It
    first reads the vault's own rebalance state (batch, lastOrderAt + venue lag, the 15-minute
    interval, the rolling budget) and sends nothing the vault would refuse, and it stands down
    while any mint is pending, any keeper order is unresolved, or the oracle reports a corporate
    action window. At most one attempt per rehedge_min_interval_sec.
"""
import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import lighter


# The Robinhood Chain RPC answers a request with no User-Agent with HTTP 403. cast sends one,
# which is why every cast call worked while the keeper's first RPC call did not.
UA = "usecert-keeper/1.0"


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *a, flush=True)


def _norm_key(k):
    k = (k or "").strip().lower()
    return k[2:] if k.startswith("0x") else k


def shares_base(certs18, mult18, size_dec):
    """Option A: `certs18` certificates (18 decimals) as the venue order they are hedged with -
    floor(certs x multiplier18 / 1e18) shares in venue units. The same arithmetic, and the same
    floor, as CertVault._toShares (Math.mulDiv(certs, m * 10**sizeDecimals, 1e36))."""
    return int(certs18) * int(mult18) * 10 ** int(size_dec) // 10 ** 36


def rehedge_key(tx_hash, log_index):
    """A receipt-0 work order's journal key: the log that carried it, never the receipt id."""
    return "%s:%d" % (str(tx_hash).lower(), int(log_index))


# client_order_index ranges, all below 2**40 (lighter-ops' range): receipts use their id; an
# orphan close 2**38 + id; a rehedge 2**39 + a value derived from its (txHash, logIndex).
CLOSE_COI_BASE = 1 << 38
REHEDGE_COI_BASE = 1 << 39


def rehedge_coi(tx_hash, log_index):
    return REHEDGE_COI_BASE + ((int(tx_hash, 16) << 8) + int(log_index)) % REHEDGE_COI_BASE


# Rehedge journal states that need no more work. Anything else (queued, in flight, or waiting
# for a human) blocks the auto-rehedge; a human marks a handled one "resolved".
REHEDGE_DONE = ("filled", "resolved")
# Receipt states with an order on the venue that is not yet settled or refunded.
RECEIPT_IN_FLIGHT = ("placing", "placed", "filled", "PLACED_UNCONFIRMED_needs_human",
                     "PARTIAL_needs_human", "FILLED_BUT_UNSETTLED_needs_human")
# Receipt states whose hedge filled IN FULL and was never settled: an orphan once the window ends.
ORPHAN = ("filled", "FILLED_BUT_UNSETTLED_needs_human")

SEL = {  # no-argument views, verified against keccak in deploy/tests/test_keeper_stack5.py
    "registry": "0x7b103999", "oracle": "0x7dc0d1d0", "solvency": "0x773c5049",
    "pendingMintCerts": "0x2f2f761d", "keeperHedging": "0x23a983f2",
    "lastRebalancedBatch": "0xb9e47400", "lastOrderAt": "0x3750e3d8",
    "lastRebalanceAt": "0x2cea13f9", "rebalanceBucket18": "0x8864b6bb",
    "REBALANCE_MIN_INTERVAL": "0x81724e55", "REBALANCE_VENUE_LAG": "0xe94864dc",
    "REBALANCE_DAILY_BUDGET_18": "0x0190f49c", "MAX_REBALANCE_NOTIONAL_18": "0x4e164ab8",
    "pxUnguarded": "0x62d484dd", "multiplier18": "0x05a3a104",
    "corporateActionWindow": "0x5548eb81", "sharePx18": "0x9aaee10d",
}
SEL_LATEST = "0x4a4aac1a"      # SolvencyRegistry.latest(address)


class Keeper:
    # Class defaults, so a Keeper built without __init__ (the tests) is a stack-4 keeper.
    stack = 4
    settler_pk = None
    attester_pk = None
    # Stack 5 / option A (see the module docstring). Class defaults so a test-built keeper has them.
    size_dec = 4
    fill_timeout = 180
    oracle = None
    refund_close_orphans = True
    close_price_band_bps = 500                  # CertVault.CLOSE_PRICE_BAND_BPS
    auto_rehedge = False
    rehedge_min_gap_usd = 250
    rehedge_min_gap_bps = 50
    rehedge_max_gap_bps = 2000
    rehedge_max_usd = 2000
    rehedge_min_interval = 3600
    rehedge_max_att_age = 300

    def __init__(self, cfg_path):
        with open(cfg_path) as f:
            c = json.load(f)
        self.rpc = c["rpc"]
        self.api = c["api"].rstrip("/")
        self.vault = c["vault"]
        self.market = int(c["market_index"])
        self.price_dec = int(c["price_decimals"])
        self.size_dec = int(c["size_decimals"])
        self.state_path = c["state_file"]
        self.fill_timeout = int(c.get("fill_timeout_sec", 180))
        # Only for vaults deployed with recallMarginUpTo (2026-09-26 and later).
        self.auto_recall = bool(c.get("auto_recall", False))
        self.settle_window = None                       # read from the vault on first use
        with open(c["api_key_file"]) as f:
            self.key = json.load(f)
        self.cast = c.get("cast", "cast")
        self.stack = int(c.get("stack", os.environ.get("STACK", "4")))
        self._load_keys(c)
        self._load_stack5(c)
        self.topic = self._cast("keccak", "HedgeRequested(uint256,uint256,uint8,uint256)").strip()
        self.state = self._load_state(c.get("start_block"))

    # ------------------------------------------------------------------ keys
    def _load_keys(self, c, env=None):
        env = os.environ if env is None else env
        if self.stack < 5:
            self.attester_pk = c["attester_pk"] if "attester_pk" in c else env["KEEPER_ATTESTER_PK"]
            if (c.get("settler_pk") or env.get("KEEPER_SETTLER_PK") or c.get("settler_key_file")
                    or env.get("KEEPER_SETTLER_KEY_FILE")):
                log("a settler key is configured but this is a stack-4 keeper: ignored "
                    "(the stack-4 vault settles only from the attester)")
            return
        # REMOTE SETTLER (Sermium M-03): the settler key lives on another host, which checks each
        # request against its own chain and venue reads before sending it. This host then holds
        # no key that can mint: every send goes through _cast's "send" branch to that host.
        self.settler_remote = c.get("settler_remote") or env.get("KEEPER_SETTLER_REMOTE")
        self.settler_ssh_key = c.get("settler_ssh_key") or env.get("KEEPER_SETTLER_SSH_KEY")
        if self.settler_remote:
            if c.get("settler_pk") or env.get("KEEPER_SETTLER_PK") or c.get("settler_key_file") \
                    or env.get("KEEPER_SETTLER_KEY_FILE"):
                raise SystemExit("stack 5: a remote settler AND a local settler key; keep the key off this host")
            if not self.settler_ssh_key:
                raise SystemExit("stack 5: KEEPER_SETTLER_REMOTE needs KEEPER_SETTLER_SSH_KEY")
            env.pop("KEEPER_ATTESTER_PK", None)
            self.settler_pk, self.attester_pk = None, None
            have = (json.loads(self._remote({"action": "whoami"})).get("settler") or "").lower()
            getter = c.get("settler_getter", "settler()(address)")
            if getter:
                want = self._cast("call", self.vault, getter, "--rpc-url", self.rpc).split()[0].lower()
                if want != have:
                    raise SystemExit("stack 5: the vault's settler is %s, the remote settler reports %s" % (want, have))
            log("settler: remote %s (%s); no settler key on this host" % (self.settler_remote, have))
            return
        pk = c.get("settler_pk") or env.get("KEEPER_SETTLER_PK")
        path = c.get("settler_key_file") or env.get("KEEPER_SETTLER_KEY_FILE")
        if not pk and path:
            with open(path) as f:
                pk = f.read().strip()
        if not pk:
            raise SystemExit("stack 5: no settler key (settler_pk, KEEPER_SETTLER_PK or KEEPER_SETTLER_KEY_FILE)")
        att = c.get("attester_pk") or env.get("KEEPER_ATTESTER_PK")
        if att and _norm_key(att) == _norm_key(pk):
            raise SystemExit("stack 5: the settler key IS the attester key; H-4 needs two keys")
        env.pop("KEEPER_ATTESTER_PK", None)
        self.settler_pk, self.attester_pk = pk, None
        getter = c.get("settler_getter", "settler()(address)")
        if getter:
            want = self._cast("call", self.vault, getter, "--rpc-url", self.rpc).split()[0].lower()
            have = self._cast("wallet", "address", "--private-key", pk).split()[0].lower()
            if want != have:
                raise SystemExit("stack 5: the vault's settler is %s, the settler key derives %s" % (want, have))

    def _load_stack5(self, c):
        """Option A settings. Read in every stack and used only in stack 5."""
        self.oracle = c.get("oracle") or None             # else read from the vault on first use
        self.refund_close_orphans = bool(c.get("refund_close_orphans", True))
        self.close_price_band_bps = int(c.get("close_price_band_bps", 500))
        self.auto_rehedge = bool(c.get("auto_rehedge", False))
        self.rehedge_min_gap_usd = float(c.get("rehedge_min_gap_usd", 250))
        self.rehedge_min_gap_bps = int(c.get("rehedge_min_gap_bps", 50))
        self.rehedge_max_gap_bps = int(c.get("rehedge_max_gap_bps", 2000))
        self.rehedge_max_usd = float(c.get("rehedge_max_usd", 2000))
        self.rehedge_min_interval = int(c.get("rehedge_min_interval_sec", 3600))
        self.rehedge_max_att_age = int(c.get("rehedge_max_attestation_age_sec", 300))
        if not 0 < self.close_price_band_bps < 10_000:
            raise SystemExit("close_price_band_bps must be in (0, 10000)")
        if self.rehedge_min_interval < 900:
            raise SystemExit("rehedge_min_interval_sec below the vault's REBALANCE_MIN_INTERVAL (900)")
        if not 0 < self.rehedge_min_gap_bps < self.rehedge_max_gap_bps:
            raise SystemExit("need 0 < rehedge_min_gap_bps < rehedge_max_gap_bps")
        if self.rehedge_max_usd <= 0 or self.rehedge_min_gap_usd < 0:
            raise SystemExit("rehedge_max_usd must be positive and rehedge_min_gap_usd non-negative")

    def _key(self, purpose):
        """The key a send is made with. Stack 5: the settler, for everything; the attester key is
        not even loaded. Stack 4: the attester, as always."""
        if self.stack >= 5:
            if getattr(self, "settler_remote", None):
                return "REMOTE"                      # never used: _cast routes the send remotely
            if not self.settler_pk:
                raise RuntimeError("stack 5 keeper has no settler key for %s" % purpose)
            return self.settler_pk
        return self.attester_pk

    # ------------------------------------------------------------------ plumbing
    def _remote(self, req):
        """One request to the remote settler over its forced-command ssh key; its JSON answer."""
        r = subprocess.run(["ssh", "-i", self.settler_ssh_key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", self.settler_remote],
                           input=json.dumps(req), capture_output=True, text=True, timeout=200)
        out = (r.stdout or "").strip().splitlines()
        if not out:
            raise RuntimeError("remote settler: no answer (ssh exit %d: %s)" % (r.returncode, (r.stderr or "").strip()[:200]))
        return out[-1]

    def _remote_send(self, args):
        """cast-style `send VAULT SIG ARG... --flags` through the remote settler; a cast-like
        answer ("status 1" + "transactionHash"), so every caller reads it as it reads cast's."""
        vault, sig = args[1], args[2]
        pos = []
        for a in args[3:]:
            if str(a).startswith("--"):
                break
            pos.append(str(a))
        ans = json.loads(self._remote({"vault": vault, "sig": sig, "args": pos}))
        if ans.get("status") != 1:
            log("remote settler refused %s(%s): %s" % (sig.split("(")[0], ",".join(pos), ans.get("reason", "?")))
            return "status 0 (refused)\ntransactionHash %s\n" % ans.get("tx", "?")
        return "status 1 (success)\ntransactionHash %s\n" % ans["tx"]

    def _cast(self, *args):
        if args and args[0] == "send" and getattr(self, "settler_remote", None):
            return self._remote_send(args)
        r = subprocess.run([self.cast, *args], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError("cast %s: %s" % (args[0], (r.stderr or r.stdout).strip()[:300]))
        return r.stdout

    @staticmethod
    def _http(req):
        """urlopen with backoff on the failures that are the SERVER's, not ours: 429 and 5xx from
        the chain RPC or the venue, and network errors. Six keepers share one IP and the RPC
        rate-limits it; one 429 mid-hedge used to abort handle() after the order was placed."""
        delay = 2
        for attempt in range(6):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code != 429 and e.code < 500 or attempt == 5:
                    raise
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if attempt == 5:
                    raise
            time.sleep(delay)
            delay = min(delay * 2, 30)

    def _rpc(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        out = self._http(urllib.request.Request(self.rpc, body, {"Content-Type": "application/json",
                                                                 "User-Agent": UA}))
        if "error" in out:
            raise RuntimeError("%s: %s" % (method, out["error"]))
        return out["result"]

    def _view(self, selector):
        """A no-argument uint256 view on the vault, as one eth_call with _http's backoff."""
        return int(self._rpc("eth_call", [{"to": self.vault, "data": selector}, "latest"]), 16)

    def _words(self, to, data):
        """An eth_call on `to` returning static words, as ints."""
        out = self._rpc("eth_call", [{"to": to, "data": data}, "latest"])[2:]
        return [int(out[i:i + 64], 16) for i in range(0, len(out), 64)]

    def _oracle(self):
        if not self.oracle:
            self.oracle = "0x" + "%040x" % self._words(self.vault, SEL["oracle"])[0]
        return self.oracle

    def _get(self, path):
        return self._http(urllib.request.Request(self.api + path, headers={"User-Agent": UA}))

    def _load_state(self, start_block):
        if os.path.exists(self.state_path):
            with open(self.state_path) as f:
                return json.load(f)
        head = int(self._rpc("eth_blockNumber", []), 16)
        return {"next_block": int(start_block) if start_block is not None else head, "receipts": {}}

    def _save(self):
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=1)
        os.replace(tmp, self.state_path)

    # ------------------------------------------------------------------ venue reads
    def position(self):
        """(signed base units, avg entry price) of this market on the vault's venue account."""
        d = self._get("/api/v1/account?by=l1_address&value=" + self.vault)
        a = d["accounts"][0]
        for p in a.get("positions", []):
            if int(p.get("market_id", -1)) == self.market:
                size = round(float(p.get("position", "0")) * 10 ** self.size_dec)
                sign = int(p.get("sign", 1) or 1)
                return sign * size, float(p.get("avg_entry_price") or 0)
        return 0, 0.0

    # ------------------------------------------------------------------ chain reads
    def receipt_open(self, rid):
        out = self._cast("call", self.vault,
                         "mintReceipts(uint256)(address,uint256,bool,uint256,uint64,bool,uint256)",
                         str(rid), "--rpc-url", self.rpc).split("\n")
        # An absent receipt reads back as all zeros - settled=false, refundStaged=false - which
        # would look "open". The user field is the only thing that distinguishes it.
        exists = int(out[0].strip(), 16) != 0
        return exists and out[2].strip() == "false" and out[5].strip() == "false"

    def new_requests(self):
        head = int(self._rpc("eth_blockNumber", []), 16)
        frm = self.state["next_block"]
        found = []
        while frm <= head:
            to = min(frm + 5000, head)
            logs = self._rpc("eth_getLogs", [{"address": self.vault, "topics": [self.topic],
                                              "fromBlock": hex(frm), "toBlock": hex(to)}])
            for lg in logs:
                rid = int(lg["topics"][1], 16)
                data = lg["data"][2:]
                base = int(data[0:64], 16)
                side = int(data[64:128], 16)
                limit_px18 = int(data[128:192], 16)
                found.append((rid, base, side, limit_px18, lg["transactionHash"], int(lg["logIndex"], 16)))
            frm = to + 1
        self.state["next_block"] = head + 1
        return found

    # ------------------------------------------------------------------ the work
    async def open(self, base, side, limit_px18, coi, reduce_only=False):
        c = lighter.SignerClient(url=self.api, account_index=self.key["account_index"],
                                 api_private_keys={self.key["api_key_index"]: self.key["private"]})
        try:
            tick = limit_px18 * 10 ** self.price_dec // 10 ** 18
            # Passed only for a close, so an open is sent exactly as it always was.
            extra = {"reduce_only": True} if reduce_only else {}
            tx, resp, err = await c.create_market_order(market_index=self.market, client_order_index=coi,
                                                        base_amount=base, avg_execution_price=tick,
                                                        is_ask=bool(side), **extra)
            if err is not None:
                raise RuntimeError(str(err)[:300])
            return str(getattr(resp, "tx_hash", resp))[:200]
        finally:
            await c.close()

    def settle(self, rid, fill_px18):
        out = self._cast("send", self.vault, "settleMint(uint256,uint256)", str(rid), str(fill_px18),
                         "--gas-limit", "1500000", "--private-key", self._key("settleMint"), "--rpc-url", self.rpc)
        ok = any(l.split()[:2] == ["status", "1"] for l in out.split("\n") if l.strip())
        h = next((l.split()[1] for l in out.split("\n") if l.startswith("transactionHash")), "?")
        if not ok:
            raise RuntimeError("settleMint reverted: " + h)
        return h

    def handle(self, rid, base, side, limit_px18):
        key = str(rid)
        rec = self.state["receipts"].get(key)
        if rec is not None and rec["status"] in ("filled", "FILLED_BUT_UNSETTLED_needs_human") \
                and "fill_px18" in rec:
            # The one mid-flight state that is SAFE to resume: the venue already confirmed the full
            # fill and its price is journaled, so finishing means settling, never ordering again.
            self._settle_journaled(rid, key, int(rec["fill_px18"]))
            return
        if rec is not None:
            if rec["status"] not in ("settled", "unfilled_left_for_refund"):
                log("receipt %d is '%s' from an earlier run - NOT retrying; needs a human" % (rid, rec["status"]))
            return
        if not self.receipt_open(rid):
            self.state["receipts"][key] = {"status": "already_closed_onchain"}
            self._save()
            return
        if side != 0:
            log("receipt %d asks for side %d; this keeper only opens buys - skipping" % (rid, side))
            self.state["receipts"][key] = {"status": "unsupported_side"}
            self._save()
            return

        res, filled, fill_px = self._fill(self.state["receipts"], key, "receipt %d" % rid,
                                          base, side, limit_px18, coi=rid)
        if res in ("refused", "unconfirmed"):
            return
        if res == "short":
            status = "unfilled_left_for_refund" if filled == 0 else "PARTIAL_needs_human"
            self.state["receipts"][key].update(status=status, filled=filled)
            self._save()
            log("receipt %d: filled %d of %d -> %s" % (rid, filled, base, status))
            return

        fill_px18 = int(round(fill_px * 10 ** 6)) * 10 ** 12
        self.state["receipts"][key].update(status="filled", filled=filled, fill_px=fill_px,
                                           fill_px18=str(fill_px18))
        self._save()
        log("receipt %d: filled %d at %.4f" % (rid, filled, fill_px))
        self._settle_journaled(rid, key, fill_px18)

    def _fill(self, box, key, label, base, side, limit_px18, coi, reduce_only=False):
        """Place one order and confirm it on the venue: the whole of what handle() always did
        between "is there work" and "settle", shared by mint opens, rehedges and orphan closes.

        Journaled in box[key] (created, or updated in place) BEFORE the order leaves, so a crash
        cannot lead to a second order. Returns (result, filled, fill_px):
          "refused"     the SDK refused it before the book - nothing opened (status order_refused)
          "unconfirmed" no venue read succeeded after it left (status PLACED_UNCONFIRMED_needs_human)
          "short"       fewer than `base` units moved within fill_timeout (caller sets the status)
          "filled"      the full `base` moved; fill_px is the average price of the units it ADDED
                        (an open's only - a close does not move the average entry, so it is None)
        `side` 0 buys (the position must grow by base), 1 sells (it must shrink by base)."""
        pos0, entry0 = self.position()
        # WRITE-AHEAD: journal before the order leaves, so a crash cannot lead to a second order.
        box.setdefault(key, {}).update(status="placing", base=base, limit_px18=str(limit_px18),
                                       pos_before=pos0, entry_before=entry0, at=int(time.time()))
        rec = box[key]
        self._save()

        try:
            if reduce_only:
                sent = asyncio.run(self.open(base, side, limit_px18, coi=coi, reduce_only=True))
            else:
                sent = asyncio.run(self.open(base, side, limit_px18, coi=coi))
        except Exception as e:                                       # noqa: BLE001
            # Refused before reaching the book (e.g. jurisdiction, auth, nonce): nothing opened.
            rec.update(status="order_refused", error=str(e)[:300])
            self._save()
            log("%s: order refused: %s" % (label, e))
            return "refused", 0, None
        rec.update(status="placed", sent=sent)
        self._save()
        log("%s: order sent for %d base, cap %.4f" % (label, base, limit_px18 / 1e18))

        sign = -1 if side else 1
        deadline = time.time() + self.fill_timeout
        pos1, entry1 = pos0, entry0
        seen = False
        while time.time() < deadline:
            time.sleep(5)
            try:
                pos1, entry1 = self.position()
            except Exception as e:                                   # noqa: BLE001
                log("%s: position read failed, still polling: %s" % (label, e))
                continue
            seen = True
            if (pos1 - pos0) * sign >= base:
                break
        if not seen:
            # Not one read succeeded after the order left. "Unfilled" would be a guess, and the
            # wrong guess refunds a user while an unsettled hedge stays open.
            rec.update(status="PLACED_UNCONFIRMED_needs_human")
            self._save()
            log("%s: order placed but the venue could not be read - needs a human" % label)
            return "unconfirmed", 0, None
        filled = (pos1 - pos0) * sign
        if filled > 0 and self.stack >= 5:
            self.state["last_fill_at"] = int(time.time())    # the auto-rehedge waits past it
        if filled < base:
            return "short", filled, None
        if side:
            return "filled", filled, None
        # Average price of exactly the units this order added, from the account's own books.
        notional1 = pos1 * entry1
        notional0 = pos0 * entry0
        return "filled", filled, (notional1 - notional0) / filled

    def _settle_journaled(self, rid, key, fill_px18):
        """Settle a receipt whose full fill the venue has confirmed. Retried, because settleMint is
        safe to resend: a second attempt after one that actually landed reverts, and the receipt
        then reads closed on chain, which is the proof it settled."""
        err = None
        for attempt in range(3):
            try:
                h = self.settle(rid, fill_px18)
                break
            except Exception as e:                                   # noqa: BLE001
                err = e
                time.sleep(10)
                try:
                    if not self.receipt_open(rid):
                        h = "(closed on chain after: %s)" % str(e)[:80]
                        break
                except Exception:                                    # noqa: BLE001
                    pass
        else:
            self.state["receipts"][key].update(status="FILLED_BUT_UNSETTLED_needs_human", error=str(err)[:300])
            self._save()
            log("receipt %d: FILLED but settle failed 3 times (retried next pass): %s" % (rid, err))
            return
        self.state["receipts"][key].update(status="settled", settle_tx=h)
        self._save()
        log("receipt %d: settled %s" % (rid, h))

    # ------------------------------------------------------------------ stack 5: rehedges
    def queue_rehedge(self, base, side, limit_px18, tx, log_index):
        """Journal a receipt-0 work order as "queued". Called before next_block is saved, so it is
        in the same write; a re-scan of the same log finds the key and adds nothing."""
        box = self.state.setdefault("rehedges", {})
        key = rehedge_key(tx, log_index)
        if key in box:
            return False
        box[key] = {"status": "queued", "base": base, "side": side, "limit_px18": str(limit_px18),
                    "tx": tx, "log_index": int(log_index), "seen_at": int(time.time()),
                    "seq": len(box)}                          # chain order: getLogs returns it
        log("rehedge %s: work order for %d base, cap %.4f" % (key, base, limit_px18 / 1e18))
        return True

    def process_rehedges(self):
        box = self.state.get("rehedges", {})
        # Everything here is synchronous, so an order in flight at the start of a pass was left by
        # a run that died with it outstanding: whether it filled can only be seen on the venue.
        for key, rec in box.items():
            if rec.get("status") in ("placing", "placed"):
                rec["status"] = "INTERRUPTED_needs_human"
                self._save()
                log("rehedge %s: interrupted mid-order by an earlier run - NOT retrying; needs a human" % key)
        for key in sorted((k for k, r in box.items() if r.get("status") == "queued"),
                          key=lambda k: (box[k].get("seq", 0), k)):
            self.handle_rehedge(key)

    def handle_rehedge(self, key):
        """Fill a rehedge exactly as a mint open is filled - same limit, same fill timeout - and
        settle nothing: receipt 0 has no receipt. Never retried: the vault booked the base when it
        emitted the order, so anything short of a full fill is a ledger a human must look at."""
        box = self.state["rehedges"]
        rec = box[key]
        base, side, limit_px18 = int(rec["base"]), int(rec["side"]), int(rec["limit_px18"])
        label = "rehedge %s" % key
        if side != 0:
            rec.update(status="UNSUPPORTED_SIDE_needs_human")
            self._save()
            log("%s: asks for side %d; this keeper only opens buys - the vault booked %d base that "
                "nothing will open: ledger overstated, needs a human" % (label, side, base))
            return
        res, filled, fill_px = self._fill(box, key, label, base, side, limit_px18,
                                          coi=rehedge_coi(rec["tx"], rec["log_index"]))
        if res == "filled":
            rec.update(status="filled", filled=filled, fill_px=fill_px)
            self._save()
            log("%s: filled %d at %.4f (receipt 0: nothing to settle)" % (label, filled, fill_px))
            return
        if res == "short":
            rec.update(status="UNFILLED_needs_human" if filled == 0 else "PARTIAL_needs_human", filled=filled)
            self._save()
        log("%s: %s after %d of %d base - the vault booked all %d at rehedge(), so its ledger now "
            "OVERSTATES the venue position by up to %d; NOT retried, needs a human"
            % (label, rec["status"], filled, base, base, base - filled))

    # ------------------------------------------------------------------ stack 5: auto-rehedge
    def maybe_auto_rehedge(self):
        """Top up an under-hedged vault with rehedge(maxBase), when enabled and only when the vault
        itself would accept it. Returns what it did, for the log and the tests."""
        if self.stack < 5 or not self.auto_rehedge:
            return "off"
        now = time.time()
        if now - self.state.get("last_rehedge_try", 0) < self.rehedge_min_interval:
            return "spacing"
        # Our own unresolved work first: an order not yet confirmed is not in any attestation, and
        # one a human must look at may mean the ledger is already wrong.
        held = [("rehedge " + k, r.get("status")) for k, r in self.state.get("rehedges", {}).items()
                if r.get("status") not in REHEDGE_DONE]
        held += [("receipt " + k, r.get("status")) for k, r in self.state["receipts"].items()
                 if r.get("status") in RECEIPT_IN_FLIGHT]
        if held:
            if any("needs_human" in (st or "") for _, st in held):
                self.state["last_rehedge_try"] = now      # say so once per interval, not every pass
                self._save()
                log("auto-rehedge held: %s is '%s'" % held[0])
            return "keeper work unresolved"
        v = lambda name: self._words(self.vault, SEL[name])[0]
        if not v("keeperHedging"):
            return "not keeper mode"
        # A pending mint counts as owed but its hedge may not be attested yet: it would read as a
        # gap, and a rehedge of it would double the hedge once the keeper fills it.
        if v("pendingMintCerts"):
            return "mint pending"
        reg = "0x%040x" % v("registry")
        att = self._words(reg, SEL_LATEST + "%064x" % int(self.vault, 16))
        notional18, batch, attested_at = att[0], att[3], att[4]
        if batch <= v("lastRebalancedBatch"):
            return "batch already used"
        if attested_at <= max(v("lastOrderAt"), int(self.state.get("last_fill_at", 0))) + v("REBALANCE_VENUE_LAG"):
            return "attestation predates the last order"
        if now - attested_at > self.rehedge_max_att_age:
            return "attestation too old"
        last_at = v("lastRebalanceAt")
        if now < last_at + v("REBALANCE_MIN_INTERVAL") + 30:
            return "vault interval"
        orc = self._oracle()
        if self._words(orc, SEL["corporateActionWindow"])[0]:
            return "corporate action window"
        px18 = self._words(orc, SEL["pxUnguarded"])[0]
        m = self._words(orc, SEL["multiplier18"])[0]
        supply = self._words(self.vault, SEL["solvency"])[0]
        if px18 == 0 or m == 0:
            return "no price"
        required = supply * px18 // 10 ** 18
        if notional18 >= required:
            return "not under-hedged"
        gap = required - notional18
        gap_bps = gap * 10_000 // required
        if gap < int(self.rehedge_min_gap_usd * 10 ** 6) * 10 ** 12 or gap_bps < self.rehedge_min_gap_bps:
            return "below threshold"
        self.state["last_rehedge_try"] = now
        if gap_bps > self.rehedge_max_gap_bps:
            self._save()
            log("auto-rehedge: under-hedged by %d bps ($%.2f) - beyond rehedge_max_gap_bps %d, not "
                "automatic (a split the venue did not rescale, or bad data): needs a human"
                % (gap_bps, gap / 1e18, self.rehedge_max_gap_bps))
            return "gap too large"
        half = v("REBALANCE_DAILY_BUDGET_18") // 2
        level = max(0, v("rebalanceBucket18") - max(0, int(now) - last_at) * half // 86400)
        room = half - level
        if room <= 0:
            self._save()
            return "budget spent"
        g = min(gap, v("MAX_REBALANCE_NOTIONAL_18"), room, int(self.rehedge_max_usd * 10 ** 6) * 10 ** 12)
        max_base = shares_base(g * 10 ** 18 // px18, m, self.size_dec)
        if max_base == 0:
            self._save()
            return "dust"
        try:
            out = self._cast("send", self.vault, "rehedge(uint256)", str(max_base), "--gas-limit", "1500000",
                             "--private-key", self._key("rehedge"), "--rpc-url", self.rpc)
            sent = any(l.split()[:2] == ["status", "1"] for l in out.splitlines())
        except RuntimeError as e:
            sent, out = False, str(e)
        self._save()
        log("auto-rehedge: under-hedged by %d bps ($%.2f, batch %d) -> rehedge(%d) %s"
            % (gap_bps, gap / 1e18, batch, max_base, "sent" if sent else "REVERTED: " + out[:160]))
        return "sent" if sent else "reverted"

    # ------------------------------------------------------------------ stack 5: orphan closes
    def _close_orphan(self, rid, rec, indicative):
        """Close exactly what this receipt's hedge opened: indicativeCerts x mintMult18 shares,
        floored to venue units - checked against the base the keeper journaled when it opened.
        Only called once the receipt reads refundStaged on chain. One attempt, write-ahead."""
        if not self.refund_close_orphans:
            log("receipt %d: orphan hedge left open (refund_close_orphans is off) - needs a human" % rid)
            return
        m = int(self._cast("call", self.vault, "mintMult18(uint256)(uint256)", str(rid),
                           "--rpc-url", self.rpc).split()[0])
        want = shares_base(indicative, m, self.size_dec)
        opened, asked = int(rec.get("filled", -1)), int(rec.get("base", -1))
        if want <= 0 or want != opened or want != asked:
            rec["close"] = {"status": "CLOSE_MISMATCH_needs_human", "want": want, "opened": opened,
                            "asked": asked, "mult18": str(m)}
            self._save()
            log("receipt %d: orphan close of %d (indicativeCerts %d x M %d) does not match the %d opened "
                "- not closing; needs a human" % (rid, want, indicative, m, opened))
            return
        limit = self._words(self._oracle(), SEL["sharePx18"])[0] * (10_000 - self.close_price_band_bps) // 10_000
        if limit <= 0:
            rec["close"] = {"status": "CLOSE_NO_PRICE_needs_human", "want": want, "mult18": str(m)}
            self._save()
            log("receipt %d: no share price for the orphan close - needs a human" % rid)
            return
        label = "receipt %d close" % rid
        res, filled, _ = self._fill(rec, "close", label, want, 1, limit, coi=CLOSE_COI_BASE + rid, reduce_only=True)
        c = rec["close"]
        c["mult18"] = str(m)
        if res == "filled":
            c.update(status="closed", filled=filled)
            log("%s: closed %d shares" % (label, filled))
        elif res == "short":
            c.update(status="CLOSE_UNFILLED_needs_human" if filled == 0 else "CLOSE_PARTIAL_needs_human", filled=filled)
            log("%s: closed %d of %d - the orphan is still open; needs a human" % (label, filled, want))
        else:
            log("%s: %s - needs a human" % (label, c["status"]))
        self._save()

    def _refund_orphan(self, rid, rec, out, send, ok):
        """maybe_refund for a receipt whose hedge filled and was never settled (stack 5)."""
        escrow, settled = int(out[1].split()[0]), out[2].strip() == "true"
        requested_at, staged = int(out[4].split()[0]), out[5].strip() == "true"
        indicative = int(out[6].split()[0])
        rec["orphan"] = True
        if settled and not staged:
            # Only settleMint closes a receipt without staging it: it settled after all.
            rec.update(status="settled")
            self._save()
            log("receipt %d: reads settled on chain - not an orphan, nothing to close" % rid)
            return
        if not staged:
            if time.time() <= requested_at + self.settle_window + 30:
                return
            rec["refund_try"] = time.time()
            o = send("stageRefund(uint256)", str(rid))
            if not ok(o):
                self._save()
                log("receipt %d (orphan): stageRefund REVERTED" % rid)
                return
            rec.update(status="refund_staged")
            self._save()
            log("receipt %d (orphan): stageRefund ok" % rid)
        rec["refund_try"] = time.time()
        if "close" not in rec:
            self._close_orphan(rid, rec, indicative)
        if settled:
            rec.update(status="refunded")
            self._save()
            return
        self._pay_refund(rid, rec, escrow, send, ok)

    def maybe_recall(self):
        """Bring margin home for redemptions waiting on it, sized to what the venue really holds.

        The vault's books do not see trading P&L, and Lighter refuses a withdrawal larger than the
        account's balance ENTIRELY (21304). So the request is capped at the available balance read
        off the venue, via recallMarginUpTo. One request in flight at a time: a withdrawal takes
        minutes to land, and repeating it would only queue duplicates against the same balance.
        """
        if not self.auto_recall:
            return
        # This runs on EVERY pass of all six keepers, and almost always finds nothing owed. It
        # used to be two `cast call`s per pass; it is now one eth_call through _http's backoff,
        # and the second read only happens when something is owed. Six keepers share one IP
        # and the RPC answers 429 under load (ROADMAP 6.24).
        owed = self._view("0xa2900772")                              # totalOwedOutstanding()
        if owed == 0:
            return
        have = self._view("0xf2a2bf59")                              # hotBuffer()
        if owed <= have:
            return
        if time.time() - self.state.get("last_recall", 0) < 600:
            return
        a = self._get("/api/v1/account?by=l1_address&value=" + self.vault)["accounts"][0]
        avail = int(float(a.get("available_balance") or 0) * 10 ** 6)
        # Ask for the shortfall and no more. The vault's marginPendingRecall is not cleared by
        # Lighter's direct payouts (they bypass the pending balance _sweepPending reads), so after
        # the first redemption it overstates, and a cap of the whole available balance would pull
        # the free margin behind every OTHER holder's hedge down to bare initial margin.
        cap = min(avail, owed - have)
        if cap == 0:
            return
        out = self._cast("send", self.vault, "recallMarginUpTo(uint256)", str(cap),
                         "--gas-limit", "1500000", "--private-key", self._key("recallMarginUpTo"), "--rpc-url", self.rpc)
        self.state["last_recall"] = time.time()
        self._save()
        log("recall: owed %d, vault holds %d, venue available %d -> recallMarginUpTo(%d) sent (%s)"
            % (owed, have, avail, cap, "ok" if any(l.split()[:2] == ["status", "1"] for l in out.splitlines()) else "REVERTED"))

    def maybe_refund(self):
        """Give back the escrow of a mint whose hedge never filled, without the holder asking.

        stageRefund and refundMint are permissionless and refundMint pays r.user, never the
        caller, so running them here costs the keeper gas and cannot redirect a unit. Only
        receipts this keeper itself saw fill ZERO on the venue are touched
        (unfilled_left_for_refund); a partial or unconfirmed fill stays for a human, because
        refunding it would leave a hedge open with nothing behind it. The contract enforces the
        settle window; this waits for it rather than spending gas on a certain revert.

        requestMint posted part of the escrow to the venue, so refundMint can revert
        RefundAwaitingSettlement until that share is home. stageRefund moves it into
        marginPendingRecall; this then asks for the shortfall with recallMarginUpTo, capped at what
        the venue holds, on the same 600 s spacing as maybe_recall, and retries the refund later.
        """
        want = ("unfilled_left_for_refund", "refund_staged")
        if self.stack >= 5 and self.refund_close_orphans:
            want += ORPHAN
        todo = [(k, r) for k, r in self.state["receipts"].items()
                if r.get("status") in want
                and time.time() - r.get("refund_try", 0) >= 120]
        if not todo:
            return
        if self.settle_window is None:
            self.settle_window = int(self._cast("call", self.vault, "settleWindow()(uint256)", "--rpc-url", self.rpc).split()[0])
        def send(*args):
            # _cast raises when cast exits non-zero, which a reverted send does. Here a revert is
            # an expected "not yet" (window, funding), so it is reported as a failed send.
            try:
                return self._cast("send", self.vault, *args, "--gas-limit", "1500000",
                                  "--private-key", self._key(args[0]), "--rpc-url", self.rpc)
            except RuntimeError as e:
                log("send %s failed: %s" % (args[0], str(e)[:200]))
                return ""
        ok = lambda out: any(l.split()[:2] == ["status", "1"] for l in out.splitlines())
        for key, rec in todo:
            rid = int(key)
            out = self._cast("call", self.vault,
                             "mintReceipts(uint256)(address,uint256,bool,uint256,uint64,bool,uint256)",
                             str(rid), "--rpc-url", self.rpc).split("\n")
            if self.stack >= 5 and (rec.get("orphan") or rec.get("status") in ORPHAN):
                self._refund_orphan(rid, rec, out, send, ok)
                continue
            escrow, settled = int(out[1].split()[0]), out[2].strip() == "true"
            requested_at, staged = int(out[4].split()[0]), out[5].strip() == "true"
            if settled:
                rec.update(status="refunded")        # by the holder, or by an earlier run of this
                self._save()
                continue
            if time.time() <= requested_at + self.settle_window + 30:
                continue
            rec["refund_try"] = time.time()
            if not staged:
                o = send("stageRefund(uint256)", str(rid))
                rec.update(status="refund_staged" if ok(o) else rec["status"])
                self._save()
                log("receipt %d: stageRefund %s" % (rid, "ok" if ok(o) else "REVERTED"))
                if not ok(o):
                    continue
            self._pay_refund(rid, rec, escrow, send, ok)

    def _pay_refund(self, rid, rec, escrow, send, ok):
        """refundMint once the vault holds the escrow; until then, recall the shortfall."""
        def u(sig):
            return int(self._cast("call", self.vault, sig, "--rpc-url", self.rpc).split()[0])
        have, owed = u("hotBuffer()(uint256)"), u("totalOwedOutstanding()(uint256)")
        if have < escrow + owed:
            if time.time() - self.state.get("last_recall", 0) >= 600:
                a = self._get("/api/v1/account?by=l1_address&value=" + self.vault)["accounts"][0]
                cap = min(int(float(a.get("available_balance") or 0) * 10 ** 6), escrow + owed - have)
                if cap > 0:
                    o = send("recallMarginUpTo(uint256)", str(cap))
                    self.state["last_recall"] = time.time()
                    log("receipt %d: refund of %d needs %d more at the vault -> recallMarginUpTo(%d) %s"
                        % (rid, escrow, escrow + owed - have, cap, "ok" if ok(o) else "REVERTED"))
            self._save()
            return
        o = send("refundMint(uint256)", str(rid))
        if ok(o):
            rec.update(status="refunded")
        self._save()
        log("receipt %d: refundMint(%d to the holder) %s" % (rid, escrow, "ok" if ok(o) else "REVERTED, retrying later"))

    def run_once(self):
        reqs = self.new_requests()
        if self.stack >= 5:
            # In the same write that advances next_block: a rehedge can be neither lost nor doubled.
            for rid, base, side, limit_px18, tx, li in reqs:
                if rid == 0:
                    self.queue_rehedge(base, side, limit_px18, tx, li)
        self._save()
        for rid, base, side, limit_px18, _tx, _li in reqs:
            if rid == 0 and self.stack >= 5:
                continue
            self.handle(rid, base, side, limit_px18)
        if self.stack >= 5:
            self.process_rehedges()
        self.maybe_recall()
        self.maybe_refund()
        if self.stack >= 5:
            self.maybe_auto_rehedge()


def main():
    k = Keeper(sys.argv[1])
    log("keeper up: vault %s market %d account %d from block %d, stack %d, sends with the %s key"
        % (k.vault, k.market, k.key["account_index"], k.state["next_block"], k.stack,
           "settler" if k.stack >= 5 else "attester"))
    if k.stack >= 5:
        log("stack 5: rehedge orders filled, orphan closes on refund %s, auto-rehedge %s"
            % ("on" if k.refund_close_orphans else "OFF", "ON" if k.auto_rehedge else "off"))
    if "--once" in sys.argv:
        k.run_once()
        return
    while True:
        try:
            k.run_once()
        except Exception as e:                                       # noqa: BLE001
            log("pass failed:", e)
        time.sleep(10)


if __name__ == "__main__":
    main()

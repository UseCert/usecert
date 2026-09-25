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
    opens. An orphan (filled but unsettled) is reported, not auto-closed.

It must run from a jurisdiction the venue permits; Lighter's API refuses order submission from
restricted regions (code 20558) and that is not to be routed around.

Usage:  usecert-keeper.py CONFIG.json            (loop)
        usecert-keeper.py CONFIG.json --once     (one pass, for testing)
"""
import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.request

import lighter


# The Robinhood Chain RPC answers a request with no User-Agent with HTTP 403. cast sends one,
# which is why every cast call worked while the keeper's first RPC call did not.
UA = "usecert-keeper/1.0"


def log(*a):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *a, flush=True)


class Keeper:
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
        with open(c["api_key_file"]) as f:
            self.key = json.load(f)
        self.attester_pk = c["attester_pk"] if "attester_pk" in c else os.environ["KEEPER_ATTESTER_PK"]
        self.cast = c.get("cast", "cast")
        self.topic = self._cast("keccak", "HedgeRequested(uint256,uint256,uint8,uint256)").strip()
        self.state = self._load_state(c.get("start_block"))

    # ------------------------------------------------------------------ plumbing
    def _cast(self, *args):
        r = subprocess.run([self.cast, *args], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError("cast %s: %s" % (args[0], (r.stderr or r.stdout).strip()[:300]))
        return r.stdout

    def _rpc(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.rpc, body, {"Content-Type": "application/json", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=30) as r:
            out = json.load(r)
        if "error" in out:
            raise RuntimeError("%s: %s" % (method, out["error"]))
        return out["result"]

    def _get(self, path):
        req = urllib.request.Request(self.api + path, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

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
                found.append((rid, base, side, limit_px18, lg["transactionHash"]))
            frm = to + 1
        self.state["next_block"] = head + 1
        return found

    # ------------------------------------------------------------------ the work
    async def open(self, base, side, limit_px18, coi):
        c = lighter.SignerClient(url=self.api, account_index=self.key["account_index"],
                                 api_private_keys={self.key["api_key_index"]: self.key["private"]})
        try:
            tick = limit_px18 * 10 ** self.price_dec // 10 ** 18
            tx, resp, err = await c.create_market_order(market_index=self.market, client_order_index=coi,
                                                        base_amount=base, avg_execution_price=tick,
                                                        is_ask=bool(side))
            if err is not None:
                raise RuntimeError(str(err)[:300])
            return str(getattr(resp, "tx_hash", resp))[:200]
        finally:
            await c.close()

    def settle(self, rid, fill_px18):
        out = self._cast("send", self.vault, "settleMint(uint256,uint256)", str(rid), str(fill_px18),
                         "--gas-limit", "1500000", "--private-key", self.attester_pk, "--rpc-url", self.rpc)
        ok = any(l.split()[:2] == ["status", "1"] for l in out.split("\n") if l.strip())
        h = next((l.split()[1] for l in out.split("\n") if l.startswith("transactionHash")), "?")
        if not ok:
            raise RuntimeError("settleMint reverted: " + h)
        return h

    def handle(self, rid, base, side, limit_px18):
        key = str(rid)
        rec = self.state["receipts"].get(key)
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

        pos0, entry0 = self.position()
        # WRITE-AHEAD: journal before the order leaves, so a crash cannot lead to a second order.
        self.state["receipts"][key] = {"status": "placing", "base": base, "limit_px18": str(limit_px18),
                                       "pos_before": pos0, "entry_before": entry0, "at": int(time.time())}
        self._save()

        try:
            sent = asyncio.run(self.open(base, side, limit_px18, coi=rid))
        except Exception as e:                                       # noqa: BLE001
            # Refused before reaching the book (e.g. jurisdiction, auth, nonce): nothing opened.
            self.state["receipts"][key].update(status="order_refused", error=str(e)[:300])
            self._save()
            log("receipt %d: order refused: %s" % (rid, e))
            return
        self.state["receipts"][key].update(status="placed", sent=sent)
        self._save()
        log("receipt %d: order sent for %d base, cap %.4f" % (rid, base, limit_px18 / 1e18))

        deadline = time.time() + self.fill_timeout
        pos1, entry1 = pos0, entry0
        while time.time() < deadline:
            time.sleep(5)
            pos1, entry1 = self.position()
            if pos1 - pos0 >= base:
                break
        filled = pos1 - pos0
        if filled < base:
            status = "unfilled_left_for_refund" if filled == 0 else "PARTIAL_needs_human"
            self.state["receipts"][key].update(status=status, filled=filled)
            self._save()
            log("receipt %d: filled %d of %d -> %s" % (rid, filled, base, status))
            return

        # Average price of exactly the units this order added, from the account's own books.
        notional1 = pos1 * entry1
        notional0 = pos0 * entry0
        fill_px = (notional1 - notional0) / filled
        fill_px18 = int(round(fill_px * 10 ** 6)) * 10 ** 12
        self.state["receipts"][key].update(status="filled", filled=filled, fill_px=fill_px)
        self._save()
        log("receipt %d: filled %d at %.4f" % (rid, filled, fill_px))

        try:
            h = self.settle(rid, fill_px18)
        except Exception as e:                                       # noqa: BLE001
            self.state["receipts"][key].update(status="FILLED_BUT_UNSETTLED_needs_human", error=str(e)[:300])
            self._save()
            log("receipt %d: FILLED but settle failed: %s" % (rid, e))
            return
        self.state["receipts"][key].update(status="settled", settle_tx=h)
        self._save()
        log("receipt %d: settled %s" % (rid, h))

    def run_once(self):
        reqs = self.new_requests()
        self._save()
        for rid, base, side, limit_px18, _tx in reqs:
            self.handle(rid, base, side, limit_px18)


def main():
    k = Keeper(sys.argv[1])
    log("keeper up: vault %s market %d account %d from block %d"
        % (k.vault, k.market, k.key["account_index"], k.state["next_block"]))
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

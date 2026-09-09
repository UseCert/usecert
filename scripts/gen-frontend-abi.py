#!/usr/bin/env python3
"""Generate frontend/usecert-contracts.ts from Foundry artifacts and the address book.

Run after any contract change or redeployment:

    forge build && python scripts/gen-frontend-abi.py

Why generated rather than hand-written: an ABI copied by hand drifts from the contract the
moment a signature changes, and this project has changed CertOracle's constructor arity twice.
Why committed TS rather than an npm package with a codegen step: the consuming front-end repo
is monitored for having NO lifecycle scripts (no postinstall/prepare) and NO CI, and that
property is deliberate. A committed module preserves it; a build hook destroys it.

Functions are filtered to the front-end surface. ALL errors and events are kept — errors so a
UI can turn a revert into a sentence, events because receipt ids are not enumerable on-chain
and a receipts screen can only be built from logs.
"""

import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOK_PATH = os.path.join(ROOT, "deployments", "46630.json")
OUT_PATH = os.path.join(ROOT, "frontend", "usecert-contracts.ts")

# The front-end surface, per contract. Anything not listed is deliberately withheld: a UI that
# can call it either does not need it (operator knobs) or should reach it through another
# contract (never read an aggregator directly - read CertOracle, which applies the guards).
KEEP = {
    "CertVault": {
        # writes - user actions
        "mintInstant", "requestMint", "settleMint", "stageRefund", "refundMint",
        "redeemInstant", "requestRedeem", "forceExit", "claimRedeem",
        # writes - permissionless, anyone may call
        "recallMargin", "rebalance",
        # reads
        "solvency", "hotBuffer", "freeCollateral18", "bufferCapacity18",
        "certificate", "buffer", "oracle", "cfg", "mintReceipts", "redeemReceipts",
        "bootstrapped", "lighterAccountIndex", "totalOwedOutstanding", "postedMargin",
        "marginPendingRecall", "marginExcess", "pendingMintCerts", "venuePositionBase",
        "governance",
    },
    "Certificate": {
        "name", "symbol", "decimals", "totalSupply", "balanceOf", "allowance",
        "approve", "transfer", "transferFrom", "vault",
    },
    "CertOracle": {
        "px", "pxUnguarded", "basisBps", "basisBpsChecked", "mintAllowed", "markPx18",
        "singleSource", "pokeLastGood", "lastGoodPx18", "lastGoodAt", "stalenessSeconds",
        "deviationBps", "basisBandBps", "priceDecimals", "toTickPrice", "attester", "feed",
    },
    "TestUSDG": {
        "name", "symbol", "decimals", "totalSupply", "balanceOf", "allowance",
        "approve", "transfer", "transferFrom", "owner",
    },
    "TestFaucet": {"claim", "nextAvailableAt", "token", "dripAmount", "interval"},
    "SolvencyRegistry": {"latest", "ageSec", "attester"},
}

ARTIFACTS = {
    "CertVault": "out/CertVault.sol/CertVault.json",
    "Certificate": "out/Certificate.sol/Certificate.json",
    "CertOracle": "out/CertOracle.sol/CertOracle.json",
    "TestUSDG": "out/TestUSDG.sol/TestUSDG.json",
    "TestFaucet": "out/TestFaucet.sol/TestFaucet.json",
    "SolvencyRegistry": "out/SolvencyRegistry.sol/SolvencyRegistry.json",
}

HEADER = """// GENERATED from Foundry artifacts - do not hand-edit.
// Regenerate:  forge build && python scripts/gen-frontend-abi.py
//
// UseCert - Robinhood Chain testnet (chain 46630)
// Deployment: block {block}, commit {commit}
//
// Functions are filtered to the front-end surface. ALL errors and events are kept:
// errors so a UI can decode a revert into a sentence, events because receipt ids are
// NOT enumerable on-chain and the receipts screen can only be built from logs.

export const CHAIN = {{
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: {{ name: 'Ether', symbol: 'ETH', decimals: 18 }},
  rpcUrls: {{ default: {{ http: ['https://rpc.testnet.chain.robinhood.com'] }} }},
  blockExplorers: {{ default: {{ name: 'Blockscout', url: 'https://explorer.testnet.chain.robinhood.com' }} }},
  testnet: true,
}} as const;

/** Decimals differ per value class. Getting this wrong is the single largest hidden cost. */
export const DECIMALS = {{
  collateral: 6,   // TestUSDG, matching real USDG. CertVault reads this ONCE at construction.
  certificate: 18, // uTSLA / uSPY
  price: 18,       // every *Px18 / px18 value
  feed: 8,         // ReplayAggregator / Chainlink answers
  bps: 4,          // 10_000 = 100%
}} as const;

"""


def main():
    if not os.path.exists(BOOK_PATH):
        sys.exit("no address book at %s - deploy first" % BOOK_PATH)
    book = json.load(open(BOOK_PATH))

    abis = {}
    for name, rel in ARTIFACTS.items():
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            sys.exit("missing artefact %s - run `forge build`" % rel)
        full = json.load(open(path))["abi"]
        keep = KEEP[name]
        abis[name] = [
            x for x in full if x.get("type") != "function" or x.get("name") in keep
        ]

    out = io.StringIO()
    out.write(
        HEADER.format(
            block=book.get("blockNumber"), commit=str(book.get("commit"))[:12]
        )
    )

    shared = book["shared"]
    out.write("export const SHARED = {\n")
    for key in (
        "collateral",
        "testFaucet",
        "solvencyRegistry",
        "capacityOracle",
        "certFactory",
        "lighterSim",
    ):
        if key in shared:
            out.write("  %s: '%s' as const,\n" % (key, shared[key]))
    out.write("} as const;\n\nexport const MIRRORS = [\n")
    for v in book["vaults"]:
        out.write("  {\n")
        out.write("    symbol: '%s' as const,\n" % v["symbol"])
        out.write("    marketIndex: %s,\n" % v["marketIndex"])
        for key in ("vault", "certificate", "certOracle", "bufferBook", "replayAggregator"):
            if key in v:
                out.write("    %s: '%s' as const,\n" % (key, v[key]))
        out.write("  },\n")
    out.write("] as const;\n\nexport type Mirror = (typeof MIRRORS)[number];\n\n")

    for name in ARTIFACTS:
        out.write(
            "export const %sABI = %s as const;\n\n"
            % (name, json.dumps(abis[name], separators=(",", ":")))
        )

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    io.open(OUT_PATH, "w", encoding="utf-8", newline="\n").write(out.getvalue())
    print("wrote %s" % OUT_PATH)
    for name in ARTIFACTS:
        fns = len([x for x in abis[name] if x.get("type") == "function"])
        evs = len([x for x in abis[name] if x.get("type") == "event"])
        errs = len([x for x in abis[name] if x.get("type") == "error"])
        print("  %-18s %2d fns  %2d events  %2d errors" % (name, fns, evs, errs))


if __name__ == "__main__":
    main()

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

import hashlib
import io
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Which deployment to generate for. Defaults to the testnet, so every existing invocation
# behaves exactly as before; `--chain 4663` emits the mainnet bundle instead.
#
# The chain is a PARAMETER rather than a constant because there are now two address books
# and only one of them describes a deployment that exists. Hardcoding either is how a
# mainnet bundle gets generated from testnet addresses, or the reverse.
# RPC and explorer live HERE rather than in the address books: they are facts about the
# chain, not about a deployment, and the books are written by the deploy scripts and must
# never be hand-edited.
CHAINS = {
    "46630": {
        "book": "46630.json",
        "out": "usecert-contracts.ts",
        "label": "Robinhood Chain Testnet",
        "rpc": "https://rpc.testnet.chain.robinhood.com",
        "explorer": "https://explorer.testnet.chain.robinhood.com",
        "testnet": True,
    },
    # The mainnet book does NOT exist yet, and that is correct. Deploy scripts write
    # deployments/<chainId>.json; until script/DeployMainnet.s.sol has run there is nothing
    # to read. The measured inputs for that run - real USDG, the real venue proxy, the real
    # market indices and the mainnet parameters - live in deploy/mainnet/4663.plan.json,
    # which is hand-maintained on purpose because it describes a deployment that has not
    # happened. The two must never be confused: a plan is not a record.
    "4663": {
        "book": "4663.json",
        "out": "usecert-contracts.mainnet.ts",
        "label": "Robinhood Chain",
        "rpc": "https://rpc.mainnet.chain.robinhood.com",
        "explorer": "https://explorer.chain.robinhood.com",
        "testnet": False,
    },
}

CHAIN = "46630"
if "--chain" in sys.argv:
    CHAIN = sys.argv[sys.argv.index("--chain") + 1]
if CHAIN not in CHAINS:
    sys.exit("unknown --chain %r; known: %s" % (CHAIN, ", ".join(CHAINS)))

CHAIN_LABEL = CHAINS[CHAIN]["label"]
BOOK_PATH = os.path.join(ROOT, "deployments", CHAINS[CHAIN]["book"])
OUT_PATH = os.path.join(ROOT, "frontend", CHAINS[CHAIN]["out"])

# Addresses without which the front end cannot function. `testFaucet` and `lighterSim` are
# deliberately absent: both are testnet-only, and requiring them would block mainnet.
REQUIRED_SHARED = ("collateral", "solvencyRegistry", "capacityOracle")
REQUIRED_VAULT = ("vault", "certificate", "certOracle", "bufferBook")


def assert_book_exists():
    """A missing book is not an error to stack-trace over; it is the normal state of a
    chain nobody has deployed to yet. Say which file would answer it."""
    if os.path.exists(BOOK_PATH):
        return
    hint = ""
    if CHAIN == "4663":
        hint = (
            " The measured inputs for that deployment - real USDG, the venue proxy, the"
            " real market indices and mainnet parameters - are in"
            " deploy/mainnet/4663.plan.json."
        )
    sys.exit(
        "no address book at " + BOOK_PATH + " - nothing has been deployed to chain "
        + CHAIN + " yet." + hint
    )


def assert_deployed(book):
    """Refuse to emit a bundle with holes in it.

    A null address means that contract is not deployed. Writing it out anyway produces a
    module that typechecks, builds, ships, and points a live UI at nothing. The mainnet
    book starts with every protocol address null on purpose, so this check is what makes
    that safe to keep in the repository.
    """
    missing = [k for k in REQUIRED_SHARED if not book.get("shared", {}).get(k)]
    for v in book.get("vaults", []):
        missing += ["%s.%s" % (v.get("symbol"), k) for k in REQUIRED_VAULT if not v.get(k)]
    if missing:
        sys.exit(
            "refusing to generate for chain " + CHAIN + ": " + str(len(missing))
            + " address(es) are null in " + os.path.basename(BOOK_PATH) + "\n  "
            + ("\n  ".join(missing))
            + "\nDeploy first and let the deploy script write them."
            + " Do not hand-edit the book."
        )

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
        # The mark-price half of the same relay. `markNonce` is needed to know which signature is
        # still live; a client that relays a superseded one just burns gas on a revert.
        "setMarkPriceSigned", "SET_MARK_TYPEHASH", "domainSeparator", "markNonce",
    },
    "TestUSDG": {
        "name", "symbol", "decimals", "totalSupply", "balanceOf", "allowance",
        "approve", "transfer", "transferFrom", "owner",
    },
    "TestFaucet": {"claim", "nextAvailableAt", "token", "dripAmount", "interval"},
    # `attestSigned` is a WRITE the front end makes, which is unusual for this file and worth
    # saying why: on the signed path the attester no longer broadcasts, it signs, and the MINTER
    # relays the signature inside their own transaction. Without these in the ABI the UI can read
    # an attestation's age but cannot refresh it, so it would show a correctly-shut protocol and
    # offer no way to open it. `ATTEST_TYPEHASH`/`domainSeparator`/`SIGNATURE_VALIDITY` come along
    # so a client can verify a signature it was handed before spending gas relaying it.
    "SolvencyRegistry": {
        "latest", "ageSec", "attester",
        "attestSigned", "ATTEST_TYPEHASH", "domainSeparator", "SIGNATURE_VALIDITY",
    },
    # `bufferCapacity18()` is the LOOSEST of three capacity legs and is NOT what blocks a mint.
    # Measured live on 46630: uTSLA bufferCapacity18 = $9,999,004 while the binding
    # `maxNotional18` = $90,000 (the absolute cap) - 111x apart. A UI that shows the former as
    # "capacity" tells a user they have $10M of room while the vault refuses a $100 mint. Worse,
    # `freeCollateral18() / bufferCapacity18()` is identically 1/BUFFER_COVERAGE_MULTIPLE = 1.0000%
    # at every fill level by construction (CertVault.sol:563-569), confirmed to six decimals on
    # both live mirrors - a progress bar built on it is a constant. So the leg that actually binds
    # has to be reachable from the front end.
    "CapacityOracle": {"maxNotional18", "absoluteCap18", "depthBps", "registry", "governance"},
    # `capacity18` returns 0 whenever `balance18 <= 0`, which forces bufferCapacity18() to 0 and
    # halts minting REGARDLESS of collateral held. That is a second "healthy-looking deployment
    # refuses to mint" cause and a UI cannot diagnose it without reading this directly.
    "BufferBook": {"balance18", "capacity18", "config", "holdingFeeBps", "insuranceDrawNeeded", "mintSlowed"},
}

ARTIFACTS = {
    "CertVault": "out/CertVault.sol/CertVault.json",
    "Certificate": "out/Certificate.sol/Certificate.json",
    "CertOracle": "out/CertOracle.sol/CertOracle.json",
    "TestUSDG": "out/TestUSDG.sol/TestUSDG.json",
    "TestFaucet": "out/TestFaucet.sol/TestFaucet.json",
    "SolvencyRegistry": "out/SolvencyRegistry.sol/SolvencyRegistry.json",
    "CapacityOracle": "out/CapacityOracle.sol/CapacityOracle.json",
    "BufferBook": "out/BufferBook.sol/BufferBook.json",
}

# ------------------------------------------------------------------ provenance
#
# The header used to print `commit {book["commit"]}` truncated to 12 characters. That
# field is whatever `COMMIT=` was set to at deploy time, so it accepted any string - and
# the string it actually carried was `signed-attestation`, which the truncation rendered
# as `signed-attes`. Twelve characters of lowercase in the slot where a commit prefix
# goes reads as a commit prefix. It pointed at nothing.
#
# Provenance a reader can check is the only kind worth printing, so the header now
# carries three facts that cannot be hand-set from the address book:
#
#   - the commit this file was GENERATED at, read from git here, marked `-dirty` when the
#     tree has uncommitted changes. A dirty build is not reproducible and says so.
#   - the sha256 of the address book, so the exact address set is pinned. Recomputable
#     with `sha256sum deployments/46630.json`.
#   - the commit the contracts were DEPLOYED at - but ONLY when the book holds something
#     shaped like one. Anything else prints as unrecorded, quoting what was found. These
#     are different commits and conflating them is how the old line came to be wrong.

_HEX40 = re.compile(r"^[0-9a-f]{40}$")


def _git(*args):
    """A git value, or None. Never raises: this runs in checkouts and in tarballs."""
    try:
        r = subprocess.run(
            ["git", "-C", ROOT] + list(args),
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() or None if r.returncode == 0 else None


def generated_at_commit():
    sha = _git("rev-parse", "HEAD")
    if sha is None:
        return "unavailable (not a git checkout)"
    return sha[:12] + ("-dirty" if _tree_is_dirty() else "")


def _tree_is_dirty():
    """Uncommitted tracked changes, EXCLUDING this script's own output.

    The output file is almost always modified at the moment it is regenerated - by the
    previous run. Counting it means `-dirty` is on every single time, and a flag that
    cannot be off carries no information. What the flag is for is the case that matters:
    a bundle generated from sources that differ from the commit it names.

    `diff --name-only HEAD` rather than `status --porcelain`: it emits bare paths, with
    no status column to slice past and no untracked files to filter. The first attempt
    here parsed porcelain with `line[3:]`, which was off by one because `_git` strips the
    leading space out of the status column - so every path failed to match the exclusion
    and the flag was stuck on, which is the exact failure this function exists to avoid.
    """
    changed = _git("diff", "--name-only", "HEAD")
    if not changed:
        return False
    out_rel = os.path.relpath(OUT_PATH, ROOT).replace(os.sep, "/")
    return any(path.strip() != out_rel for path in changed.splitlines() if path.strip())


def deployed_at_commit(book):
    """The book's `commit`, but only if it IS one. Never truncated into looking like one."""
    raw = book.get("commit")
    c = str(raw or "").strip().lower()
    if _HEX40.match(c):
        return c[:12]
    return "unrecorded (address book carries %r, which is not a commit hash)" % (raw,)


def book_digest(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:12]


HEADER = """// GENERATED from Foundry artifacts - do not hand-edit.
// Regenerate:  forge build && python scripts/gen-frontend-abi.py
//
// UseCert - {label} (chain {chain})
// Deployment:   block {block}
// Address book: deployments/{bookfile}, sha256 {book} (first 12)
// Deployed at:  {deployed}
// Generated at: commit {generated}
//
// Functions are filtered to the front-end surface. ALL errors and events are kept:
// errors so a UI can decode a revert into a sentence, events because receipt ids are
// NOT enumerable on-chain and the receipts screen can only be built from logs.

export const CHAIN = {{
  id: {chain},
  name: '{label}',
  nativeCurrency: {{ name: 'Ether', symbol: 'ETH', decimals: 18 }},
  rpcUrls: {{ default: {{ http: ['{rpc}'] }} }},
  blockExplorers: {{ default: {{ name: 'Blockscout', url: '{explorer}' }} }},
  testnet: {is_testnet},
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
    assert_book_exists()
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
            label=CHAIN_LABEL,
            chain=CHAIN,
            rpc=CHAINS[CHAIN]["rpc"],
            explorer=CHAINS[CHAIN]["explorer"],
            is_testnet="true" if CHAINS[CHAIN]["testnet"] else "false",
            block=book.get("blockNumber"),
            bookfile=os.path.basename(BOOK_PATH),
            book=book_digest(BOOK_PATH),
            deployed=deployed_at_commit(book),
            generated=generated_at_commit(),
        )
    )

    assert_deployed(book)
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
        # A null means "not deployed on this chain", and the mainnet book has testFaucet
        # and lighterSim null on purpose. Emitting them anyway writes the literal string
        # 'None' into the bundle - which typechecks, reads like an address, and is one of
        # the more expensive things a front end could be handed. Omitting them instead lets
        # the front end test for ABSENCE and say true things about which chain it is on.
        if shared.get(key):
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

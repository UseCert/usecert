#!/usr/bin/env python3
"""Emit src/chain/contracts.stack5.ts for the front end from the STACK-5 Foundry artifacts.

Why not scripts/gen-frontend-abi.py directly: that generator writes ONE bundle (addresses + ABIs)
from a deployed address book, and stack 5 has no book yet (not deployed). Running it now would
either refuse (no book) or pair stack-5 ABIs with stack-4 addresses, which breaks the live app
(CertOracle.setMarkPriceSigned changed arity). So this emits ABIs ONLY, filtered with the repo
generator's own KEEP sets (imported, not copied) plus the stack-5 additions listed below.

    python gen-stack5-abi.py <contracts-repo-root> <frontend-repo-root>
"""
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True

CONTRACTS, FRONTEND = sys.argv[1], sys.argv[2]
OUT = os.path.join(FRONTEND, "src", "chain", "contracts.stack5.ts")

spec = importlib.util.spec_from_file_location("genfe", os.path.join(CONTRACTS, "scripts", "gen-frontend-abi.py"))
genfe = importlib.util.module_from_spec(spec)
saved = sys.argv
sys.argv = [saved[0]]  # the repo generator parses --chain at import; give it nothing
spec.loader.exec_module(genfe)
sys.argv = saved

# Stack-5 functions the UI reads or calls, on top of the repo generator's KEEP.
ADD = {
    "CertVault": {
        "redeemPaid", "redeemFee", "redeemCertIn", "mintFee",
        "INSTANT_MAX_PRICE_AGE", "QUEUED_PRICE_TIMEOUT", "REDEEM_OWNER_GRACE",
        "insuranceShortfall", "settler",
    },
    "CertOracle": {"markAt", "maxMarkAge", "MARK_SIGNATURE_VALIDITY"},
    "SolvencyRegistry": set(),
}

# The staking contracts are not in the repo generator at all (the front end keeps them in
# insurance.ts / certStaking.ts). Their surface: the v1 module's function list plus v2's views.
INSURANCE_KEEP = {
    "DRAW_EXECUTION_WINDOW", "MIN_PROPOSAL_GAP", "asset", "balanceOf", "cancelWithdraw", "convertToAssets",
    "convertToShares", "cooldown", "decimals", "deposit", "depositCap", "drawCap", "drawCount", "drawDelay",
    "drawPending", "draws", "governance", "lastProposalAt", "maxDeposit", "maxDrawBps", "maxRedeem",
    "maxWithdraw", "previewDeposit", "previewRedeem", "redeem", "registry", "requestWithdraw", "totalAssets",
    "totalSupply", "withdrawOpen", "withdrawRequests", "withdrawWindow",
    # v2
    "unvestedIncome", "vestingEnd", "vestingRemaining", "vestingCheckpoint", "netPrincipal",
    "accountedBalance", "registrationDelay", "drawnInPeriod", "DRAW_CAP_PERIOD", "VESTING_PERIOD", "sync",
}
CERT_STAKING_KEEP = {
    "PRECISION", "balanceOf", "earned", "exit", "getReward", "lastTimeRewardApplicable", "lastUpdateTime",
    "notifyRewardAmount", "periodFinish", "remainingReward", "rewardPerToken", "rewardPerTokenStored",
    "rewardRate", "rewardToken", "rewards", "rewardsDuration", "stake", "stakeCap", "stakingToken",
    "totalStaked", "unallocated", "userRewardPerTokenPaid", "withdraw",
    # v2
    "minNotify", "unallocatedScaled", "MIN_TIME_LEFT",
}

SOURCES = [
    ("Stack5CertVaultABI", "CertVault", "out/CertVault.sol/CertVault.json", genfe.KEEP["CertVault"] | ADD["CertVault"]),
    ("Stack5CertOracleABI", "CertOracle", "out/CertOracle.sol/CertOracle.json", genfe.KEEP["CertOracle"] | ADD["CertOracle"]),
    ("Stack5SolvencyRegistryABI", "SolvencyRegistry", "out/SolvencyRegistry.sol/SolvencyRegistry.json",
     genfe.KEEP["SolvencyRegistry"] | ADD["SolvencyRegistry"]),
    ("Stack5InsuranceStakingABI", "InsuranceStaking", "out/InsuranceStaking.sol/InsuranceStaking.json", INSURANCE_KEEP),
    ("Stack5CertStakingABI", "CertStaking", "out/CertStaking.sol/CertStaking.json", CERT_STAKING_KEEP),
]


def git(*a):
    r = subprocess.run(["git", "-C", CONTRACTS] + list(a), capture_output=True, text=True)
    return r.stdout.strip()


commit = git("rev-parse", "HEAD")
branch = git("rev-parse", "--abbrev-ref", "HEAD")
dirty = bool(git("status", "--porcelain", "--", "src", "scripts/gen-frontend-abi.py"))


def sha12(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:12]


# The stack-4 mark relay, pinned from the CURRENT generated bundle (src/chain/contracts.ts), so the
# stack-4 branch keeps type-checking once contracts.ts is regenerated from stack-5 artifacts.
fe_bundle = open(os.path.join(FRONTEND, "src", "chain", "contracts.ts"), encoding="utf-8").read()
m = re.search(r"export const CertOracleABI = (\[.*?\]) as const;", fe_bundle)
stack4_oracle = json.loads(m.group(1))
stack4_relay = [x for x in stack4_oracle if x.get("type") == "function" and x.get("name") in ("setMarkPriceSigned", "markNonce")]
assert [len(x["inputs"]) for x in stack4_relay if x["name"] == "setMarkPriceSigned"] == [4], "stack-4 bundle changed"
bundle_hdr = "\n".join(l for l in fe_bundle.splitlines()[:8] if l.startswith("// Address book") or l.startswith("// Deployed at") or l.startswith("// Generated at"))

out = io.StringIO()
out.write("// GENERATED from Foundry artifacts - do not hand-edit.\n")
out.write("// Stack-5 ABIs ONLY (no addresses: stack 5 is not deployed). Every Stack5* export is used only\n")
out.write("// where IS_STACK5 (src/chain/deployment.ts) is true; on a stack-4 bundle their reads are disabled\n")
out.write("// and their writes unreachable. Stack4MarkRelayABI, at the end, is the stack-4 relay's own.\n")
out.write("//\n")
out.write("// Contracts repo: branch %s, commit %s%s\n" % (branch, commit[:12], "-dirty" if dirty else ""))
out.write("// Built with:     forge build (in that checkout), then gen-stack5-abi.py, which imports\n")
out.write("//                 scripts/gen-frontend-abi.py's KEEP sets and adds the stack-5 names below.\n")
out.write("// Artifacts (sha256 of the artifact file, first 12):\n")
for export, name, rel, _ in SOURCES:
    out.write("//   %-28s %s  %s\n" % (export, rel, sha12(os.path.join(CONTRACTS, rel))))
out.write("// Stack-5 additions to KEEP:\n")
for k in ("CertVault", "CertOracle"):
    out.write("//   %s: %s\n" % (k, ", ".join(sorted(ADD[k]))))
out.write("// InsuranceStaking / CertStaking: the v1 modules' function lists plus\n")
out.write("//   %s\n" % ", ".join(sorted({"unvestedIncome", "vestingEnd", "vestingRemaining", "vestingCheckpoint", "netPrincipal", "accountedBalance", "registrationDelay", "drawnInPeriod", "DRAW_CAP_PERIOD", "VESTING_PERIOD", "sync"})))
out.write("//   %s\n" % ", ".join(sorted({"minNotify", "unallocatedScaled", "MIN_TIME_LEFT"})))
out.write("//\n")
out.write("// Functions are filtered to the front-end surface. ALL errors and events are kept, as in\n")
out.write("// contracts.ts: errors so a revert decodes into a sentence, events for receipts.\n\n")

for export, name, rel, keep in SOURCES:
    full = json.load(open(os.path.join(CONTRACTS, rel), encoding="utf-8"))["abi"]
    missing = sorted(k for k in keep if not any(x.get("type") == "function" and x.get("name") == k for x in full))
    assert not missing, (name, missing)
    abi = [x for x in full if x.get("type") != "function" or x.get("name") in keep]
    out.write("/** %s, stack 5 (%s). */\n" % (name, rel))
    out.write("export const %s = %s as const;\n\n" % (export, json.dumps(abi, separators=(",", ":"))))

out.write("/**\n")
out.write(" * The STACK-4 mark relay: CertOracle.setMarkPriceSigned(px18, nonce, deadline, sig) and markNonce,\n")
out.write(" * copied by this generator from src/chain/contracts.ts as it stood when this file was generated:\n")
for l in bundle_hdr.splitlines():
    out.write(" *   %s\n" % l[3:])
out.write(" * Pinned so the stack-4 relay does not depend on contracts.ts, which changes arity when it is\n")
out.write(" * regenerated from stack-5 artifacts (stack 5 adds observedAt).\n")
out.write(" */\n")
out.write("export const Stack4MarkRelayABI = %s as const;\n" % json.dumps(stack4_relay, separators=(",", ":")))

io.open(OUT, "w", encoding="utf-8", newline="\n").write(out.getvalue())
print("wrote", OUT)
for export, name, rel, keep in SOURCES:
    full = json.load(open(os.path.join(CONTRACTS, rel), encoding="utf-8"))["abi"]
    abi = [x for x in full if x.get("type") != "function" or x.get("name") in keep]
    print("  %-28s %2d fns %2d events %2d errors" % (export, sum(1 for x in abi if x["type"] == "function"),
          sum(1 for x in abi if x["type"] == "event"), sum(1 for x in abi if x["type"] == "error")))

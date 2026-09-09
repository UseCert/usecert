#!/usr/bin/env bash
#
# check-sizes.sh — THE EIP-170 GATE. Run it before any deploy.
#
# WHY THIS EXISTS AND WHY A GREEN TEST SUITE IS NOT A SUBSTITUTE.
#
#   Foundry does NOT enforce EIP-170's 24,576 B runtime ceiling in `forge test`: the test EVM
#   deploys oversized code happily, so a contract that CANNOT BE DEPLOYED ON ANY CHAIN passes the
#   whole suite green. `docs/DEPLOYMENT-CHECKLIST.md` §9's last row and Global Constraint 6 both say
#   so in as many words.
#
#   This project has already shipped one undeployable contract for exactly that reason:
#   `CertFactory.deployVault` could not exist, because `CertVault`'s creation code is 25,743 B and
#   any contract embedding it would have to fit that inside the 24,576 B RUNTIME ceiling. That is
#   why `CertFactory` is a registry and `script/DeployTestnet.s.sol` deploys the vaults. The defect
#   was found at deployment time, not by the suite.
#
# WHAT IT CHECKS
#
#   `forge build --sizes` for every contract in the compilation unit, and a NEGATIVE MARGIN in
#   either column is a hard failure:
#
#     * runtime margin  — EIP-170, 24,576 B. A negative margin means the contract cannot be
#                         deployed at all.
#     * initcode margin — EIP-3860, 49,152 B. A negative margin means the deployment transaction
#                         is rejected before the runtime code is ever written.
#
#   Both are deploy blockers, so both fail this script. The sizes are re-derived against the
#   ceilings as well as read from the margin columns, so a change in how Foundry formats that table
#   cannot turn this gate into a no-op that reports success.
#
#   IT ALSO FAILS IF NO CONTRACTS WERE PARSED. A size gate that finds an empty table and exits 0 is
#   the worst possible outcome — it reports success for having checked nothing. That case is an
#   explicit error here.
#
# USAGE
#
#   bash script/check-sizes.sh
#
#   Exits 0 when every contract has a positive margin in both columns, non-zero otherwise. Takes no
#   arguments and reads no environment beyond what `forge` itself needs. §9 requires this to have
#   been run against THE EXACT COMMIT BEING DEPLOYED, which is why `script/DeployTestnet.s.sol`
#   records `COMMIT` in the address book: the claim stays checkable afterwards.

set -u

# EIP-170 and EIP-3860. Hardcoded rather than read from `foundry.toml`, deliberately: they are
# protocol constants, not project configuration, and Global Constraint 1 forbids relaxing the size
# checks. A gate whose own limit is configurable by the thing it gates is not a gate.
RUNTIME_LIMIT=24576
INITCODE_LIMIT=49152

echo "== EIP-170 / EIP-3860 size gate =================================================="
echo "   runtime ceiling  ${RUNTIME_LIMIT} B"
echo "   initcode ceiling ${INITCODE_LIMIT} B"
echo

# STDOUT AND STDERR ARE KEPT APART ON PURPOSE. The size table goes to stdout; forge's post-build
# lint notes go to stderr and run to ~23,000 lines on this tree. Folding them together with `2>&1`
# buries the table — and buries a FAIL line in it — so stderr is held back and printed only when
# forge actually failed, which is the only time it matters.
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

out="$(NO_COLOR=1 forge build --sizes 2>"$err_file")"
forge_status=$?

echo "$out"
echo

# THE TABLE IS PARSED BEFORE forge's EXIT CODE IS CONSULTED, and the order is deliberate.
#
# Measured on forge 1.8.1: `forge build --sizes` DOES exit 1 by itself when a contract is over
# EIP-170. Deferring to that alone would have been the tempting implementation and it is the wrong
# one, for two reasons. It reports "exited 1" without naming the contract or the overage, which is
# the difference between a gate an engineer can act on and one they have to re-run by hand. And it
# is behaviour of a tool, not of this repository: the day a forge release stops exiting non-zero,
# or a `[profile]` setting suppresses it, a gate built on it reports PASS on an undeployable tree.
# The awk pass below is this repository's own check and stands on its own; forge's status is then
# honoured as a second, independent signal.
if [ "$forge_status" -ne 0 ]; then
  echo "NOTE: 'forge build --sizes' itself exited ${forge_status}. Parsing the table for specifics."
  echo
fi

# Parse the table. Rows look like:
#   | CertVault | 17,559 | 25,743 | 7,017 | 23,409 |
# and the thousands separators have to come out before any comparison. Separator rows start with
# `|-` or `+=`, and the header row carries the word "Contract"; everything else beginning with `|`
# is a contract.
echo "$out" | awk -v rl="$RUNTIME_LIMIT" -v il="$INITCODE_LIMIT" '
  function clean(s) {
    gsub(/[ \t,]/, "", s)
    return s
  }
  BEGIN { FS = "|"; rows = 0; bad = 0 }
  /^\|-/  { next }
  /^\+=/  { next }
  # The header row, matched on a column title rather than on the word "Contract": a contract whose
  # own name contained "Contract" would otherwise skip its own row and go unchecked.
  /Runtime Size/ { next }
  /^\|/ {
    # FS="|" on "| Name | a | b | c | d |" yields an empty $1 before the first pipe and an empty
    # $7 after the last, so the five columns are $2..$6 and a well-formed row has NF == 7.
    if (NF < 7) next
    name = clean($2)
    rsize = clean($3)
    isize = clean($4)
    rmargin = clean($5)
    imargin = clean($6)
    if (name == "") next
    # Every numeric field must actually look numeric. A row that does not parse is NOT skipped
    # quietly: silently ignoring a row is how a gate stops gating.
    if (rsize !~ /^-?[0-9]+$/ || isize !~ /^-?[0-9]+$/ || rmargin !~ /^-?[0-9]+$/ || imargin !~ /^-?[0-9]+$/) {
      printf "UNPARSEABLE ROW: %s\n", $0
      bad++
      next
    }
    rows++
    # Two independent statements of the same fact: the margin column as forge reports it, and the
    # size re-derived against the protocol ceiling. Either one failing is a failure.
    # `+ 0` on every comparison operand, deliberately: after `gsub` these are STRINGS, and awk
    # compares two strings lexically. "-1,234" happens to sort below "0" so the naive form appears
    # to work, which is exactly how a gate like this rots into a no-op.
    if (rmargin + 0 < 0 || rsize + 0 > rl + 0) {
      printf "FAIL  %-28s runtime %8d B  OVER EIP-170 BY %d B (margin %d)\n", name, rsize, rsize - rl, rmargin
      bad++
    }
    if (imargin + 0 < 0 || isize + 0 > il + 0) {
      printf "FAIL  %-28s initcode %7d B  OVER EIP-3860 BY %d B (margin %d)\n", name, isize, isize - il, imargin
      bad++
    }
  }
  END {
    if (rows == 0) {
      print "FAIL: no contract rows were parsed out of forge build --sizes."
      print "      This gate reports success only after actually checking contracts. Empty table,"
      print "      changed format, or a build that produced no artefacts - all of them are a fail."
      exit 1
    }
    if (bad > 0) {
      printf "\nFAIL: %d size violation(s) across %d contracts. DO NOT DEPLOY.\n", bad, rows
      print  "      A negative runtime margin means the contract cannot be deployed on any chain."
      print  "      forge test does NOT enforce this, so a green suite is not evidence."
      exit 1
    }
    printf "\nOK: %d contracts, every one with a positive runtime and initcode margin.\n", rows
    exit 0
  }
'
awk_status=$?

if [ "$awk_status" -ne 0 ]; then
  echo
  echo "== FAIL: DO NOT DEPLOY ==========================================================="
  exit 1
fi

# The second, independent signal. Reaching here means every row parsed clean, so a non-zero forge
# status is something this script did not model — a build warning promoted to an error, a size
# check forge applies that the table does not show. It is NOT swallowed.
if [ "$forge_status" -ne 0 ]; then
  echo
  echo "FAIL: every table row has a positive margin, but 'forge build --sizes' still exited"
  echo "      ${forge_status}. Do not deploy on the strength of the table alone. forge's own"
  echo "      diagnostics follow:"
  echo
  cat "$err_file"
  echo
  echo "== FAIL: DO NOT DEPLOY ==========================================================="
  exit 1
fi

echo "== PASS =========================================================================="
exit 0

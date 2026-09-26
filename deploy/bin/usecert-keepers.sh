#!/usr/bin/env bash
# UseCert keeper stack - Linux/systemd edition.
#
# DIFFERENCES FROM THE LAPTOP VERSION, AND WHY EACH EXISTS. Every one of these is a fix for an
# outage that actually happened during testnet operation, not a hypothetical:
#
#   1. NO LOCKFILE OF ITS OWN. systemd is the single-instance guard: the unit is Type=simple with
#      no Restart=on-success loop, so systemd will not start a second copy. The laptop version
#      used a /tmp lockfile and it failed twice - once because a TaskStop killed the wrapper but
#      not the shell, and once because the operator deleted a "stale" lock that was not stale.
#      Two loops share keys and race nonces: measured 19 failures in 13 iterations with two alive,
#      1 in the following iterations with one.
#
#   2. THE FEED LEG NEVER READS BEFORE IT WRITES. Prices come from the address book's
#      seedPrice18, resolved once at start. An earlier version read latestRoundData() and pushed
#      the result back, so a failed READ skipped the WRITE - the feed then aged past
#      stalenessSeconds and minting stopped while the attester leg kept succeeding.
#
#   3. ATTESTATION CADENCE SCALES WITH MIRROR COUNT. maxAttestationAgeSec is 300 and the attester
#      writes 2 transactions per mirror per cycle. At 4 mirrors the worst observed age reached
#      283s of that 300s budget. ATTEST_EVERY is therefore derived, not fixed.
#
# Keys are read from an EnvironmentFile that systemd owns (0600, root) - never from a keystore
# this script decrypts, and never from the unit file itself (unit files are world-readable).
set -uo pipefail

: "${USECERT_HOME:?set USECERT_HOME to the repo root}"
: "${RPC_URL:?set RPC_URL}"
: "${DEPLOYER_PK:?}" ; : "${ATTESTER_PK:?}" ; : "${BATCH_KEEPER_PK:?}"
export DEPLOYER_PK ATTESTER_PK BATCH_KEEPER_PK GOV_PK="${GOV_PK:-}" BATCH_KEEPER="${BATCH_KEEPER:-}"
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
cd "$USECERT_HOME" || exit 1

BOOK="deployments/${CHAIN_ID:-46630}.json"
[ -r "$BOOK" ] || { echo "FATAL: no address book at $BOOK"; exit 1; }

# "<aggregator> <price8>" per mirror. python3 only - no RPC, no cast, so a flaky binary or a
# rate-limited endpoint cannot stop the feed leg from writing.
PAIRS=$(python3 -c "
import json,sys
d=json.load(open('$BOOK'))
for v in d['vaults']:
    print(v['replayAggregator'], int(v['seedPrice18'])//10**10)
") || { echo "FATAL: could not parse $BOOK"; exit 1; }
MIRRORS=$(printf '%s\n' "$PAIRS" | grep -c .)
[ "$MIRRORS" -gt 0 ] || { echo "FATAL: no mirrors in $BOOK"; exit 1; }

TICK="${TICK_SECONDS:-30}"
# 2 txs per mirror per attest cycle. Keep the worst age under half the 300s budget.
ATTEST_EVERY=$([ "$MIRRORS" -le 2 ] && echo 2 || echo 1)
FEED_EVERY="${FEED_EVERY:-4}"

echo "keeper up: $MIRRORS mirrors, tick ${TICK}s, attest every ${ATTEST_EVERY}, feed every ${FEED_EVERY}"
printf '%s\n' "$PAIRS" | sed 's/^/  /'

i=0
while :; do
  i=$((i+1))
  forge script script/keepers/BatchAdvancer.s.sol --rpc-url "$RPC_URL" --broadcast >/dev/null 2>&1 \
    || echo "[$i] batch FAIL"
  # ATTEST_ON_DEMAND=1 stops the keeper broadcasting attestations: they are signed by
  # usecert-signer and RELAYED by whoever mints, so an idle protocol costs nothing.
  # Capacity reads zero between mints - correct, not a fault; the front end refreshes
  # it as part of the mint. Set to 0 to put the keeper back in charge.
  if [ "${ATTEST_ON_DEMAND:-0}" != "1" ] && [ $((i % ATTEST_EVERY)) -eq 0 ]; then
    forge script script/keepers/Attester.s.sol --rpc-url "$RPC_URL" --broadcast >/dev/null 2>&1 \
      || echo "[$i] attest FAIL"
  fi
  if [ $((i % FEED_EVERY)) -eq 0 ]; then
    while read -r AGG SEEDPX; do
      [ -n "$AGG" ] || continue
      REPLAY_AGGREGATOR="$AGG" FEED_PRICE="$SEEDPX" \
        forge script script/FeedKeeper.s.sol --rpc-url "$RPC_URL" --broadcast >/dev/null 2>&1 \
        || echo "[$i] feed PUSH FAIL $AGG"
    done <<< "$PAIRS"
  fi
  [ $((i % 40)) -eq 0 ] && echo "[$i] healthy"
  sleep "$TICK"
done

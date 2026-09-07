#!/usr/bin/env bash
# Security audit for a collaborator-owned repo we do not control.
#
# READ-ONLY BY DESIGN. This script clones and greps. It never runs repo code,
# never installs dependencies, and never pushes. Do not add `npm install`,
# `bun install`, or any repo script invocation to this file.
#
# Usage:  ./scripts/audit-collab-repo.sh [owner/repo]
# Default target is sleroy1312-arch/usecertlah.
#
# Writes a snapshot to security/snapshots/<repo>-<UTC date>.txt and diffs it
# against the most recent previous snapshot, so drift is what you read, not
# the whole surface every time.

set -uo pipefail

REPO="${1:-sleroy1312-arch/usecertlah}"
SLUG="$(printf '%s' "$REPO" | tr '/' '-')"
STAMP="$(date -u +%Y-%m-%dT%H%MZ)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPDIR="$ROOT/security/snapshots"
OUT="$SNAPDIR/$SLUG-$STAMP.txt"
mkdir -p "$SNAPDIR"

# gh is a Windows binary; it needs APPDATA and unmangled API paths under Git Bash.
export PATH="$PATH:/c/Program Files/GitHub CLI"
export APPDATA="${APPDATA:-C:\\Users\\$USER\\AppData\\Roaming}"
export MSYS_NO_PATHCONV=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Known-good commit authors. A new name here is the single loudest signal in
# this whole script: it means a human started pushing to a bot-only repo.
KNOWN_AUTHORS='gpt-engineer-app\[bot\]|lovable-dev\[bot\]|Lovable'

{
  echo "# Security audit: $REPO"
  echo "# Generated: $STAMP (read-only; no repo code executed)"
  echo

  echo "## Repo metadata"
  gh api "repos/$REPO" \
    --jq '"private=\(.private) pushed=\(.pushed_at) size=\(.size)KB lang=\(.language) forks=\(.forks_count) default_branch=\(.default_branch) archived=\(.archived)"' \
    2>&1
  echo

  echo "## Our permissions (expect: pull/push/triage, NOT admin)"
  gh api "repos/$REPO" --jq '.permissions | to_entries | map("\(.key)=\(.value)") | join(" ")' 2>&1
  echo

  echo "## Collaborators (watch for additions)"
  gh api "repos/$REPO/collaborators" --jq '.[] | "\(.login) \(.role_name)"' 2>&1 | sort
  echo

  # Deploy keys and webhooks are admin-only endpoints. We are a write
  # collaborator, not an owner, so these are NOT VERIFIABLE by us - the 404 is
  # a permissions answer, not an "all clear". Recorded so the blind spot stays
  # visible instead of looking like a passed check.
  echo "## Deploy keys / webhooks"
  if gh api "repos/$REPO/keys" >/dev/null 2>&1; then
    gh api "repos/$REPO/keys" --jq 'if length==0 then "  deploy keys: none" else .[] | "  key: \(.title) read_only=\(.read_only)" end' 2>&1
    gh api "repos/$REPO/hooks" --jq 'if length==0 then "  webhooks: none" else .[] | "  hook: \(.name) \(.config.url // "-") active=\(.active)" end' 2>&1
  else
    echo "  NOT VERIFIABLE - requires repo admin. Blind spot: the owner could"
    echo "  add a deploy key or webhook and we would not see it. Ask the owner"
    echo "  directly if this ever matters."
  fi
  echo

  echo "## Commit authors, all-time (NON-BOT AUTHORS ARE THE KEY SIGNAL)"
  gh api "repos/$REPO/commits?per_page=100" \
    --jq '.[] | "\(.commit.author.name) <\(.commit.author.email)>"' 2>&1 \
    | sort | uniq -c | sort -rn
  echo
  echo "### Unrecognised authors"
  gh api "repos/$REPO/commits?per_page=100" --jq '.[] | .commit.author.name' 2>&1 \
    | sort -u | grep -vE "$KNOWN_AUTHORS" || echo "none - still bot-only"
  echo

  # ---- content checks ----
  if ! gh repo clone "$REPO" "$(cygpath -m "$WORK/repo" 2>/dev/null || echo "$WORK/repo")" -- --quiet --depth 1 >/dev/null 2>&1; then
    echo "!! CLONE FAILED - access may have been revoked. Investigate."
    exit 0
  fi
  cd "$WORK/repo" || exit 0

  echo "## Tracked files by type"
  git ls-files | sed -E 's/.*\.//' | sort | uniq -c | sort -rn | head -12
  echo

  echo "## Lifecycle scripts (MUST be none: postinstall/preinstall/install/prepare)"
  if [ -f package.json ]; then
    python -c "
import json,sys
d=json.load(open('package.json'))
s=d.get('scripts',{})
bad=[k for k in s if k in ('postinstall','preinstall','install','prepare','prepublish','prepublishOnly')]
print('  FOUND:', {k:s[k] for k in bad}) if bad else print('  none')
print('  all scripts:', ' | '.join(f'{k}={v}' for k,v in s.items()))
" 2>&1
  else
    echo "  no package.json"
  fi
  echo

  echo "## CI workflows (MUST be none, or reviewed line by line)"
  if [ -d .github ]; then find .github -type f | sort; else echo "  no .github directory"; fi
  echo

  echo "## Wallet / web3 dependencies (MUST be none while there is no dApp)"
  grep -iE '"(wagmi|viem|ethers|web3|@walletconnect|@rainbow-me|@solana|@privy-io|thirdweb|@reown)' package.json 2>/dev/null || echo "  none"
  echo

  echo "## Secret-shaped strings"
  grep -rInE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{10,}|BEGIN [A-Z ]*PRIVATE KEY|PRIVATE_KEY[[:space:]]*=|MNEMONIC|SEED_PHRASE)' \
    -- src public *.json *.ts 2>/dev/null | head -20 || echo "  none"
  echo

  echo "## Hardcoded EVM addresses (each must be mock/placeholder or reviewed)"
  grep -rInoE '0x[a-fA-F0-9]{40}' src 2>/dev/null | head -20 || echo "  none"
  echo

  echo "## Dynamic code execution / obfuscation"
  grep -rInE '[^a-zA-Z.]eval\(|new Function\(|atob\(|String\.fromCharCode|innerHTML[[:space:]]*=|dangerouslySetInnerHTML' src 2>/dev/null | head -20 || echo "  none"
  echo

  echo "## Outbound network calls"
  grep -rInE 'fetch\(|axios|XMLHttpRequest|new WebSocket\(|sendBeacon' src 2>/dev/null | head -20 || echo "  none"
  echo

  echo "## External domains referenced"
  grep -rhoE 'https?://[a-zA-Z0-9._-]+' src public 2>/dev/null | sed -E 's|https?://||' | sort -u
  echo

  echo "## Env vars read"
  grep -rhoE 'import\.meta\.env\.[A-Za-z_]+|process\.env\.[A-Za-z_]+' src 2>/dev/null | sort -u || echo "  none"
} > "$OUT" 2>&1

echo "Snapshot: $OUT"

PREV="$(ls -1 "$SNAPDIR/$SLUG-"*.txt 2>/dev/null | grep -v "$(basename "$OUT")" | tail -1)"
if [ -n "${PREV:-}" ]; then
  echo
  echo "=== DRIFT vs $(basename "$PREV") ==="
  if diff -u "$PREV" "$OUT" | sed -n '3,$p' | grep -E '^[+-]' | grep -vE '^[+-]# Generated'; then
    echo
    echo "Review every line above. Additions under lifecycle scripts, CI"
    echo "workflows, wallet deps, or unrecognised commit authors are blocking."
  else
    echo "No drift."
  fi
else
  echo "First snapshot - this is the baseline."
fi

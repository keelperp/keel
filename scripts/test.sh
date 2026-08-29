#!/usr/bin/env bash
# Run the full suite. Pins the fork a few blocks back on purpose.
#
# bsc-dataseed is load balanced across nodes at different heights: five calls in a row
# returned blocks 118767492 through 118767511. Forge forks at the height one node reports
# and then reads state from another, so Venus's stored accrual block can be AHEAD of the
# fork block, blockDelta underflows, and accrueInterest reverts "math error" at random.
# Pinning a few blocks back makes every node agree.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

RPC="${KEEL_RPC_URL:-https://bsc-dataseed.bnbchain.org}"
LAG="${FORK_LAG:-5}"
BLK=$(( $(cast block-number --rpc-url "$RPC") - LAG ))
echo "fork pinned at $BLK (lag $LAG)"

fail=0
echo; echo "=== offline: schema, factory guards, beacon ownership ==="
forge test --match-contract LeverVaultSchemaTest || fail=1

echo; echo "=== forked: authorization, guards, receive stipend ==="
forge test --match-contract LeverVaultAuthTest --fork-url "$RPC" --fork-block-number "$BLK" || fail=1

echo; echo "=== forked: receive gas budget (rule 005) ==="
forge test --match-contract LeverVaultGasTest --fork-url "$RPC" --fork-block-number "$BLK" || fail=1

echo; echo "=== forked: position lifecycle ==="
if [ "${KEEL_ARCHIVE:-0}" = "1" ]; then
  forge test --match-contract LeverVaultPositionTest --fork-url "$RPC" || fail=1
else
  echo "  SKIPPED — needs an archive RPC (set KEEL_ARCHIVE=1 and point KEEL_RPC_URL at one)."
  echo "  The same paths are covered by the live-state probes below, which do not fork."
fi

echo; echo "=== live state: full lifecycle as one atomic eth_call ==="
python3 tools/flap.py || fail=1

echo; echo "=== sizes (EIP-170) ==="
forge build --sizes | awk '/^\|/ {gsub(/\|/,""); if ($2+0 > 24576) { print "  OVER:", $1, $2; over=1 }} END { if (!over) print "  all within limit" }'

exit $fail

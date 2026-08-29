#!/usr/bin/env bash
# Run the full suite. Pins the fork a few blocks back on purpose.
#
# Note on the fork: bsc-dataseed is load balanced across nodes at different heights (five
# calls in a row spanned 19 blocks), so forge can fork at one node's height and read state
# from another. Venus's stored accrual block then leads the fork block and accrueInterest
# reverts "math error". The fix is in each test's setUp — vm.roll forward past anything a
# node could have recorded. Pinning the fork BACKWARD makes it worse.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

RPC="${KEEL_RPC_URL:-https://bsc-dataseed.bnbchain.org}"

fail=0
echo; echo "=== offline: schema, factory guards, beacon ownership ==="
forge test --match-contract LeverVaultSchemaTest || fail=1

echo; echo "=== forked: authorization, guards, receive stipend ==="
forge test --match-contract LeverVaultAuthTest --fork-url "$RPC" || fail=1

echo; echo "=== forked: receive gas budget (rule 005) ==="
forge test --match-contract LeverVaultGasTest --fork-url "$RPC" || fail=1

echo; echo "=== forked: position lifecycle ==="
if [ "${KEEL_ARCHIVE:-0}" = "1" ]; then
  forge test --match-contract LeverVaultPositionTest --fork-url "$RPC" || fail=1
else
  echo "  SKIPPED by design — see AUDIT.md. These need an archive RPC; BSC has no free one."
  echo "  The same paths are asserted by tools/verify.py below, on live state, atomically."
fi

echo; echo "=== live state: 33 assertions, one atomic eth_call each ==="
python3 tools/verify.py || fail=1

echo; echo "=== vault UI package: ABI currency and i18n coverage ==="
node tools/check-vault-ui.mjs || fail=1

echo; echo "=== sizes (EIP-170) ==="
forge build --sizes | awk '/^\|/ {gsub(/\|/,""); if ($2+0 > 24576) { print "  OVER:", $1, $2; over=1 }} END { if (!over) print "  all within limit" }'

exit $fail

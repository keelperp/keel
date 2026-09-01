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

echo; echo; echo "=== offline: everything beyond the vault is Guardian-upgradeable too ==="
forge test --match-contract LeverVaultUpgradeableTest || fail=1

echo "=== forked: authorization, guards, receive stipend ==="
forge test --match-contract LeverVaultAuthTest --fork-url "$RPC" || fail=1

echo; echo "=== forked: the underwater position Flap's review asked about ==="
forge test --match-contract LeverVaultInsolventTest --fork-url "$RPC" || fail=1

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
# verify.py reads the probe's bytecode straight out of out/. A forked forge run can still be
# flushing artefacts when it starts, which once produced four failures against a contract that
# had already been changed correctly. Build explicitly first so the artefact is never behind.
forge build --silent >/dev/null 2>&1 || true
python3 tools/verify.py || fail=1

echo; echo "=== documents vs build: every published number re-derived ==="
python3 tools/check-docs.py || fail=1

echo; echo "=== vault UI package: ABI currency and i18n coverage ==="
node tools/check-vault-ui.mjs || fail=1

echo; echo "=== sizes (EIP-170) ==="
# forge prints sizes with thousands separators, so "30,081"+0 evaluates to 30 and the old
# gate waved every oversized contract through. Strip the commas before comparing. Test-only
# probes are allowed to be huge: they are injected by eth_call state override, never deployed.
{ forge build --sizes || true; } | awk -F'|' '
  /^\|/ {
    name = $2; size = $3
    gsub(/[ \t]/, "", name); gsub(/[ ,\t]/, "", size)
    if (name == "" || size !~ /^[0-9]+$/) next
    if (size + 0 <= 24576) next
    if (name ~ /^(FlapProbe|KeelProbe|KeelE2E)$/) { probes = probes "  note: " name " " size " (test-only probe, never deployed)\n"; next }
    print "  OVER: " name " " size; over = 1
  }
  END {
    printf "%s", probes
    if (over) { print "  EIP-170 gate FAILED"; exit 1 }
    print "  all deployable contracts within limit"
  }' || fail=1

exit $fail

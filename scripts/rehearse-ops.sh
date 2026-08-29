#!/usr/bin/env bash
# Runs the three real operator commands against a local fork. Not a simulation of
# them — the same executables, the same go.mjs, the same receipts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT=8581
LOG="$ROOT/.rehearsal"
mkdir -p "$LOG"

pkill -f "anvil --fork-url.*$PORT" 2>/dev/null
pkill -f "anvil .*--port $PORT" 2>/dev/null
nohup anvil --fork-url https://bsc-dataseed.bnbchain.org --port $PORT --silent --no-rate-limit \
  > "$LOG/anvil.log" 2>&1 &
for i in $(seq 1 60); do
  cast block-number --rpc-url http://127.0.0.1:$PORT >/dev/null 2>&1 && break
  perl -e 'select(undef,undef,undef,0.5)'
done
echo "fork at $(cast block-number --rpc-url http://127.0.0.1:$PORT)"

# anvil default accounts 0 and 1: deployer and custody are deliberately different
export KEEL_RPC_URL=http://127.0.0.1:$PORT
export KEEL_DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export KEEL_CUSTODY=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export KEEL_CUSTODY_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export KEEL_EXIT_RECIPIENT=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

fail=0
echo; echo "=== ./deploy ==="
CONFIRM=KEEL ./deploy 2>&1 | tee "$LOG/deploy.log" | tail -20
grep -q "manifest ->" "$LOG/deploy.log" || { echo "DEPLOY FAILED"; fail=1; }

if [ $fail -eq 0 ]; then
  echo; echo "=== ./lock (first) ==="
  CONFIRM=LOCK ./lock 2>&1 | tee "$LOG/lock1.log" | tail -6
  echo; echo "=== ./lock (second — must stack, not reset) ==="
  CONFIRM=LOCK ./lock 2>&1 | tee "$LOG/lock2.log" | tail -6
  echo; echo "=== ./exit while locked (must refuse the sweep, still name every balance) ==="
  ./exit 2>&1 | tee "$LOG/exit-locked.log" | tail -14
fi

pkill -f "anvil .*--port $PORT" 2>/dev/null
echo; echo "rehearsal logs in $LOG"
exit $fail

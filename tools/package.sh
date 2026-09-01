#!/usr/bin/env bash
# Build both submission archives. Refuses to package anything that does not pass its gates,
# and refuses to ship a UI zip whose contents differ from vault-ui/ -- the last pair of
# archives sat on disk while the component gained twelve i18n keys and a top risk banner, and
# nothing pointed that out.
#
#   ./tools/package.sh          build both
#   SKIP_SITE=1 ./tools/package.sh   skip the browser gate (no playwright available)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$(cd .. && pwd)}"
fail=0
say() { printf '  %s\n' "$1"; }

echo "=== gates ==="
node tools/check-vault-ui.mjs >/dev/null 2>&1 \
  && say "PASS  vault UI gate" || { say "FAIL  vault UI gate"; fail=1; }
python3 tools/check-docs.py >/dev/null 2>&1 \
  && say "PASS  documents agree with the build" || { say "FAIL  documents vs build"; fail=1; }
./submission/check >/dev/null 2>&1 \
  && say "PASS  submission package self-check" || { say "FAIL  submission check"; fail=1; }
if [ "${SKIP_SITE:-0}" != "1" ]; then
  node tools/qa-site.mjs >/dev/null 2>&1 \
    && say "PASS  site gate" || { say "FAIL  site gate"; fail=1; }
fi

if [ $fail -ne 0 ]; then
  echo; echo "  refusing to package: fix the failures above"; exit 1
fi

echo; echo "=== building ==="
rm -rf /tmp/keelpkg && mkdir -p /tmp/keelpkg/keel /tmp/keelui/keel
rsync -a --exclude lib --exclude out --exclude cache --exclude broadcast --exclude node_modules \
      --exclude .git --exclude .qa --exclude dist --exclude .vercel --exclude '.env*' \
      --exclude site --exclude frontend --exclude .rehearsal --exclude '*.log' \
      --exclude 'scripts/rehearse-ops.sh' ./ /tmp/keelpkg/keel/
rm -f "$OUT/keel-submission.zip"; (cd /tmp/keelpkg && zip -qr "$OUT/keel-submission.zip" keel)

rm -rf /tmp/keelui && mkdir -p /tmp/keelui/keel
cp vault-ui/Component.tsx vault-ui/VaultABI.ts vault-ui/i18n.json vault-ui/manifest.json \
   vault-ui/README.md /tmp/keelui/keel/
rm -f "$OUT/keel-vault-ui.zip"; (cd /tmp/keelui && zip -qr "$OUT/keel-vault-ui.zip" keel)

echo; echo "=== the zip must equal the source, not resemble it ==="
rm -rf /tmp/keelverify && mkdir -p /tmp/keelverify
unzip -q "$OUT/keel-vault-ui.zip" -d /tmp/keelverify
for f in Component.tsx VaultABI.ts i18n.json manifest.json; do
  a=$(md5 -q "vault-ui/$f"); b=$(md5 -q "/tmp/keelverify/keel/$f")
  [ "$a" = "$b" ] && say "PASS  $f matches vault-ui/" || { say "FAIL  $f differs from source"; fail=1; }
done
keys=$(python3 -c "
import json;d=json.load(open('/tmp/keelverify/keel/i18n.json'));print(len(d['en']),len(d['zh']))")
say "NOTE  packaged i18n keys: $keys"
for k in topWarning topBody permissionless bountyDeploy; do
  grep -q "$k" /tmp/keelverify/keel/i18n.json \
    && say "PASS  $k is in the package" || { say "FAIL  $k missing from the package"; fail=1; }
done

echo
ls -la "$OUT/keel-submission.zip" "$OUT/keel-vault-ui.zip" | awk '{printf "  %-46s %8.0f KB\n", $NF, $5/1024}'
[ $fail -eq 0 ] && echo "  both archives built and verified" || echo "  PACKAGED WITH FAILURES"
exit $fail

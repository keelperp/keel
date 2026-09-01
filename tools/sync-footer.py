#!/usr/bin/env python3
"""Write one canonical footer into every page.

The six footers had already drifted into two formatting variants, so editing them by hand is
how a link ends up on five pages out of six. This derives all six from the block below and
exits non-zero if any page did not actually change.
"""
import re, sys, pathlib

SITE = pathlib.Path(__file__).resolve().parent.parent / "site"
PAGES = ["index.html", "how-it-works/index.html", "economics/index.html",
         "vault/index.html", "risks/index.html", "verify/index.html"]

FOOTER = '''<footer>
  <div class="wrap foot-grid">
    <div><p class="foot-h">Product</p>
      <a href="/">Overview</a><a href="/how-it-works/">How it works</a><a href="/economics/">Economics</a><a href="/vault/">The vault</a></div>
    <div><p class="foot-h">Diligence</p>
      <a href="/risks/">Risks</a><a href="/verify/">Verify</a></div>
    <div><p class="foot-h">Follow</p>
      <a href="https://x.com/keel_perp" target="_blank" rel="noopener noreferrer">X &middot; @keel_perp</a></div>
    <div><p class="foot-h">Status</p>
      <span style="color:var(--positive)">Factory live</span>
      <span style="display:block;color:var(--fg-quaternary);padding-top:3px">No token yet &middot; submitted for review</span></div>
  </div>
  <div class="wrap" style="margin-top:30px;padding-top:18px;border-top:1px solid var(--line-soft);font-size:12px;color:var(--fg-quaternary)">
    A 3&times; position is liquidated by a 16.7% move against it. Venus and PancakeSwap are
    dependencies. Submitted to Flap for review; no third-party security audit.
  </div>
</footer>'''

fails, changed = [], 0
for rel in PAGES:
    p = SITE / rel
    if not p.exists():
        fails.append(f"{rel}: missing"); continue
    html = orig = p.read_text()
    new, n = re.subn(r"<footer>.*?</footer>", lambda _: FOOTER, html, flags=re.S)
    if n != 1:
        fails.append(f"{rel}: matched {n} footer blocks, want exactly 1"); continue
    if "x.com/keel_perp" not in new:
        fails.append(f"{rel}: link did not land")
    if new != orig:
        p.write_text(new); changed += 1

# Every page must now carry a byte-identical footer.
seen = {}
for rel in PAGES:
    m = re.search(r"<footer>.*?</footer>", (SITE / rel).read_text(), flags=re.S)
    seen.setdefault(m.group(0) if m else "MISSING", []).append(rel)
if len(seen) != 1:
    fails.append(f"footers still differ across {len(seen)} variants")

if fails:
    print("FAIL:"); [print("  " + f) for f in fails]; sys.exit(1)
print(f"OK  {len(PAGES)} pages share one footer, {changed} rewritten")

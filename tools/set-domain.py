#!/usr/bin/env python3
"""Stamp the canonical origin into every page + regenerate sitemap.xml.

Run again with a new origin when the site moves to a custom domain; it is
idempotent and rewrites in place. Exits non-zero if any single edit did not
land, so a silent partial rewrite can never pass as success.
"""
import re, sys, pathlib

if len(sys.argv) != 2:
    sys.exit("usage: set-domain.py https://example.com")
ORIGIN = sys.argv[1].rstrip("/")
if not ORIGIN.startswith("https://"):
    sys.exit("origin must be https://")

SITE = pathlib.Path(__file__).resolve().parent.parent / "site"
PAGES = {
    "index.html": "/",
    "how-it-works/index.html": "/how-it-works/",
    "economics/index.html": "/economics/",
    "vault/index.html": "/vault/",
    "risks/index.html": "/risks/",
    "verify/index.html": "/verify/",
}

failures, changed = [], 0
for rel, route in PAGES.items():
    p = SITE / rel
    if not p.exists():
        failures.append(f"{rel}: missing"); continue
    html = orig = p.read_text()
    url = ORIGIN + route

    # og:image must be absolute -- crawlers do not resolve relative paths.
    html = re.sub(r'(<meta property="og:image" content=")[^"]*(">)',
                  rf'\1{ORIGIN}/assets/og.png\2', html)

    # canonical + og:url: replace if present, otherwise insert before the icon link.
    if 'rel="canonical"' in html:
        html = re.sub(r'<link rel="canonical" href="[^"]*">',
                      f'<link rel="canonical" href="{url}">', html)
    else:
        html = html.replace('<link rel="icon"',
                            f'<link rel="canonical" href="{url}">\n<link rel="icon"', 1)
    if 'og:url' in html:
        html = re.sub(r'<meta property="og:url" content="[^"]*">',
                      f'<meta property="og:url" content="{url}">', html)
    else:
        html = html.replace('<meta property="og:site_name"',
                            f'<meta property="og:url" content="{url}">\n<meta property="og:site_name"', 1)

    # Verify each edit actually landed, rather than trusting the replace.
    for probe, what in ((f'<link rel="canonical" href="{url}">', "canonical"),
                        (f'<meta property="og:url" content="{url}">', "og:url"),
                        (f'content="{ORIGIN}/assets/og.png"', "og:image")):
        if probe not in html:
            failures.append(f"{rel}: {what} did not land")
    n_canon = html.count('rel="canonical"')
    if n_canon != 1:
        failures.append(f"{rel}: {n_canon} canonical tags, want 1")
    if html != orig:
        p.write_text(html); changed += 1

sitemap = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
for route in PAGES.values():
    prio = "1.0" if route == "/" else "0.7"
    sitemap.append(f"  <url><loc>{ORIGIN}{route}</loc><priority>{prio}</priority></url>")
sitemap.append("</urlset>")
(SITE / "sitemap.xml").write_text("\n".join(sitemap) + "\n")

robots = SITE / "robots.txt"
txt = robots.read_text()
txt = re.sub(r"(?m)^Sitemap: .*$", "", txt).rstrip() + f"\nSitemap: {ORIGIN}/sitemap.xml\n"
robots.write_text(txt)

if failures:
    print("FAIL:"); [print("  " + f) for f in failures]; sys.exit(1)
print(f"OK  origin={ORIGIN}  pages_rewritten={changed}  sitemap={len(PAGES)} urls")

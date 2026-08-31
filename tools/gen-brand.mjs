#!/usr/bin/env node
/**
 * Render the brand assets from the site's own Geist Mono, so the icon and the wordmark in the
 * nav are the same shapes rather than a lookalike. The font is inlined as a data URI because a
 * file:// page will not fetch a sibling font reliably across platforms.
 */
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PW = process.env.PLAYWRIGHT ?? "playwright";
const _pw = await import(PW);
const chromium = _pw.chromium ?? _pw.default?.chromium;

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "site");
const mono = (await readFile(join(ROOT, "assets/fonts/geist-mono-variable.woff2"))).toString("base64");

const BG = "#141414", FG = "#ffffff", ACCENT = "#e0894a";

// wordmark: "keel" in white, the period as a square accent block — matching the supplied logo.
const page = (w, h, fontPx, dotPx, gapPx, radius) => `<!doctype html><meta charset="utf-8">
<style>
  @font-face { font-family:'Geist Mono'; src:url(data:font/woff2;base64,${mono}) format('woff2');
               font-weight:100 900; font-display:block; }
  html,body { margin:0; padding:0; }
  body { width:${w}px; height:${h}px; background:${BG}; display:flex;
         align-items:center; justify-content:center; ${radius ? `border-radius:${radius}px;` : ""} }
  .m { font-family:'Geist Mono'; font-weight:350; font-size:${fontPx}px; color:${FG};
       letter-spacing:0.01em; display:flex; align-items:baseline; gap:${gapPx}px; line-height:1; }
  .d { width:${dotPx}px; height:${dotPx}px; background:${ACCENT}; display:block; }
</style>
<div class="m"><span>keel</span><span class="d"></span></div>`;

const browser = await chromium.launch();
const shoot = async (file, w, h, fontPx, dotPx, gapPx, radius = 0, scale = 1) => {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: scale });
  const p = await ctx.newPage();
  await p.setContent(page(w, h, fontPx, dotPx, gapPx, radius), { waitUntil: "load" });
  await p.evaluate(() => document.fonts.ready);
  await p.screenshot({ path: join(ROOT, file), omitBackground: false });
  await ctx.close();
  console.log(`  ${file}  ${w}x${h}${scale > 1 ? ` @${scale}x` : ""}`);
};

// Social card: wordmark centred on the site's own ground.
await shoot("assets/og.png", 1200, 630, 132, 17, 13);
// Apple touch icon and the PNG favicon fallbacks. The wordmark stays legible down to 180px;
// below that only the "k." survives, so the small sizes use the initial alone.
await shoot("apple-touch-icon.png", 180, 180, 44, 6, 4);
await shoot("assets/logo.png", 1024, 320, 150, 19, 15);
// Submission art: Flap's package carries a square mark and a wide banner alongside the logo.
await shoot("../submission/art/keel-square.png", 1000, 1000, 128, 17, 13);
await shoot("../submission/art/keel-banner.png", 1500, 500, 150, 19, 15);
await shoot("../submission/art/keel-logo-1000.png", 1000, 320, 148, 19, 15);

const initial = (w, fontPx, dotPx, gapPx) => `<!doctype html><meta charset="utf-8">
<style>
  @font-face { font-family:'Geist Mono'; src:url(data:font/woff2;base64,${mono}) format('woff2');
               font-weight:100 900; font-display:block; }
  html,body { margin:0; padding:0; }
  body { width:${w}px; height:${w}px; background:${BG}; display:flex; align-items:center; justify-content:center; }
  .m { font-family:'Geist Mono'; font-weight:400; font-size:${fontPx}px; color:${FG};
       display:flex; align-items:baseline; gap:${gapPx}px; line-height:1; }
  .d { width:${dotPx}px; height:${dotPx}px; background:${ACCENT}; display:block; }
</style>
<div class="m"><span>k</span><span class="d"></span></div>`;

for (const [file, size, fontPx, dotPx, gapPx] of [
  ["favicon-32.png", 32, 20, 4, 2],
  ["favicon-16.png", 16, 11, 2, 1],
]) {
  const ctx = await browser.newContext({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
  const p = await ctx.newPage();
  await p.setContent(initial(size, fontPx, dotPx, gapPx), { waitUntil: "load" });
  await p.evaluate(() => document.fonts.ready);
  await p.screenshot({ path: join(ROOT, file) });
  await ctx.close();
  console.log(`  ${file}  ${size}x${size}`);
}

await browser.close();

#!/usr/bin/env node
/**
 * Renders every page in a real browser and checks what a person would actually see.
 *
 * Element presence is not the test. A previous project passed a headless check while its hero
 * sat underneath a fixed header, so this measures geometry: where the h1 lands relative to the
 * sticky nav, whether the page scrolls sideways, and whether each canvas drew anything at all.
 */
import { createServer } from "node:http";
import { readFile, mkdir, stat } from "node:fs/promises";
import { join, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// Playwright is not a dependency of this repo — point at an existing install rather than
// adding one. ESM ignores NODE_PATH, so the path has to be resolved explicitly.
const PW = process.env.PLAYWRIGHT ?? "playwright";
const _pw = await import(PW);
const chromium = _pw.chromium ?? _pw.default?.chromium;
if (!chromium) throw new Error(`no chromium export from ${PW}`);

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "site");
const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", ".qa");
const PAGES = ["/", "/how-it-works/", "/economics/", "/vault/", "/risks/", "/verify/"];
const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".json": "application/json" };

// With no argument the gate serves ./site itself; with a URL it drives the real deployment,
// which is the only way to see CSP blocks, header effects and font MIME types.
const TARGET = process.argv[2];
const server = createServer(async (req, res) => {
  try {
    let p = decodeURIComponent(req.url.split("?")[0]);
    let f = join(ROOT, p);
    try { if ((await stat(f)).isDirectory()) f = join(f, "index.html"); } catch { f = join(ROOT, p); }
    const body = await readFile(f);
    res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404); res.end("not found");
  }
});
let base;
if (TARGET) {
  base = TARGET.replace(/\/$/, "");
  console.log(`target: ${base}  (live deployment)`);
} else {
  await new Promise((r) => server.listen(0, r));
  base = `http://127.0.0.1:${server.address().port}`;
  console.log(`target: ${base}  (local ./site)`);
}
await mkdir(OUT, { recursive: true });

const browser = await chromium.launch();
let fail = 0;
const say = (ok, msg) => { console.log(`  ${ok ? "PASS" : "FAIL"}  ${msg}`); if (!ok) fail = 1; };

for (const [w, h, label] of [[1440, 900, "desktop"], [390, 844, "mobile"]]) {
  console.log(`\n=== ${label} ${w}x${h} ===`);
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
  for (const path of PAGES) {
    const page = await ctx.newPage();
    const errors = [];
    page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(base + path, { waitUntil: "networkidle" });
    await page.waitForTimeout(700);

    const name0 = path === "/" ? "home" : path.replaceAll("/", "");
    await page.screenshot({ path: join(OUT, `${label}-${name0}.png`), fullPage: false });

    const geo = await page.evaluate(() => {
      const nav = document.querySelector("header.nav").getBoundingClientRect();
      const h1 = document.querySelector("h1").getBoundingClientRect();
      return {
        navBottom: nav.bottom,
        h1Top: h1.top,
        h1Visible: h1.height > 0 && h1.width > 0,
        overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      };
    });

    // Scroll the whole page before judging visibility: .rise starts hidden by design and is
    // revealed on intersection, so anything still at opacity 0 after a full pass is content
    // that no reader will ever see.
    await page.evaluate(async () => {
      // Half-viewport steps with room for the observer callback: at 0.8 screens and 90ms it
      // outran IntersectionObserver and reported content as hidden that a reader would see.
      const step = innerHeight * 0.5;
      for (let y = 0; y <= document.body.scrollHeight; y += step) {
        scrollTo(0, y);
        await new Promise((r) => setTimeout(r, 150));
      }
    });
    await page.waitForTimeout(1000);

    const r = await page.evaluate(() => {
      // Visibility, not presence. The previous version of this file passed /verify/ 14/14
      // while 46% of that page sat at opacity 0, because nothing ever measured whether the
      // content could be seen — only whether the elements existed.
      const hidden = [...document.querySelectorAll("main *")].filter((el) => {
        const cs = getComputedStyle(el);
        if (parseFloat(cs.opacity) > 0.01) return false;
        return el.textContent.trim().length > 20;
      }).length;
      const bodyChars = document.querySelector("main").innerText.trim().length;
      // Only canvases actually on screen: the draw loop deliberately does not run for
      // one that has never been scrolled into view, so an off-screen blank is correct.
      const onScreen = [...document.querySelectorAll("canvas")].filter((c) => {
        const b = c.getBoundingClientRect();
        return b.top < innerHeight && b.bottom > 0 && b.width > 0;
      });
      const canvases = onScreen.map((c) => {
        const g = c.getContext("2d");
        try {
          const d = g.getImageData(0, 0, c.width, c.height).data;
          let lit = 0;
          for (let i = 3; i < d.length; i += 4 * 97) if (d[i] > 8) lit++;
          return { w: c.width, h: c.height, lit };
        } catch { return { w: c.width, h: c.height, lit: -1 }; }
      });
      return {
        hidden,
        bodyChars,
        title: document.title,
        bg: getComputedStyle(document.body).backgroundColor,
        font: getComputedStyle(document.body).fontFamily,
        // computedStyle returns the CSS name whether or not the file loaded, so ask the
        // font system what it actually has, and confirm the face really changes metrics.
        fontsLoaded: [...document.fonts].filter((f) => f.status === "loaded").map((f) => f.family),
        geistReal: document.fonts.check('400 16px Geist') && (() => {
          const m = (fam) => { const s2 = document.createElement("span");
            s2.textContent = "KEELkeel0123456789"; s2.style.cssText =
              `position:absolute;visibility:hidden;font:400 40px ${fam}`;
            document.body.appendChild(s2); const w = s2.getBoundingClientRect().width;
            s2.remove(); return w; };
          return Math.abs(m("Geist") - m("serif")) > 1;
        })(),
        canvases,
        firstScreens: (() => {
          // the last section that begins within two viewport heights
          const secs = [...document.querySelectorAll("section")];
          const within = secs.filter((s) => s.getBoundingClientRect().top < innerHeight * 2).length;
          return { within, total: secs.length };
        })(),
      };
    });

    const tag = `${path}`;
    // The gate judged visibility with getBoundingClientRect, which an overlay on top of the page
    // does not affect at all. An opening animation that never lifts would leave the site blank
    // and every existing check green, so this waits past its duration and asserts it is gone.
    await page.waitForTimeout(1700);
    const opening = await page.evaluate(() => {
      const el = document.getElementById("intro");
      if (!el) return { present: false, blocking: false };
      const cs = getComputedStyle(el);
      const r = el.getBoundingClientRect();
      return {
        present: true,
        blocking: cs.display !== "none" && cs.visibility !== "hidden" &&
                  parseFloat(cs.opacity) > 0.01 && r.width > 0 && r.height > 0,
      };
    });
    say(!opening.blocking, `${tag} the opening has lifted and is not covering the page`);

    const figs = await page.evaluate(() => [...document.images].map((i) => {
      const r = i.getBoundingClientRect();
      // Walk the ancestors: an image is invisible if anything above it is, and the element
      // that hides it is usually a wrapper rather than the image.
      let opacity = 1, node = i;
      while (node && node !== document.documentElement) {
        const cs = getComputedStyle(node);
        if (cs.display === "none" || cs.visibility === "hidden") { opacity = 0; break; }
        opacity = Math.min(opacity, parseFloat(cs.opacity || "1"));
        node = node.parentElement;
      }
      return {
        src: new URL(i.currentSrc || i.src, location.href).pathname,
        ok: i.complete && i.naturalWidth > 0,
        alt: (i.getAttribute("alt") ?? "").trim().length,
        hidden: i.closest("[aria-hidden='true']") !== null,
        visible: opacity > 0.05 && r.width > 0 && r.height > 0,
        opacity: opacity.toFixed(2),
        width: Math.round(r.width),
        // A figure authored at 1000px is meant to run its column. Compare against the column
        // rather than against a pixel count, or every mobile render reads as squeezed.
        wide: (i.getAttribute("width") ?? "") === "1000",
        fill: (() => {
          const col = i.closest(".wrap") ?? i.parentElement;
          const cw = col ? col.getBoundingClientRect().width : 0;
          return cw > 0 ? r.width / cw : 1;
        })(),
      };
    }));
    const invisible = figs.filter((f) => !f.visible);
    say(invisible.length === 0,
      `${tag} every image is actually visible${invisible.length ? ` — ${invisible[0].src} at opacity ${invisible[0].opacity}` : ""}`);
    const squeezed = figs.filter((f) => f.wide && f.fill < 0.85);
    say(squeezed.length === 0,
      `${tag} every full-width figure fills its column${squeezed.length ? ` — ${squeezed[0].src} at ${Math.round(squeezed[0].fill * 100)}% of it` : ""}`);
    const broken = figs.filter((f) => !f.ok);
    say(broken.length === 0, `${tag} ${figs.length} image(s) all decoded${broken.length ? ` — broken: ${broken[0].src}` : ""}`);
    const unlabelled = figs.filter((f) => f.alt === 0 && !f.hidden);
    say(unlabelled.length === 0, `${tag} every content image has alt text${unlabelled.length ? ` — missing on ${unlabelled[0].src}` : ""}`);

    say(errors.length === 0, `${tag} no console errors${errors.length ? ": " + errors[0].slice(0, 90) : ""}`);
    say(geo.h1Visible && geo.h1Top >= geo.navBottom - 1, `${tag} h1 clears the sticky nav (h1 top ${Math.round(geo.h1Top)}, nav bottom ${Math.round(geo.navBottom)})`);
    say(geo.overflowX <= 1, `${tag} no horizontal scroll (${geo.overflowX}px)`);
    say(r.bg === "rgb(20, 20, 20)", `${tag} ground is #141414 (${r.bg})`);
    say(/Geist/.test(r.font), `${tag} Geist is applied (${r.font.split(",")[0]})`);
    say(r.geistReal, `${tag} Geist webfont really loaded, not falling back (${r.fontsLoaded.length} face(s) loaded)`);
    const blank = r.canvases.filter((c) => c.lit === 0);
    say(blank.length === 0, `${tag} ${r.canvases.length} on-screen canvas(es) drew something${blank.length ? ` — ${blank.length} blank` : ""}`);
    say(r.firstScreens.within >= 2, `${tag} ${r.firstScreens.within} of ${r.firstScreens.total} sections start within two screens`);
    say(r.hidden === 0, `${tag} no text is stuck at opacity 0${r.hidden ? ` — ${r.hidden} elements invisible` : ""}`);

    // The same page with scripting off must still carry its content.
    const noJs = await ctx.browser().newContext({ viewport: { width: w, height: h }, javaScriptEnabled: false });
    const np = await noJs.newPage();
    await np.goto(base + path, { waitUntil: "domcontentloaded" });
    const njChars = await np.evaluate(() => document.querySelector("main").innerText.trim().length);
    await noJs.close();
    const kept = r.bodyChars ? njChars / r.bodyChars : 0;
    say(kept > 0.95, `${tag} keeps ${Math.round(kept * 100)}% of its body with JS off`);
    await page.close();
  }
  await ctx.close();
}

console.log("\n=== source rules ===");
{
  const { readFile } = await import("node:fs/promises");
  const offenders = [];
  for (const path of PAGES) {
    const file = join(ROOT, path === "/" ? "index.html" : path.replace(/^\/|\/$/g, "") + "/index.html");
    const html = await readFile(file, "utf8");
    for (const m of html.matchAll(/<figure[^>]*class="([^"]*)"/g)) {
      if (/\bfig\b/.test(m[1]) && /\brise\b/.test(m[1])) offenders.push(path);
    }
  }
  say(offenders.length === 0,
    `no figure depends on the scroll reveal to be visible${offenders.length ? ` — ${offenders[0]}` : ""}`);
}

console.log("\n=== site-wide ===");
{
  const seen = new Set();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  for (const path of PAGES) {
    const page = await ctx.newPage();
    await page.goto(base + path, { waitUntil: "networkidle" });
    for (const src of await page.evaluate(() => [...document.images].map((i) => new URL(i.src, location.href).pathname))) seen.add(src);
    await page.close();
  }
  await ctx.close();
  say(seen.size >= 10, `${seen.size} distinct images across the site (minimum 10)`);
}

await browser.close();
if (!TARGET) server.close();
console.log(`\n  screenshots -> .qa/`);
process.exit(fail);

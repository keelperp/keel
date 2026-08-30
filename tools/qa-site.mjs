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
const { chromium } = await import(PW);

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "site");
const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", ".qa");
const PAGES = ["/", "/how-it-works/", "/economics/", "/vault/", "/risks/", "/verify/"];
const MIME = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".json": "application/json" };

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
await new Promise((r) => server.listen(0, r));
const base = `http://127.0.0.1:${server.address().port}`;
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
    say(errors.length === 0, `${tag} no console errors${errors.length ? ": " + errors[0].slice(0, 90) : ""}`);
    say(geo.h1Visible && geo.h1Top >= geo.navBottom - 1, `${tag} h1 clears the sticky nav (h1 top ${Math.round(geo.h1Top)}, nav bottom ${Math.round(geo.navBottom)})`);
    say(geo.overflowX <= 1, `${tag} no horizontal scroll (${geo.overflowX}px)`);
    say(r.bg === "rgb(20, 20, 20)", `${tag} ground is #141414 (${r.bg})`);
    say(/Geist/.test(r.font), `${tag} Geist is applied (${r.font.split(",")[0]})`);
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

await browser.close();
server.close();
console.log(`\n  screenshots -> .qa/`);
process.exit(fail);

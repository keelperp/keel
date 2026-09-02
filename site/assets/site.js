/* Shared behaviour: nav state, scroll reveals, and a DPR-correct canvas helper.
   Every visual on this site is drawn, not photographed — the subject is a position and a
   clock, and those are better as geometry than as stock imagery. */

// Mark the document as scripted so the stylesheet may hide .rise. Without this the
// reveal stays off and every section renders plainly, which is the correct failure.
document.documentElement.classList.add("js");

// aria-current is written into each page's HTML, so it survives with JS off. Nothing to do
// here beyond marking the document as scripted, above.

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

const io = new IntersectionObserver(
  (entries) => entries.forEach((e) => e.isIntersecting && (e.target.classList.add("in"), io.unobserve(e.target))),
  { rootMargin: "0px 0px -8% 0px", threshold: 0.06 }
);
document.querySelectorAll(".rise").forEach((el, i) => {
  el.style.transitionDelay = `${Math.min(i % 5, 4) * 60}ms`;
  io.observe(el);
});

/** Sizes a canvas to its box at device pixel ratio and returns a ready 2D context. */
export function fitCanvas(cv, cssHeight) {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = cv.clientWidth || cv.parentElement.clientWidth;
  const h = cssHeight;
  cv.width = Math.round(w * dpr);
  cv.height = Math.round(h * dpr);
  cv.style.height = h + "px";
  const ctx = cv.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w, h };
}

/** Runs a draw(t) loop only while the canvas is on screen, and once if motion is reduced. */
export function animate(cv, draw) {
  let raf = 0;
  let running = false;
  const tick = (t) => {
    // Reschedule in a finally: one throwing frame used to kill a canvas permanently and
    // silently, leaving a detailed figcaption describing an empty box.
    try {
      draw(t / 1000);
    } catch (e) {
      console.error("canvas draw failed", e);
    } finally {
      if (running) raf = requestAnimationFrame(tick);
    }
  };
  const obs = new IntersectionObserver((es) => {
    es.forEach((e) => {
      if (e.isIntersecting && !running && !reduced) {
        running = true;
        raf = requestAnimationFrame(tick);
      } else if (!e.isIntersecting && running) {
        running = false;
        cancelAnimationFrame(raf);
      }
    });
  });
  if (reduced) draw(0);
  else obs.observe(cv);
  addEventListener("resize", () => draw(performance.now() / 1000), { passive: true });
}

/** Cached per canvas: reading clientWidth and writing width/height every frame forced one
 *  style recalculation per frame. Geometry only changes on resize. */
const geom = new WeakMap();

export function fitCanvasCached(cv, height) {
  const hit = geom.get(cv);
  if (hit && hit.h === height && hit.w === (cv.clientWidth || cv.parentElement.clientWidth)) {
    return hit;
  }
  const box = fitCanvas(cv, height);
  geom.set(cv, box);
  return box;
}

export const C = {
  bg: "#191919",
  line: "rgba(255,255,255,0.12)",
  lineSoft: "rgba(255,255,255,0.08)",
  fg: "#ffffff",
  strong: "rgba(255,255,255,0.8)",
  body: "rgba(255,255,255,0.7)",
  dim: "rgba(255,255,255,0.4)",
  faint: "rgba(255,255,255,0.2)",
  accent: "#e0894a",
  positive: "#5bbf9a",
  negative: "#d96a6a",
  warn: "#d9b45b",
  info: "#6aa3d8",
  mono: '11px "Geist Mono", ui-monospace, monospace',
  monoSm: '10px "Geist Mono", ui-monospace, monospace',
};

/* The opening. It is opt-in from script, so a reader without JS gets the page with no overlay
   at all rather than a black screen that never lifts. It also runs once per session: a reader
   moving between pages should not sit through it five times. */
(function opening() {
  const root = document.documentElement;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let seen = false;
  try { seen = sessionStorage.getItem("keel.intro") === "1"; } catch { seen = false; }
  if (reduce || seen) return;
  try { sessionStorage.setItem("keel.intro", "1"); } catch { /* private mode: show it, once */ }
  root.classList.add("intro-run");
  const lift = () => {
    root.classList.add("intro-out");
    setTimeout(() => {
      root.classList.remove("intro-run", "intro-out");
      const el = document.getElementById("intro");
      if (el) el.remove();
    }, 560);
  };
  // Fixed delay rather than waiting on load: a slow asset must never hold the page behind it.
  setTimeout(lift, 1180);
})();

/**
 * Leverage dial. The reader drags it and watches health and the distance to liquidation move
 * together, which is the whole argument for why 3x is a ceiling rather than a preference --
 * an argument that takes three paragraphs to write and one drag to feel.
 *
 * health = CF * L / (L - 1), and the liquidation drop is 1 - 1/(L * (1 - CF) + CF)... in the
 * shape the lending market actually uses: a position is liquidated once health reaches 1.00, which for a
 * long at leverage L happens after the collateral falls by (health - 1) / health.
 */
export function leverageDial(root) {
  const CF = 0.8;
  const cv = root.querySelector("canvas");
  const slider = root.querySelector("input[type=range]");
  const out = {
    lev: root.querySelector("[data-out=lev]"),
    health: root.querySelector("[data-out=health]"),
    drop: root.querySelector("[data-out=drop]"),
    verdict: root.querySelector("[data-out=verdict]"),
  };
  if (!cv || !slider) return;

  const model = (L) => {
    const health = (CF * L) / (L - 1);
    return { health, drop: health <= 1 ? 0 : (health - 1) / health };
  };

  const draw = (L) => {
    const { ctx, w, h } = fitCanvas(cv, 126);
    const { health, drop } = model(L);
    ctx.clearRect(0, 0, w, h);
    const padL = 8, padR = 8, trackW = w - padL - padR, y = 56;

    ctx.font = C.monoSm; ctx.fillStyle = C.dim; ctx.textAlign = "left";
    ctx.fillText("NVDA against the position", padL, 20);
    ctx.textAlign = "right"; ctx.fillText("−40%", padL + trackW, 20);

    ctx.strokeStyle = C.lineSoft; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(padL + trackW, y); ctx.stroke();

    const frac = Math.min(drop / 0.4, 1);
    const tone = health >= 1.3 ? C.positive : health >= 1.2 ? C.accent : health > 1.05 ? C.warn : C.negative;
    ctx.strokeStyle = tone; ctx.lineWidth = 3;
    ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(padL + trackW * frac, y); ctx.stroke();

    const x = padL + trackW * frac;
    ctx.fillStyle = tone;
    ctx.beginPath(); ctx.arc(x, y, 5, 0, Math.PI * 2); ctx.fill();
    ctx.font = C.mono; ctx.textAlign = frac > 0.8 ? "right" : "left";
    ctx.fillText(`−${(drop * 100).toFixed(1)}%`, frac > 0.8 ? x - 12 : x + 12, y - 14);

    // The floor the contract enforces, drawn wherever it currently sits.
    const floorDrop = (1.2 - 1) / 1.2, fx = padL + trackW * Math.min(floorDrop / 0.4, 1);
    ctx.strokeStyle = C.lineSoft; ctx.setLineDash([3, 4]);
    ctx.beginPath(); ctx.moveTo(fx, y + 14); ctx.lineTo(fx, y + 34); ctx.stroke(); ctx.setLineDash([]);
    ctx.fillStyle = C.dim; ctx.font = C.monoSm; ctx.textAlign = "center";
    ctx.fillText("health 1.20", fx, y + 48);
  };

  const update = () => {
    const L = Number(slider.value) / 100;
    const { health, drop } = model(L);
    if (out.lev) out.lev.textContent = `${L.toFixed(2)}×`;
    if (out.health) out.health.textContent = health.toFixed(3);
    if (out.drop) out.drop.textContent = `−${(drop * 100).toFixed(1)}%`;
    if (out.verdict) {
      out.verdict.textContent =
        L > 4.99 ? "this is the liquidation point itself"
        : health < 1.2 ? "below the floor the contract enforces"
        : health < 1.25 ? "exactly on the floor — where 3× sits"
        : "inside the floor";
      out.verdict.style.color = health < 1.2 ? "var(--negative)" : health < 1.25 ? "var(--accent)" : "var(--positive)";
    }
    draw(L);
  };
  slider.addEventListener("input", update);
  addEventListener("resize", update);
  update();
}

/**
 * The build, as a sequence rather than four boxes. The lending market checks collateral before the borrowed
 * funds become collateral, so the four steps have to happen inside one transaction -- which is
 * a thing to watch happen, not a thing to read about.
 */
export function buildSequence(cv) {
  const STEPS = [
    { t: "flash", d: "borrow WETH from the V3 pool", c: () => C.accent },
    { t: "supply", d: "into the lending market as collateral", c: () => C.positive },
    { t: "borrow", d: "USDT against it", c: () => C.negative },
    { t: "repay", d: "swap back, close the flash", c: () => C.accent },
  ];
  const PERIOD = 1.35;
  animate(cv, (t) => {
    const { ctx, w, h } = fitCanvas(cv, 168);
    ctx.clearRect(0, 0, w, h);
    const padL = 10, padR = 10, trackW = w - padL - padR;
    const y = 96, cell = trackW / STEPS.length;
    const phase = (t / PERIOD) % (STEPS.length + 0.8);

    ctx.strokeStyle = C.lineSoft; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(padL + trackW, y); ctx.stroke();

    STEPS.forEach((s, i) => {
      const cx = padL + cell * (i + 0.5);
      const active = phase >= i && phase < i + 1;
      const done = phase >= i + 1;
      const grow = active ? Math.min((phase - i) * 1.6, 1) : done ? 1 : 0;
      const col = done || active ? s.c() : C.lineSoft;

      if (i > 0 && (done || active)) {
        const px = padL + cell * (i - 0.5);
        ctx.strokeStyle = STEPS[i - 1].c(); ctx.lineWidth = 2;
        ctx.beginPath(); ctx.moveTo(px + 20, y);
        ctx.lineTo(px + 20 + (cx - px - 40) * (active ? grow : 1), y); ctx.stroke();
      }
      ctx.fillStyle = col; ctx.globalAlpha = done || active ? 1 : 0.35;
      ctx.beginPath(); ctx.arc(cx, y, active ? 6 + grow * 3 : 6, 0, Math.PI * 2); ctx.fill();
      ctx.globalAlpha = 1;

      ctx.textAlign = "center"; ctx.font = C.mono;
      ctx.fillStyle = done || active ? C.fg : C.dim;
      ctx.fillText(s.t, cx, y - 24);
      ctx.font = C.monoSm; ctx.fillStyle = C.dim;
      const words = s.d.split(" "); let line = "", ly = y + 26;
      words.forEach((word) => {
        if ((line + word).length > 20) { ctx.fillText(line, cx, ly); line = word + " "; ly += 14; }
        else line += word + " ";
      });
      ctx.fillText(line.trim(), cx, ly);
    });

    ctx.textAlign = "left"; ctx.font = C.monoSm; ctx.fillStyle = C.dim;
    ctx.fillText("one transaction", padL, 24);
    ctx.textAlign = "right";
    ctx.fillText("The lending market checks collateral before the borrowed funds become collateral", padL + trackW, 24);
  });
}

/* Contract address. Set data-ca on #ca once the token exists and this fills itself in. With no
   address it keeps saying "not launched yet" rather than rendering something copyable. */
(function () {
  var el = document.getElementById("ca");
  if (!el) return;
  var val = document.getElementById("ca-value");
  var btn = document.getElementById("ca-copy");
  var addr = (el.getAttribute("data-ca") || "").trim();
  if (!addr) return;
  val.textContent = addr;
  btn.hidden = false;
  btn.addEventListener("click", function () {
    navigator.clipboard.writeText(addr).then(function () {
      btn.textContent = "copied";
      setTimeout(function () { btn.textContent = "copy"; }, 1200);
    }, function () {});
  });
})();

/* Shared behaviour: nav state, scroll reveals, and a DPR-correct canvas helper.
   Every visual on this site is drawn, not photographed — the subject is a position and a
   clock, and those are better as geometry than as stock imagery. */

document.querySelectorAll("header.nav a.link").forEach((a) => {
  const here = location.pathname.replace(/index\.html$/, "").replace(/\/$/, "") || "/";
  const there = a.getAttribute("href").replace(/index\.html$/, "").replace(/\/$/, "") || "/";
  if (here === there) a.setAttribute("aria-current", "page");
});

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
    draw(t / 1000);
    if (running) raf = requestAnimationFrame(tick);
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

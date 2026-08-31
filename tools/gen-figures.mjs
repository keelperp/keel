#!/usr/bin/env node
/**
 * Render the site's figures. They share one palette, one typeface and one geometric vocabulary,
 * and each one draws a concept that exists in the contract -- not decoration.
 *
 * They are generated rather than sourced: the site's CSP is `img-src 'self' data:`, so a remote
 * image would not load, and a generated one has a provenance we can point at.
 */
import { readFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PW = process.env.PLAYWRIGHT ?? "playwright";
const _pw = await import(PW);
const chromium = _pw.chromium ?? _pw.default?.chromium;

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "site");
const OUT = join(ROOT, "assets/fig");
await mkdir(OUT, { recursive: true });

const mono = (await readFile(join(ROOT, "assets/fonts/geist-mono-variable.woff2"))).toString("base64");
const sans = (await readFile(join(ROOT, "assets/fonts/geist-variable.woff2"))).toString("base64");

const BG = "#141414", SURF = "#191919", LINE = "#2a2a2a", LINE2 = "#3a3a3a";
const FG = "#f2f0ed", DIM = "#8b8b88", MUTE = "#5f5f5d";
const ACC = "#e0894a", POS = "#5bbf9a", NEG = "#c2554a", WARN = "#d9a441";

const shell = (body, extra = "") => `<!doctype html><meta charset="utf-8"><style>
@font-face{font-family:'GM';src:url(data:font/woff2;base64,${mono}) format('woff2');font-weight:100 900;font-display:block}
@font-face{font-family:'GS';src:url(data:font/woff2;base64,${sans}) format('woff2');font-weight:100 900;font-display:block}
*{margin:0;padding:0;box-sizing:border-box}
body{background:${BG};color:${FG};font-family:'GS',system-ui,sans-serif;-webkit-font-smoothing:antialiased}
.m{font-family:'GM',ui-monospace,monospace}
.lbl{font-family:'GM',monospace;font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:${MUTE}}
.cap{font-family:'GM',monospace;font-size:12.5px;color:${DIM}}
.val{font-family:'GM',monospace;font-variant-numeric:tabular-nums}
.box{border:1px solid ${LINE};border-radius:8px;background:${SURF}}
${extra}
</style>${body}`;

const browser = await chromium.launch();
const shoot = async (name, w, h, body, extra) => {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
  const p = await ctx.newPage();
  await p.setContent(shell(body, extra), { waitUntil: "load" });
  await p.evaluate(() => document.fonts.ready);
  const real = await p.evaluate(() => {
    const b = document.body, cs = getComputedStyle(b);
    const kids = [...b.children];
    const bottom = kids.length ? Math.max(...kids.map((k) => k.getBoundingClientRect().bottom)) : 0;
    return Math.ceil(bottom + parseFloat(cs.paddingBottom || "0"));
  });
  const height = Math.max(120, real);
  await p.setViewportSize({ width: w, height });
  await p.screenshot({ path: join(OUT, name) });
  await ctx.close();
  console.log(`  ${name}  ${w}x${height}@2x`);
};

const W = 1000, PAD = 40;

/* 1 — where the tax goes: the whole argument in one picture */
await shoot("tax-route.png", W, 420, `<body style="padding:${PAD}px">
  <div class="lbl">每 2% · where each 2% goes</div>
  <div style="display:flex;align-items:stretch;gap:0;margin-top:26px;height:120px">
    <div style="flex:80;background:linear-gradient(90deg,${ACC}22,${ACC}44);border:1px solid ${ACC}66;border-right:0;border-radius:8px 0 0 8px;padding:16px 18px;display:flex;flex-direction:column;justify-content:space-between">
      <div class="lbl" style="color:${ACC}">80% → vault</div>
      <div style="font-size:15px;line-height:1.4">becomes a 3× BNB long<br><span class="cap">the contract holds it</span></div>
    </div>
    <div style="flex:20;background:${POS}18;border:1px solid ${POS}55;border-radius:0 8px 8px 0;padding:16px 18px;display:flex;flex-direction:column;justify-content:space-between">
      <div class="lbl" style="color:${POS}">20% → holders</div>
      <div class="cap" style="font-size:12px">paid at once</div>
    </div>
  </div>
  <div style="display:flex;gap:10px;margin-top:22px">
    <div class="box" style="flex:1;padding:14px 16px"><div class="lbl">burn</div><div class="val" style="font-size:22px;color:${MUTE};margin-top:6px">0%</div></div>
    <div class="box" style="flex:1;padding:14px 16px"><div class="lbl">liquidity</div><div class="val" style="font-size:22px;color:${MUTE};margin-top:6px">0%</div></div>
    <div class="box" style="flex:2;padding:14px 16px"><div class="lbl">fixed at launch · sums to</div><div class="val" style="font-size:22px;color:${FG};margin-top:6px">10000 bps</div></div>
  </div>
</body>`);

/* 2 — the position itself */
await shoot("leverage-stack.png", W, 430, `<body style="padding:${PAD}px">
  <div class="lbl">the position · 1 BNB of tax becomes</div>
  <div style="margin-top:30px;display:flex;flex-direction:column;gap:12px">
    <div style="display:flex;align-items:center;gap:16px">
      <div class="cap" style="width:120px;text-align:right">supply</div>
      <div style="flex:1;height:52px;background:${ACC}33;border:1px solid ${ACC};border-radius:6px;display:flex;align-items:center;padding:0 16px">
        <span class="val" style="font-size:19px;color:${ACC}">3.00 BNB</span>
        <span class="cap" style="margin-left:auto">supplied to Venus as vBNB</span>
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:16px">
      <div class="cap" style="width:120px;text-align:right">debt</div>
      <div style="width:calc(66.6% - 0px);height:52px;background:${NEG}22;border:1px solid ${NEG}88;border-radius:6px;display:flex;align-items:center;padding:0 16px">
        <span class="val" style="font-size:19px;color:${NEG}">2.00 BNB</span>
        <span class="cap" style="margin-left:auto">borrowed in USDT</span>
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:16px">
      <div class="cap" style="width:120px;text-align:right">net</div>
      <div style="width:calc(33.3%);height:52px;background:${POS}22;border:1px solid ${POS};border-radius:6px;display:flex;align-items:center;padding:0 16px">
        <span class="val" style="font-size:19px;color:${POS}">1.00 BNB</span>
      </div>
    </div>
  </div>
  <div class="cap" style="margin-top:24px">3.00 supplied · 2.00 owed · <span style="color:${FG}">3× exposure on 1.00 of value</span></div>
</body>`);

/* 3 — why three and not five */
await shoot("why-three.png", W, 400, `<body style="padding:${PAD}px">
  <div class="lbl">health = CF × L / (L − 1) · at Venus CF 0.80</div>
  <div style="display:flex;gap:12px;margin-top:28px">
    ${[["2×","1.60",POS,"comfortable"],["3×","1.20",ACC,"the floor, exactly"],["4×","1.07",WARN,"below the floor"],["5×","1.00",NEG,"liquidation itself"]]
      .map(([l,h,c,note])=>`
      <div class="box" style="flex:1;padding:18px 16px;border-color:${c}55">
        <div class="val" style="font-size:26px;color:${c}">${l}</div>
        <div class="val" style="font-size:15px;color:${FG};margin-top:10px">health ${h}</div>
        <div class="cap" style="margin-top:8px;font-size:11.5px;color:${c}">${note}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:26px">5× is not a risk preference. It is the liquidation point itself, which is why the contract has no 5× —
  and why <span style="color:${ACC}">MIN_HEALTH_BPS = 12000</span> is a constant rather than an operating rule.</div>
</body>`);

/* 4 — the distance to liquidation, stated plainly */
await shoot("liquidation-distance.png", W, 330, `<body style="padding:${PAD}px">
  <div class="lbl">what a 3× long costs · BNB move against the position</div>
  <div style="position:relative;margin-top:34px;height:76px">
    <div style="position:absolute;inset:0;background:linear-gradient(90deg,${POS}22,${WARN}22 55%,${NEG}55);border:1px solid ${LINE2};border-radius:8px"></div>
    <div style="position:absolute;left:0;top:0;bottom:0;width:1px;background:${LINE2}"></div>
    <div style="position:absolute;left:41.75%;top:-10px;bottom:-10px;width:2px;background:${NEG}"></div>
    <div style="position:absolute;left:calc(41.75% + 12px);top:14px">
      <div class="val" style="font-size:24px;color:${NEG}">−16.7%</div>
      <div class="cap" style="font-size:11.5px;margin-top:2px">liquidated here</div>
    </div>
    <div style="position:absolute;left:12px;top:22px" class="cap">0%</div>
    <div style="position:absolute;right:12px;top:22px;text-align:right" class="cap">−40%</div>
  </div>
  <div class="cap" style="margin-top:22px">This is the price of a treasury that moves when nobody trades. It is on the front page for that reason.</div>
</body>`);

/* 5 — one job per wake */
await shoot("priority-chain.png", W, 440, `<body style="padding:${PAD}px">
  <div class="lbl">every wake · the first true branch wins, then it stops</div>
  <div style="margin-top:26px;display:flex;flex-direction:column;gap:10px">
    ${[["1","health < 1.10","rescue — shrink both legs",NEG],
       ["2","pending ≥ 0.01 BNB","deploy — build toward 3×",ACC],
       ["3","gain ≥ 0.02 BNB","harvest — 70 / 30, paid in WBNB",POS],
       ["4","leverage outside ±5%","rebalance — back to target",WARN],
       ["—","none of the above","book the next slot and stop",MUTE]]
      .map(([n,cond,act,c])=>`
      <div style="display:flex;align-items:center;gap:14px">
        <div class="val" style="width:26px;height:26px;border:1px solid ${c};border-radius:50%;color:${c};display:flex;align-items:center;justify-content:center;font-size:12px">${n}</div>
        <div class="val" style="width:200px;font-size:13px;color:${c}">${cond}</div>
        <div style="flex:1;height:1px;background:${LINE}"></div>
        <div style="width:330px;font-size:14px;color:${FG}">${act}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:24px">Woken every 5 minutes by Flap's trigger service · 1.20–1.24M gas against a 2,000,000 cap</div>
</body>`);

/* 6 — the flash loan, and why it is required */
await shoot("flash-sequence.png", W, 400, `<body style="padding:${PAD}px">
  <div class="lbl">building the position · why a flash loan is required, not preferred</div>
  <div style="display:flex;gap:0;margin-top:30px;align-items:stretch">
    ${[["1","flash WBNB","from the V3 pool"],["2","supply","to Venus as collateral"],["3","borrow USDT","against it"],["4","swap + repay","the flash in the same tx"]]
      .map(([n,t2,s2],i)=>`
      <div style="flex:1;position:relative;padding-right:${i<3?"18px":"0"}">
        <div class="box" style="padding:16px 14px;height:100%">
          <div class="val" style="font-size:11px;color:${ACC}">step ${n}</div>
          <div style="font-size:15px;margin-top:8px;color:${FG}">${t2}</div>
          <div class="cap" style="margin-top:6px;font-size:11.5px">${s2}</div>
        </div>
        ${i<3?`<div style="position:absolute;right:4px;top:50%;color:${LINE2};font-size:16px">→</div>`:""}
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:26px">Venus checks collateral <span style="color:${FG}">before</span> the borrowed funds become collateral.
  Without the flash there is no ordering that works — the position cannot be opened at all.</div>
</body>`);

/* 7 — the split */
await shoot("split-70-30.png", W, 330, `<body style="padding:${PAD}px">
  <div class="lbl">every harvest · after the caller's bounty</div>
  <div style="display:flex;margin-top:28px;height:96px;border-radius:8px;overflow:hidden;border:1px solid ${LINE2}">
    <div style="flex:70;background:${POS}22;border-right:1px solid ${LINE2};padding:18px 20px">
      <div class="val" style="font-size:30px;color:${POS}">70%</div>
      <div class="cap" style="margin-top:6px">holders · WBNB via the token's dividend contract</div>
    </div>
    <div style="flex:30;background:${ACC}18;padding:18px 20px">
      <div class="val" style="font-size:30px;color:${ACC}">30%</div>
      <div class="cap" style="margin-top:6px">project · fixed at creation</div>
    </div>
  </div>
  <div class="cap" style="margin-top:20px"><span class="val" style="color:${FG}">PROJECT_SHARE_BPS = 3000</span> · constant, no setter.
  Holders take 2.33× whatever the project takes, every time.</div>
</body>`);

/* 8 — the four constants */
await shoot("constants.png", W, 300, `<body style="padding:${PAD}px">
  <div class="lbl">no setter · no role · no governance path</div>
  <div style="display:flex;gap:12px;margin-top:26px">
    ${[["TARGET_LEVERAGE","3×"],["MIN_HEALTH_BPS","1.20"],["PROJECT_SHARE_BPS","30%"],["TRIGGER_INTERVAL","5 min"]]
      .map(([k,v])=>`
      <div class="box" style="flex:1;padding:18px 16px">
        <div class="val" style="font-size:10.5px;color:${MUTE};letter-spacing:.04em">${k}</div>
        <div class="val" style="font-size:27px;color:${ACC};margin-top:12px">${v}</div>
      </div>`).join("")}
  </div>
</body>`);

/* 9 — the upgrade boundary, stated honestly */
await shoot("beacon-guardian.png", W, 360, `<body style="padding:${PAD}px">
  <div class="lbl">who can change what</div>
  <div style="display:flex;gap:14px;margin-top:26px;align-items:stretch">
    <div class="box" style="flex:1;padding:18px;border-color:${LINE}">
      <div class="cap" style="color:${MUTE}">project · deployer · holders</div>
      <div style="font-size:17px;margin-top:12px;color:${FG}">nothing</div>
      <div class="cap" style="margin-top:8px;font-size:11.5px">every value is a constant with no setter</div>
    </div>
    <div class="box" style="flex:1;padding:18px;border-color:${WARN}66">
      <div class="cap" style="color:${WARN}">flap guardian</div>
      <div style="font-size:17px;margin-top:12px;color:${FG}">can replace the implementation</div>
      <div class="cap" style="margin-top:8px;font-size:11.5px">the beacon it owns, transferred in the constructor</div>
    </div>
  </div>
  <div class="cap" style="margin-top:22px">Stated here rather than left out: the vault runs behind a BeaconProxy, and that upgrade path is real.
  The deployer never held it.</div>
</body>`);

/* 10 — what a reader can check themselves */
await shoot("verify-surface.png", W, 380, `<body style="padding:${PAD}px">
  <div class="lbl">nothing here asks to be believed</div>
  <div style="margin-top:24px;display:flex;flex-direction:column;gap:9px">
    ${[["nav()","what the treasury is worth, right now"],
       ["leverage()","how levered it is against the 3× target"],
       ["health()","distance to liquidation, in bps"],
       ["pendingAction()","what the next wake will do"],
       ["PROJECT_SHARE_BPS","the split, as a constant"]]
      .map(([fn,d2])=>`
      <div style="display:flex;align-items:baseline;gap:16px;padding:11px 14px;border-left:2px solid ${ACC}55;background:${SURF}">
        <span class="val" style="font-size:14px;color:${ACC};width:190px">${fn}</span>
        <span class="cap" style="font-size:13px">${d2}</span>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:22px">All <span style="color:${FG}">view</span> functions. Call them against the chain and you have priced the treasury yourself.</div>
</body>`);

/* 11 — the comparison, as a picture */
await shoot("wallet-vs-position.png", W, 340, `<body style="padding:${PAD}px">
  <div style="display:flex;gap:0;align-items:stretch;height:100%">
    <div style="flex:1;padding:20px 24px 20px 0;border-right:1px solid ${LINE}">
      <div class="lbl">most tokens with a tax</div>
      <div style="margin-top:20px;display:flex;flex-direction:column;gap:13px;color:${DIM};font-size:14.5px;line-height:1.4">
        <div>the tax reaches a wallet</div>
        <div>what happens next is a promise</div>
        <div>the treasury is a number somebody publishes</div>
        <div>no trades, no income</div>
      </div>
    </div>
    <div style="flex:1;padding:20px 0 20px 24px">
      <div class="lbl" style="color:${ACC}">keel</div>
      <div style="margin-top:20px;display:flex;flex-direction:column;gap:13px;font-size:14.5px;line-height:1.4">
        <div>the tax reaches a Venus position the contract holds</div>
        <div>what happens next is a <span class="val" style="color:${ACC}">constant</span></div>
        <div>the treasury is a <span class="val" style="color:${ACC}">view</span> function you call</div>
        <div style="color:${FG}">it moves whenever BNB moves</div>
      </div>
    </div>
  </div>
</body>`);


/* ── second set: one visual for every section that had none ───────────────── */

/* the reserve, against the two shapes it is not */
await shoot("reserve-shapes.png", W, 400, `<body style="padding:${PAD}px">
  <div class="lbl">where a treasury can live</div>
  <div style="display:flex;gap:12px;margin-top:26px">
    ${[["a multisig","an account somebody controls",`${MUTE}`,"×"],
       ["a perp position","held at a venue, on an account",`${MUTE}`,"×"],
       ["this vault","the contract is the borrower",`${ACC}`,"✓"]]
      .map(([t2,s2,c,mark])=>`
      <div class="box" style="flex:1;padding:20px 18px;border-color:${c==ACC?ACC+"66":LINE}">
        <div style="display:flex;align-items:center;gap:9px">
          <span class="val" style="color:${c};font-size:15px">${mark}</span>
          <span style="font-size:16px;color:${c==ACC?FG:DIM}">${t2}</span>
        </div>
        <div class="cap" style="margin-top:11px;font-size:12px">${s2}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:24px">Venus holds the collateral and the contract is the borrower. There is no account in between,
  which is also why there is nobody to ask for it back.</div>
</body>`);

/* the cadence, as a dial rather than a sentence */
await shoot("wake-schedule.png", W, 330, `<body style="padding:${PAD}px">
  <div class="lbl">the cadence · what wakes it</div>
  <div style="display:flex;align-items:center;gap:0;margin-top:30px">
    ${[["5 min","working",ACC],["5 min","working",ACC],["5 min","working",ACC],["1 hr","idle",MUTE]]
      .map(([t2,s2,c],i)=>`
      <div style="flex:${i===3?2:1};text-align:center;position:relative">
        <div style="height:3px;background:${c};opacity:${c===ACC?1:.4}"></div>
        <div class="val" style="font-size:17px;color:${c};margin-top:12px">${t2}</div>
        <div class="cap" style="font-size:11px;margin-top:4px">${s2}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:26px">Flap's trigger service buys the next slot before the work runs, so one failed wake cannot
  break the chain that would have retried it. When there is nothing to do it drops to hourly.</div>
</body>`);

/* what leaves and what stays */
await shoot("gain-vs-principal.png", W, 360, `<body style="padding:${PAD}px">
  <div class="lbl">a harvest · what leaves, what stays</div>
  <div style="margin-top:28px;display:flex;gap:14px;align-items:stretch">
    <div style="flex:2;border:1px solid ${ACC}55;border-radius:8px;background:${ACC}14;padding:20px">
      <div class="lbl" style="color:${ACC}">stays</div>
      <div style="font-size:17px;margin-top:10px">the position itself</div>
      <div class="cap" style="margin-top:8px;font-size:12px">supply and debt both shrink only enough to free the gain</div>
    </div>
    <div style="flex:1;border:1px solid ${POS}66;border-radius:8px;background:${POS}14;padding:20px">
      <div class="lbl" style="color:${POS}">leaves</div>
      <div style="font-size:17px;margin-top:10px">the gain only</div>
      <div class="cap" style="margin-top:8px;font-size:12px">70% holders · 30% project</div>
    </div>
  </div>
  <div class="cap" style="margin-top:22px">The principal is never withdrawn. What compounds is the position; what is paid out is only
  what the position earned since the last harvest.</div>
</body>`);

/* the bounties, as amounts rather than a paragraph */
await shoot("bounties.png", W, 320, `<body style="padding:${PAD}px">
  <div class="lbl">every job pays whoever does it · permissionless</div>
  <div style="display:flex;gap:12px;margin-top:26px">
    ${[["deployPending","25 bps","of what it deploys"],
       ["harvest","50 bps","of the gain"],
       ["rebalance","30 bps","of what it frees"]]
      .map(([fn,bp,of])=>`
      <div class="box" style="flex:1;padding:18px 16px">
        <div class="val" style="font-size:12.5px;color:${ACC}">${fn}()</div>
        <div class="val" style="font-size:25px;margin-top:12px">${bp}</div>
        <div class="cap" style="font-size:11.5px;margin-top:6px">${of}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:22px">The automatic path pays no bounty at all — the trigger fee already came out of the vault.
  Nobody has to show up, but anybody may.</div>
</body>`);

/* what running it costs */
await shoot("running-costs.png", W, 330, `<body style="padding:${PAD}px">
  <div class="lbl">what it costs to keep turning</div>
  <div style="margin-top:26px;display:flex;flex-direction:column;gap:10px">
    ${[["trigger fee","0.0002 BNB","per slot, paid to Flap's service",MUTE],
       ["Venus borrow APR","variable","the cost of the leverage itself",WARN],
       ["swap fee","0.05%","the deepest WBNB/USDT tier",MUTE],
       ["bounties","25–50 bps","only on the manual path",MUTE]]
      .map(([k,v,d2,c])=>`
      <div style="display:flex;align-items:baseline;gap:14px;padding:12px 16px;background:${SURF};border-left:2px solid ${c}66">
        <span style="width:170px;font-size:14px;color:${FG}">${k}</span>
        <span class="val" style="width:120px;font-size:14px;color:${c===WARN?WARN:ACC}">${v}</span>
        <span class="cap" style="font-size:12px">${d2}</span>
      </div>`).join("")}
  </div>
</body>`);

/* the readings a live vault answers */
await shoot("live-readings.png", W, 340, `<body style="padding:${PAD}px">
  <div class="lbl">measured on live BNB Chain state · not a simulation</div>
  <div style="display:flex;gap:12px;margin-top:26px">
    ${[["leverage","2.96×","target 3.00"],["health","1.208","floor 1.20"],["callback gas","1.20–1.24M","cap 2.00M"],["assertions","33 / 33",""]]
      .map(([k,v,n2])=>`
      <div class="box" style="flex:1;padding:18px 16px">
        <div class="lbl">${k}</div>
        <div class="val" style="font-size:26px;color:${POS};margin-top:10px">${v}</div>
        ${n2?`<div class="cap" style="font-size:11px;margin-top:6px">${n2}</div>`:""}
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:24px">Each assertion is one atomic <span class="val" style="color:${ACC}">eth_call</span> with the probe
  injected by state override — the real Venus market, the real pool depth, at the current block.</div>
</body>`);

/* the five risks, as a single board */
await shoot("risk-board.png", W, 430, `<body style="padding:${PAD}px">
  <div class="lbl">everything that can hurt you</div>
  <div style="margin-top:24px;display:flex;flex-direction:column;gap:9px">
    ${[["liquidation","BNB falls 16.7% against the position",NEG],
       ["trust moved, not removed","the Guardian can replace the implementation",WARN],
       ["settlement costs","the fee is paid whether or not anything happened",WARN],
       ["leverage decays","between rebalances it drifts from target",MUTE],
       ["dividend threshold","below 10,000 KEEL there is no share",MUTE],
       ["unaudited","no third party has reviewed this code",NEG]]
      .map(([k,v,c])=>`
      <div style="display:flex;align-items:center;gap:14px;padding:12px 16px;background:${SURF};border-left:3px solid ${c}">
        <span class="val" style="width:210px;font-size:13px;color:${c}">${k}</span>
        <span style="font-size:14px;color:${DIM}">${v}</span>
      </div>`).join("")}
  </div>
</body>`);

/* what the 33 assertions actually cover */
await shoot("assertions.png", W, 350, `<body style="padding:${PAD}px">
  <div class="lbl">33 assertions · one atomic eth_call each</div>
  <div style="display:flex;gap:12px;margin-top:26px">
    ${[["build","12","three tax sizes reach target leverage and hold the floor"],
       ["harvest","10","the split, the amount freed, health after"],
       ["settlement","11","the slot, the fee, replay refusal, the callback"]]
      .map(([k,n2,d2])=>`
      <div class="box" style="flex:1;padding:18px 16px">
        <div class="val" style="font-size:30px;color:${ACC}">${n2}</div>
        <div style="font-size:14px;margin-top:8px;color:${FG}">${k}</div>
        <div class="cap" style="font-size:11.5px;margin-top:8px;line-height:1.45">${d2}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:24px">The forge suite adds 28 more, and the position-lifecycle group is skipped by design —
  it needs an archive RPC that BSC does not offer for free.</div>
</body>`);

/* status, as a state rather than a sentence */
await shoot("status.png", W, 300, `<body style="padding:${PAD}px">
  <div class="lbl">where this is</div>
  <div style="display:flex;gap:0;margin-top:28px;align-items:center">
    ${[["factory deployed","done",POS],["registered by Flap","waiting",WARN],["token launched","not yet",MUTE],["vault live","not yet",MUTE]]
      .map(([k,v,c],i)=>`
      <div style="flex:1;position:relative">
        <div style="height:2px;background:${c};opacity:${c===MUTE?.3:1}"></div>
        <div style="width:9px;height:9px;border-radius:50%;background:${c};margin-top:-5.5px;margin-left:0"></div>
        <div style="font-size:14px;margin-top:14px;color:${c===MUTE?MUTE:FG}">${k}</div>
        <div class="val" style="font-size:11.5px;margin-top:5px;color:${c}">${v}</div>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:26px">The factory is live on BNB Chain and its beacon is already Guardian-owned. Nothing else has
  happened, and this page says so rather than letting an address list imply otherwise.</div>
</body>`);

/* the three calls that answer everything */
await shoot("three-calls.png", W, 330, `<body style="padding:${PAD}px">
  <div class="lbl">three calls answer the whole page</div>
  <div style="margin-top:26px;display:flex;flex-direction:column;gap:12px">
    ${[["nav()","what it is worth"],["health()","how far from liquidation"],["pendingAction()","what the next wake will do"]]
      .map(([fn,d2],i)=>`
      <div style="display:flex;align-items:center;gap:18px">
        <span class="val" style="width:34px;height:34px;border:1px solid ${ACC}66;border-radius:6px;color:${ACC};display:flex;align-items:center;justify-content:center;font-size:13px">${i+1}</span>
        <span class="val" style="width:230px;font-size:16px;color:${ACC}">${fn}</span>
        <span style="font-size:15px;color:${DIM}">${d2}</span>
      </div>`).join("")}
  </div>
  <div class="cap" style="margin-top:26px">All <span class="val" style="color:${FG}">view</span>. No key, no archive node, no indexer.</div>
</body>`);

await browser.close();

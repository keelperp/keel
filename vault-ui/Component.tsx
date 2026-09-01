"use client";

/**
 * Keel — the vault page.
 *
 * The thing worth showing here is not a set of buttons. This vault settles itself every five
 * minutes through Flap's trigger service, so the page leads with what the next wake will do and
 * how long until it happens; the manual calls are a fallback and are laid out as one.
 *
 * Boundaries this stays inside, deliberately: every contract call is labelled `vault` and targets
 * `context.vaultAddress` — there is no second address anywhere in this file — the health gauge is
 * static SVG geometry positioned from React state (no text nodes, no external reference), no font
 * file travels with the package so the stacks below name faces and fall back to system ones, and
 * the component makes no outbound request of any kind. A number that has not loaded renders as an
 * em dash and never as a zero, so an empty read can never be mistaken for an empty vault.
 *
 * Every number that describes the rules — the revenue split and the three caller bounties — is
 * read from the contract, never written here. A vault redeployed with different constants shows
 * its own numbers without this file changing.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import type { ActionAvailabilityStage, VaultComponentProps } from "@/src/sdk";
import { handleTxError, isActionAvailableForPhase, readTaxVaultHostContext, useFlapSdk } from "@/src/sdk";
import { Alert, Button, Card, CardContent, CardHeader, CardTitle, StatusBadge } from "@/src/ui";
import { vaultAbi } from "./VaultABI";

const INK = "#11181f";
const BODY = "#3a4652";
const MUTE = "#6b7683";
const LINE = "#dcd7cb";
const PAPER = "#f6f4ef";
const PANEL = "#fffdf9";
const COPPER = "#a85d2e";
const SEA = "#1f5f5b";
const RUST = "#8c3a2b";
const MONO = "ui-monospace, 'SF Mono', Menlo, Consolas, monospace";

const WAD = 10n ** 18n;

/** A value that has not loaded is not zero. Every reader here returns undefined until it has one. */
type Maybe<T> = T | undefined;

function dec(v: Maybe<bigint>, dp = 4): string {
  if (v === undefined) return "—";
  const whole = v / WAD;
  const frac = (v % WAD) / 10n ** BigInt(18 - dp);
  return `${whole.toString()}.${frac.toString().padStart(dp, "0")}`;
}

function lev(v: Maybe<bigint>): string {
  return v === undefined ? "—" : `${dec(v, 2)}×`;
}

/** Health is bps over the liquidation point. An unlevered vault reads type(uint256).max. */
function healthText(v: Maybe<bigint>, noDebt: string): string {
  if (v === undefined) return "—";
  if (v > 10n ** 9n) return noDebt;
  return (Number(v) / 10000).toFixed(3);
}

/** The move against the position that would liquidate it: 1 − 1/health. */
function liqMove(v: Maybe<bigint>): string {
  if (v === undefined || v > 10n ** 9n || v <= 10000n) return "—";
  return `${((1 - 10000 / Number(v)) * 100).toFixed(1)}%`;
}

/** Bare bps, for copy that already says "bps". */
function bps(v: Maybe<bigint>): string {
  return v === undefined ? "—" : v.toString();
}

/** bps as a percentage, trailing zeros trimmed: 2000 -> "20%", 2550 -> "25.5%". */
function pct(v: Maybe<bigint>): string {
  if (v === undefined) return "—";
  const p = Number(v) / 100;
  return `${Number.isInteger(p) ? p.toString() : p.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")}%`;
}

function clock(s: Maybe<number>, due: string): string {
  if (s === undefined) return "—";
  if (s <= 0) return due;
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r.toString().padStart(2, "0")}`;
}

export default function KeelVault(_props: VaultComponentProps) {
  const sdk = useFlapSdk();
  const { context, i18n } = sdk;
  const t = i18n.t;
  const host = readTaxVaultHostContext(context.host);

  // Stage gating, and why it lands on "both". deployPending, harvest and rebalance all act on BNB
  // the vault already holds: they push collected tax into the Venus position, pull realised gain
  // back out, or move the position back to target. None of them touches the bonding curve and none
  // of them is a trade, so none of them depends on whether the token is still on the internal
  // market or already listed on a DEX. The stage is "both" — the same reasoning Shift documents for
  // claiming a wage and closing a period.
  const marketPhase = host.marketPhase;
  const actionStage: ActionAvailabilityStage = "both";
  const actionsAvailable = isActionAvailableForPhase(actionStage, marketPhase);

  // The host owns the risk verdict; this page only renders it. An absent level is its own state —
  // it is not "low" and it is not zero — so it reads as danger and says so out loud below.
  const riskLevel = host.vaultInfo?.riskLevel ?? host.taxInfo?.vaultInfo?.riskLevel ?? null;
  const riskLabel =
    riskLevel === 1 ? t("riskLow")
    : riskLevel === 2 ? t("riskLowMedium")
    : riskLevel === 3 ? t("riskMedium")
    : riskLevel === 4 ? t("riskHigh")
    : riskLevel === 0 ? t("riskUnverified")
    : t("riskMissing");
  const riskTone = riskLevel === null || riskLevel === 0 || riskLevel >= 4 ? "danger" : riskLevel >= 3 ? "warning" : "success";
  const phaseLabel =
    marketPhase === "internal-market" ? t("phaseInternal")
    : marketPhase === "dex-listed" ? t("phaseDex")
    : t("phaseUnknown");

  const [nav, setNav] = useState<Maybe<bigint>>();
  const [leverage, setLeverage] = useState<Maybe<bigint>>();
  const [target, setTarget] = useState<Maybe<bigint>>();
  const [health, setHealth] = useState<Maybe<bigint>>();
  const [floor, setFloor] = useState<Maybe<bigint>>();
  const [pending, setPending] = useState<Maybe<bigint>>();
  const [toHolders, setToHolders] = useState<Maybe<bigint>>();
  const [toProject, setToProject] = useState<Maybe<bigint>>();
  const [projectShare, setProjectShare] = useState<Maybe<bigint>>();
  const [deployBounty, setDeployBounty] = useState<Maybe<bigint>>();
  const [harvestBounty, setHarvestBounty] = useState<Maybe<bigint>>();
  const [rebalanceBounty, setRebalanceBounty] = useState<Maybe<bigint>>();
  const [action, setAction] = useState<Maybe<number>>();
  const [requestId, setRequestId] = useState<Maybe<bigint>>();
  const [countdown, setCountdown] = useState<Maybe<number>>();
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);

  const read = useCallback(
    async <T,>(functionName: string): Promise<Maybe<T>> => {
      try {
        return (await sdk.readContract({
          contract: "vault", address: context.vaultAddress, abi: vaultAbi, functionName,
        })) as T;
      } catch {
        return undefined;
      }
    },
    [sdk, context.vaultAddress]
  );

  useEffect(() => {
    let live = true;
    (async () => {
      const [n, l, tg, h, f, p, th, tp, ps, db, hb, rb, a, rid, secs] = await Promise.all([
        read<bigint>("nav"),
        read<bigint>("currentLeverage"),
        read<bigint>("TARGET_LEVERAGE"),
        read<bigint>("healthBps"),
        read<bigint>("MIN_HEALTH_BPS"),
        read<bigint>("pendingRevenue"),
        read<bigint>("totalHarvested"),
        read<bigint>("totalToProject"),
        read<bigint>("PROJECT_SHARE_BPS"),
        read<bigint>("DEPLOY_BOUNTY_BPS"),
        read<bigint>("HARVEST_BOUNTY_BPS"),
        read<bigint>("REBALANCE_BOUNTY_BPS"),
        read<number>("pendingAction"),
        read<bigint>("pendingRequestId"),
        read<bigint>("nextSettlementIn"),
      ]);
      if (!live) return;
      setNav(n);
      setLeverage(l);
      setTarget(tg);
      setHealth(h);
      setFloor(f);
      setPending(p);
      setToHolders(th);
      setToProject(tp);
      setProjectShare(ps);
      setDeployBounty(db);
      setHarvestBounty(hb);
      setRebalanceBounty(rb);
      setAction(a === undefined ? undefined : Number(a));
      setRequestId(rid);
      setCountdown(secs === undefined ? undefined : Number(secs));
    })();
    return () => {
      live = false;
    };
  }, [read, sdk.refetchNonce]);

  // Tick the countdown locally rather than polling the chain once a second.
  useEffect(() => {
    if (countdown === undefined) return;
    const id = setInterval(() => setCountdown((s) => (s === undefined ? s : Math.max(0, s - 1))), 1000);
    return () => clearInterval(id);
  }, [countdown === undefined]);

  const actionLabel = useMemo(() => {
    switch (action) {
      case 1:
        return t("actionRescue");
      case 2:
        return t("actionBuild");
      case 3:
        return t("actionHarvest");
      case 4:
        return t("actionRebalance");
      case 0:
        return t("actionNothing");
      default:
        return "—";
    }
  }, [action, t]);

  const send = useCallback(
    async (functionName: string, key: string) => {
      setNote(null);
      setBusy(key);
      try {
        const sim = await sdk.simulateContract({
          contract: "vault", address: context.vaultAddress, abi: vaultAbi, functionName,
        });
        const hash = await sdk.writeContract(sim.request);
        await sdk.waitForTx(hash);
        await sdk.refetch();
      } catch (e) {
        setNote(handleTxError(e));
      } finally {
        setBusy(null);
      }
    },
    [sdk, context.vaultAddress]
  );

  // The split is derived, never typed. Holders take whatever the project's constant leaves.
  const holderShare = projectShare === undefined ? undefined : 10_000n - projectShare;

  const connected = Boolean(context.userAddress);
  const wrongNetwork = sdk.wallet.isWrongNetwork;
  const canWrite = connected && !wrongNetwork && actionsAvailable;
  const scheduled = requestId !== undefined && requestId > 0n;

  // Gauge geometry: 1.00 is liquidation, the floor sits at MIN_HEALTH_BPS, and 2.00 is the far
  // end of the drawn range. Positions come from state; the SVG carries no text.
  const gaugePos = (bps: Maybe<bigint>): number | undefined => {
    if (bps === undefined || bps > 10n ** 9n) return undefined;
    const v = Number(bps) / 10000;
    return Math.max(0, Math.min(1, (v - 1) / 1));
  };
  const hx = gaugePos(health);
  const fx = gaugePos(floor);

  // The package ships inside a dark default chrome; Keel's own ground is paper, so each card
  // states it rather than inheriting.
  const cardSkin: React.CSSProperties = { background: PANEL, borderColor: LINE, color: INK };

  const stat = (label: string, value: string, hint?: string, tone?: string) => (
    <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
      <div style={{ fontFamily: MONO, fontSize: 10.5, letterSpacing: "0.1em", textTransform: "uppercase", color: MUTE }}>
        {label}
      </div>
      <div style={{ fontFamily: MONO, fontSize: 24, fontVariantNumeric: "tabular-nums", color: tone ?? INK }}>
        {value}
      </div>
      {hint ? <div style={{ fontSize: 12, color: MUTE, lineHeight: 1.45 }}>{hint}</div> : null}
    </div>
  );

  // One manual call: the button, and directly under it what calling it pays. A rate that has not
  // loaded prints an em dash inside the sentence rather than a zero bounty.
  const job = (key: string, label: string, onClick: () => void, bounty: string, tone?: string) => (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <Button disabled={!canWrite || busy !== null} onClick={onClick} style={{ width: "100%" }}>
        {busy === key ? "…" : label}
      </Button>
      <div style={{ fontFamily: MONO, fontSize: 11, lineHeight: 1.45, color: tone ?? COPPER }}>{bounty}</div>
    </div>
  );

  // The floor is what bounds the position, so the move that liquidates it derives from the
  // floor rather than from wherever the position happens to sit right now.
  const levText = lev(target);
  const floorLiq = liqMove(floor);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, color: INK, background: PAPER }}>
      <div style={{ border: `1px solid ${RUST}`, borderLeft: `3px solid ${RUST}`, borderRadius: 8,
                    background: "#fdf6f3", padding: "14px 16px" }}>
        <div style={{ fontFamily: MONO, fontSize: 12.5, color: RUST, fontWeight: 600, lineHeight: 1.45 }}>
          {t("topWarning").replace("{lev}", levText)}
        </div>
        <div style={{ fontSize: 12.5, color: BODY, lineHeight: 1.6, marginTop: 8 }}>
          {t("topBody").replace("{pct}", floorLiq)}
        </div>
      </div>
      <Card style={cardSkin}>
        <CardHeader>
          <div style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
            <CardTitle style={{ color: INK }}>{t("title")}</CardTitle>
            <span style={{ marginLeft: "auto", display: "inline-flex", gap: 8, flexWrap: "wrap" }}>
              <StatusBadge tone={riskTone}>{riskLabel}</StatusBadge>
              <StatusBadge tone={actionsAvailable ? "success" : "warning"}>{phaseLabel}</StatusBadge>
            </span>
          </div>
          <div style={{ fontSize: 12, lineHeight: 1.5, color: riskTone === "danger" ? RUST : MUTE }}>
            {t("riskLine").replace("{status}", riskLabel)}
          </div>
        </CardHeader>
        <CardContent>
          <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
            {riskLevel === null ? <Alert tone="danger">{t("riskIntegrationMissing")}</Alert> : null}

            <div style={{ fontSize: 15, color: BODY, maxWidth: "56ch", lineHeight: 1.55 }}>{t("tagline")}</div>

            {/* What the vault will do next, and when. This is the page's lead. */}
            <div
              style={{
                border: `1px solid ${LINE}`,
                borderLeft: `3px solid ${COPPER}`,
                borderRadius: 3,
                background: PAPER,
                padding: "16px 18px",
                display: "flex",
                flexWrap: "wrap",
                gap: 22,
                alignItems: "baseline",
              }}
            >
              {scheduled
                ? stat(t("nextSettlement"), clock(countdown, t("due")), `${t("willDo")}: ${actionLabel}`, COPPER)
                : stat(t("idle"), "—", t("nothingToDo"), MUTE)}
              {stat(t("awaitingTax"), `${dec(pending)} BNB`)}
            </div>

            <div style={{ fontSize: 13, color: BODY, lineHeight: 1.55 }}>{t("auto")}</div>
            <div style={{ fontSize: 12, color: MUTE, lineHeight: 1.5 }}>{t("autoNoBounty")}</div>

            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))",
                gap: 18,
              }}
            >
              {stat(t("treasury"), `${dec(nav)} BNB`, t("treasuryHint"))}
              {stat(t("leverage"), lev(leverage), `${t("target")} ${lev(target)}`)}
              {stat(
                t("health"),
                healthText(health, t("noDebt")),
                t("liquidatesAt").replace("{pct}", liqMove(health)),
                health !== undefined && health <= 11000n ? RUST : SEA
              )}
            </div>

            {/* Health gauge. Left edge is the Venus liquidation point, the notch is the vault's
                own floor, and the mark is where the position stands now. */}
            <svg viewBox="0 0 300 26" width="100%" height="26" role="presentation" aria-hidden="true">
              <rect x="0" y="11" width="300" height="4" fill={LINE} />
              <rect x="0" y="9" width="3" height="8" fill={RUST} />
              {fx !== undefined ? <rect x={fx * 297} y="7" width="2" height="12" fill={MUTE} /> : null}
              {hx !== undefined ? (
                <>
                  <rect x="0" y="11" width={Math.max(3, hx * 297)} height="4" fill={SEA} />
                  <circle cx={Math.max(3, hx * 297)} cy="13" r="5" fill={SEA} />
                </>
              ) : null}
            </svg>

            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))",
                gap: 18,
                borderTop: `1px solid ${LINE}`,
                paddingTop: 16,
              }}
            >
              {stat(t("paidHolders"), `${dec(toHolders)} BNB`, undefined, SEA)}
              {stat(t("paidProject"), `${dec(toProject)} BNB`)}
            </div>
            <div style={{ fontSize: 12, color: MUTE, lineHeight: 1.5 }}>
              {t("split").replace("{holders}", pct(holderShare)).replace("{project}", pct(projectShare))}
            </div>
          </div>
        </CardContent>
      </Card>

      <Card style={cardSkin}>
        <CardHeader>
          <CardTitle style={{ color: INK }}>{t("manualTitle")}</CardTitle>
        </CardHeader>
        <CardContent>
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <div style={{ fontSize: 13, color: BODY, lineHeight: 1.55 }}>{t("manualHint")}</div>

            {/* The two facts a community taking this over has to be told outright: nobody's
                permission is required, and the contract pays whoever does the work. */}
            <div
              style={{
                border: `1px solid ${LINE}`,
                borderLeft: `3px solid ${COPPER}`,
                borderRadius: 3,
                background: PAPER,
                padding: "12px 14px",
                fontSize: 13,
                color: BODY,
                lineHeight: 1.55,
              }}
            >
              {t("permissionless")}
            </div>

            <div style={{ fontSize: 12, color: MUTE, lineHeight: 1.5 }}>{t("stageBoth")}</div>
            {note ? <Alert tone="danger">{note}</Alert> : null}
            {connected ? null : <Alert>{t("connect")}</Alert>}
            {wrongNetwork ? (
              <Alert tone="warning">{t("wrongNetwork").replace("{chain}", sdk.wallet.requiredChainLabel)}</Alert>
            ) : null}

            {/* The consequence sits against the buttons, not only at the foot of the card. */}
            <div
              style={{
                border: `1px solid ${RUST}`,
                borderLeft: `3px solid ${RUST}`,
                borderRadius: 3,
                background: PAPER,
                padding: "12px 14px",
                display: "flex",
                flexDirection: "column",
                gap: 6,
              }}
            >
              <div
                style={{
                  fontFamily: MONO,
                  fontSize: 10.5,
                  letterSpacing: "0.1em",
                  textTransform: "uppercase",
                  color: RUST,
                }}
              >
                {t("beforeYouPress")}
              </div>
              <div style={{ fontSize: 12.5, color: RUST, lineHeight: 1.5 }}>{t("warnLiquidation").replace("{lev}", levText).replace("{pct}", floorLiq)}</div>
              <div style={{ fontSize: 12.5, color: RUST, lineHeight: 1.5 }}>{t("warnUnaudited")}</div>
              <div style={{ fontSize: 12.5, color: RUST, lineHeight: 1.5 }}>{t("warnRevert")}</div>
            </div>

            <div
              style={{
                display: "grid",
                gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
                gap: 12,
                alignItems: "start",
              }}
            >
              {job(
                "deploy",
                t("deploy"),
                () => send("deployPending", "deploy"),
                t("bountyDeploy").replace("{bps}", bps(deployBounty))
              )}
              {job(
                "harvest",
                t("harvestBtn"),
                () => send("harvest", "harvest"),
                t("bountyHarvest").replace("{bps}", bps(harvestBounty))
              )}
              {job(
                "rebalance",
                t("rebalanceBtn"),
                () => send("rebalance", "rebalance"),
                t("bountyRebalance").replace("{bps}", bps(rebalanceBounty))
              )}
              {scheduled
                ? null
                : job("kickstart", t("kickstart"), () => send("kickstart", "kickstart"), t("bountyNone"), MUTE)}
            </div>
            <div style={{ fontSize: 12, color: RUST, lineHeight: 1.5, borderTop: `1px solid ${LINE}`, paddingTop: 12 }}>
              {t("risk").replace("{lev}", levText).replace("{pct}", floorLiq)}
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

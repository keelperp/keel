import { createPublicClient, createWalletClient, custom, http, defineChain } from "viem";

export const bsc = defineChain({
  id: 56,
  name: "BNB Chain",
  nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
  rpcUrls: { default: { http: ["https://bsc-dataseed.bnbchain.org"] } },
  blockExplorers: { default: { name: "BscScan", url: "https://bscscan.com" } },
});

export const publicClient = createPublicClient({ chain: bsc, transport: http() });

export function walletClient() {
  const eth = (window as any).ethereum;
  if (!eth) return null;
  return createWalletClient({ chain: bsc, transport: custom(eth) });
}

/** Deployment manifest, written by ./deploy. Absent until the contracts are live. */
export type Manifest = {
  schema: number;
  chainId: string;
  custody: `0x${string}`;
  factory: `0x${string}`;
  bonding: `0x${string}`;
  feeVault: `0x${string}`;
  lpLock: `0x${string}`;
  vaults: { address: `0x${string}`; symbol: string }[];
};

export async function loadManifest(): Promise<Manifest | null> {
  const res = await fetch("/deployments/56.json").catch(() => null);
  if (!res || !res.ok) return null;
  return (await res.json()) as Manifest;
}

/** A balance that has not loaded is not zero. Callers must handle null. */
export type Maybe<T> = T | null;

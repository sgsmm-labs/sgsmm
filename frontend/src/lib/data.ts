/**
 * SGSMM static data loader.
 *
 * Currently imports committed JSON from public/data/ for demo robustness.
 * To swap in live indexer data, replace each `import` below with a fetch to
 * the Ponder indexer API, e.g.:
 *   const res = await fetch("http://localhost:42069/api/leaderboard")
 *   return res.json()
 */

import leaderboardRaw from "../../public/data/leaderboard.json";
import decisionsRaw from "../../public/data/decisions.json";
import equityRaw from "../../public/data/equity.json";
import vaultRaw from "../../public/data/vault.json";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type Verdict = "MIRRORED" | "WATCHING" | "SKIPPED" | "DEFUNDED";

export interface LeaderboardEntry {
  /** Full EVM address */
  address: string;
  /** Rolling 90-day Sortino ratio */
  sortino: number;
  /** 30-day maximum drawdown, percent (negative) */
  dd30d: number;
  /** Number of positions observed in the rolling 90-day window */
  observations: number;
  /** Current scoring verdict */
  verdict: Verdict;
}

export type DecisionAction =
  | "ENTER"
  | "HOLD"
  | "DEFUND"
  | "EMERGENCY_UNWIND"
  | "SKIP";

export interface DecisionEntry {
  /** Cycle / epoch number */
  epoch: number;
  /** Wallet address involved */
  wallet: string;
  /** On-chain decision type */
  action: DecisionAction;
  /** Rolling Sortino at time of decision */
  sortino: number;
  /** Sleeve allocation in basis points (0 if no sleeve) */
  sleevePctBps: number;
  /** Vault NAV immediately after this decision settled */
  navAfter: number;
}

export interface EquityPoint {
  /** Cycle / epoch number */
  epoch: number;
  /** SGSMM vault NAV in USD */
  nav: number;
  /** Naive 60/40 baseline NAV for comparison */
  baselineNav: number;
}

export interface VaultState {
  /** Total vault NAV in USD */
  nav: number;
  /** Floor allocation percent (USDY) */
  floorPct: number;
  /** Active sleeve percent */
  sleevePct: number;
  /** Never-deployable reserve percent */
  reservePct: number;
  /** Number of currently mirrored wallets */
  activeMirrors: number;
  /** ISO timestamp of last rebalance */
  lastRebalance: string;
  /** ISO timestamp of next scheduled rebalance */
  nextRebalance: string;
  /** Floor yield asset name */
  floorAsset: string;
  /** Human-readable floor venue label */
  floorVenueLabel: string;
  /** Human-readable sleeve venue label */
  sleeveVenueLabel: string;
  /** Current cycle/epoch counter */
  cycleEpoch: number;
  /** Total on-chain decisions logged since inception */
  totalDecisionsLogged: number;
  /** Cumulative return since inception, percent */
  cumulativeReturn: number;
}

// ---------------------------------------------------------------------------
// Loaders
// ---------------------------------------------------------------------------

export function getLeaderboard(): LeaderboardEntry[] {
  return leaderboardRaw as LeaderboardEntry[];
}

export function getDecisions(): DecisionEntry[] {
  return decisionsRaw as DecisionEntry[];
}

export function getEquity(): EquityPoint[] {
  return equityRaw as EquityPoint[];
}

export function getVault(): VaultState {
  return vaultRaw as VaultState;
}

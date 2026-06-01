import Nav from "@/components/Nav";
import { getLeaderboard, type Verdict } from "@/lib/data";

function truncateAddress(addr: string) {
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

function sortinoColor(s: number) {
  if (s >= 3) return "text-emerald-400";
  if (s >= 2) return "text-cyan-300";
  if (s >= 1.5) return "text-sky-400";
  if (s >= 1) return "text-amber-400";
  return "text-red-400";
}

/** Per-wallet Sortino is clamped at 10 in the backtest; show it as a floor. */
function formatSortino(s: number) {
  return s >= 10 ? "≥10" : s.toFixed(2);
}

type VerdictStyle = { label: string; bg: string; text: string; ring: string };

const NEUTRAL_VERDICT: VerdictStyle = {
  label: "—",
  bg: "bg-zinc-800/30",
  text: "text-zinc-500",
  ring: "ring-zinc-600/20",
};

const verdictConfig: Record<Verdict, VerdictStyle> = {
  MIRRORED: {
    label: "MIRRORED",
    bg: "bg-emerald-500/10",
    text: "text-emerald-300",
    ring: "ring-emerald-400/30",
  },
  WATCHING: {
    label: "WATCHING",
    bg: "bg-sky-500/10",
    text: "text-sky-300",
    ring: "ring-sky-400/30",
  },
  SKIPPED: {
    label: "SKIPPED",
    bg: "bg-zinc-700/30",
    text: "text-zinc-400",
    ring: "ring-zinc-500/20",
  },
  DEFUNDED: {
    label: "DEFUNDED",
    bg: "bg-amber-500/10",
    text: "text-amber-400",
    ring: "ring-amber-400/30",
  },
};

export default function PositionsPage() {
  const leaderboard = getLeaderboard();
  // Sorted by sortino desc (already sorted in JSON, but be explicit)
  const sorted = [...leaderboard].sort((a, b) => b.sortino - a.sortino);

  const mirroredCount = sorted.filter((w) => w.verdict === "MIRRORED").length;
  const defundedCount = sorted.filter((w) => w.verdict === "DEFUNDED").length;

  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-black text-zinc-100">
      <Nav />

      <main className="mx-auto max-w-5xl px-6 pt-14 pb-32">
        {/* Page header */}
        <div className="mb-10">
          <p className="mb-3 inline-flex items-center gap-2 rounded-full bg-violet-500/10 px-3 py-1 text-xs font-medium text-violet-300 ring-1 ring-violet-400/30">
            Smart Money Leaderboard · 90-day Sortino window
          </p>
          <h1 className="text-4xl font-semibold tracking-tight">Positions</h1>
          <p className="mt-3 text-sm leading-6 text-zinc-400 max-w-2xl">
            Ranked by rolling 90-day Sortino ratio across 300k Mantle DEX
            trades. Only wallets above the 1.5 gate qualify for mirroring.
            Auto-defund triggers below 0.5.
          </p>
        </div>

        {/* Summary strip */}
        <div className="mb-8 grid grid-cols-2 gap-4 sm:grid-cols-4">
          {[
            { label: "Scored Wallets", value: sorted.length.toString() },
            { label: "Currently Mirrored", value: mirroredCount.toString() },
            {
              label: "Defunded",
              value: `${defundedCount}/${sorted.length}`,
              sublabel: "screened out by the gate",
            },
            {
              label: "Entry Gate",
              value: "1.5",
              sublabel: "Sortino min",
            },
          ].map((s) => (
            <div
              key={s.label}
              className="rounded-2xl border border-white/10 bg-white/[0.02] p-4 backdrop-blur"
            >
              <p className="text-xs uppercase tracking-widest text-zinc-500">
                {s.label}
              </p>
              <p className="mt-1.5 text-2xl font-semibold tabular-nums">
                {s.value}
              </p>
              {s.sublabel && (
                <p className="mt-0.5 text-xs text-zinc-500">{s.sublabel}</p>
              )}
            </div>
          ))}
        </div>

        {/* Leaderboard table */}
        <div className="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-white/[0.06]">
                  <th className="px-5 py-3.5 text-left text-xs font-medium uppercase tracking-widest text-zinc-500 w-8">
                    #
                  </th>
                  <th className="px-5 py-3.5 text-left text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Wallet
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    90d Sortino
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    30d Drawdown
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Observations
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Verdict
                  </th>
                </tr>
              </thead>
              <tbody>
                {sorted.map((w, i) => {
                  const vc = verdictConfig[w.verdict] ?? NEUTRAL_VERDICT;
                  return (
                    <tr
                      key={w.address}
                      className="border-b border-white/[0.04] hover:bg-white/[0.02] transition-colors"
                    >
                      <td className="px-5 py-4 text-zinc-600 tabular-nums text-xs">
                        {i + 1}
                      </td>
                      <td className="px-5 py-4">
                        <span className="font-mono text-xs text-zinc-300">
                          {truncateAddress(w.address)}
                        </span>
                      </td>
                      <td className="px-5 py-4 text-right">
                        <span
                          className={`font-semibold tabular-nums ${sortinoColor(w.sortino)}`}
                        >
                          {formatSortino(w.sortino)}
                        </span>
                        {/* Sortino bar */}
                        <div className="mt-1 flex justify-end">
                          <div className="w-16 h-0.5 rounded-full bg-white/5">
                            <div
                              className={`h-0.5 rounded-full ${
                                w.sortino >= 1.5
                                  ? "bg-cyan-400"
                                  : "bg-zinc-600"
                              }`}
                              style={{
                                width: `${Math.min(100, (w.sortino / 4) * 100)}%`,
                              }}
                            />
                          </div>
                        </div>
                      </td>
                      <td className="px-5 py-4 text-right tabular-nums text-zinc-400">
                        <span
                          className={
                            w.dd30d < -20
                              ? "text-red-400"
                              : w.dd30d < -10
                              ? "text-amber-400"
                              : "text-zinc-300"
                          }
                        >
                          {w.dd30d.toFixed(1)}%
                        </span>
                      </td>
                      <td className="px-5 py-4 text-right tabular-nums text-zinc-400">
                        {w.observations}
                      </td>
                      <td className="px-5 py-4 text-right">
                        <span
                          className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-[10px] font-medium uppercase tracking-widest ring-1 ${vc.bg} ${vc.text} ${vc.ring}`}
                        >
                          {vc.label}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>

        {/* Gate legend */}
        <div className="mt-6 flex flex-wrap gap-4 text-xs text-zinc-500">
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-emerald-400" />
            Sortino ≥ 1.5 → MIRRORED
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-sky-400" />
            Sortino 1.0–1.5 → WATCHING
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-zinc-500" />
            Below gate → SKIPPED
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-amber-400" />
            Sortino &lt; 0.5 → DEFUNDED
          </span>
        </div>
      </main>

      <footer className="border-t border-white/10 py-8 text-center text-xs text-zinc-500">
        SGSMM does not synthetic-asset mirror. No relationship to Terra Mirror
        Protocol. · Built for the Turing Test Hackathon 2026.
      </footer>
    </div>
  );
}

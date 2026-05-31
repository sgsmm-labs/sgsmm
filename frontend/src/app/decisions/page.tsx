import Nav from "@/components/Nav";
import { getDecisions, type DecisionAction } from "@/lib/data";

function truncateAddress(addr: string) {
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

function formatNav(v: number) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    notation: "compact",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(v);
}

function bpsToPercent(bps: number) {
  return (bps / 100).toFixed(1) + "%";
}

const actionConfig: Record<
  DecisionAction,
  { label: string; bg: string; text: string; ring: string }
> = {
  ENTER: {
    label: "ENTER",
    bg: "bg-emerald-500/10",
    text: "text-emerald-300",
    ring: "ring-emerald-400/30",
  },
  HOLD: {
    label: "HOLD",
    bg: "bg-zinc-700/30",
    text: "text-zinc-300",
    ring: "ring-zinc-500/20",
  },
  DEFUND: {
    label: "DEFUND",
    bg: "bg-amber-500/10",
    text: "text-amber-400",
    ring: "ring-amber-400/30",
  },
  EMERGENCY_UNWIND: {
    label: "EMERGENCY",
    bg: "bg-red-500/10",
    text: "text-red-400",
    ring: "ring-red-400/30",
  },
  SKIP: {
    label: "SKIP",
    bg: "bg-zinc-800/30",
    text: "text-zinc-500",
    ring: "ring-zinc-600/20",
  },
};

export default function DecisionsPage() {
  const decisions = getDecisions();

  const actionCounts = decisions.reduce<Record<string, number>>((acc, d) => {
    acc[d.action] = (acc[d.action] ?? 0) + 1;
    return acc;
  }, {});

  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-black text-zinc-100">
      <Nav />

      <main className="mx-auto max-w-5xl px-6 pt-14 pb-32">
        {/* Page header */}
        <div className="mb-10">
          <p className="mb-3 inline-flex items-center gap-2 rounded-full bg-emerald-500/10 px-3 py-1 text-xs font-medium text-emerald-300 ring-1 ring-emerald-400/30">
            On-Chain Audit Trail · DecisionLog
          </p>
          <h1 className="text-4xl font-semibold tracking-tight">
            Decision Feed
          </h1>
          <p className="mt-3 text-sm leading-6 text-zinc-400 max-w-2xl">
            Every ENTER, HOLD, DEFUND, EMERGENCY_UNWIND, and SKIP is written
            to the Mantle DecisionLog contract. Independent observers can
            reconstruct the full policy from this feed alone.
          </p>
        </div>

        {/* Action count strip */}
        <div className="mb-8 grid grid-cols-2 gap-3 sm:grid-cols-5">
          {(
            [
              "ENTER",
              "HOLD",
              "DEFUND",
              "EMERGENCY_UNWIND",
              "SKIP",
            ] as DecisionAction[]
          ).map((action) => {
            const cfg = actionConfig[action];
            return (
              <div
                key={action}
                className={`rounded-xl border border-white/[0.06] ${cfg.bg} p-3 backdrop-blur`}
              >
                <p className={`text-[10px] font-medium uppercase tracking-widest ${cfg.text}`}>
                  {cfg.label}
                </p>
                <p className={`mt-1 text-2xl font-semibold tabular-nums ${cfg.text}`}>
                  {actionCounts[action] ?? 0}
                </p>
              </div>
            );
          })}
        </div>

        {/* Decision table */}
        <div className="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-white/[0.06]">
                  <th className="px-5 py-3.5 text-left text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Epoch
                  </th>
                  <th className="px-5 py-3.5 text-left text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Wallet
                  </th>
                  <th className="px-5 py-3.5 text-left text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Action
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Sortino
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    Sleeve
                  </th>
                  <th className="px-5 py-3.5 text-right text-xs font-medium uppercase tracking-widest text-zinc-500">
                    NAV After
                  </th>
                </tr>
              </thead>
              <tbody>
                {decisions.map((d, i) => {
                  const cfg = actionConfig[d.action];
                  return (
                    <tr
                      key={i}
                      className="border-b border-white/[0.04] hover:bg-white/[0.02] transition-colors"
                    >
                      <td className="px-5 py-4 tabular-nums text-zinc-500 text-xs">
                        {d.epoch}
                      </td>
                      <td className="px-5 py-4">
                        <span className="font-mono text-xs text-zinc-300">
                          {truncateAddress(d.wallet)}
                        </span>
                      </td>
                      <td className="px-5 py-4">
                        <span
                          className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-[10px] font-medium uppercase tracking-widest ring-1 ${cfg.bg} ${cfg.text} ${cfg.ring}`}
                        >
                          {cfg.label}
                        </span>
                      </td>
                      <td className="px-5 py-4 text-right tabular-nums">
                        <span
                          className={
                            d.sortino >= 2
                              ? "text-cyan-300"
                              : d.sortino >= 1.5
                              ? "text-sky-400"
                              : d.sortino >= 1
                              ? "text-amber-400"
                              : "text-red-400"
                          }
                        >
                          {d.sortino.toFixed(2)}
                        </span>
                      </td>
                      <td className="px-5 py-4 text-right tabular-nums text-zinc-400">
                        {d.sleevePctBps > 0 ? bpsToPercent(d.sleevePctBps) : (
                          <span className="text-zinc-600">—</span>
                        )}
                      </td>
                      <td className="px-5 py-4 text-right tabular-nums text-zinc-300">
                        {formatNav(d.navAfter)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>

        {/* Action legend */}
        <div className="mt-6 flex flex-wrap gap-x-6 gap-y-2 text-xs text-zinc-500">
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-emerald-400" />
            ENTER — wallet cleared gate; sleeve opened
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-zinc-500" />
            HOLD — Sortino still above gate; no resize
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-amber-400" />
            DEFUND — Sortino &lt; 0.5; sleeve closed
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-red-500" />
            EMERGENCY_UNWIND — forced full exit
          </span>
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2 w-2 rounded-full bg-zinc-600" />
            SKIP — evaluated but below gate; no action
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

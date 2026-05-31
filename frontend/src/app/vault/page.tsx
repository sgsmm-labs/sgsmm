import Nav from "@/components/Nav";
import { getVault } from "@/lib/data";

function formatNav(v: number) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(v);
}

function formatDate(iso: string) {
  return new Date(iso).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZoneName: "short",
  });
}

export default function VaultPage() {
  const vault = getVault();

  const partitions = [
    {
      label: "USDY Floor",
      pct: vault.floorPct,
      color: "bg-cyan-400",
      glow: "shadow-cyan-500/30",
      textColor: "text-cyan-300",
      description: vault.floorVenueLabel,
      sublabel: "Principal-protective · yield-bearing",
    },
    {
      label: "Active Sleeve",
      pct: vault.sleevePct,
      color: "bg-violet-500",
      glow: "shadow-violet-500/30",
      textColor: "text-violet-300",
      description: vault.sleeveVenueLabel,
      sublabel: "Sortino-gated mirrors only",
    },
    {
      label: "Reserve",
      pct: vault.reservePct,
      color: "bg-zinc-600",
      glow: "shadow-zinc-500/10",
      textColor: "text-zinc-400",
      description: "Never-deployed buffer",
      sublabel: "Emergency unwind liquidity",
    },
  ];

  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-black text-zinc-100">
      <Nav />

      <main className="mx-auto max-w-5xl px-6 pt-14 pb-32">
        {/* Page header */}
        <div className="mb-12">
          <p className="mb-3 inline-flex items-center gap-2 rounded-full bg-cyan-500/10 px-3 py-1 text-xs font-medium text-cyan-300 ring-1 ring-cyan-400/30">
            Vault State · Epoch {vault.cycleEpoch}
          </p>
          <h1 className="text-4xl font-semibold tracking-tight">
            Capital Partition
          </h1>
          <p className="mt-3 text-sm leading-6 text-zinc-400 max-w-2xl">
            Real-time breakdown of the SGSMM treasury. The 60% USDY floor is
            always deployed to Mantle-native yield venues. The sleeve mirrors
            only Sortino-cleared wallets. The reserve is never deployed.
          </p>
        </div>

        {/* NAV hero */}
        <div className="mb-8 rounded-2xl border border-white/10 bg-white/[0.02] p-8 backdrop-blur">
          <p className="text-xs uppercase tracking-widest text-zinc-500 mb-2">
            Total Vault NAV
          </p>
          <p className="text-5xl font-semibold tabular-nums tracking-tight text-zinc-100">
            {formatNav(vault.nav)}
          </p>
          <div className="mt-4 flex flex-wrap gap-6 text-sm text-zinc-400">
            <span>
              <span className="text-cyan-300 font-medium">+{vault.cumulativeReturn}%</span>{" "}
              cumulative return
            </span>
            <span>
              <span className="text-violet-300 font-medium">{vault.activeMirrors}</span> active
              mirrors
            </span>
            <span>
              <span className="text-zinc-300 font-medium">{vault.totalDecisionsLogged}</span>{" "}
              decisions logged
            </span>
          </div>
        </div>

        {/* Capital partition visual */}
        <div className="mb-4 h-5 rounded-full overflow-hidden flex gap-px">
          {partitions.map((p) => (
            <div
              key={p.label}
              className={`${p.color} transition-all`}
              style={{ width: `${p.pct}%` }}
            />
          ))}
        </div>
        <div className="mb-10 flex gap-6 text-xs text-zinc-500">
          {partitions.map((p) => (
            <span key={p.label} className="flex items-center gap-1.5">
              <span className={`inline-block h-2 w-2 rounded-full ${p.color}`} />
              {p.label} {p.pct}%
            </span>
          ))}
        </div>

        {/* Partition cards */}
        <div className="mb-10 grid grid-cols-1 gap-4 md:grid-cols-3">
          {partitions.map((p) => (
            <div
              key={p.label}
              className={`rounded-2xl border border-white/10 bg-white/[0.02] p-6 backdrop-blur shadow-lg ${p.glow}`}
            >
              <div className="flex items-start justify-between mb-4">
                <p className={`text-xs font-medium uppercase tracking-widest ${p.textColor}`}>
                  {p.label}
                </p>
                <span
                  className={`text-3xl font-semibold tabular-nums ${p.textColor}`}
                >
                  {p.pct}%
                </span>
              </div>
              <p className="text-sm text-zinc-300 font-medium">{p.description}</p>
              <p className="mt-1 text-xs text-zinc-500">{p.sublabel}</p>
              <div className="mt-4 h-1 rounded-full bg-white/5">
                <div
                  className={`h-1 rounded-full ${p.color} opacity-60`}
                  style={{ width: `${p.pct}%` }}
                />
              </div>
            </div>
          ))}
        </div>

        {/* Rebalance schedule */}
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="rounded-2xl border border-white/10 bg-white/[0.02] p-5 backdrop-blur">
            <p className="text-xs uppercase tracking-widest text-zinc-500 mb-2">
              Last Rebalance
            </p>
            <p className="text-sm font-medium text-zinc-200">
              {formatDate(vault.lastRebalance)}
            </p>
            <p className="mt-1 text-xs text-zinc-500">Epoch {vault.cycleEpoch}</p>
          </div>
          <div className="rounded-2xl border border-white/10 bg-white/[0.02] p-5 backdrop-blur">
            <p className="text-xs uppercase tracking-widest text-zinc-500 mb-2">
              Next Rebalance
            </p>
            <p className="text-sm font-medium text-cyan-300">
              {formatDate(vault.nextRebalance)}
            </p>
            <p className="mt-1 text-xs text-zinc-500">Epoch {vault.cycleEpoch + 1}</p>
          </div>
        </div>
      </main>

      <footer className="border-t border-white/10 py-8 text-center text-xs text-zinc-500">
        SGSMM does not synthetic-asset mirror. No relationship to Terra Mirror
        Protocol. · Built for the Turing Test Hackathon 2026.
      </footer>
    </div>
  );
}

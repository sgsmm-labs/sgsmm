import Link from "next/link";
import Nav from "@/components/Nav";
import EquityChart from "@/components/EquityChart";
import { getVault, getLeaderboard, getEquity } from "@/lib/data";

const principles = [
  {
    title: "Sortino-gated entry",
    body: "Mirror only wallets whose rolling 90-day downside-adjusted return survives the gate. Below 0.5 triggers auto-defund.",
  },
  {
    title: "Layered architecture",
    body: "60% USDY treasury floor + capped sleeve + 10% never-deployable reserve. Principal-protective by default.",
  },
  {
    title: "Not discretionary",
    body: "Every entry, exit, and resize is mechanical and on-chain-verifiable. Independent observers reconstruct policy from the DecisionLog.",
  },
];

function formatNav(v: number) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(v);
}

export default function Home() {
  const vault = getVault();
  const leaderboard = getLeaderboard();
  const equity = getEquity();

  const topSortino = leaderboard[0]?.sortino ?? 0;

  const stats = [
    {
      label: "Vault NAV",
      value: formatNav(vault.nav),
      subtext: `+${vault.cumulativeReturn}% cumulative return`,
    },
    {
      label: "Top 90d Sortino",
      value: topSortino.toFixed(2),
      subtext: "Sortino-gated entry ≥ 1.5",
    },
    {
      label: "Active Mirrors",
      value: vault.activeMirrors.toString(),
      subtext: "Sleeve cap 40% · epoch " + vault.cycleEpoch,
    },
    {
      label: "Decisions Logged",
      value: vault.totalDecisionsLogged.toLocaleString(),
      subtext: "Cycle " + vault.cycleEpoch + " · on-chain audit",
    },
  ];

  const lastPoint = equity[equity.length - 1];
  const firstPoint = equity[0];
  const sgReturn = lastPoint && firstPoint
    ? (((lastPoint.nav - firstPoint.nav) / firstPoint.nav) * 100).toFixed(2)
    : "—";
  const baseReturn = lastPoint && firstPoint
    ? (((lastPoint.baselineNav - firstPoint.baselineNav) / firstPoint.baselineNav) * 100).toFixed(2)
    : "—";

  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-black text-zinc-100">
      <Nav />

      <main className="mx-auto max-w-6xl px-6 pt-16 pb-32">
        <section className="mb-16">
          <p className="mb-4 inline-flex items-center gap-2 rounded-full bg-violet-500/10 px-3 py-1 text-xs font-medium text-violet-300 ring-1 ring-violet-400/30">
            Alpha & Data · Path B · Mirana Ventures Track
          </p>
          <h1 className="text-balance text-5xl font-semibold leading-tight tracking-tight">
            Sortino-Gated Smart Money Mirror.
            <span className="block text-zinc-400">
              Manager scoring infrastructure for the Mantle Eco Fund.
            </span>
          </h1>
          <p className="mt-6 max-w-3xl text-pretty text-lg leading-8 text-zinc-300">
            SGSMM scores on-chain managers via rolling downside-adjusted returns,
            routes capital through Mantle-native venues, and gives Mirana real-time
            visibility into how managers compound capital. Every entry, exit, and
            resize is mechanical and verifiable on Mantle.
          </p>
        </section>

        <section className="mb-16 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {stats.map((s) => (
            <div
              key={s.label}
              className="rounded-2xl border border-white/10 bg-white/[0.02] p-5 backdrop-blur"
            >
              <p className="text-xs uppercase tracking-widest text-zinc-500">{s.label}</p>
              <p className="mt-2 text-3xl font-semibold tabular-nums">{s.value}</p>
              <p className="mt-1 text-xs text-zinc-500">{s.subtext}</p>
            </div>
          ))}
        </section>

        <section className="mb-16">
          <div className="mb-4 flex items-baseline justify-between">
            <h2 className="text-sm font-medium uppercase tracking-widest text-zinc-400">
              Equity Curve
            </h2>
            <div className="flex items-center gap-4 text-xs text-zinc-500">
              <span className="flex items-center gap-1.5">
                <span className="inline-block h-2 w-2 rounded-full bg-cyan-400" />
                SGSMM{" "}
                <span className="text-cyan-300 font-medium">+{sgReturn}%</span>
              </span>
              <span className="flex items-center gap-1.5">
                <span className="inline-block h-2 w-2 rounded-full bg-violet-500" />
                Principal{" "}
                <span className="text-violet-300 font-medium">+{baseReturn}%</span>
              </span>
            </div>
          </div>
          <div className="rounded-2xl border border-white/10 bg-white/[0.02] p-4 backdrop-blur">
            <EquityChart data={equity} />
          </div>
          <p className="mt-2 text-xs text-zinc-600">
            26-epoch preliminary window · 300k real Mantle DEX trades · vs. $100k principal floor
          </p>
        </section>

        <section className="mb-16 grid grid-cols-1 gap-4 md:grid-cols-3">
          {principles.map((p) => (
            <div key={p.title} className="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
              <h3 className="text-sm font-medium text-cyan-300">{p.title}</h3>
              <p className="mt-3 text-sm leading-6 text-zinc-300">{p.body}</p>
            </div>
          ))}
        </section>

        <section className="rounded-2xl border border-white/10 bg-gradient-to-br from-cyan-500/[0.05] to-violet-500/[0.05] p-8">
          <h2 className="text-lg font-semibold">For the Mantle Eco Fund</h2>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-zinc-300">
            SGSMM is a distribution layer for quant intelligence on Mantle. We
            surface smart money flows, route capital through Lendle / Init Capital
            / Agni / Merchant Moe, and give institutional allocators a dashboard
            to watch what on-chain managers actually do with capital.
          </p>
          <div className="mt-6 flex flex-wrap items-center gap-3">
            <Link
              href="/decisions"
              className="rounded-full bg-cyan-400 px-5 py-2 text-sm font-medium text-zinc-950 hover:bg-cyan-300"
            >
              View Decision Feed
            </Link>
            <Link
              href="/positions"
              className="rounded-full border border-white/20 px-5 py-2 text-sm font-medium text-zinc-200 hover:bg-white/10"
            >
              Leaderboard
            </Link>
            <a
              href="https://github.com/sgsmm-labs/sgsmm"
              target="_blank"
              rel="noopener noreferrer"
              className="rounded-full border border-white/20 px-5 py-2 text-sm font-medium text-zinc-200 hover:bg-white/10"
            >
              GitHub
            </a>
          </div>
        </section>
      </main>

      <footer className="border-t border-white/10 py-8 text-center text-xs text-zinc-500">
        SGSMM does not synthetic-asset mirror. No relationship to Terra Mirror
        Protocol. · Built for the Turing Test Hackathon 2026.
      </footer>
    </div>
  );
}

import Link from "next/link";

const HACKATHON_URL = "https://devhub.mantle.xyz/";

const stats = [
  { label: "Vault NAV", value: "—", subtext: "Connect to Mantle to load" },
  { label: "Rolling 90d Sortino", value: "—", subtext: "Sortino-gated entry ≥ 1.5" },
  { label: "Active Mirrors", value: "0", subtext: "Sleeve cap 40%" },
  { label: "Decisions Logged", value: "0", subtext: "Cycle 0 / on-chain audit" },
];

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

export default function Home() {
  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-black text-zinc-100">
      <header className="border-b border-white/10 backdrop-blur sticky top-0 bg-black/30 z-10">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-3">
            <div className="h-8 w-8 rounded-lg bg-gradient-to-br from-cyan-400 to-violet-500" />
            <div>
              <p className="text-sm font-semibold tracking-tight">SGSMM</p>
              <p className="text-[10px] uppercase tracking-widest text-zinc-400">
                Manager Scoring Infrastructure · Mantle
              </p>
            </div>
          </div>
          <nav className="flex items-center gap-6 text-sm">
            <Link href="/vault" className="hover:text-cyan-300">
              Vault
            </Link>
            <Link href="/positions" className="hover:text-cyan-300">
              Positions
            </Link>
            <Link href="/decisions" className="hover:text-cyan-300">
              Decisions
            </Link>
            <a
              href={HACKATHON_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="rounded-full bg-cyan-500/10 px-3 py-1.5 text-cyan-300 ring-1 ring-cyan-400/30 hover:bg-cyan-500/20"
            >
              The Turing Test
            </a>
          </nav>
        </div>
      </header>

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
          <h2 className="mb-6 text-sm font-medium uppercase tracking-widest text-zinc-400">
            Equity Curve
          </h2>
          <div className="flex h-64 items-center justify-center rounded-2xl border border-dashed border-white/10 bg-white/[0.02] text-sm text-zinc-500">
            Phase 1 backtest output renders here · SGSMM vs naive baseline overlay
          </div>
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
            <a
              href="https://github.com/"
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

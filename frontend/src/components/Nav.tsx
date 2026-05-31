"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const HACKATHON_URL = "https://devhub.mantle.xyz/";

const navLinks = [
  { href: "/vault", label: "Vault" },
  { href: "/positions", label: "Positions" },
  { href: "/decisions", label: "Decisions" },
];

export default function Nav() {
  const pathname = usePathname();

  return (
    <header className="border-b border-white/10 backdrop-blur sticky top-0 bg-black/30 z-10">
      <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
        <Link href="/" className="flex items-center gap-3">
          <div className="h-8 w-8 rounded-lg bg-gradient-to-br from-cyan-400 to-violet-500" />
          <div>
            <p className="text-sm font-semibold tracking-tight text-zinc-100">SGSMM</p>
            <p className="text-[10px] uppercase tracking-widest text-zinc-400">
              Manager Scoring Infrastructure · Mantle
            </p>
          </div>
        </Link>
        <nav className="flex items-center gap-6 text-sm">
          {navLinks.map(({ href, label }) => {
            const active = pathname === href;
            return (
              <Link
                key={href}
                href={href}
                className={
                  active
                    ? "text-cyan-300 font-medium"
                    : "text-zinc-300 hover:text-cyan-300 transition-colors"
                }
              >
                {label}
              </Link>
            );
          })}
          <a
            href={HACKATHON_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-full bg-cyan-500/10 px-3 py-1.5 text-cyan-300 ring-1 ring-cyan-400/30 hover:bg-cyan-500/20 transition-colors"
          >
            The Turing Test
          </a>
        </nav>
      </div>
    </header>
  );
}

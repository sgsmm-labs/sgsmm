"use client";

import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from "recharts";
import type { EquityPoint } from "@/lib/data";

interface Props {
  data: EquityPoint[];
}

function formatNav(v: number) {
  return "$" + (v / 1_000_000).toFixed(3) + "M";
}

function formatNavShort(v: number) {
  return "$" + (v / 1_000).toFixed(0) + "k";
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function CustomTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-xl border border-white/10 bg-zinc-900/90 px-4 py-3 text-xs backdrop-blur shadow-xl">
      <p className="mb-2 font-semibold text-zinc-400 uppercase tracking-widest">
        Epoch {label}
      </p>
      {payload.map((p: { name: string; value: number; color: string }) => (
        <div key={p.name} className="flex items-center gap-2 mb-1">
          <span
            className="inline-block h-2 w-2 rounded-full"
            style={{ background: p.color }}
          />
          <span className="text-zinc-300">{p.name}</span>
          <span className="ml-auto pl-4 font-semibold tabular-nums" style={{ color: p.color }}>
            {formatNav(p.value)}
          </span>
        </div>
      ))}
    </div>
  );
}

export default function EquityChart({ data }: Props) {
  return (
    <ResponsiveContainer width="100%" height={256}>
      <LineChart data={data} margin={{ top: 8, right: 8, left: 8, bottom: 0 }}>
        <defs>
          <filter id="glow-cyan">
            <feGaussianBlur stdDeviation="3" result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.04)" />
        <XAxis
          dataKey="epoch"
          tick={{ fill: "#71717a", fontSize: 11 }}
          axisLine={{ stroke: "rgba(255,255,255,0.08)" }}
          tickLine={false}
          label={{ value: "Epoch", position: "insideBottomRight", offset: -4, fill: "#52525b", fontSize: 10 }}
        />
        <YAxis
          tickFormatter={formatNavShort}
          tick={{ fill: "#71717a", fontSize: 11 }}
          axisLine={{ stroke: "rgba(255,255,255,0.08)" }}
          tickLine={false}
          width={56}
        />
        <Tooltip content={<CustomTooltip />} />
        <Legend
          wrapperStyle={{ fontSize: 11, color: "#a1a1aa", paddingTop: 8 }}
          iconType="circle"
          iconSize={8}
        />
        <Line
          type="monotone"
          dataKey="nav"
          name="SGSMM"
          stroke="#22d3ee"
          strokeWidth={2}
          dot={false}
          activeDot={{ r: 4, fill: "#22d3ee", strokeWidth: 0 }}
          filter="url(#glow-cyan)"
        />
        <Line
          type="monotone"
          dataKey="baselineNav"
          name="Principal ($100k)"
          stroke="#6366f1"
          strokeWidth={1.5}
          strokeDasharray="4 3"
          dot={false}
          activeDot={{ r: 3, fill: "#6366f1", strokeWidth: 0 }}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}

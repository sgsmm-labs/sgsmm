import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql, desc, eq, isNotNull } from "ponder";

const app = new Hono();

// ─── Ponder built-in SQL client + GraphQL ────────────────────────────────────
app.use("/sql/*", client({ db, schema }));
app.use("/", graphql({ db, schema }));
app.use("/graphql", graphql({ db, schema }));

// ─── Custom REST endpoints ────────────────────────────────────────────────────

/**
 * GET /health
 * Returns service status and the list of indexed tables.
 */
app.get("/health", async (c) => {
  return c.json({
    status: "ok",
    indexedTables: ["wallet", "bridge_arrival", "lendle_event", "decision_event"],
  });
});

/**
 * GET /wallets/eligible?min_sortino=<bigint>&limit=<number>
 *
 * Returns wallets ordered by rolling90dSortinoMicros descending.
 * Filters out wallets with null sortino values.
 * Query params:
 *   min_sortino  — minimum rolling90dSortinoMicros (integer micros, optional, default 0)
 *   limit        — max rows to return (optional, default 50)
 */
app.get("/wallets/eligible", async (c) => {
  const limitParam = c.req.query("limit");
  const minSortinoParam = c.req.query("min_sortino");

  const limit = Math.min(Math.max(1, Number(limitParam ?? "50") || 50), 500);
  const minSortino = BigInt(minSortinoParam ?? "0");

  const rows = await db
    .select()
    .from(schema.wallet)
    .where(isNotNull(schema.wallet.rolling90dSortinoMicros))
    .orderBy(desc(schema.wallet.rolling90dSortinoMicros))
    .limit(limit);

  // Apply min_sortino filter in JS (avoids importing gte; keeps imports simple)
  const filtered =
    minSortino > 0n
      ? rows.filter(
          (w) =>
            w.rolling90dSortinoMicros !== null &&
            w.rolling90dSortinoMicros !== undefined &&
            BigInt(w.rolling90dSortinoMicros) >= minSortino,
        )
      : rows;

  const result = filtered.map((w) => ({
    address: w.address,
    rolling90dSortinoMicros: w.rolling90dSortinoMicros?.toString() ?? null,
    realizedDd30dBps: w.realizedDd30dBps,
    nObservedPositions90d: w.nObservedPositions90d,
    labelScoreMicros: w.labelScoreMicros,
    lendleActive: w.lendleActive,
    bridgedFromEthereum: w.bridgedFromEthereum,
    firstSeenAt: w.firstSeenAt?.toString() ?? null,
  }));

  return c.json({ wallets: result, count: result.length });
});

/**
 * GET /wallets/:address
 * Returns the single wallet row + its last 20 decisionEvents.
 */
app.get("/wallets/:address", async (c) => {
  const rawAddress = c.req.param("address").toLowerCase() as `0x${string}`;

  const [walletRow] = await db
    .select()
    .from(schema.wallet)
    .where(eq(schema.wallet.address, rawAddress))
    .limit(1);

  if (!walletRow) {
    return c.json({ error: "wallet not found" }, 404);
  }

  const decisions = await db
    .select()
    .from(schema.decisionEvent)
    .where(eq(schema.decisionEvent.wallet, rawAddress))
    .orderBy(desc(schema.decisionEvent.timestamp))
    .limit(20);

  return c.json({
    wallet: {
      address: walletRow.address,
      firstSeenAt: walletRow.firstSeenAt?.toString() ?? null,
      bridgedFromEthereum: walletRow.bridgedFromEthereum,
      lendleActive: walletRow.lendleActive,
      initCapitalActive: walletRow.initCapitalActive,
      agniActive: walletRow.agniActive,
      moeActive: walletRow.moeActive,
      rolling90dSortinoMicros:
        walletRow.rolling90dSortinoMicros?.toString() ?? null,
      realizedDd30dBps: walletRow.realizedDd30dBps,
      nObservedPositions90d: walletRow.nObservedPositions90d,
      labelScoreMicros: walletRow.labelScoreMicros,
    },
    recentDecisions: decisions.map((d) => ({
      id: d.id,
      cycle: d.cycle?.toString() ?? null,
      action: d.action,
      sortinoMicros: d.sortinoMicros?.toString() ?? null,
      sleevePctBps: d.sleevePctBps,
      navAfter: d.navAfter?.toString() ?? null,
      reasonCode: d.reasonCode,
      blockNumber: d.blockNumber?.toString() ?? null,
      timestamp: d.timestamp?.toString() ?? null,
    })),
  });
});

/**
 * GET /decisions/recent?limit=<number>
 * Returns the last N decision events, newest first.
 * Query params:
 *   limit — max rows (optional, default 50, max 500)
 */
app.get("/decisions/recent", async (c) => {
  const limitParam = c.req.query("limit");
  const limit = Math.min(Math.max(1, Number(limitParam ?? "50") || 50), 500);

  const rows = await db
    .select()
    .from(schema.decisionEvent)
    .orderBy(desc(schema.decisionEvent.timestamp))
    .limit(limit);

  const result = rows.map((d) => ({
    id: d.id,
    cycle: d.cycle?.toString() ?? null,
    wallet: d.wallet,
    action: d.action,
    sortinoMicros: d.sortinoMicros?.toString() ?? null,
    sleevePctBps: d.sleevePctBps,
    navAfter: d.navAfter?.toString() ?? null,
    reasonCode: d.reasonCode,
    blockNumber: d.blockNumber?.toString() ?? null,
    timestamp: d.timestamp?.toString() ?? null,
  }));

  return c.json({ decisions: result, count: result.length });
});

export default app;

import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql, desc, eq, isNotNull, gte, lt } from "ponder";
import { isAddress } from "viem";

const app = new Hono();

// ─── Global error handler ─────────────────────────────────────────────────────
app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "internal error" }, 500);
});

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
 * GET /wallets/eligible?min_sortino=<bigint>&limit=<number>&before=<rolling90dSortinoMicros>
 *
 * Returns wallets ordered by rolling90dSortinoMicros descending.
 * Filters out wallets with null sortino values.
 * Query params:
 *   min_sortino  — minimum rolling90dSortinoMicros (integer micros, optional, default 0)
 *   limit        — max rows to return (optional, default 50, max 500)
 *   before       — keyset cursor: return rows with rolling90dSortinoMicros < this value (integer micros)
 */
app.get("/wallets/eligible", async (c) => {
  const limitParam = c.req.query("limit");
  const minSortinoParam = c.req.query("min_sortino");
  const beforeParam = c.req.query("before");

  const limit = Math.min(Math.max(1, Number(limitParam ?? "50") || 50), 500);

  if (minSortinoParam !== undefined && !/^-?\d+$/.test(minSortinoParam)) {
    return c.json({ error: "min_sortino must be an integer (micros)" }, 400);
  }
  if (beforeParam !== undefined && !/^-?\d+$/.test(beforeParam)) {
    return c.json({ error: "before must be an integer (micros)" }, 400);
  }
  const minSortino = BigInt(minSortinoParam ?? "0");
  const beforeCursor = beforeParam !== undefined ? BigInt(beforeParam) : undefined;

  // Build WHERE: combine isNotNull/gte with optional keyset cursor (lt)
  const baseCondition =
    minSortinoParam !== undefined
      ? gte(schema.wallet.rolling90dSortinoMicros, minSortino)
      : isNotNull(schema.wallet.rolling90dSortinoMicros);

  const rows = await db
    .select()
    .from(schema.wallet)
    .where(
      beforeCursor !== undefined
        ? lt(schema.wallet.rolling90dSortinoMicros, beforeCursor)
        : baseCondition,
    )
    .orderBy(desc(schema.wallet.rolling90dSortinoMicros))
    .limit(limit + 1);

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;

  const result = page.map((w) => ({
    address: w.address,
    rolling90dSortinoMicros: w.rolling90dSortinoMicros?.toString() ?? null,
    realizedDd30dBps: w.realizedDd30dBps,
    nObservedPositions90d: w.nObservedPositions90d,
    labelScoreMicros: w.labelScoreMicros,
    lendleActive: w.lendleActive,
    bridgedFromEthereum: w.bridgedFromEthereum,
    firstSeenAt: w.firstSeenAt?.toString() ?? null,
  }));

  const lastRow = page[page.length - 1];
  const nextCursor =
    hasMore && lastRow?.rolling90dSortinoMicros != null
      ? lastRow.rolling90dSortinoMicros.toString()
      : null;

  return c.json({ wallets: result, count: result.length, nextCursor });
});

/**
 * GET /wallets/:address
 * Returns the single wallet row + its last 20 decisionEvents.
 */
app.get("/wallets/:address", async (c) => {
  const raw = c.req.param("address");
  if (!isAddress(raw)) {
    return c.json({ error: "invalid address" }, 400);
  }
  const rawAddress = raw.toLowerCase() as `0x${string}`;

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
 * GET /decisions/recent?limit=<number>&before=<timestamp>
 * Returns the last N decision events, newest first.
 * Query params:
 *   limit  — max rows (optional, default 50, max 500)
 *   before — keyset cursor: return rows with timestamp < this value (unix seconds as integer)
 */
app.get("/decisions/recent", async (c) => {
  const limitParam = c.req.query("limit");
  const beforeParam = c.req.query("before");

  const limit = Math.min(Math.max(1, Number(limitParam ?? "50") || 50), 500);

  if (beforeParam !== undefined && !/^\d+$/.test(beforeParam)) {
    return c.json({ error: "before must be a non-negative integer (unix seconds)" }, 400);
  }
  const beforeCursor = beforeParam !== undefined ? BigInt(beforeParam) : undefined;

  const rows = await db
    .select()
    .from(schema.decisionEvent)
    .where(
      beforeCursor !== undefined
        ? lt(schema.decisionEvent.timestamp, beforeCursor)
        : undefined,
    )
    .orderBy(desc(schema.decisionEvent.timestamp))
    .limit(limit + 1);

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;

  const result = page.map((d) => ({
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

  const lastRow = page[page.length - 1];
  const nextCursor = hasMore && lastRow ? lastRow.timestamp?.toString() ?? null : null;

  return c.json({ decisions: result, count: result.length, nextCursor });
});

export default app;

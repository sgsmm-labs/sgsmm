import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import {
  client,
  graphql,
  desc,
  asc,
  eq,
  gt,
  lt,
  gte,
  and,
  or,
  isNotNull,
} from "ponder";
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
 * Split a composite keyset cursor "<value>_<key>" on the FIRST underscore.
 * The value part is always numeric (no underscore); the key part is the rest
 * (an address or an event id), so this is unambiguous even if the key contains
 * underscores.
 */
function splitCursor(cursor: string): { value: string; key: string } {
  const i = cursor.indexOf("_");
  return i === -1
    ? { value: cursor, key: "" }
    : { value: cursor.slice(0, i), key: cursor.slice(i + 1) };
}

/**
 * GET /wallets/eligible?min_sortino=<micros>&limit=<n>&before=<sortinoMicros>_<address>
 *
 * Wallets ordered by rolling90dSortinoMicros DESC, then address ASC (a total
 * order, so keyset pagination never skips boundary-tied rows). The min_sortino
 * filter is applied on EVERY page (page 1 and beyond).
 *   min_sortino  — minimum rolling90dSortinoMicros (signed integer micros, optional)
 *   limit        — max rows (optional, default 50, max 500)
 *   before       — composite keyset cursor "<sortinoMicros>_<address>" (from nextCursor)
 */
app.get("/wallets/eligible", async (c) => {
  const limitParam = c.req.query("limit");
  const minSortinoParam = c.req.query("min_sortino");
  const beforeParam = c.req.query("before");

  const limit = Math.min(Math.max(1, Number(limitParam ?? "50") || 50), 500);

  if (minSortinoParam !== undefined && !/^-?\d+$/.test(minSortinoParam)) {
    return c.json({ error: "min_sortino must be an integer (micros)" }, 400);
  }

  // Parse the optional composite cursor.
  let beforeSortino: bigint | undefined;
  let beforeAddress: `0x${string}` | undefined;
  if (beforeParam !== undefined) {
    const { value, key } = splitCursor(beforeParam);
    if (!/^-?\d+$/.test(value) || !isAddress(key)) {
      return c.json(
        { error: "before must be '<sortinoMicros>_<address>'" },
        400,
      );
    }
    beforeSortino = BigInt(value);
    beforeAddress = key.toLowerCase() as `0x${string}`;
  }

  // Base filter — applied on every page.
  const baseFilter =
    minSortinoParam !== undefined
      ? gte(schema.wallet.rolling90dSortinoMicros, BigInt(minSortinoParam))
      : isNotNull(schema.wallet.rolling90dSortinoMicros);

  // Keyset predicate for (sortino DESC, address ASC): rows strictly after the
  // cursor are `sortino < cv OR (sortino == cv AND address > ck)`.
  const keyset =
    beforeSortino !== undefined && beforeAddress !== undefined
      ? or(
          lt(schema.wallet.rolling90dSortinoMicros, beforeSortino),
          and(
            eq(schema.wallet.rolling90dSortinoMicros, beforeSortino),
            gt(schema.wallet.address, beforeAddress),
          ),
        )
      : undefined;

  const rows = await db
    .select()
    .from(schema.wallet)
    .where(keyset ? and(baseFilter, keyset) : baseFilter)
    .orderBy(desc(schema.wallet.rolling90dSortinoMicros), asc(schema.wallet.address))
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
      ? `${lastRow.rolling90dSortinoMicros.toString()}_${lastRow.address}`
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
 * GET /decisions/recent?limit=<n>&before=<timestamp>_<id>
 *
 * Decision events ordered by timestamp DESC, then id ASC (a total order, so
 * keyset pagination never skips boundary-tied rows).
 *   limit  — max rows (optional, default 50, max 500)
 *   before — composite keyset cursor "<timestamp>_<id>" (from nextCursor)
 */
app.get("/decisions/recent", async (c) => {
  const limitParam = c.req.query("limit");
  const beforeParam = c.req.query("before");

  const limit = Math.min(Math.max(1, Number(limitParam ?? "50") || 50), 500);

  let beforeTs: bigint | undefined;
  let beforeId: string | undefined;
  if (beforeParam !== undefined) {
    const { value, key } = splitCursor(beforeParam);
    if (!/^\d+$/.test(value) || key.length === 0) {
      return c.json(
        { error: "before must be '<timestamp>_<id>'" },
        400,
      );
    }
    beforeTs = BigInt(value);
    beforeId = key;
  }

  // Keyset predicate for (timestamp DESC, id ASC).
  const keyset =
    beforeTs !== undefined && beforeId !== undefined
      ? or(
          lt(schema.decisionEvent.timestamp, beforeTs),
          and(
            eq(schema.decisionEvent.timestamp, beforeTs),
            gt(schema.decisionEvent.id, beforeId),
          ),
        )
      : undefined;

  const rows = await db
    .select()
    .from(schema.decisionEvent)
    .where(keyset)
    .orderBy(desc(schema.decisionEvent.timestamp), asc(schema.decisionEvent.id))
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
  const nextCursor =
    hasMore && lastRow?.timestamp != null
      ? `${lastRow.timestamp.toString()}_${lastRow.id}`
      : null;

  return c.json({ decisions: result, count: result.length, nextCursor });
});

export default app;

import { onchainTable, index, relations } from "ponder";

/**
 * Wallet — one row per smart-money candidate.
 * Hydrated from Lendle protocol actors + L1 bridge arrivals.
 */
export const wallet = onchainTable(
  "wallet",
  (t) => ({
    address: t.hex().primaryKey(),
    firstSeenAt: t.bigint().notNull(), // unix timestamp (seconds)
    bridgedFromEthereum: t.boolean().notNull().default(false),
    lendleActive: t.boolean().notNull().default(false),
    initCapitalActive: t.boolean().notNull().default(false),
    agniActive: t.boolean().notNull().default(false),
    moeActive: t.boolean().notNull().default(false),
    // Aggregated metrics (recomputed off-chain by agent, written by indexer)
    rolling90dSortinoMicros: t.bigint(),
    realizedDd30dBps: t.integer(),
    nObservedPositions90d: t.integer().notNull().default(0),
    labelScoreMicros: t.integer(),
  }),
  (table) => ({
    bridgedIdx: index().on(table.bridgedFromEthereum),
    lendleIdx: index().on(table.lendleActive),
    sortinoIdx: index().on(table.rolling90dSortinoMicros),
  }),
);

/**
 * BridgeArrival — Ethereum L1 → Mantle bridge events.
 * The `to` field becomes a Wallet on Mantle.
 */
export const bridgeArrival = onchainTable(
  "bridge_arrival",
  (t) => ({
    id: t.text().primaryKey(), // ethTxHash + logIndex
    fromAddress: t.hex().notNull(),
    toAddress: t.hex().notNull(),
    amountWei: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    toIdx: index().on(table.toAddress),
    blockIdx: index().on(table.blockNumber),
  }),
);

/**
 * LendleEvent — raw Supply/Borrow/Repay/Liquidation per wallet.
 * Used to reconstruct per-wallet position history for the Sortino classifier.
 */
export const lendleEvent = onchainTable(
  "lendle_event",
  (t) => ({
    id: t.text().primaryKey(), // txHash + logIndex
    eventKind: t.text().notNull(), // "deposit" | "borrow" | "repay" | "withdraw" | "liquidation"
    wallet: t.hex().notNull(),
    reserve: t.hex().notNull(), // token contract address
    amountWei: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    walletIdx: index().on(table.wallet),
    reserveIdx: index().on(table.reserve),
    kindIdx: index().on(table.eventKind),
    timeIdx: index().on(table.timestamp),
  }),
);

/**
 * DecisionEvent — mirror of DecisionLog.Decision on Mantle.
 * One row per agent decision per cycle.
 */
export const decisionEvent = onchainTable(
  "decision_event",
  (t) => ({
    id: t.text().primaryKey(), // txHash + logIndex
    cycle: t.bigint().notNull(),
    wallet: t.hex().notNull(),
    action: t.text().notNull(), // "Enter" | "Hold" | "Defund" | "EmergencyUnwind" | "Skip"
    sortinoMicros: t.bigint().notNull(),
    sleevePctBps: t.integer().notNull(),
    navAfter: t.bigint().notNull(),
    reasonCode: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    walletIdx: index().on(table.wallet),
    cycleIdx: index().on(table.cycle),
    actionIdx: index().on(table.action),
  }),
);

export const walletRelations = relations(wallet, ({ many }) => ({
  bridgeArrivals: many(bridgeArrival),
  lendleEvents: many(lendleEvent),
  decisions: many(decisionEvent),
}));

export const bridgeArrivalRelations = relations(bridgeArrival, ({ one }) => ({
  wallet: one(wallet, { fields: [bridgeArrival.toAddress], references: [wallet.address] }),
}));

export const lendleEventRelations = relations(lendleEvent, ({ one }) => ({
  walletRef: one(wallet, { fields: [lendleEvent.wallet], references: [wallet.address] }),
}));

export const decisionEventRelations = relations(decisionEvent, ({ one }) => ({
  walletRef: one(wallet, { fields: [decisionEvent.wallet], references: [wallet.address] }),
}));

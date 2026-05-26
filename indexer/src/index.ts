import { ponder } from "ponder:registry";
import { wallet, bridgeArrival, lendleEvent } from "ponder:schema";

// ─── Lendle (Mantle Mainnet) ─────────────────────────────────────────────────

ponder.on("LendlePool:Deposit", async ({ event, context }) => {
  const user = event.args.onBehalfOf.toLowerCase() as `0x${string}`;
  await context.db
    .insert(wallet)
    .values({
      address: user,
      firstSeenAt: event.block.timestamp,
      lendleActive: true,
    })
    .onConflictDoUpdate({ lendleActive: true });

  await context.db.insert(lendleEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    eventKind: "deposit",
    wallet: user,
    reserve: event.args.reserve.toLowerCase() as `0x${string}`,
    amountWei: event.args.amount,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("LendlePool:Borrow", async ({ event, context }) => {
  const user = event.args.onBehalfOf.toLowerCase() as `0x${string}`;
  await context.db
    .insert(wallet)
    .values({
      address: user,
      firstSeenAt: event.block.timestamp,
      lendleActive: true,
    })
    .onConflictDoUpdate({ lendleActive: true });

  await context.db.insert(lendleEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    eventKind: "borrow",
    wallet: user,
    reserve: event.args.reserve.toLowerCase() as `0x${string}`,
    amountWei: event.args.amount,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("LendlePool:Repay", async ({ event, context }) => {
  const user = event.args.user.toLowerCase() as `0x${string}`;
  await context.db
    .insert(wallet)
    .values({
      address: user,
      firstSeenAt: event.block.timestamp,
      lendleActive: true,
    })
    .onConflictDoUpdate({ lendleActive: true });

  await context.db.insert(lendleEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    eventKind: "repay",
    wallet: user,
    reserve: event.args.reserve.toLowerCase() as `0x${string}`,
    amountWei: event.args.amount,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("LendlePool:Withdraw", async ({ event, context }) => {
  const user = event.args.user.toLowerCase() as `0x${string}`;
  await context.db
    .insert(wallet)
    .values({
      address: user,
      firstSeenAt: event.block.timestamp,
      lendleActive: true,
    })
    .onConflictDoUpdate({ lendleActive: true });

  await context.db.insert(lendleEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    eventKind: "withdraw",
    wallet: user,
    reserve: event.args.reserve.toLowerCase() as `0x${string}`,
    amountWei: event.args.amount,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

ponder.on("LendlePool:LiquidationCall", async ({ event, context }) => {
  const user = event.args.user.toLowerCase() as `0x${string}`;
  await context.db
    .insert(wallet)
    .values({
      address: user,
      firstSeenAt: event.block.timestamp,
      lendleActive: true,
    })
    .onConflictDoUpdate({ lendleActive: true });

  await context.db.insert(lendleEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    eventKind: "liquidation",
    wallet: user,
    reserve: event.args.collateralAsset.toLowerCase() as `0x${string}`,
    amountWei: event.args.liquidatedCollateralAmount,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

// ─── L1StandardBridge (Ethereum Mainnet) ─────────────────────────────────────

ponder.on("L1StandardBridge:ETHBridgeInitiated", async ({ event, context }) => {
  const to = event.args.to.toLowerCase() as `0x${string}`;
  await context.db
    .insert(wallet)
    .values({
      address: to,
      firstSeenAt: event.block.timestamp,
      bridgedFromEthereum: true,
    })
    .onConflictDoUpdate({ bridgedFromEthereum: true });

  await context.db.insert(bridgeArrival).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    fromAddress: event.args.from.toLowerCase() as `0x${string}`,
    toAddress: to,
    amountWei: event.args.amount,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
  });
});

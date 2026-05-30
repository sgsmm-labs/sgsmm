# @sgsmm/indexer

Ponder-based blockchain indexer for the Sortino-Gated Smart Money Mirror (SGSMM) project.

Indexes Lendle lending events on Mantle Mainnet and L1 bridge arrivals from Ethereum Mainnet.
Exposes GraphQL, SQL-over-HTTP, and custom REST endpoints for the SGSMM agent and frontend.

## Running

From the repo root:

```bash
pnpm indexer:dev
```

Or directly targeting the package:

```bash
pnpm --filter @sgsmm/indexer dev
```

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `PONDER_RPC_URL_5000` | no | `https://rpc.mantle.xyz` | Mantle Mainnet RPC |
| `PONDER_RPC_URL_1` | no | `https://ethereum-rpc.publicnode.com` | Ethereum Mainnet RPC |
| `PONDER_RPC_URL_5003` | no | `https://rpc.sepolia.mantle.xyz` | Mantle Sepolia RPC (for SGSMM contracts post-deploy) |
| `DECISION_LOG_ADDRESS` | post-deploy | — | DecisionLog contract address on Mantle Sepolia |
| `DECISION_LOG_START_BLOCK` | post-deploy | `0` | DecisionLog deploy block |
| `SGSMM_VAULT_ADDRESS` | post-deploy | — | SGSMMVault contract address on Mantle Sepolia |
| `SGSMM_VAULT_START_BLOCK` | post-deploy | `0` | SGSMMVault deploy block |

Copy `.env.example` to `.env.local` and fill in your RPC endpoints.

## API Endpoints

The indexer listens on `http://localhost:42069` by default (Ponder default port).

### Built-in Ponder endpoints

| Method | Path | Description |
|---|---|---|
| `GET / POST` | `/graphql` | GraphQL endpoint (full schema) |
| `GET / POST` | `/` | GraphQL endpoint (alias) |
| `GET` | `/sql/*` | SQL-over-HTTP Drizzle client |

### Custom REST endpoints

#### `GET /health`

Returns service status and indexed table names.

```json
{
  "status": "ok",
  "indexedTables": ["wallet", "bridge_arrival", "lendle_event", "decision_event"]
}
```

#### `GET /wallets/eligible`

Returns wallets ranked by `rolling90dSortinoMicros` descending. Only wallets with a non-null Sortino score are returned.

Query parameters:

| Param | Type | Default | Description |
|---|---|---|---|
| `min_sortino` | integer (micros) | `0` | Minimum Sortino score filter |
| `limit` | integer | `50` | Max rows (capped at 500) |

Example: `GET /wallets/eligible?min_sortino=1000000&limit=20`

```json
{
  "wallets": [
    {
      "address": "0xabc...",
      "rolling90dSortinoMicros": "2450000",
      "realizedDd30dBps": 80,
      "nObservedPositions90d": 14,
      "labelScoreMicros": 920000,
      "lendleActive": true,
      "bridgedFromEthereum": true,
      "firstSeenAt": "1716000000"
    }
  ],
  "count": 1
}
```

Note: `bigint` fields (`rolling90dSortinoMicros`, `firstSeenAt`, etc.) are serialised as strings to preserve precision in JSON.

#### `GET /wallets/:address`

Returns a single wallet row plus its 20 most recent decision events.

Example: `GET /wallets/0xabc...`

```json
{
  "wallet": {
    "address": "0xabc...",
    "firstSeenAt": "1716000000",
    "bridgedFromEthereum": true,
    "lendleActive": true,
    "initCapitalActive": false,
    "agniActive": false,
    "moeActive": false,
    "rolling90dSortinoMicros": "2450000",
    "realizedDd30dBps": 80,
    "nObservedPositions90d": 14,
    "labelScoreMicros": 920000
  },
  "recentDecisions": [
    {
      "id": "0xtx...-3",
      "cycle": "42",
      "action": "Enter",
      "sortinoMicros": "2450000",
      "sleevePctBps": 1000,
      "navAfter": "5000000000000000000",
      "reasonCode": 1,
      "blockNumber": "95840100",
      "timestamp": "1716001200"
    }
  ]
}
```

Returns `404` with `{ "error": "wallet not found" }` if the address is unknown.

#### `GET /decisions/recent`

Returns the most recent decision events across all wallets, newest first.

Query parameters:

| Param | Type | Default | Description |
|---|---|---|---|
| `limit` | integer | `50` | Max rows (capped at 500) |

Example: `GET /decisions/recent?limit=10`

```json
{
  "decisions": [
    {
      "id": "0xtx...-3",
      "cycle": "42",
      "wallet": "0xabc...",
      "action": "Enter",
      "sortinoMicros": "2450000",
      "sleevePctBps": 1000,
      "navAfter": "5000000000000000000",
      "reasonCode": 1,
      "blockNumber": "95840100",
      "timestamp": "1716001200"
    }
  ],
  "count": 1
}
```

## SGSMM Contracts (Mantle Sepolia — post-deploy)

`DecisionLog` and `SGSMMVault` contract blocks in `ponder.config.ts` are **commented out** until after Phase 4 Sepolia deployment. Once deployed:

1. Set the four env vars (`DECISION_LOG_ADDRESS`, `DECISION_LOG_START_BLOCK`, `SGSMM_VAULT_ADDRESS`, `SGSMM_VAULT_START_BLOCK`).
2. Uncomment the two contract blocks in `ponder.config.ts` (marked `TODO(deploy)`).
3. The `mantleSepolia` chain entry (id 5003) is already registered and active.

## Schema

Tables: `wallet`, `bridge_arrival`, `lendle_event`, `decision_event`. See `ponder.schema.ts` for full column definitions and indexes.

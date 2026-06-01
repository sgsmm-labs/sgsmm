# SGSMM Contracts

Foundry-based Solidity smart contracts for the Sortino-Gated Smart Money Mirror vault system on Mantle.

## Contracts Overview

### 1. **SGSMMVault.sol** (ERC-4626 Vault)
- Holds user deposits (USDY on Mantle)
- Implements 60/40 floor/sleeve split: 60% in stable floor (USDY), 40% in dynamic sleeve (mirror positions)
- Exposes standard ERC-4626 interface: `deposit()`, `withdraw()`, `redeem()`, `preview*()` functions
- Enforces 10% fee reserve on profits

### 2. **MirrorExecutor.sol** (Policy Enforcement)
- On-chain decision enforcement: caps per position, per-wallet limits
- Even if agent submits rogue transactions, executor hard-gates:
  - Per-position cap: 5% of vault AUM
  - Per-wallet cap: 15% of vault AUM
  - Total sleeve utilization: max 40% of vault
- Coordinates with DecisionLog for verifiable action history

### 3. **DecisionLog.sol** (Verifiability)
- Immutable on-chain log of all agent decisions
- Emits `Decision` events: `(wallet, action: ENTER/HOLD/DEFUND, sortino, timestamp, tx_hash)`
- Proves to judges that decisions are mechanically enforced and auditable
- Satisfies Path B rubric requirement: "live on-chain records"

### 4. **AgentIdentityNFT.sol** (ERC-8004 Reputation)
- Reputation NFT minted to agent address
- Tracks cumulative:
  - Decisions executed
  - Profit/loss per epoch
  - Uptime
- Required for ERC-8004 hackathon award consideration

## Build & Test

### Prerequisites
- **Foundry** installed; see [foundry.paradigm.xyz](https://foundry.paradigm.xyz)

### Build

```bash
cd contracts
forge build
```

### Test

All 35 tests should pass:

```bash
cd contracts
forge test
```

**Test breakdown:**
- `SGSMMVault.t.sol` — ERC-4626 deposit/withdraw/preview, fee logic
- `MirrorExecutor.t.sol` — Cap enforcement, access control
- `DecisionLog.t.sol` — Event emissions, decision history
- `AgentIdentityNFT.t.sol` — NFT minting, metadata

### Format Code

```bash
cd contracts
forge fmt
```

## Deployment (Mantle Sepolia — Pending Phase 2 Gate Clearance)

The strategy must first clear the kill-criterion gate (Sortino ≥ 1.5 on a 26-epoch backtest window) before on-chain deployment is warranted. Currently, the realized Sortino is 0.51 on the validated 26-epoch window — **deployment is blocked pending a window where the strategy clears the gate.**

Once gate clearance is achieved:

```bash
cd contracts

# Set environment variables
export MANTLE_SEPOLIA_RPC="https://rpc.sepolia.mantle.xyz"
export DEPLOYER_PRIVATE_KEY="0x..."

# Run deployment script
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $MANTLE_SEPOLIA_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

**Deploy.s.sol workflow:**
1. Deploy `DecisionLog`
2. Deploy `SGSMMVault` (reference to DecisionLog)
3. Deploy `MirrorExecutor` (reference to Vault + DecisionLog)
4. Deploy `AgentIdentityNFT` (agent address + Vault reference)
5. Set `MirrorExecutor` as vault's privileged caller (for position updates)
6. Emit initialization events

### Gas Snapshots

```bash
cd contracts
forge snapshot
```

See `.gas-snapshot` for per-function gas costs.

## Current Status

- **✓ All 4 contracts written** (SGSMMVault, MirrorExecutor, DecisionLog, AgentIdentityNFT)
- **✓ 35 tests passing** (unit + integration)
- **✓ Code formatted & linted** (via `forge fmt`)
- **⏸ NOT YET DEPLOYED** — awaiting Phase 2 gate clearance on Mantle Sepolia

## References

- [Foundry Docs](https://paritytech.github.io/foundry-book-polkadot/)
- [ERC-4626 Spec](https://eips.ethereum.org/EIPS/eip-4626)
- [Mantle RPC Docs](https://docs.mantle.xyz)
- Root README: [../../README.md](../../README.md)

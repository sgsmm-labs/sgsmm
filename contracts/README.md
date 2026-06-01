# SGSMM Contracts

Foundry smart contracts for the Sortino-Gated Smart Money Mirror on Mantle. **Written + tested (75 forge tests incl. invariants); not yet deployed.**

## Contracts

### `SGSMMVault.sol` — ERC-4626 vault
- Holds user deposits (USDY on Mantle). Layered capital: **60% USDY floor / 30% deployable sleeve / 10% reserve**, with a hard **40% total-sleeve cap** enforced on entry (`RetainedLiquidityBreached` if <70% liquid retained).
- First-depositor inflation protection: `_decimalsOffset()=6`, reverts on zero-share mint, deploy seeds dead shares.
- `Pausable` (deposits halt under incident), `ReentrancyGuard` + CEI on the custom enter/exit, conservative ceil cap math, `nav==0` guard.
- **Custody is trust-minimized:** `enterMirror(wallet, amount)` sends the sleeve **only to a governance-set `custodian` contract** (`setCustodian` rejects EOAs and the zero address). There is no caller-supplied recipient — funds can never go to an arbitrary/agent address.

### `MirrorExecutor.sol` — the custodian + policy layer
- **Holds the deployed sleeve** (it is the vault's custodian). A compromised `AGENT_ROLE` key **cannot extract funds**: the only fund-moving paths are
  - `deployToVenue(router, tokenIn, tokenOut, amountIn, minOut)` — swaps **only** via a governance-whitelisted router + tokens, with proceeds hard-coded to `address(this)`; and
  - `executeExit(...)` — returns funds to the vault (the vault pulls).
- Emits decisions to `DecisionLog`. `agentId` is governance-settable to point at the Mantle-issued ERC-8004 ID (see below).

### `DecisionLog.sol` — on-chain benchmarking of AI
- Immutable, append-only log of every agent decision; **`navAfter` is read from the vault** inside `logDecision` (not caller-forged). Independent observers reconstruct the full policy from chain — this is the hackathon's *"on-chain benchmarking of AI"* primitive and the Path-B verifiability requirement.

### `AgentIdentityNFT.sol` — LOCAL STAND-IN for Mantle's ERC-8004
- ⚠️ **We do NOT deploy our own canonical agent identity.** Per the organizers, **Mantle issues each agent's ERC-8004 Agent ID.** This contract is a *local dev stand-in* so the testnet demo is self-contained; on mainnet `MirrorExecutor.agentId` is set (via governance) to the **Mantle-issued** ID.

## Build & Test

```bash
cd contracts
forge build
forge test     # 75 passed: unit + custody-security + 4 invariants (256x128k calls, 0 reverts)
forge fmt
```

Custody-security tests of note: `test_setCustodian_rejects_eoa`, `test_agent_cannot_whitelist_router`, `test_deployToVenue_whitelisted_keeps_funds_in_custodian`, `test_vault_custodian_is_executor_contract_not_eoa`.

## Governance

`DEFAULT_ADMIN_ROLE` on all four contracts is held by an OpenZeppelin **`TimelockController`** (2-day delay), with a governance **multisig** as proposer; the deployer **renounces** its admin during deploy. Whitelist/custodian/agentId changes route through the timelock.

## Deployment (Mantle Sepolia)

Testnet deployment is acceptable for the hackathon. The strategy does **not** yet clear its kill-criterion gate — a 90-day-gated policy can't be validated on the 26-epoch backtest (positions open in only ~7 of 26 epochs), so this is a methodology + infrastructure demo. Deploy is still warranted to demonstrate the on-chain DecisionLog + custody design.

```bash
cd contracts
export GOVERNANCE_MULTISIG_ADDRESS="0x..."   # a Safe on mainnet; defaults to deployer on testnet
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://rpc.sepolia.mantle.xyz \
  --private-key <DEPLOYER_KEY> --broadcast
```

`Deploy.s.sol` deploys DecisionLog → Vault → MirrorExecutor → AgentIdentityNFT + the TimelockController, sets the vault custodian to the executor, then hands `DEFAULT_ADMIN_ROLE` to the timelock and renounces the deployer's admin.

## Before mainnet (open items)
- **Professional audit** (AI review ≠ audit).
- Pass a **real Safe** as `GOVERNANCE_MULTISIG_ADDRESS`.
- Confirm the Mantle venue routers (Agni / Merchant Moe / FusionX) expose the V2-style `swapExactTokensForTokens` selector, or add a V3 (`exactInput`) adapter — still output-to-self, still whitelisted.

## References
- Root README: [`../README.md`](../README.md) · Architecture: [`../docs/architecture.md`](../docs/architecture.md)
- [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) · [Foundry](https://book.getfoundry.sh)

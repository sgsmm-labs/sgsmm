// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {IVaultNav} from "../src/DecisionLog.sol";
import {AgentIdentityNFT} from "../src/AgentIdentityNFT.sol";
import {MirrorExecutor} from "../src/MirrorExecutor.sol";
import {MockUSDY} from "../test/mocks/MockUSDY.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deploy
 * @notice One-shot deploy script for SGSMM on Mantle Sepolia.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *       --rpc-url $MANTLE_SEPOLIA_RPC \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $MANTLESCAN_API_KEY \
 *       --private-key $DEPLOYER_PRIVATE_KEY
 *
 * After deploy, copy addresses into agent/.env and frontend/.env.local.
 *
 * ┌──────────────────────────────────────────────────────────────────────────┐
 * │ ADMIN / GOVERNANCE — REQUIRED BEFORE MAINNET (tracked as an open item).    │
 * │                                                                            │
 * │ Every contract here grants DEFAULT_ADMIN_ROLE to the EOA deployer for      │
 * │ bootstrap convenience. A single EOA holding DEFAULT_ADMIN_ROLE is a        │
 * │ critical centralization risk: it can grant itself EXECUTOR/LOGGER/PAUSER   │
 * │ and drain or brick the system.                                             │
 * │                                                                            │
 * │ Before mainnet you MUST:                                                   │
 * │   1. Transfer DEFAULT_ADMIN_ROLE on the Vault, DecisionLog, AgentIdentity, │
 * │      and MirrorExecutor to a multisig (e.g. Safe).                         │
 * │   2. Place that multisig behind a TimelockController so privileged changes │
 * │      (role grants, pause policy) are delayed and publicly observable.      │
 * │   3. Renounce the deployer's DEFAULT_ADMIN_ROLE once the handover is       │
 * │      confirmed.                                                            │
 * │                                                                            │
 * │ NOTE: These contracts use plain OpenZeppelin AccessControl, which has a    │
 * │ ONE-STEP (push) admin model. A two-step (pull) handover would need         │
 * │ AccessControlDefaultAdminRules, a base-class change deferred to a          │
 * │ dedicated governance pass to keep this hardening build compiling. Until    │
 * │ then, perform the role transfer carefully (grant new admin, verify, then   │
 * │ renounce) — a fat-finger on a one-step grant/renounce can brick admin.     │
 * └──────────────────────────────────────────────────────────────────────────┘
 */
contract Deploy is Script {
    /// @dev Canonical burn sink for the anti-inflation dead-shares seed.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Seed deposit size for dead shares. With MockUSDY (18 decimals) this is
    ///      1 whole token of underlying, permanently locked to the DEAD address so
    ///      the vault can never return to a zero-supply state (which is what makes
    ///      the first-depositor inflation attack possible). Combined with the
    ///      vault's non-zero _decimalsOffset() this makes the attack uneconomical.
    uint256 internal constant DEAD_SHARES_SEED = 1e18;

    function run() external {
        address deployer = msg.sender;
        address agentOperator = vm.envOr("AGENT_OPERATOR_ADDRESS", deployer);
        string memory agentManifestUri =
            vm.envOr("AGENT_MANIFEST_URI", string("ipfs://placeholder-sgsmm-manifest"));

        vm.startBroadcast();

        // 1. Mock USDY (testnet only — replace with real USDY address on mainnet)
        MockUSDY usdy = new MockUSDY();
        console2.log("MockUSDY:", address(usdy));

        // 2. AgentIdentityNFT
        AgentIdentityNFT identity = new AgentIdentityNFT(deployer);
        console2.log("AgentIdentityNFT:", address(identity));

        // 3. Register the SGSMM agent (deployer is initial owner).
        //    NOTE: registration is permissionless and the URI is self-asserted /
        //    untrusted (see AgentIdentityNFT.register NatSpec).
        uint256 agentId = identity.register(agentManifestUri);
        console2.log("Agent ID:", agentId);

        // 4. SGSMM Vault (asset = MockUSDY). Deployed BEFORE DecisionLog because the
        //    log binds an immutable vault reference for forge-proof NAV snapshots.
        SGSMMVault vault = new SGSMMVault(IERC20(address(usdy)), deployer);
        console2.log("SGSMMVault:", address(vault));

        // 5. DecisionLog (binds the vault for navAfter reads)
        DecisionLog decisionLog = new DecisionLog(deployer, IVaultNav(address(vault)));
        console2.log("DecisionLog:", address(decisionLog));

        // 6. MirrorExecutor
        MirrorExecutor executor =
            new MirrorExecutor(vault, decisionLog, identity, agentId, deployer, agentOperator);
        console2.log("MirrorExecutor:", address(executor));

        // 7. Role wiring
        vault.grantRole(vault.EXECUTOR_ROLE(), address(executor));
        decisionLog.grantRole(decisionLog.LOGGER_ROLE(), address(executor));
        identity.grantRole(identity.METADATA_WRITER_ROLE(), address(executor));

        // 8. Anti-inflation dead-shares seed (AFTER role wiring).
        //    Mint underlying to the deployer, approve the vault, then deposit a
        //    non-trivial amount with the resulting shares sent to DEAD. This locks
        //    a permanent non-zero share supply + asset balance so the vault never
        //    re-enters the exploitable empty state. The deposit goes through the
        //    standard ERC-4626 path (whenNotPaused, zero-share guard) — the vault
        //    is unpaused at deploy, so this succeeds.
        usdy.mint(deployer, DEAD_SHARES_SEED);
        usdy.approve(address(vault), DEAD_SHARES_SEED);
        uint256 deadShares = vault.deposit(DEAD_SHARES_SEED, DEAD);
        console2.log("Dead-shares seeded (shares):", deadShares);

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Deploy summary:");
        console2.log("  USDY (test):     ", address(usdy));
        console2.log("  DecisionLog:     ", address(decisionLog));
        console2.log("  AgentIdentity:   ", address(identity));
        console2.log("  AgentId:         ", agentId);
        console2.log("  Vault:           ", address(vault));
        console2.log("  MirrorExecutor:  ", address(executor));
        console2.log("  Agent Operator:  ", agentOperator);
        console2.log("  Dead shares ->   ", DEAD);
    }
}

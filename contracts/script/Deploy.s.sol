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
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

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
 * │ ADMIN / GOVERNANCE HANDOVER — PERFORMED IN THIS SCRIPT.                    │
 * │                                                                            │
 * │ The deployer EOA bootstraps every contract (it temporarily holds          │
 * │ DEFAULT_ADMIN_ROLE) so it can wire roles and set the vault custodian in    │
 * │ one transaction batch. It then hands ownership to an OZ                    │
 * │ TimelockController and renounces its own admin, so no EOA retains          │
 * │ privileged control after deploy. Concretely, step (9) below:              │
 * │   1. Deploys a TimelockController(minDelay=TIMELOCK_MIN_DELAY,             │
 * │      proposers=[governanceMultisig], executors=[governanceMultisig]).     │
 * │   2. Grants DEFAULT_ADMIN_ROLE on Vault / DecisionLog / AgentIdentity /    │
 * │      MirrorExecutor to the timelock.                                       │
 * │   3. Renounces the deployer's DEFAULT_ADMIN_ROLE on all four.             │
 * │                                                                            │
 * │ `governanceMultisig` (GOVERNANCE_MULTISIG_ADDRESS env) is the sole         │
 * │ proposer/executor/canceller behind the timelock. It DEFAULTS to the       │
 * │ deployer for local/testnet so the demo stays self-contained.              │
 * │                                                                            │
 * │ MAINNET REQUIREMENT: you MUST pass a real multisig (e.g. a Gnosis Safe)    │
 * │ as GOVERNANCE_MULTISIG_ADDRESS. Defaulting the proposer/executor to a      │
 * │ single deployer EOA on mainnet re-introduces the centralization risk the   │
 * │ timelock is meant to remove.                                               │
 * │                                                                            │
 * │ NOTE: These contracts use plain OpenZeppelin AccessControl (one-step push  │
 * │ admin). The grant-then-renounce order below is deliberate: the new admin   │
 * │ (timelock) is granted and asserted BEFORE the deployer renounces, so a     │
 * │ failed grant cannot strand the contracts without an admin.                 │
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

    /// @dev Timelock delay between a queued privileged op and its execution. 2 days
    ///      gives vault users a window to react to a pending admin change before it
    ///      lands. Mainnet may raise this; do not lower it without a governance note.
    uint256 internal constant TIMELOCK_MIN_DELAY = 2 days;

    function run() external {
        address deployer = msg.sender;
        address agentOperator = vm.envOr("AGENT_OPERATOR_ADDRESS", deployer);
        // Governance multisig behind the timelock. Defaults to the deployer for
        // local/testnet; MAINNET MUST pass a real Safe via GOVERNANCE_MULTISIG_ADDRESS.
        address governanceMultisig = vm.envOr("GOVERNANCE_MULTISIG_ADDRESS", deployer);
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

        // 7b. Custody wiring (C-1): the MirrorExecutor CONTRACT is the vault's sole
        //     sleeve custodian. enterMirror reverts until this is set, and funds can
        //     only ever flow vault -> executor (never to an EOA). Set while the
        //     deployer still holds DEFAULT_ADMIN_ROLE (before the handover below).
        vault.setCustodian(address(executor));
        console2.log("Vault custodian set to MirrorExecutor:", address(executor));

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

        // 9. Governance handover to a TimelockController (extracted to keep run()'s
        //    stack shallow under the non-via-ir profile). Grants DEFAULT_ADMIN_ROLE on
        //    all four contracts to a fresh timelock, then renounces the deployer's own
        //    admin — leaving no EOA with privileged control. The helper logs the
        //    timelock + governance addresses itself (not bound here, to save stack).
        _handoverToTimelock(vault, decisionLog, identity, executor, deployer, governanceMultisig);

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
        console2.log("  (Timelock admin + gov multisig logged above in step 9.)");
    }

    /// @dev Deploys the TimelockController and hands DEFAULT_ADMIN_ROLE on all four
    ///      protocol contracts from `deployer` to it, then renounces the deployer's
    ///      admin everywhere. MUST be called inside the deployer's active broadcast.
    ///
    ///      proposers = executors = [governanceMultisig]; admin = address(0) so the
    ///      timelock is self-administered (only the multisig can queue/execute
    ///      privileged ops, after TIMELOCK_MIN_DELAY). Grant-before-renounce ordering
    ///      with explicit assertions guarantees no contract is ever left without an
    ///      admin and no deployer EOA backdoor survives.
    ///
    ///      Extracted from {run} purely to keep that function's local-variable count
    ///      below the EVM stack limit without enabling via-ir.
    function _handoverToTimelock(
        SGSMMVault vault,
        DecisionLog decisionLog,
        AgentIdentityNFT identity,
        MirrorExecutor executor,
        address deployer,
        address governanceMultisig
    ) internal {
        address[] memory proposers = new address[](1);
        proposers[0] = governanceMultisig;
        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;
        TimelockController timelock =
            new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));
        console2.log("TimelockController (new admin):", address(timelock));
        console2.log("Governance multisig (proposer/executor):", governanceMultisig);

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        // Grant the timelock admin on all four BEFORE renouncing the deployer's.
        vault.grantRole(adminRole, address(timelock));
        decisionLog.grantRole(adminRole, address(timelock));
        identity.grantRole(adminRole, address(timelock));
        executor.grantRole(adminRole, address(timelock));

        require(vault.hasRole(adminRole, address(timelock)), "vault admin->timelock failed");
        require(decisionLog.hasRole(adminRole, address(timelock)), "log admin->timelock failed");
        require(identity.hasRole(adminRole, address(timelock)), "identity admin->timelock failed");
        require(executor.hasRole(adminRole, address(timelock)), "executor admin->timelock failed");

        // Now drop the deployer's admin everywhere.
        vault.renounceRole(adminRole, deployer);
        decisionLog.renounceRole(adminRole, deployer);
        identity.renounceRole(adminRole, deployer);
        executor.renounceRole(adminRole, deployer);

        require(!vault.hasRole(adminRole, deployer), "vault deployer admin not renounced");
        require(!decisionLog.hasRole(adminRole, deployer), "log deployer admin not renounced");
        require(!identity.hasRole(adminRole, deployer), "identity deployer admin not renounced");
        require(!executor.hasRole(adminRole, deployer), "executor deployer admin not renounced");
        console2.log("DEFAULT_ADMIN_ROLE handed to timelock; deployer renounced on all four.");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {DecisionLog, IVaultNav} from "../src/DecisionLog.sol";
import {AgentIdentityNFT} from "../src/AgentIdentityNFT.sol";
import {MirrorExecutor} from "../src/MirrorExecutor.sol";
import {MockUSDY} from "./mocks/MockUSDY.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract MirrorExecutorTest is Test {
    SGSMMVault internal vault;
    DecisionLog internal decisionLog;
    AgentIdentityNFT internal identity;
    MirrorExecutor internal executor;
    MockUSDY internal usdy;

    address internal admin = address(0xA11CE);
    address internal agent = address(0xA6EE7);
    address internal alice = address(0xA1);
    address internal attacker = address(0xBAD);
    address internal wallet1 = address(0xBEEF1);
    uint256 internal agentId;

    function setUp() public {
        usdy = new MockUSDY();
        vault = new SGSMMVault(IERC20(address(usdy)), admin);
        // DecisionLog now binds the vault so navAfter is read on-chain (not forged).
        decisionLog = new DecisionLog(admin, IVaultNav(address(vault)));
        identity = new AgentIdentityNFT(admin);

        // Mint agent identity NFT
        vm.prank(agent);
        agentId = identity.register("ipfs://agent-manifest");

        // Wire executor
        executor = new MirrorExecutor(vault, decisionLog, identity, agentId, admin, agent);

        // Grant roles + set the executor CONTRACT as the vault's sole custodian (C-1).
        bytes32 vaultExecRole = vault.EXECUTOR_ROLE();
        bytes32 logRole = decisionLog.LOGGER_ROLE();
        bytes32 metaRole = identity.METADATA_WRITER_ROLE();

        vm.startPrank(admin);
        vault.grantRole(vaultExecRole, address(executor));
        decisionLog.grantRole(logRole, address(executor));
        identity.grantRole(metaRole, address(executor));
        // Custody: enterMirror sends the sleeve to the executor contract, nowhere else.
        vault.setCustodian(address(executor));
        vm.stopPrank();

        // Seed Alice deposit
        usdy.mint(alice, 10_000_000 ether);
        vm.startPrank(alice);
        usdy.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Cycle / enter / exit basics (now under contract custody)
    // ---------------------------------------------------------------------

    function test_advance_cycle_advances_log() public {
        vm.prank(agent);
        uint64 c = executor.advanceCycle();
        assertEq(c, 1);
        assertEq(decisionLog.currentCycle(), 1);
    }

    function test_executeEnter_moves_funds_to_custodian_and_logs() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        uint256 positionId =
            executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        // First position for a wallet is id 0 (monotonic per-wallet nonce starts at 0).
        assertEq(positionId, 0);
        assertEq(vault.deployedSleeve(), 80_000 ether);
        // CUSTODY (C-1): the sleeve lands on the executor CONTRACT, NOT the agent EOA.
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);
        assertEq(usdy.balanceOf(agent), 0, "agent EOA must never receive the sleeve");
        assertEq(vault.walletExposure(wallet1), 80_000 ether);
        // The ledger must record the principal for this exact position id.
        assertEq(vault.positionPrincipal(wallet1, positionId), 80_000 ether);
    }

    /// @notice executeEnter must surface the vault position id via MirrorPositionOpened.
    function test_executeEnter_emits_position_opened() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        vm.expectEmit(true, true, false, true, address(executor));
        emit MirrorExecutor.MirrorPositionOpened(wallet1, 0, 80_000 ether);
        executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));
    }

    function test_executeExit_with_defund_returns_funds_to_vault() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        uint256 positionId =
            executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        uint256 vaultBalBefore = usdy.balanceOf(address(vault));

        // The executor CONTRACT already holds the sleeve; on exit it approves the vault
        // and the vault PULLS. The agent EOA is NOT in the fund path and does not approve.
        vm.prank(agent);
        executor.executeExit(
            wallet1, positionId, 80_000 ether, DecisionLog.Action.Defund, int128(400_000), uint32(2)
        );

        assertEq(vault.deployedSleeve(), 0);
        assertEq(vault.walletExposure(wallet1), 0);
        // Position is closed: principal ledger zeroed.
        assertEq(vault.positionPrincipal(wallet1, positionId), 0);
        // Funds returned to the VAULT (balance restored), and left the executor.
        assertEq(usdy.balanceOf(address(vault)), vaultBalBefore + 80_000 ether);
        assertEq(usdy.balanceOf(address(executor)), 0);
    }

    /// @notice Settlement integrity: vault credits the MEASURED balance delta and reduces
    ///         accounting by the RECORDED principal, so a profitable return lifts NAV.
    function test_executeExit_credits_measured_profit() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        uint256 positionId =
            executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        // Simulate offchain profit accruing to the custodian CONTRACT (not an EOA): it
        // now holds 85k to return to the vault.
        usdy.mint(address(executor), 5_000 ether);

        vm.prank(agent);
        executor.executeExit(
            wallet1, positionId, 85_000 ether, DecisionLog.Action.Defund, int128(400_000), uint32(2)
        );

        assertEq(vault.deployedSleeve(), 0);
        // NAV grew by realized 5k profit: 1M - 80k principal + 85k returned = 1.005M.
        assertEq(vault.totalAssets(), 1_005_000 ether);
        assertEq(usdy.balanceOf(address(executor)), 0);
    }

    function test_executeExit_with_enter_action_reverts() public {
        vm.prank(agent);
        executor.advanceCycle();
        vm.prank(agent);
        uint256 positionId =
            executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        vm.prank(agent);
        vm.expectRevert(MirrorExecutor.UnknownAction.selector);
        executor.executeExit(
            wallet1, positionId, 80_000 ether, DecisionLog.Action.Enter, int128(0), uint32(0)
        );
    }

    function test_executeExit_insufficient_balance_reverts() public {
        vm.prank(agent);
        executor.advanceCycle();
        vm.prank(agent);
        uint256 positionId =
            executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        // Executor holds exactly 80k; attempting to return more than it holds reverts in
        // the custodian's own balance check (no EOA top-up path exists).
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                MirrorExecutor.InsufficientSleeveBalance.selector, 80_000 ether, 80_001 ether
            )
        );
        executor.executeExit(
            wallet1, positionId, 80_001 ether, DecisionLog.Action.Defund, int128(0), uint32(0)
        );
    }

    function test_executeNoOp_with_hold_only_logs() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        executor.executeNoOp(wallet1, DecisionLog.Action.Hold, int128(1_500_000), uint32(0));

        assertEq(vault.deployedSleeve(), 0); // no funds moved
    }

    function test_executeNoOp_with_invalid_action_reverts() public {
        vm.prank(agent);
        executor.advanceCycle();
        vm.prank(agent);
        vm.expectRevert(MirrorExecutor.UnknownAction.selector);
        executor.executeNoOp(wallet1, DecisionLog.Action.Enter, int128(0), uint32(0));
    }

    function test_executeEnter_without_agent_role_reverts() public {
        // Cache the role BEFORE pranking: an inline executor.AGENT_ROLE() in the
        // expectRevert args would consume the prank (it only affects the next call).
        bytes32 agentRole = executor.AGENT_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, agentRole
            )
        );
        executor.executeEnter(wallet1, 1 ether, int128(0), uint32(0), uint32(0));
    }

    function test_updateAgentMetadata_writes_to_identity() public {
        bytes memory sortinoBytes = abi.encode(int256(1_500_000));
        vm.prank(agent);
        executor.updateAgentMetadata("sortino_score", sortinoBytes);
        assertEq(identity.getMetadata(agentId, "sortino_score"), sortinoBytes);
    }

    function test_updateAgentMetadata_without_role_reverts() public {
        bytes32 agentRole = executor.AGENT_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, agentRole
            )
        );
        executor.updateAgentMetadata("sortino_score", abi.encode(int256(0)));
    }

    // =====================================================================
    // CUSTODY SECURITY (C-1): prove the agent-EOA rug is gone.
    // =====================================================================

    /// @dev Helper: enter a position so the executor custodian holds a sleeve to swap.
    function _enterSleeve(uint256 amount) internal returns (uint256 positionId) {
        vm.prank(agent);
        executor.advanceCycle();
        vm.prank(agent);
        positionId =
            executor.executeEnter(wallet1, amount, int128(1_800_000), uint32(800), uint32(1));
    }

    /// @notice (a) A whitelisted swap keeps ALL proceeds inside the executor custodian.
    ///         The router honours the executor's hard-coded `to == address(this)`, so the
    ///         agent cannot redirect output anywhere.
    function test_deployToVenue_whitelisted_keeps_funds_in_custodian() public {
        _enterSleeve(80_000 ether);

        // tokenOut is a second mintable token; router mints output to the custodian.
        MockUSDY tokenOut = new MockUSDY();
        MockSwapRouter router = new MockSwapRouter(); // 1:1 by default

        vm.startPrank(admin);
        executor.setRouterWhitelist(address(router), true);
        executor.setTokenWhitelist(address(usdy), true);
        executor.setTokenWhitelist(address(tokenOut), true);
        vm.stopPrank();

        uint256 inBefore = usdy.balanceOf(address(executor));
        assertEq(inBefore, 80_000 ether);

        vm.prank(agent);
        uint256 out = executor.deployToVenue(
            address(router), address(usdy), address(tokenOut), 30_000 ether, 30_000 ether
        );

        // 1:1 swap: 30k in, 30k out — and EVERYTHING stays in the custodian.
        assertEq(out, 30_000 ether);
        assertEq(usdy.balanceOf(address(executor)), 50_000 ether); // 80k - 30k spent
        assertEq(tokenOut.balanceOf(address(executor)), 30_000 ether); // proceeds custodied
        // No proceeds leaked to the agent or router beyond the swapped input.
        assertEq(tokenOut.balanceOf(agent), 0);
        assertEq(usdy.balanceOf(agent), 0);
        // Allowance was reset to 0 after the swap (defence-in-depth).
        assertEq(usdy.allowance(address(executor), address(router)), 0);
    }

    /// @notice (a) There is NO path for AGENT_ROLE to move funds to an arbitrary router:
    ///         a non-whitelisted router REVERTS.
    function test_deployToVenue_non_whitelisted_router_reverts() public {
        _enterSleeve(80_000 ether);

        MockUSDY tokenOut = new MockUSDY();
        MockSwapRouter evilRouter = new MockSwapRouter();

        // Whitelist the tokens but NOT the router.
        vm.startPrank(admin);
        executor.setTokenWhitelist(address(usdy), true);
        executor.setTokenWhitelist(address(tokenOut), true);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                MirrorExecutor.RouterNotWhitelisted.selector, address(evilRouter)
            )
        );
        executor.deployToVenue(
            address(evilRouter), address(usdy), address(tokenOut), 10_000 ether, 0
        );

        // Funds untouched — still fully custodied.
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);
    }

    /// @notice (a) A whitelisted router but a NON-whitelisted tokenIn reverts.
    function test_deployToVenue_non_whitelisted_tokenIn_reverts() public {
        _enterSleeve(80_000 ether);

        MockUSDY tokenOut = new MockUSDY();
        MockSwapRouter router = new MockSwapRouter();

        vm.startPrank(admin);
        executor.setRouterWhitelist(address(router), true);
        executor.setTokenWhitelist(address(tokenOut), true); // tokenOut only
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(MirrorExecutor.TokenNotWhitelisted.selector, address(usdy))
        );
        executor.deployToVenue(
            address(router), address(usdy), address(tokenOut), 10_000 ether, 0
        );
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);
    }

    /// @notice (a) A whitelisted router + tokenIn but NON-whitelisted tokenOut reverts.
    ///         This shuts the door on swapping into an attacker-controlled "token" whose
    ///         transfer could forward value out.
    function test_deployToVenue_non_whitelisted_tokenOut_reverts() public {
        _enterSleeve(80_000 ether);

        MockUSDY tokenOut = new MockUSDY();
        MockSwapRouter router = new MockSwapRouter();

        vm.startPrank(admin);
        executor.setRouterWhitelist(address(router), true);
        executor.setTokenWhitelist(address(usdy), true); // tokenIn only
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(MirrorExecutor.TokenNotWhitelisted.selector, address(tokenOut))
        );
        executor.deployToVenue(
            address(router), address(usdy), address(tokenOut), 10_000 ether, 0
        );
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);
    }

    /// @notice (a) Slippage guard: if the router returns less than minOut the swap reverts
    ///         (and the executor's allowance is left as the pre-swap state — funds intact).
    function test_deployToVenue_respects_min_out() public {
        _enterSleeve(80_000 ether);

        MockUSDY tokenOut = new MockUSDY();
        MockSwapRouter router = new MockSwapRouter();
        router.setRate(1, 2); // lossy 0.5x output

        vm.startPrank(admin);
        executor.setRouterWhitelist(address(router), true);
        executor.setTokenWhitelist(address(usdy), true);
        executor.setTokenWhitelist(address(tokenOut), true);
        vm.stopPrank();

        // Ask for full 1:1 minOut on a 0.5x router → router reverts InsufficientOutput.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockSwapRouter.InsufficientOutput.selector, 5_000 ether, 10_000 ether
            )
        );
        executor.deployToVenue(
            address(router), address(usdy), address(tokenOut), 10_000 ether, 10_000 ether
        );
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);
    }

    /// @notice (a) deployToVenue is AGENT_ROLE-gated; a random attacker cannot call it.
    function test_deployToVenue_without_agent_role_reverts() public {
        _enterSleeve(80_000 ether);
        MockUSDY tokenOut = new MockUSDY();
        MockSwapRouter router = new MockSwapRouter();
        vm.startPrank(admin);
        executor.setRouterWhitelist(address(router), true);
        executor.setTokenWhitelist(address(usdy), true);
        executor.setTokenWhitelist(address(tokenOut), true);
        vm.stopPrank();

        bytes32 agentRole = executor.AGENT_ROLE();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, agentRole
            )
        );
        executor.deployToVenue(
            address(router), address(usdy), address(tokenOut), 10_000 ether, 0
        );
    }

    /// @notice (a) Whitelist administration is governance-only: AGENT_ROLE cannot
    ///         self-whitelist a router to widen its own reach.
    function test_agent_cannot_whitelist_router() public {
        MockSwapRouter router = new MockSwapRouter();
        bytes32 adminRole = executor.DEFAULT_ADMIN_ROLE();
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole
            )
        );
        executor.setRouterWhitelist(address(router), true);
    }

    /// @notice (a) THE rug attempt, end to end: a compromised AGENT_ROLE key tries every
    ///         fund-moving entrypoint to extract the sleeve to an address it controls.
    ///         Every attempt reverts and the sleeve stays fully custodied.
    function test_agent_role_cannot_extract_funds_to_attacker() public {
        _enterSleeve(80_000 ether);
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);

        // An attacker-deployed router that would forward output to the attacker is simply
        // not whitelisted, so deployToVenue can never call it.
        MockSwapRouter attackerRouter = new MockSwapRouter();
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                MirrorExecutor.RouterNotWhitelisted.selector, address(attackerRouter)
            )
        );
        executor.deployToVenue(
            address(attackerRouter), address(usdy), address(usdy), 80_000 ether, 0
        );

        // Even with a whitelisted router, the swap `to` is hard-coded to the executor, so
        // a whitelisted swap of asset->asset just returns funds to the custodian (proven
        // by the balance staying put). Whitelist usdy + router and swap 1:1.
        MockSwapRouter goodRouter = new MockSwapRouter();
        vm.startPrank(admin);
        executor.setRouterWhitelist(address(goodRouter), true);
        executor.setTokenWhitelist(address(usdy), true);
        vm.stopPrank();

        vm.prank(agent);
        executor.deployToVenue(
            address(goodRouter), address(usdy), address(usdy), 80_000 ether, 80_000 ether
        );
        // Net asset position of the custodian is unchanged (asset->asset 1:1 to self);
        // crucially NOTHING reached the attacker or the agent.
        assertEq(usdy.balanceOf(address(executor)), 80_000 ether);
        assertEq(usdy.balanceOf(attacker), 0);
        assertEq(usdy.balanceOf(agent), 0);
    }

    /// @notice (c) The vault's custodian is the executor CONTRACT, never an EOA.
    function test_vault_custodian_is_executor_contract_not_eoa() public view {
        assertEq(vault.custodian(), address(executor));
        assertGt(address(executor).code.length, 0, "custodian must be a contract");
        // The hot agent key is an EOA and is explicitly NOT the custodian.
        assertTrue(vault.custodian() != agent);
        assertEq(agent.code.length, 0, "agent is an EOA");
    }

    // =====================================================================
    // (d) Governance handover: TimelockController holds DEFAULT_ADMIN_ROLE,
    //     deployer has renounced — mirrors Deploy.s.sol's _handoverToTimelock.
    // =====================================================================

    function test_timelock_handover_grants_admin_and_renounces_deployer() public {
        // Build the timelock exactly like the deploy script: gov multisig is the sole
        // proposer/executor; the timelock self-administers (admin = address(0)).
        address governanceMultisig = makeAddr("govSafe");
        address[] memory proposers = new address[](1);
        proposers[0] = governanceMultisig;
        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;
        TimelockController timelock =
            new TimelockController(2 days, proposers, executors, address(0));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        // `admin` is the current DEFAULT_ADMIN_ROLE holder in this test (the deploy
        // "deployer"). Grant the timelock admin on all four, then renounce admin's.
        vm.startPrank(admin);
        vault.grantRole(adminRole, address(timelock));
        decisionLog.grantRole(adminRole, address(timelock));
        identity.grantRole(adminRole, address(timelock));
        executor.grantRole(adminRole, address(timelock));

        // Granted BEFORE renounce (no contract is ever left admin-less).
        assertTrue(vault.hasRole(adminRole, address(timelock)));
        assertTrue(decisionLog.hasRole(adminRole, address(timelock)));
        assertTrue(identity.hasRole(adminRole, address(timelock)));
        assertTrue(executor.hasRole(adminRole, address(timelock)));

        vault.renounceRole(adminRole, admin);
        decisionLog.renounceRole(adminRole, admin);
        identity.renounceRole(adminRole, admin);
        executor.renounceRole(adminRole, admin);
        vm.stopPrank();

        // Deployer admin fully renounced on all four.
        assertFalse(vault.hasRole(adminRole, admin));
        assertFalse(decisionLog.hasRole(adminRole, admin));
        assertFalse(identity.hasRole(adminRole, admin));
        assertFalse(executor.hasRole(adminRole, admin));

        // Post-handover: only the timelock can administer. The deployer EOA can no longer
        // change the custody-critical whitelists.
        MockSwapRouter router = new MockSwapRouter();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole
            )
        );
        executor.setRouterWhitelist(address(router), true);
    }

    /// @notice (d) After handover the agent key remains the limited hot operational key:
    ///         it still cannot touch governance, confirming privilege separation persists.
    function test_after_handover_agent_still_cannot_touch_governance() public {
        address governanceMultisig = makeAddr("govSafe2");
        address[] memory proposers = new address[](1);
        proposers[0] = governanceMultisig;
        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;
        TimelockController timelock =
            new TimelockController(2 days, proposers, executors, address(0));

        bytes32 adminRole = executor.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        executor.grantRole(adminRole, address(timelock));
        executor.renounceRole(adminRole, admin);
        vm.stopPrank();

        // Agent still cannot set the agentId (governance-only).
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, agent, adminRole
            )
        );
        executor.setAgentId(999);

        // But the timelock CAN (sanity that governance authority actually moved).
        vm.prank(address(timelock));
        executor.setAgentId(999);
        assertEq(executor.agentId(), 999);
    }
}

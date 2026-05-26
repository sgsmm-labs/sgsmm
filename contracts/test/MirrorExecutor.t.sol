// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {AgentIdentityNFT} from "../src/AgentIdentityNFT.sol";
import {MirrorExecutor} from "../src/MirrorExecutor.sol";
import {MockUSDY} from "./mocks/MockUSDY.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MirrorExecutorTest is Test {
    SGSMMVault internal vault;
    DecisionLog internal decisionLog;
    AgentIdentityNFT internal identity;
    MirrorExecutor internal executor;
    MockUSDY internal usdy;

    address internal admin = address(0xA11CE);
    address internal agent = address(0xA6EE7);
    address internal alice = address(0xA1);
    address internal wallet1 = address(0xBEEF1);
    uint256 internal agentId;

    function setUp() public {
        usdy = new MockUSDY();
        vault = new SGSMMVault(IERC20(address(usdy)), admin);
        decisionLog = new DecisionLog(admin);
        identity = new AgentIdentityNFT(admin);

        // Mint agent identity NFT
        vm.prank(agent);
        agentId = identity.register("ipfs://agent-manifest");

        // Wire executor
        executor = new MirrorExecutor(vault, decisionLog, identity, agentId, admin, agent);

        // Grant roles
        bytes32 vaultExecRole = vault.EXECUTOR_ROLE();
        bytes32 logRole = decisionLog.LOGGER_ROLE();
        bytes32 metaRole = identity.METADATA_WRITER_ROLE();

        vm.startPrank(admin);
        vault.grantRole(vaultExecRole, address(executor));
        decisionLog.grantRole(logRole, address(executor));
        identity.grantRole(metaRole, address(executor));
        vm.stopPrank();

        // Seed Alice deposit
        usdy.mint(alice, 10_000_000 ether);
        vm.startPrank(alice);
        usdy.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, alice);
        vm.stopPrank();
    }

    function test_advance_cycle_advances_log() public {
        vm.prank(agent);
        uint64 c = executor.advanceCycle();
        assertEq(c, 1);
        assertEq(decisionLog.currentCycle(), 1);
    }

    function test_executeEnter_moves_funds_and_logs() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        assertEq(vault.deployedSleeve(), 80_000 ether);
        assertEq(usdy.balanceOf(agent), 80_000 ether);
        assertEq(vault.walletExposure(wallet1), 80_000 ether);
    }

    function test_executeExit_with_defund_returns_funds() public {
        vm.prank(agent);
        executor.advanceCycle();

        vm.prank(agent);
        executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        // Agent returns same amount (no PnL for test simplicity)
        vm.startPrank(agent);
        usdy.approve(address(executor), 80_000 ether);
        executor.executeExit(
            wallet1, 80_000 ether, 80_000 ether, DecisionLog.Action.Defund, int128(400_000), uint32(2)
        );
        vm.stopPrank();

        assertEq(vault.deployedSleeve(), 0);
        assertEq(vault.walletExposure(wallet1), 0);
    }

    function test_executeExit_with_enter_action_reverts() public {
        vm.prank(agent);
        executor.advanceCycle();
        vm.prank(agent);
        executor.executeEnter(wallet1, 80_000 ether, int128(1_800_000), uint32(800), uint32(1));

        vm.prank(agent);
        vm.expectRevert(MirrorExecutor.UnknownAction.selector);
        executor.executeExit(
            wallet1, 80_000 ether, 80_000 ether, DecisionLog.Action.Enter, int128(0), uint32(0)
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
        vm.prank(alice);
        vm.expectRevert();
        executor.executeEnter(wallet1, 1 ether, int128(0), uint32(0), uint32(0));
    }

    function test_updateAgentMetadata_writes_to_identity() public {
        bytes memory sortinoBytes = abi.encode(int256(1_500_000));
        vm.prank(agent);
        executor.updateAgentMetadata("sortino_score", sortinoBytes);
        assertEq(identity.getMetadata(agentId, "sortino_score"), sortinoBytes);
    }

    function test_updateAgentMetadata_without_role_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        executor.updateAgentMetadata("sortino_score", abi.encode(int256(0)));
    }
}

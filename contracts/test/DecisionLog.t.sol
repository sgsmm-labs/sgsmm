// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract DecisionLogTest is Test {
    DecisionLog internal decisionLog;
    address internal admin = address(0xA11CE);
    address internal logger = address(0xB0B);
    address internal rando = address(0xDEAD);

    function setUp() public {
        decisionLog = new DecisionLog(admin);
        bytes32 loggerRole = decisionLog.LOGGER_ROLE();
        vm.prank(admin);
        decisionLog.grantRole(loggerRole, logger);
    }

    function test_initial_cycle_is_zero() public view {
        assertEq(decisionLog.currentCycle(), 0);
    }

    function test_advance_cycle_increments_and_returns() public {
        vm.prank(logger);
        uint64 next = decisionLog.advanceCycle();
        assertEq(next, 1);
        assertEq(decisionLog.currentCycle(), 1);
    }

    function test_advance_cycle_reverts_without_role() public {
        vm.prank(rando);
        vm.expectRevert();
        decisionLog.advanceCycle();
    }

    function test_log_decision_emits_event() public {
        vm.prank(logger);
        decisionLog.advanceCycle();

        address wallet = address(0xCAFE);
        vm.prank(logger);
        vm.expectEmit(true, true, true, true);
        emit DecisionLog.Decision(
            1, // cycle
            wallet,
            DecisionLog.Action.Enter,
            int128(1_800_000), // 1.8 Sortino
            uint32(800), // 8.00% bps
            1_000_000 ether,
            uint32(1)
        );
        decisionLog.logDecision(
            wallet, DecisionLog.Action.Enter, int128(1_800_000), uint32(800), 1_000_000 ether, uint32(1)
        );
    }

    function test_log_decision_reverts_without_role() public {
        vm.prank(rando);
        vm.expectRevert();
        decisionLog.logDecision(address(0xCAFE), DecisionLog.Action.Enter, 0, 0, 0, 0);
    }

    function test_log_vault_frozen_emits_event() public {
        vm.prank(logger);
        decisionLog.advanceCycle();
        vm.prank(logger);
        vm.expectEmit(true, false, false, true);
        emit DecisionLog.VaultFrozen(1, 600, block.timestamp + 7 days);
        decisionLog.logVaultFrozen(600, block.timestamp + 7 days);
    }

    function test_admin_can_revoke_logger() public {
        bytes32 role = decisionLog.LOGGER_ROLE();
        assertTrue(decisionLog.hasRole(role, logger));
        vm.prank(admin);
        decisionLog.revokeRole(role, logger);
        assertFalse(decisionLog.hasRole(role, logger));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DecisionLog, IVaultNav} from "../src/DecisionLog.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Minimal NAV source so the unit test controls `totalAssets()` deterministically.
///      DecisionLog now reads navAfter from its bound vault instead of a caller arg, so
///      tests must supply a vault and assert the *vault-sourced* NAV in the event.
contract MockVaultNav is IVaultNav {
    uint256 public nav;

    function setNav(uint256 nav_) external {
        nav = nav_;
    }

    function totalAssets() external view override returns (uint256) {
        return nav;
    }
}

contract DecisionLogTest is Test {
    DecisionLog internal decisionLog;
    MockVaultNav internal navSource;

    address internal admin = address(0xA11CE);
    address internal logger = address(0xB0B);
    address internal rando = address(0xDEAD);

    function setUp() public {
        navSource = new MockVaultNav();
        navSource.setNav(1_000_000 ether);
        // DecisionLog signature changed: (admin, IVaultNav vault).
        decisionLog = new DecisionLog(admin, IVaultNav(address(navSource)));
        bytes32 loggerRole = decisionLog.LOGGER_ROLE();
        vm.prank(admin);
        decisionLog.grantRole(loggerRole, logger);
    }

    /// @notice The new constructor must reject a zero vault (NAV source is now mandatory).
    function test_constructor_reverts_on_zero_vault() public {
        vm.expectRevert(DecisionLog.ZeroVault.selector);
        new DecisionLog(admin, IVaultNav(address(0)));
    }

    /// @notice The bound vault is immutable and exposed for observers.
    function test_vault_is_bound() public view {
        assertEq(address(decisionLog.vault()), address(navSource));
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

    /// @notice logDecision no longer takes navAfter; the event must carry the NAV
    ///         the contract reads from the bound vault at emit time.
    function test_log_decision_emits_event_with_vault_sourced_nav() public {
        vm.prank(logger);
        decisionLog.advanceCycle();

        // Move NAV on the source AFTER the cycle advance to prove the event reflects
        // the live vault read, not a stale or caller-forged figure.
        navSource.setNav(1_234_567 ether);

        address wallet = address(0xCAFE);
        vm.prank(logger);
        vm.expectEmit(true, true, true, true);
        emit DecisionLog.Decision(
            1, // cycle
            wallet,
            DecisionLog.Action.Enter,
            int128(1_800_000), // 1.8 Sortino
            uint32(800), // 8.00% bps
            1_234_567 ether, // navAfter — sourced from the bound vault, not the caller
            uint32(1)
        );
        // New 5-arg signature: navAfter param removed.
        decisionLog.logDecision(
            wallet, DecisionLog.Action.Enter, int128(1_800_000), uint32(800), uint32(1)
        );
    }

    function test_log_decision_reverts_without_role() public {
        vm.prank(rando);
        vm.expectRevert();
        decisionLog.logDecision(address(0xCAFE), DecisionLog.Action.Enter, 0, 0, 0);
    }

    function test_log_vault_frozen_emits_event() public {
        vm.prank(logger);
        decisionLog.advanceCycle();
        vm.prank(logger);
        vm.expectEmit(true, false, false, true);
        emit DecisionLog.VaultFrozen(1, 600, block.timestamp + 7 days);
        decisionLog.logVaultFrozen(600, block.timestamp + 7 days);
    }

    function test_log_vault_unfrozen_emits_event() public {
        vm.prank(logger);
        decisionLog.advanceCycle();
        vm.prank(logger);
        vm.expectEmit(true, false, false, false);
        emit DecisionLog.VaultUnfrozen(1);
        decisionLog.logVaultUnfrozen();
    }

    function test_admin_can_revoke_logger() public {
        bytes32 role = decisionLog.LOGGER_ROLE();
        assertTrue(decisionLog.hasRole(role, logger));
        vm.prank(admin);
        decisionLog.revokeRole(role, logger);
        assertFalse(decisionLog.hasRole(role, logger));
    }
}

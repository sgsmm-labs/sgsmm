// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {MockUSDY} from "./mocks/MockUSDY.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SGSMMVaultTest is Test {
    SGSMMVault internal vault;
    MockUSDY internal usdy;

    address internal admin = address(0xA11CE);
    address internal executor = address(0xEEEE);
    address internal alice = address(0xA1);
    address internal wallet1 = address(0xBEEF1);
    address internal wallet2 = address(0xBEEF2);

    function setUp() public {
        usdy = new MockUSDY();
        vault = new SGSMMVault(IERC20(address(usdy)), admin);
        bytes32 execRole = vault.EXECUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(execRole, executor);

        // Seed Alice with 10M USDY and deposit 1M into vault
        usdy.mint(alice, 10_000_000 ether);
        vm.startPrank(alice);
        usdy.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, alice);
        vm.stopPrank();
    }

    function test_initial_nav_after_deposit() public view {
        assertEq(vault.totalAssets(), 1_000_000 ether);
        assertEq(vault.deployedSleeve(), 0);
    }

    function test_enter_mirror_within_per_position_cap_succeeds() public {
        // 8% of 1M = 80_000 — exactly at per-position cap, should pass
        vm.prank(executor);
        vault.enterMirror(wallet1, 80_000 ether, executor);

        assertEq(vault.deployedSleeve(), 80_000 ether);
        assertEq(vault.walletExposure(wallet1), 80_000 ether);
        assertEq(vault.walletPositionCount(wallet1), 1);
        assertEq(usdy.balanceOf(address(vault)), 920_000 ether);
        assertEq(usdy.balanceOf(executor), 80_000 ether);
    }

    function test_enter_mirror_exceeds_per_position_cap_reverts() public {
        // 8.01% of 1M = 80_100 → over per-position cap
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                SGSMMVault.SizingCapExceeded.selector, 801, 800, "per_position"
            )
        );
        vault.enterMirror(wallet1, 80_100 ether, executor);
    }

    function test_enter_mirror_exceeds_per_wallet_cap_reverts() public {
        // Two entries on same wallet: 8% + 5% = 13% > per_wallet 12%
        vm.prank(executor);
        vault.enterMirror(wallet1, 80_000 ether, executor);

        vm.prank(executor);
        vm.expectRevert();
        vault.enterMirror(wallet1, 50_000 ether, executor);
    }

    function test_enter_mirror_respects_sleeve_total_cap() public {
        // Fill 40% across multiple wallets — 5 wallets x 8% = 40%, should pass
        for (uint160 i = 0; i < 5; i++) {
            address w = address(uint160(0xCAFE0) + i);
            vm.prank(executor);
            vault.enterMirror(w, 80_000 ether, executor);
        }
        assertEq(vault.deployedSleeve(), 400_000 ether);

        // 6th wallet of 80K (8% of NAV) would push sleeve to 48% > 40% cap
        vm.prank(executor);
        vm.expectRevert();
        vault.enterMirror(address(0xCAFEF), 80_000 ether, executor);
    }

    function test_exit_mirror_with_profit_increases_nav() public {
        // Enter at 80k
        vm.prank(executor);
        vault.enterMirror(wallet1, 80_000 ether, executor);

        // Simulate trade: executor receives extra capital from offchain trade
        usdy.mint(executor, 5_000 ether);
        vm.startPrank(executor);
        usdy.approve(address(vault), type(uint256).max);
        vault.exitMirror(wallet1, 80_000 ether, 85_000 ether);
        vm.stopPrank();

        assertEq(vault.deployedSleeve(), 0);
        assertEq(vault.walletExposure(wallet1), 0);
        assertEq(vault.walletPositionCount(wallet1), 0);
        // NAV grew by 5K (1M - 80K + 85K = 1.005M)
        assertEq(vault.totalAssets(), 1_005_000 ether);
    }

    function test_exit_mirror_with_loss_decreases_nav() public {
        vm.prank(executor);
        vault.enterMirror(wallet1, 80_000 ether, executor);

        // Loss: only 70k of original 80k returned
        vm.startPrank(executor);
        usdy.approve(address(vault), type(uint256).max);
        vault.exitMirror(wallet1, 80_000 ether, 70_000 ether);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 990_000 ether);
    }

    function test_enter_mirror_without_executor_role_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.enterMirror(wallet1, 1 ether, alice);
    }

    function test_pause_blocks_new_entries() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(executor);
        vm.expectRevert();
        vault.enterMirror(wallet1, 1 ether, executor);
    }

    function test_pause_does_not_block_exits() public {
        vm.prank(executor);
        vault.enterMirror(wallet1, 50_000 ether, executor);

        vm.prank(admin);
        vault.pause();

        vm.startPrank(executor);
        usdy.approve(address(vault), type(uint256).max);
        vault.exitMirror(wallet1, 50_000 ether, 50_000 ether);
        vm.stopPrank();

        assertEq(vault.deployedSleeve(), 0);
    }

    function test_erc4626_deposit_redeem_roundtrip() public {
        // Bob deposits, then redeems — should get same shares ratio
        address bob = address(0xB1);
        usdy.mint(bob, 1_000_000 ether);
        vm.startPrank(bob);
        usdy.approve(address(vault), type(uint256).max);
        uint256 sharesOut = vault.deposit(500_000 ether, bob);
        assertGt(sharesOut, 0);
        uint256 assetsBack = vault.redeem(sharesOut, bob, bob);
        vm.stopPrank();
        assertApproxEqAbs(assetsBack, 500_000 ether, 1);
    }
}

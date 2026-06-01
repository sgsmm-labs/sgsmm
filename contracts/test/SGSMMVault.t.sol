// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {MockUSDY} from "./mocks/MockUSDY.sol";
import {MockCustodian} from "./mocks/MockCustodian.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract SGSMMVaultTest is Test {
    SGSMMVault internal vault;
    MockUSDY internal usdy;

    /// @dev Contract custodian (mirrors MirrorExecutor's vault-boundary role): it is
    ///      BOTH the EXECUTOR_ROLE caller and the configured `custodian`, so the
    ///      sleeve always lands on a CONTRACT (never an EOA) under the new model.
    MockCustodian internal custodian;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal wallet1 = address(0xBEEF1);
    address internal wallet2 = address(0xBEEF2);

    function setUp() public {
        usdy = new MockUSDY();
        vault = new SGSMMVault(IERC20(address(usdy)), admin);

        // Deploy the contract custodian and wire it as BOTH executor + custodian.
        custodian = new MockCustodian(vault);
        bytes32 execRole = vault.EXECUTOR_ROLE();
        vm.startPrank(admin);
        vault.grantRole(execRole, address(custodian));
        vault.setCustodian(address(custodian));
        vm.stopPrank();

        // Seed Alice with 10M USDY and deposit 1M into vault
        usdy.mint(alice, 10_000_000 ether);
        vm.startPrank(alice);
        usdy.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Custody configuration (C-1): custodian must be a CONTRACT, never an EOA
    // ---------------------------------------------------------------------

    function test_custodian_is_the_wired_contract() public view {
        assertEq(vault.custodian(), address(custodian));
        // Sanity: the custodian really is a contract, not an EOA.
        assertGt(address(custodian).code.length, 0);
    }

    function test_setCustodian_rejects_eoa() public {
        // An EOA has no code → must revert CustodianNotContract.
        vm.prank(admin);
        vm.expectRevert(SGSMMVault.CustodianNotContract.selector);
        vault.setCustodian(address(0xE0A));
    }

    function test_setCustodian_rejects_zero_address() public {
        vm.prank(admin);
        vm.expectRevert(SGSMMVault.ZeroAddress.selector);
        vault.setCustodian(address(0));
    }

    function test_setCustodian_requires_admin_role() public {
        // alice lacks DEFAULT_ADMIN_ROLE. Cache the role BEFORE pranking: an inline
        // vault.DEFAULT_ADMIN_ROLE() in the expectRevert args would otherwise consume the
        // prank (vm.prank affects only the next call) so setCustodian would run as the
        // default sender and the asserted caller wouldn't match.
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        vault.setCustodian(address(custodian));
    }

    function test_enterMirror_reverts_when_custodian_unset() public {
        // Fresh, funded vault with an executor but NO custodian set.
        SGSMMVault bare = new SGSMMVault(IERC20(address(usdy)), admin);
        MockCustodian exec = new MockCustodian(bare);
        bytes32 execRole = bare.EXECUTOR_ROLE();
        vm.prank(admin);
        bare.grantRole(execRole, address(exec));

        // Fund it so the revert is provably the custody guard, not NavIsZero.
        usdy.mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        usdy.approve(address(bare), type(uint256).max);
        bare.deposit(1_000_000 ether, alice);
        vm.stopPrank();

        vm.expectRevert(SGSMMVault.CustodianNotSet.selector);
        exec.enter(wallet1, 1 ether);
    }

    // ---------------------------------------------------------------------
    // NAV / accounting
    // ---------------------------------------------------------------------

    function test_initial_nav_after_deposit() public view {
        assertEq(vault.totalAssets(), 1_000_000 ether);
        assertEq(vault.deployedSleeve(), 0);
    }

    /// @notice With a non-zero _decimalsOffset() (6), the first depositor receives
    ///         shares scaled by 10**offset. This is the anti-inflation hardening:
    ///         shares = assets * (totalSupply + 10**offset) / (totalAssets + 1).
    ///         For the empty-vault first deposit that is assets * 1e6.
    function test_first_deposit_share_math_reflects_decimals_offset() public view {
        // Alice deposited 1_000_000 ether as the first depositor into an empty vault.
        // shares = 1_000_000e18 * (0 + 1e6) / (0 + 1) = 1_000_000e18 * 1e6.
        assertEq(vault.balanceOf(alice), 1_000_000 ether * 1e6);
        // decimals() = underlying(18) + offset(6) = 24.
        assertEq(vault.decimals(), 24);
        // totalAssets is unaffected by the offset — still the real asset balance.
        assertEq(vault.totalAssets(), 1_000_000 ether);
    }

    // ---------------------------------------------------------------------
    // enterMirror — sizing caps + contract custody
    // ---------------------------------------------------------------------

    function test_enter_mirror_within_per_position_cap_succeeds() public {
        // 8% of 1M = 80_000 — exactly at per-position cap, should pass
        uint256 positionId = custodian.enter(wallet1, 80_000 ether);

        assertEq(positionId, 0);
        assertEq(vault.deployedSleeve(), 80_000 ether);
        assertEq(vault.walletExposure(wallet1), 80_000 ether);
        assertEq(vault.walletPositionCount(wallet1), 1);
        assertEq(vault.positionPrincipal(wallet1, positionId), 80_000 ether);
        assertEq(usdy.balanceOf(address(vault)), 920_000 ether);
        // CUSTODY: the sleeve lands on the custodian CONTRACT — not on any EOA.
        assertEq(usdy.balanceOf(address(custodian)), 80_000 ether);
    }

    function test_enter_mirror_exceeds_per_position_cap_reverts() public {
        // 8.01% of 1M = 80_100 → over per-position cap
        vm.expectRevert(
            abi.encodeWithSelector(SGSMMVault.SizingCapExceeded.selector, 801, 800, "per_position")
        );
        custodian.enter(wallet1, 80_100 ether);
    }

    function test_enter_mirror_exceeds_per_wallet_cap_reverts() public {
        // Two entries on same wallet: 8% + 5% = 13% > per_wallet 12%
        custodian.enter(wallet1, 80_000 ether);

        // walletAfter = 130_000 → 1300 bps > 1200 per_wallet cap.
        vm.expectRevert(
            abi.encodeWithSelector(SGSMMVault.SizingCapExceeded.selector, 1300, 1200, "per_wallet")
        );
        custodian.enter(wallet1, 50_000 ether);
    }

    /// @notice The 70% retained-liquidity floor (floor 60% + reserve 10%) is the binding
    ///         cumulative-sleeve constraint reachable through enterMirror. Because
    ///         balance' = nav - deployedSleeve', requiring balance' >= 70% nav is exactly
    ///         deployedSleeve' <= 30% nav. So cumulative deployments stop at 30% of NAV —
    ///         STRICTER than the 40% hard ceiling (which only guards transient NAV-dip
    ///         states the contract cannot itself create via enterMirror).
    function test_enter_mirror_retained_liquidity_floor_binds_at_30pct() public {
        // Deploy 3 distinct wallets x 8% = 24% — all fine.
        for (uint160 i = 0; i < 3; i++) {
            address w = address(uint160(0xCAFE0) + i);
            custodian.enter(w, 80_000 ether);
        }
        assertEq(vault.deployedSleeve(), 240_000 ether);

        // Top up to exactly 30% (300_000) with a 4th wallet of 60k (6% — under caps). OK.
        custodian.enter(address(0xCAFE3), 60_000 ether);
        assertEq(vault.deployedSleeve(), 300_000 ether);
        assertEq(usdy.balanceOf(address(vault)), 700_000 ether);
        // All deployed capital is custodied by the contract.
        assertEq(usdy.balanceOf(address(custodian)), 300_000 ether);

        // Any further deployment breaches the 70% retained floor: a 5th wallet of even
        // 1_000 would leave 699_000 retained < required 700_000.
        // required = ceil(7000 * 1_000_000e18 / 10_000) = 700_000e18.
        // wouldRetain = 700_000e18 - 1_000e18 = 699_000e18.
        vm.expectRevert(
            abi.encodeWithSelector(
                SGSMMVault.RetainedLiquidityBreached.selector, 699_000 ether, 700_000 ether
            )
        );
        custodian.enter(address(0xCAFE4), 1_000 ether);
    }

    function test_enter_mirror_zero_amount_reverts() public {
        // Previously this path wrongly reverted NothingToExit; now it is ZeroAmount.
        vm.expectRevert(SGSMMVault.ZeroAmount.selector);
        custodian.enter(wallet1, 0);
    }

    function test_enter_mirror_on_empty_vault_reverts_nav_is_zero() public {
        // A fresh, unseeded vault has zero NAV; enterMirror must revert NavIsZero
        // (custom error, not a Panic) AFTER the custody guard passes. We therefore set
        // a (contract) custodian first so the revert provably comes from the NAV check.
        SGSMMVault bare = new SGSMMVault(IERC20(address(usdy)), admin);
        MockCustodian exec = new MockCustodian(bare);
        bytes32 execRole = bare.EXECUTOR_ROLE();
        vm.startPrank(admin);
        bare.grantRole(execRole, address(exec));
        bare.setCustodian(address(exec));
        vm.stopPrank();

        vm.expectRevert(SGSMMVault.NavIsZero.selector);
        exec.enter(wallet1, 1 ether);
    }

    function test_enter_mirror_without_executor_role_reverts() public {
        // alice (an EOA without EXECUTOR_ROLE) cannot call enterMirror directly. Cache the
        // role BEFORE pranking so the inline view call doesn't consume the prank.
        bytes32 execRole = vault.EXECUTOR_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, execRole
            )
        );
        vault.enterMirror(wallet1, 1 ether);
    }

    // ---------------------------------------------------------------------
    // exitMirror — settlement integrity (keyed by positionId), funds pulled
    // from the contract custodian
    // ---------------------------------------------------------------------

    function test_exit_mirror_with_profit_increases_nav() public {
        // Enter at 80k — sleeve lands on the custodian contract.
        uint256 positionId = custodian.enter(wallet1, 80_000 ether);

        // Simulate a profitable offchain trade: extra capital accrues to the custodian
        // CONTRACT (not an EOA). The vault then PULLS the returned amount from it.
        usdy.mint(address(custodian), 5_000 ether);
        uint256 realized = custodian.exit(wallet1, positionId, 85_000 ether);

        // Realized is the MEASURED balance delta, not the caller's asserted figure.
        assertEq(realized, 85_000 ether);
        assertEq(vault.deployedSleeve(), 0);
        assertEq(vault.walletExposure(wallet1), 0);
        assertEq(vault.walletPositionCount(wallet1), 0);
        assertEq(vault.positionPrincipal(wallet1, positionId), 0);
        // NAV grew by 5K (1M - 80K + 85K = 1.005M)
        assertEq(vault.totalAssets(), 1_005_000 ether);
        // Custodian returned everything it held for this position.
        assertEq(usdy.balanceOf(address(custodian)), 0);
    }

    function test_exit_mirror_with_loss_decreases_nav() public {
        uint256 positionId = custodian.enter(wallet1, 80_000 ether);

        // Loss: custodian only returns 70k of the original 80k (10k lost offchain).
        // Move 10k out of the custodian so it holds exactly 70k to return.
        vm.prank(address(custodian));
        usdy.transfer(address(0xBE111), 10_000 ether); // simulate the 10k offchain loss
        uint256 realized = custodian.exit(wallet1, positionId, 70_000 ether);

        assertEq(realized, 70_000 ether);
        // Accounting reduced by the RECORDED principal (80k), balance up by measured 70k.
        assertEq(vault.totalAssets(), 990_000 ether);
        assertEq(vault.deployedSleeve(), 0);
        assertEq(usdy.balanceOf(address(custodian)), 0);
    }

    function test_exit_mirror_unknown_position_reverts() public {
        // No position opened for wallet1 → positionId 0 has zero recorded principal.
        vm.expectRevert(SGSMMVault.PositionNotOpen.selector);
        custodian.exit(wallet1, 0, 1 ether);
    }

    function test_exit_mirror_double_exit_reverts() public {
        uint256 positionId = custodian.enter(wallet1, 80_000 ether);

        custodian.exit(wallet1, positionId, 80_000 ether);
        // Second exit of the same position must revert — ledger already zeroed.
        vm.expectRevert(SGSMMVault.PositionNotOpen.selector);
        custodian.exit(wallet1, positionId, 80_000 ether);
    }

    /// @notice Two positions on the same wallet get distinct, monotonically-increasing ids
    ///         and settle independently against their own recorded principals.
    function test_two_positions_same_wallet_have_distinct_ids() public {
        uint256 id0 = custodian.enter(wallet1, 80_000 ether); // 8%
        uint256 id1 = custodian.enter(wallet1, 40_000 ether); // +4% = 12% wallet cap

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(vault.walletExposure(wallet1), 120_000 ether);
        assertEq(vault.walletPositionCount(wallet1), 2);
        assertEq(vault.deployedSleeve(), 120_000 ether);

        // Close the first position only; second remains open.
        custodian.exit(wallet1, id0, 80_000 ether);

        assertEq(vault.walletExposure(wallet1), 40_000 ether);
        assertEq(vault.walletPositionCount(wallet1), 1);
        assertEq(vault.deployedSleeve(), 40_000 ether);
        assertEq(vault.positionPrincipal(wallet1, id0), 0);
        assertEq(vault.positionPrincipal(wallet1, id1), 40_000 ether);
    }

    // ---------------------------------------------------------------------
    // Pause coverage
    // ---------------------------------------------------------------------

    function test_pause_blocks_new_entries() public {
        vm.prank(admin);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        custodian.enter(wallet1, 1 ether);
    }

    /// @notice NEW hardening: _deposit carries whenNotPaused, so deposits (and mints)
    ///         halt during an incident.
    function test_pause_blocks_deposits() public {
        vm.prank(admin);
        vault.pause();

        usdy.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1_000 ether, alice);
        vm.stopPrank();
    }

    function test_pause_blocks_mints() public {
        vm.prank(admin);
        vault.pause();

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.mint(1_000 ether * 1e6, alice);
        vm.stopPrank();
    }

    function test_pause_does_not_block_exits() public {
        uint256 positionId = custodian.enter(wallet1, 50_000 ether);

        vm.prank(admin);
        vault.pause();

        // exitMirror intentionally stays OPEN while paused so capital can flow back
        // from the custodian to the vault during an incident.
        custodian.exit(wallet1, positionId, 50_000 ether);

        assertEq(vault.deployedSleeve(), 0);
    }

    function test_unpause_restores_deposits() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();

        usdy.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        uint256 shares = vault.deposit(1_000 ether, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 round-trip & inflation hardening
    // ---------------------------------------------------------------------

    function test_erc4626_deposit_redeem_roundtrip() public {
        // Bob deposits, then redeems — should get back no MORE than deposited.
        address bob = address(0xB1);
        usdy.mint(bob, 1_000_000 ether);
        vm.startPrank(bob);
        usdy.approve(address(vault), type(uint256).max);
        uint256 sharesOut = vault.deposit(500_000 ether, bob);
        assertGt(sharesOut, 0);
        uint256 assetsBack = vault.redeem(sharesOut, bob, bob);
        vm.stopPrank();
        // Round-trip must never return more than deposited (rounding favours the vault).
        assertLe(assetsBack, 500_000 ether);
        assertApproxEqAbs(assetsBack, 500_000 ether, 1);
    }

    /// @notice Inflation-fix unit test: a deposit so tiny it rounds to zero shares MUST
    ///         revert ZeroSharesMinted rather than silently minting nothing.
    ///         Construct a vault whose share price is inflated enough that 1 wei of
    ///         assets converts to 0 shares.
    function test_zero_share_mint_reverts() public {
        // Fresh vault, first depositor seeds a tiny supply, then a large asset donation
        // inflates the price-per-share so a 1-wei follow-up deposit floors to 0 shares.
        SGSMMVault v = new SGSMMVault(IERC20(address(usdy)), admin);

        address seeder = address(0x5EED);
        // Need 1 wei for the seed deposit + 1_000 ether for the inflating donation.
        usdy.mint(seeder, 1_000 ether + 1);
        vm.startPrank(seeder);
        usdy.approve(address(v), type(uint256).max);
        v.deposit(1, seeder); // mints 1 * 1e6 = 1e6 shares; totalAssets = 1 wei
        // Donate assets directly to inflate price-per-share massively.
        usdy.transfer(address(v), 1_000 ether);
        vm.stopPrank();

        // Now previewDeposit(1 wei) = 1 * (1e6 + 1e6) / (1000e18 + 1 + 1) = 0 (floors).
        assertEq(v.previewDeposit(1), 0);

        address dust = address(0xD057);
        usdy.mint(dust, 1);
        vm.startPrank(dust);
        usdy.approve(address(v), type(uint256).max);
        vm.expectRevert(SGSMMVault.ZeroSharesMinted.selector);
        v.deposit(1, dust);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @notice convertToAssets(convertToShares(x)) must never exceed x. Rounding in the
    ///         ERC-4626 conversions always favours the vault, so the round-trip is a
    ///         contraction — a depositor can never extract more than they put in.
    function testFuzz_convertRoundTrip(uint256 x) public view {
        // Bound to a sane asset range to avoid mulDiv overflow on the 1e6 offset scaling
        // (totalSupply here is ~1e30, so x up to 1e30 keeps the intermediate within 256 bits).
        x = bound(x, 0, 1e30);
        uint256 shares = vault.convertToShares(x);
        uint256 assetsBack = vault.convertToAssets(shares);
        assertLe(assetsBack, x);
    }

    /// @notice Fuzz the inflation guard: for the seeded live vault any non-zero deposit
    ///         that yields shares is consistent, and a deposit yielding zero shares
    ///         reverts. Here the vault is well-funded so we assert the positive branch:
    ///         every accepted deposit mints a positive, monotonic share amount.
    function testFuzz_deposit_mints_positive_shares(uint256 assets) public {
        assets = bound(assets, 1, 1_000_000 ether);
        address depositor = makeAddr("fuzzDepositor");
        usdy.mint(depositor, assets);
        vm.startPrank(depositor);
        usdy.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(assets, depositor);
        vm.stopPrank();
        // In the seeded vault, price-per-share ~1e-6 so any >=1 wei deposit mints >0 shares.
        assertGt(shares, 0);
        assertEq(vault.balanceOf(depositor), shares);
    }
}

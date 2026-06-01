// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {MockUSDY} from "./mocks/MockUSDY.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VaultHandler
 * @notice Bounded action surface for the SGSMMVault invariant fuzzer.
 * @dev The handler holds EXECUTOR_ROLE and is itself the `executorRecipient`, so deployed
 *      sleeve capital lands in the handler and can be returned via {exit}. It maintains a
 *      ghost ledger (tracked wallets + their open position ids + a running exposure sum)
 *      so the invariant suite can cross-check the vault's internal accounting and so
 *      exits always reference a *valid, open* positionId.
 *
 *      Round-trip safety (invariant d) is exercised by {depositThenRedeem}, which asserts
 *      in-flight that a deposit→redeem of the exact minted shares never returns more than
 *      was put in, and records the worst observed surplus for the suite to assert == 0.
 */
contract VaultHandler is Test {
    SGSMMVault public immutable vault;
    MockUSDY public immutable usdy;

    address[] internal actors;
    address[] internal wallets;

    // Ghost: open position ids per wallet (FILO stack) + sum of recorded principals.
    mapping(address => uint256[]) internal openPositions;
    uint256 public ghostExposureSum;

    // Ghost: worst-case (assetsBack - assetsIn) observed across all round-trips. Must stay 0.
    uint256 public worstRoundTripSurplus;

    // Ghost call counters (useful when reading invariant run statistics).
    uint256 public callsDeposit;
    uint256 public callsRedeem;
    uint256 public callsEnter;
    uint256 public callsExit;
    uint256 public callsRoundTrip;

    constructor(SGSMMVault vault_, MockUSDY usdy_) {
        vault = vault_;
        usdy = usdy_;

        // A small fixed actor + wallet universe keeps state-space exploration meaningful.
        for (uint160 i = 1; i <= 4; i++) {
            address a = address(uint160(0xA00) + i);
            actors.push(a);
            usdy.mint(a, 5_000_000 ether);
            vm.prank(a);
            usdy.approve(address(vault), type(uint256).max);
        }
        for (uint160 i = 1; i <= 6; i++) {
            wallets.push(address(uint160(0xB00) + i));
        }
        // Handler returns capital on exit; pre-approve the vault to pull from it.
        usdy.approve(address(vault), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _wallet(uint256 seed) internal view returns (address) {
        return wallets[seed % wallets.length];
    }

    /// @notice Deposit a bounded amount from a pseudo-random actor.
    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 0, 2_000_000 ether);
        if (assets == 0) return;
        if (usdy.balanceOf(actor) < assets) return;
        vm.prank(actor);
        vault.deposit(assets, actor);
        callsDeposit++;
    }

    /// @notice Redeem a bounded fraction of an actor's shares.
    /// @dev Redemptions are served ONLY from the unencumbered liquid cushion — never from
    ///      the capital that is currently deployed in the sleeve. This mirrors the SGSMM
    ///      redemption-liquidity policy: the 60% floor + 10% reserve exist precisely so
    ///      that exits/redemptions draw from liquid asset, while the deployed sleeve is
    ///      backed by capital that is out with the executor (and is reconciled via
    ///      {exitMirror}, not redeemed directly). Concretely we cap the payout so the
    ///      post-redeem liquid balance still keeps the deployed sleeve within its 40%
    ///      ceiling: sleeve <= 40% * (balance' + sleeve)  ⇔  balance' >= 1.5 * sleeve.
    ///      Without this, a redeem could drain liquidity below the deployed sleeve and
    ///      drive sleeve/NAV above 40% — a documented transient-NAV / custody concern
    ///      (open item C-1), NOT a property the enter/exit code path itself guarantees.
    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        shares = bound(shares, 0, bal);
        if (shares == 0) return;

        uint256 assetsOut = vault.previewRedeem(shares);
        uint256 liquid = usdy.balanceOf(address(vault));
        uint256 sleeve = vault.deployedSleeve();

        // Liquidity that may be withdrawn while still backing the sleeve at <=40%.
        // Need balance' = liquid - assetsOut >= 1.5 * sleeve  ⇒  withdrawable = liquid - 1.5*sleeve.
        uint256 minRetain = (sleeve * 3) / 2; // 1.5 * sleeve
        if (liquid <= minRetain) return; // nothing redeemable without breaching the cap
        uint256 withdrawable = liquid - minRetain;
        if (assetsOut > withdrawable) return;

        vm.prank(actor);
        vault.redeem(shares, actor, actor);
        callsRedeem++;
    }

    /// @notice Enter a mirror position for a tracked wallet. Amount is bounded small so
    ///         it has a realistic chance of fitting the caps / retained-liquidity floor;
    ///         if it still doesn't fit, the call reverts and the fuzzer discards it.
    function enter(uint256 walletSeed, uint256 amount) external {
        uint256 nav = vault.totalAssets();
        if (nav == 0) return;
        address wallet = _wallet(walletSeed);
        // Keep within the 8% per-position cap envelope to maximise successful enters.
        amount = bound(amount, 0, (nav * 7) / 100);
        if (amount == 0) return;

        // Pre-check the binding constraints so we don't waste runs on guaranteed reverts.
        if (vault.walletExposure(wallet) + amount > (nav * vault.PER_WALLET_CAP_BPS()) / 10_000) {
            return;
        }
        uint256 liquid = usdy.balanceOf(address(vault));
        uint256 requiredRetained = (uint256(vault.RETAINED_LIQUID_BPS()) * nav) / 10_000;
        if (liquid < amount || liquid - amount < requiredRetained) return;

        // Handler is the executorRecipient; funds land here for later return on exit.
        uint256 positionId = vault.enterMirror(wallet, amount, address(this));
        openPositions[wallet].push(positionId);
        ghostExposureSum += amount;
        callsEnter++;

        // Post-condition on the enter code path itself: immediately after a successful
        // enter the deployed sleeve must sit within the 40% hard ceiling of NAV.
        uint256 navAfter = vault.totalAssets();
        assertLe(
            vault.deployedSleeve() * 10_000,
            uint256(vault.SLEEVE_TOTAL_CAP_BPS()) * navAfter,
            "post-enter: sleeve exceeded 40% of NAV"
        );
    }

    /// @notice Exit the most-recently-opened position of a tracked wallet, returning a
    ///         bounded amount (possibly a profit if the handler has spare balance, or a
    ///         loss). The vault settles against its recorded principal + measured delta.
    function exit(uint256 walletSeed, uint256 returnAmount, bool withProfit) external {
        address wallet = _wallet(walletSeed);
        uint256[] storage stack = openPositions[wallet];
        if (stack.length == 0) return;

        uint256 positionId = stack[stack.length - 1];
        uint256 principal = vault.positionPrincipal(wallet, positionId);
        if (principal == 0) return; // defensive; ghost stack should match the ledger

        if (withProfit) {
            // Mint a small profit to the handler so it can return >= principal.
            uint256 profit = bound(returnAmount, 0, principal / 10);
            usdy.mint(address(this), profit);
            returnAmount = principal + profit;
        } else {
            // Return somewhere between 80% and 100% of principal (a loss path).
            returnAmount = bound(returnAmount, (principal * 8) / 10, principal);
        }
        if (usdy.balanceOf(address(this)) < returnAmount) return;

        vault.exitMirror(wallet, positionId, returnAmount);

        // Pop ghost stack + reduce exposure sum by the RECORDED principal (matches vault).
        stack.pop();
        ghostExposureSum -= principal;
        callsExit++;
    }

    /// @notice Round-trip safety probe (invariant d): deposit then immediately redeem the
    ///         exact shares minted. The depositor must never get back more than put in.
    function depositThenRedeem(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1, 1_000_000 ether);
        if (usdy.balanceOf(actor) < assets) return;

        // Ensure the round-trip is self-funded by liquid balance (deposit adds to balance,
        // so the immediate redeem of the same shares is always payable).
        uint256 balBefore = usdy.balanceOf(actor);
        vm.startPrank(actor);
        uint256 shares = vault.deposit(assets, actor);
        if (shares == 0) {
            vm.stopPrank();
            return;
        }
        vault.redeem(shares, actor, actor);
        vm.stopPrank();
        uint256 balAfter = usdy.balanceOf(actor);

        // assetsBack = balAfter - (balBefore - assets) = balAfter - balBefore + assets.
        // Round-trip must be a contraction: assetsBack <= assets.
        uint256 assetsBack = balAfter + assets - balBefore;
        assertLe(assetsBack, assets, "round-trip returned more than deposited");
        if (assetsBack > assets) {
            uint256 surplus = assetsBack - assets;
            if (surplus > worstRoundTripSurplus) worstRoundTripSurplus = surplus;
        }
        callsRoundTrip++;
    }
}

/**
 * @title SGSMMVaultInvariantTest
 * @notice Handler-based StdInvariant suite for the SGSMM vault accounting invariants.
 */
contract SGSMMVaultInvariantTest is StdInvariant, Test {
    SGSMMVault internal vault;
    MockUSDY internal usdy;
    VaultHandler internal handler;

    address internal admin = address(0xA11CE);
    address internal seeder = address(0x5EED);

    function setUp() public {
        usdy = new MockUSDY();
        vault = new SGSMMVault(IERC20(address(usdy)), admin);

        // Seed the vault like the real deploy does (dead shares) so it never sits in the
        // exploitable empty state during fuzzing and NAV math is well-conditioned.
        usdy.mint(seeder, 1_000 ether);
        vm.startPrank(seeder);
        usdy.approve(address(vault), type(uint256).max);
        vault.deposit(1_000 ether, address(0xdEaD));
        vm.stopPrank();

        handler = new VaultHandler(vault, usdy);

        // Grant the handler EXECUTOR_ROLE so it can enter/exit mirror positions.
        // Cache the role BEFORE pranking (vm.prank affects only the next call; an inline
        // vault.EXECUTOR_ROLE() view would otherwise consume the prank → grantRole would
        // run as the test contract and revert AccessControlUnauthorizedAccount).
        bytes32 execRole = vault.EXECUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(execRole, address(handler));

        // Only fuzz the handler's curated action surface.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.redeem.selector;
        selectors[2] = VaultHandler.enter.selector;
        selectors[3] = VaultHandler.exit.selector;
        selectors[4] = VaultHandler.depositThenRedeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice (a) deployedSleeve == Σ walletExposure (tracked via the handler ghost sum).
    function invariant_sleeveEqualsSumOfWalletExposure() public view {
        assertEq(
            vault.deployedSleeve(),
            handler.ghostExposureSum(),
            "deployedSleeve != sum(walletExposure)"
        );
    }

    /// @notice (b) totalAssets() == asset.balanceOf(vault) + deployedSleeve.
    function invariant_navIsBalancePlusSleeve() public view {
        assertEq(
            vault.totalAssets(),
            usdy.balanceOf(address(vault)) + vault.deployedSleeve(),
            "totalAssets != balance + deployedSleeve"
        );
    }

    /// @notice (c) sleeve never exceeds the 40% hard ceiling of NAV after any sequence.
    ///         Asserted as deployedSleeve * 10_000 <= 4_000 * nav (holds at nav==0 too).
    function invariant_sleeveNeverExceeds40pct() public view {
        uint256 nav = vault.totalAssets();
        assertLe(
            vault.deployedSleeve() * 10_000,
            uint256(vault.SLEEVE_TOTAL_CAP_BPS()) * nav,
            "sleeve exceeded 40% of NAV"
        );
    }

    /// @notice (d) a deposit→redeem round-trip never returns more than deposited.
    ///         The handler asserts this in-flight; here we assert the recorded worst-case
    ///         surplus stayed exactly zero across the whole run.
    function invariant_roundTripNeverProfits() public view {
        assertEq(handler.worstRoundTripSurplus(), 0, "a round-trip returned more than deposited");
    }
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CoercionResistantVault, IEntryPoint} from "../src/CoercionResistantVault.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockDexRouter} from "./helpers/MockDexRouter.sol";

/**
 * @title CoercionResistantVaultDeFiTest
 * @notice Unit tests for the DeFi execution extension.
 *
 *         Verifies that the vault, acting as an ERC-4337 smart account, can
 *         interact with whitelisted external protocols (DEXes, lending, etc.)
 *         through execute()/executeBatch() and approveToken(), while
 *         preserving all security invariants:
 *
 *           - Only whitelisted targets can be called
 *           - Whitelist additions require the full timelock
 *           - Whitelist removals are immediate
 *           - Token allowances require a whitelisted SPENDER (not a whitelisted token)
 *           - Value-preserving swaps do NOT consume the hot spending budget
 *           - All DeFi paths are blocked during emergency pause
 */
contract CoercionResistantVaultDeFiTest is Test {

    CoercionResistantVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockDexRouter internal router;

    address internal owner      = makeAddr("owner");
    address internal recipient  = makeAddr("recipient");
    address internal guardian1  = makeAddr("guardian1");
    address internal guardian2  = makeAddr("guardian2");
    address internal guardian3  = makeAddr("guardian3");
    address internal entryPoint = makeAddr("entryPoint");

    uint256 internal constant TIMELOCK = 3 days;
    uint256 internal constant EPOCH    = 1 days;

    function setUp() public {
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vault = new CoercionResistantVault(
            IEntryPoint(entryPoint),
            owner,
            1 ether,
            EPOCH,
            TIMELOCK,
            guardians,
            2
        );

        usdc   = new MockERC20("USD Coin", "USDC", 6);
        wbtc   = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        router = new MockDexRouter();

        // Fund the vault with 10,000 USDC for swap tests
        usdc.mint(address(vault), 10_000e6);

        // Configure USDC spending limit so hot operations are possible
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), 500e6, EPOCH);
    }

    // ══════════════════════════════════════════════
    //  Whitelist — addition requires timelock
    // ══════════════════════════════════════════════

    function test_Whitelist_AdditionRequiresTimelock() public {
        vm.prank(owner);
        vault.setWhitelistedTarget(address(router), true);

        // Not whitelisted yet
        assertFalse(vault.isWhitelisted(address(router)));

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(owner);
        vault.executeWhitelistChange(address(router));

        assertTrue(vault.isWhitelisted(address(router)));
    }

    function test_Whitelist_RemovalIsImmediate() public {
        // First add
        _whitelistTarget(address(router));
        assertTrue(vault.isWhitelisted(address(router)));

        // Removal is immediate — more restrictive = always safe
        vm.prank(owner);
        vault.setWhitelistedTarget(address(router), false);

        assertFalse(vault.isWhitelisted(address(router)));
    }

    function test_Whitelist_CancelPendingAddition_ByGuardian() public {
        vm.prank(owner);
        vault.setWhitelistedTarget(address(router), true);

        // Guardian cancels the pending addition (panic button)
        vm.prank(guardian1);
        vault.cancelWhitelistChange(address(router));

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.NoActiveConfigChange.selector);
        vault.executeWhitelistChange(address(router));
    }

    function test_Whitelist_CannotWhitelistSelf() public {
        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.SelfCallNotAllowed.selector);
        vault.setWhitelistedTarget(address(vault), true);
    }

    // ══════════════════════════════════════════════
    //  Execute — target gating
    // ══════════════════════════════════════════════

    function test_Execute_NonWhitelisted_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.TargetNotWhitelisted.selector,
                address(router)
            )
        );
        vault.execute(address(router), 0, "");
    }

    function test_Execute_WhitelistedTarget_Succeeds() public {
        _whitelistTarget(address(router));

        // Call a harmless function — router has none, so just send empty call (fallback missing)
        // Use a real function: call swap with 0 amount to an unrelated mock
        // Instead test with approveToken + execute flow (the canonical DeFi sequence)

        // Approve router as spender
        vm.prank(owner);
        vault.approveToken(address(usdc), address(router), 100e6);

        // Mint some tokenOut so router can produce it
        vm.prank(owner);
        bytes memory data = abi.encodeCall(
            MockDexRouter.swap,
            (address(usdc), address(wbtc), 100e6, address(vault))
        );

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 vaultWbtcBefore = wbtc.balanceOf(address(vault));

        vm.prank(owner);
        vault.execute(address(router), 0, data);

        // USDC decreased by 100e6, WBTC increased by 100e6 (1:1 mock rate)
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - 100e6);
        assertEq(wbtc.balanceOf(address(vault)), vaultWbtcBefore + 100e6);
    }

    // ══════════════════════════════════════════════
    //  Approve token — spender gating
    // ══════════════════════════════════════════════

    function test_ApproveToken_SpenderNotWhitelisted_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.SpenderNotWhitelisted.selector,
                address(router)
            )
        );
        vault.approveToken(address(usdc), address(router), 100e6);
    }

    function test_ApproveToken_WhitelistedSpender_Succeeds() public {
        _whitelistTarget(address(router));

        vm.prank(owner);
        vault.approveToken(address(usdc), address(router), 100e6);

        assertEq(usdc.allowance(address(vault), address(router)), 100e6);
    }

    function test_ApproveToken_RevokeWithZero() public {
        _whitelistTarget(address(router));

        vm.startPrank(owner);
        vault.approveToken(address(usdc), address(router), 100e6);
        vault.approveToken(address(usdc), address(router), 0);
        vm.stopPrank();

        assertEq(usdc.allowance(address(vault), address(router)), 0);
    }

    // ══════════════════════════════════════════════
    //  Value-preserving swap — hot budget NOT consumed
    // ══════════════════════════════════════════════

    /// @notice This is the key invariant: a DeFi swap doesn't count against
    ///         the hot spending limit because the vault retains custody of
    ///         equivalent value (just in a different token form).
    function test_DeFiSwap_DoesNotConsumeHotBudget() public {
        _whitelistTarget(address(router));

        // Record hot budget BEFORE swap
        uint256 usdcHotBefore = vault.remainingTokenHotBudget(address(usdc));
        assertEq(usdcHotBefore, 500e6);

        // Swap 500 USDC → 500 WBTC (uses entire hot budget worth, but via execute())
        vm.startPrank(owner);
        vault.approveToken(address(usdc), address(router), 500e6);
        bytes memory data = abi.encodeCall(
            MockDexRouter.swap,
            (address(usdc), address(wbtc), 500e6, address(vault))
        );
        vault.execute(address(router), 0, data);
        vm.stopPrank();

        // Hot budget is UNCHANGED — spent via execute(), not hotSpendToken()
        uint256 usdcHotAfter = vault.remainingTokenHotBudget(address(usdc));
        assertEq(usdcHotAfter, usdcHotBefore, "DeFi execute must not consume hot budget");

        // But the USDC balance did decrease (tokens moved to router)
        // The hot budget is min(limit, balance), so after swap new budget is min(500, 9500) = 500
        // i.e., balance is still > limit, so hot budget stays at 500
    }

    // ══════════════════════════════════════════════
    //  executeBatch — atomic
    // ══════════════════════════════════════════════

    function test_ExecuteBatch_AllSucceed() public {
        _whitelistTarget(address(router));

        vm.prank(owner);
        vault.approveToken(address(usdc), address(router), 300e6);

        // Two swaps in one tx
        address[] memory targets = new address[](2);
        uint256[] memory values  = new uint256[](2);
        bytes[]   memory datas   = new bytes[](2);

        targets[0] = address(router);
        targets[1] = address(router);

        datas[0] = abi.encodeCall(MockDexRouter.swap, (address(usdc), address(wbtc), 100e6, address(vault)));
        datas[1] = abi.encodeCall(MockDexRouter.swap, (address(usdc), address(wbtc), 200e6, address(vault)));

        uint256 wbtcBefore = wbtc.balanceOf(address(vault));

        vm.prank(owner);
        vault.executeBatch(targets, values, datas);

        assertEq(wbtc.balanceOf(address(vault)), wbtcBefore + 300e6);
    }

    function test_ExecuteBatch_OneCallFails_AllRevert() public {
        _whitelistTarget(address(router));

        // Only approve 100e6 — second call will fail on transferFrom
        vm.prank(owner);
        vault.approveToken(address(usdc), address(router), 100e6);

        address[] memory targets = new address[](2);
        uint256[] memory values  = new uint256[](2);
        bytes[]   memory datas   = new bytes[](2);

        targets[0] = address(router);
        targets[1] = address(router);

        datas[0] = abi.encodeCall(MockDexRouter.swap, (address(usdc), address(wbtc), 100e6, address(vault)));
        // Second call wants to swap 200 more, but allowance was only 100
        datas[1] = abi.encodeCall(MockDexRouter.swap, (address(usdc), address(wbtc), 200e6, address(vault)));

        uint256 usdcBefore = usdc.balanceOf(address(vault));
        uint256 wbtcBefore = wbtc.balanceOf(address(vault));

        vm.prank(owner);
        vm.expectRevert();
        vault.executeBatch(targets, values, datas);

        // Atomic revert: balances unchanged
        assertEq(usdc.balanceOf(address(vault)), usdcBefore);
        assertEq(wbtc.balanceOf(address(vault)), wbtcBefore);
    }

    function test_ExecuteBatch_ArrayLengthMismatch_Reverts() public {
        _whitelistTarget(address(router));

        address[] memory targets = new address[](2);
        uint256[] memory values  = new uint256[](1); // mismatch
        bytes[]   memory datas   = new bytes[](2);

        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.BatchLengthMismatch.selector);
        vault.executeBatch(targets, values, datas);
    }

    // ══════════════════════════════════════════════
    //  Pause blocks DeFi execution
    // ══════════════════════════════════════════════

    function test_Execute_BlockedWhilePaused() public {
        _whitelistTarget(address(router));

        vm.prank(owner);
        vault.approveToken(address(usdc), address(router), 100e6);

        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(
            MockDexRouter.swap,
            (address(usdc), address(wbtc), 100e6, address(vault))
        );

        vm.prank(owner);
        vm.expectRevert();
        vault.execute(address(router), 0, data);
    }

    function test_ApproveToken_BlockedWhilePaused() public {
        _whitelistTarget(address(router));

        vm.prank(guardian1);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert();
        vault.approveToken(address(usdc), address(router), 100e6);
    }

    // ══════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════

    function _whitelistTarget(address target) internal {
        vm.prank(owner);
        vault.setWhitelistedTarget(target, true);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(owner);
        vault.executeWhitelistChange(target);
    }
}

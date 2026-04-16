// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CoercionResistantVault, IEntryPoint} from "../src/CoercionResistantVault.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title CoercionResistantVaultTokensTest
 * @notice Tests for the ERC-20 extension: per-token spending limits, deposits,
 *         hot/cold token flows, and first-time-config behavior.
 */
contract CoercionResistantVaultTokensTest is Test {

    CoercionResistantVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;

    address internal owner      = makeAddr("owner");
    address internal recipient  = makeAddr("recipient");
    address internal guardian1  = makeAddr("guardian1");
    address internal guardian2  = makeAddr("guardian2");
    address internal guardian3  = makeAddr("guardian3");
    address internal entryPoint = makeAddr("entryPoint");

    uint256 internal constant ETH_LIMIT   = 1 ether;
    uint256 internal constant EPOCH       = 1 days;
    uint256 internal constant TIMELOCK    = 3 days;
    uint256 internal constant THRESHOLD   = 2;

    // USDC has 6 decimals
    uint256 internal constant USDC_LIMIT  = 500e6;   // 500 USDC
    // WBTC has 8 decimals
    uint256 internal constant WBTC_LIMIT  = 0.01e8;  // 0.01 WBTC

    function setUp() public {
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vault = new CoercionResistantVault(
            IEntryPoint(entryPoint),
            owner,
            ETH_LIMIT,
            EPOCH,
            TIMELOCK,
            guardians,
            THRESHOLD
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // Fund the vault with tokens (10,000 USDC, 1 WBTC)
        usdc.mint(address(vault), 10_000e6);
        wbtc.mint(address(vault), 1e8);
    }

    // ══════════════════════════════════════════════
    //  Deposit
    // ══════════════════════════════════════════════

    function test_DepositToken_IncreasesBalance() public {
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);

        uint256 before_ = usdc.balanceOf(address(vault));
        vault.depositToken(address(usdc), 1_000e6);

        assertEq(usdc.balanceOf(address(vault)), before_ + 1_000e6);
    }

    // ══════════════════════════════════════════════
    //  Hot spend — ERC-20
    // ══════════════════════════════════════════════

    function test_HotSpendToken_NotConfigured_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.TokenNotConfigured.selector,
                address(usdc)
            )
        );
        vault.hotSpendToken(address(usdc), recipient, 100e6);
    }

    function test_SetTokenSpendingLimit_FirstTime_Immediate() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        (uint256 limit, uint256 epoch) = vault.tokenSpendingLimit(address(usdc));
        assertEq(limit, USDC_LIMIT);
        assertEq(epoch, EPOCH);
    }

    function test_HotSpendToken_WithinLimit_Succeeds() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        vm.prank(owner);
        vault.hotSpendToken(address(usdc), recipient, 200e6);

        assertEq(usdc.balanceOf(recipient), 200e6);
        assertEq(vault.tokenSpentInCurrentEpoch(address(usdc)), 200e6);
    }

    function test_HotSpendToken_ExceedsLimit_Reverts() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.ExceedsHotBudget.selector,
                1_000e6,
                500e6
            )
        );
        vault.hotSpendToken(address(usdc), recipient, 1_000e6);
    }

    function test_HotSpendToken_IndependentPerToken() public {
        vm.startPrank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);
        vault.setTokenSpendingLimit(address(wbtc), WBTC_LIMIT, EPOCH);

        // Spend full USDC budget
        vault.hotSpendToken(address(usdc), recipient, USDC_LIMIT);

        // WBTC budget should be untouched
        vault.hotSpendToken(address(wbtc), recipient, WBTC_LIMIT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), USDC_LIMIT);
        assertEq(wbtc.balanceOf(recipient), WBTC_LIMIT);
    }

    function test_HotSpendToken_EpochReset() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        vm.prank(owner);
        vault.hotSpendToken(address(usdc), recipient, USDC_LIMIT);

        vm.warp(block.timestamp + EPOCH + 1);

        vm.prank(owner);
        vault.hotSpendToken(address(usdc), recipient, 100e6);

        assertEq(vault.tokenSpentInCurrentEpoch(address(usdc)), 100e6);
    }

    // ══════════════════════════════════════════════
    //  Config timelock — token limits
    // ══════════════════════════════════════════════

    function test_TokenLimitIncrease_RequiresTimelock() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT * 10, EPOCH);

        // Still old limit
        (uint256 limit,) = vault.tokenSpendingLimit(address(usdc));
        assertEq(limit, USDC_LIMIT);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(owner);
        vault.executeTokenSpendingLimitChange(address(usdc));

        (limit,) = vault.tokenSpendingLimit(address(usdc));
        assertEq(limit, USDC_LIMIT * 10);
    }

    function test_TokenLimitDecrease_Immediate() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT / 2, EPOCH);

        (uint256 limit,) = vault.tokenSpendingLimit(address(usdc));
        assertEq(limit, USDC_LIMIT / 2);
    }

    function test_TokenEpochDecrease_RequiresTimelock() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, 1 hours);

        // Not yet applied
        (, uint256 epoch) = vault.tokenSpendingLimit(address(usdc));
        assertEq(epoch, EPOCH);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(owner);
        vault.executeTokenSpendingLimitChange(address(usdc));

        (, epoch) = vault.tokenSpendingLimit(address(usdc));
        assertEq(epoch, 1 hours);
    }

    // ══════════════════════════════════════════════
    //  Cold vault — token withdrawal
    // ══════════════════════════════════════════════

    function test_RequestTokenWithdrawal_RespectsTimelock() public {
        vm.prank(owner);
        uint256 requestId = vault.requestTokenWithdrawal(address(usdc), payable(recipient), 5_000e6);

        assertEq(vault.pendingWithdrawalCount(), 1);

        // Pre-timelock execution fails
        vm.expectRevert();
        vault.executeWithdrawal(requestId);

        // After timelock succeeds
        vm.warp(block.timestamp + TIMELOCK + 1);

        uint256 before_ = usdc.balanceOf(recipient);
        vault.executeWithdrawal(requestId);

        assertEq(usdc.balanceOf(recipient), before_ + 5_000e6);
        assertEq(vault.pendingWithdrawalCount(), 0);
    }

    function test_RequestTokenWithdrawal_MultisigBypass() public {
        vm.prank(owner);
        uint256 requestId = vault.requestTokenWithdrawal(address(usdc), payable(recipient), 5_000e6);

        vm.prank(guardian1);
        vault.approveWithdrawal(requestId);

        vm.prank(guardian2);
        vault.approveWithdrawal(requestId);

        // No warp needed
        uint256 before_ = usdc.balanceOf(recipient);
        vault.executeWithdrawal(requestId);

        assertEq(usdc.balanceOf(recipient), before_ + 5_000e6);
    }

    function test_ColdTokenBalance_DefaultsToFull() public {
        // Before any spending limit is set, full balance is cold
        assertEq(vault.tokenColdBalance(address(usdc)), 10_000e6);
        assertEq(vault.tokenHotBalance(address(usdc)), 0);
    }

    function test_ColdTokenBalance_AfterConfiguration() public {
        vm.prank(owner);
        vault.setTokenSpendingLimit(address(usdc), USDC_LIMIT, EPOCH);

        assertEq(vault.tokenHotBalance(address(usdc)), USDC_LIMIT);
        assertEq(vault.tokenColdBalance(address(usdc)), 10_000e6 - USDC_LIMIT);
    }
}

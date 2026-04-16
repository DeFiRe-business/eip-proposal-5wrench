// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CoercionResistantVault, IEntryPoint} from "../src/CoercionResistantVault.sol";

/**
 * @title CoercionResistantVaultTest
 * @notice Unit tests for the core vault behavior: hot spend, cold withdrawals,
 *         multisig bypass, emergency pause, config timelock, guardian management.
 * @dev Fork tests against Sepolia live in CoercionResistantVaultDeFi.fork.t.sol.
 */
contract CoercionResistantVaultTest is Test {

    // ==============================================
    //  Actors & config
    // ==============================================

    CoercionResistantVault internal vault;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");
    address internal guardian1 = makeAddr("guardian1");
    address internal guardian2 = makeAddr("guardian2");
    address internal guardian3 = makeAddr("guardian3");
    address internal entryPoint = makeAddr("entryPoint");

    uint256 internal constant SPENDING_LIMIT    = 1 ether;
    uint256 internal constant EPOCH_DURATION    = 1 days;
    uint256 internal constant TIMELOCK_DURATION = 3 days;
    uint256 internal constant MULTISIG_THRESHOLD = 2;

    // ==============================================
    //  Setup
    // ==============================================

    function setUp() public {
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vault = new CoercionResistantVault(
            IEntryPoint(entryPoint),
            owner,
            SPENDING_LIMIT,
            EPOCH_DURATION,
            TIMELOCK_DURATION,
            guardians,
            MULTISIG_THRESHOLD
        );

        // Fund the vault with 10 ETH to have room for both hot and cold operations
        vm.deal(address(vault), 10 ether);
    }

    // ==============================================
    //  Hot spend -- ETH
    // ==============================================

    function test_HotSpend_WithinLimit_Succeeds() public {
        uint256 initialBalance = recipient.balance;

        vm.prank(owner);
        vault.hotSpend(payable(recipient), 0.5 ether);

        assertEq(recipient.balance, initialBalance + 0.5 ether);
        assertEq(vault.spentInCurrentEpoch(), 0.5 ether);
    }

    function test_HotSpend_ExceedsLimit_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.ExceedsHotBudget.selector,
                2 ether,   // requested
                1 ether    // available (= spendingLimit)
            )
        );
        vault.hotSpend(payable(recipient), 2 ether);
    }

    function test_HotSpend_MultipleSpends_AccumulateWithinEpoch() public {
        vm.startPrank(owner);
        vault.hotSpend(payable(recipient), 0.4 ether);
        vault.hotSpend(payable(recipient), 0.3 ether);
        vm.stopPrank();

        assertEq(vault.spentInCurrentEpoch(), 0.7 ether);

        // Third spend that would push over the limit reverts
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.ExceedsHotBudget.selector,
                0.4 ether,
                0.3 ether
            )
        );
        vault.hotSpend(payable(recipient), 0.4 ether);
    }

    function test_HotSpend_EpochReset_AfterDurationPasses() public {
        vm.prank(owner);
        vault.hotSpend(payable(recipient), SPENDING_LIMIT);

        // Warp past epoch end
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        // Should now be able to spend again
        vm.prank(owner);
        vault.hotSpend(payable(recipient), 0.5 ether);

        // Epoch should have reset to this block
        assertEq(vault.spentInCurrentEpoch(), 0.5 ether);
    }

    function test_HotSpend_NotOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(CoercionResistantVault.NotOwnerOrEntryPoint.selector);
        vault.hotSpend(payable(recipient), 0.1 ether);
    }

    // ==============================================
    //  Cold vault -- ETH withdrawal flow
    // ==============================================

    function test_ColdWithdrawal_BeforeTimelock_Reverts() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        assertEq(vault.pendingWithdrawalCount(), 1);

        // Try to execute immediately -- should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.TimelockNotExpired.selector,
                block.timestamp + TIMELOCK_DURATION,
                block.timestamp
            )
        );
        vault.executeWithdrawal(requestId);
    }

    function test_ColdWithdrawal_AfterTimelock_Succeeds() public {
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        // Warp past timelock
        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vault.executeWithdrawal(requestId);

        assertEq(recipient.balance, recipientBalanceBefore + 5 ether);
        assertEq(vault.pendingWithdrawalCount(), 0);
    }

    function test_ColdWithdrawal_CancelByOwner_Succeeds() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        vm.prank(owner);
        vault.cancelWithdrawal(requestId);

        // Pending count decrements
        assertEq(vault.pendingWithdrawalCount(), 0);

        // Cannot execute a cancelled request
        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.RequestAlreadyCancelled.selector,
                requestId
            )
        );
        vault.executeWithdrawal(requestId);
    }

    function test_ColdWithdrawal_CancelByGuardian_Succeeds() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        // Guardian acts as "panic button" after attacker leaves
        vm.prank(guardian1);
        vault.cancelWithdrawal(requestId);

        assertEq(vault.pendingWithdrawalCount(), 0);
    }

    function test_ColdWithdrawal_CancelByAttacker_Reverts() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        vm.prank(attacker);
        vm.expectRevert(CoercionResistantVault.NotOwnerOrGuardian.selector);
        vault.cancelWithdrawal(requestId);
    }

    function test_ColdWithdrawal_ExceedsColdBalance_Reverts() public {
        // Vault has 10 ETH, 1 ETH is hot budget, so cold = 9 ETH
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.ExceedsColdBalance.selector,
                100 ether,
                9 ether
            )
        );
        vault.requestWithdrawal(payable(recipient), 100 ether);
    }

    // ==============================================
    //  Multisig bypass
    // ==============================================

    function test_MultisigBypass_TwoGuardiansApprove_BypassesTimelock() public {
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        // Two guardians approve (meets threshold of 2)
        vm.prank(guardian1);
        vault.approveWithdrawal(requestId);

        vm.prank(guardian2);
        vault.approveWithdrawal(requestId);

        // No time warp -- should execute immediately despite timelock
        vault.executeWithdrawal(requestId);

        assertEq(recipient.balance, recipientBalanceBefore + 5 ether);
    }

    function test_MultisigBypass_OneGuardianApproval_InsufficientForBypass() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        vm.prank(guardian1);
        vault.approveWithdrawal(requestId);

        // Only 1 approval, threshold is 2 -- still subject to timelock
        vm.expectRevert(); // TimelockNotExpired
        vault.executeWithdrawal(requestId);
    }

    function test_MultisigBypass_GuardianDoubleApproval_Reverts() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        vm.prank(guardian1);
        vault.approveWithdrawal(requestId);

        vm.prank(guardian1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.AlreadyApproved.selector,
                requestId,
                guardian1
            )
        );
        vault.approveWithdrawal(requestId);
    }

    function test_MultisigBypass_NonGuardianCannotApprove() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        vm.prank(attacker);
        vm.expectRevert(CoercionResistantVault.NotGuardian.selector);
        vault.approveWithdrawal(requestId);
    }

    // ==============================================
    //  MAX_PENDING_WITHDRAWALS cap (DoS protection)
    // ==============================================

    function test_PendingWithdrawalCap_RevertsAtLimit() public {
        // Fund enough for 32 withdrawals of 0.01 ether each (cold needs to cover it)
        vm.deal(address(vault), 100 ether);

        uint256 max = vault.MAX_PENDING_WITHDRAWALS();
        assertEq(max, 32);

        vm.startPrank(owner);
        for (uint256 i = 0; i < max; i++) {
            vault.requestWithdrawal(payable(recipient), 0.01 ether);
        }
        assertEq(vault.pendingWithdrawalCount(), 32);

        // 33rd reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.TooManyPendingWithdrawals.selector,
                32,
                32
            )
        );
        vault.requestWithdrawal(payable(recipient), 0.01 ether);
        vm.stopPrank();
    }

    function test_PendingWithdrawalCap_CancelFreesSlot() public {
        vm.deal(address(vault), 100 ether);

        uint256 max = vault.MAX_PENDING_WITHDRAWALS();

        vm.startPrank(owner);
        uint256[] memory ids = new uint256[](max);
        for (uint256 i = 0; i < max; i++) {
            ids[i] = vault.requestWithdrawal(payable(recipient), 0.01 ether);
        }
        assertEq(vault.pendingWithdrawalCount(), 32);

        // Cancel one
        vault.cancelWithdrawal(ids[0]);
        assertEq(vault.pendingWithdrawalCount(), 31);

        // Now a new request fits
        vault.requestWithdrawal(payable(recipient), 0.01 ether);
        assertEq(vault.pendingWithdrawalCount(), 32);
        vm.stopPrank();
    }

    // ==============================================
    //  Emergency pause
    // ==============================================

    function test_Pause_SingleGuardianCanPause() public {
        vm.prank(guardian1);
        vault.pause();

        assertTrue(vault.isPaused());
        assertEq(vault.pausedUntil(), block.timestamp + vault.MAX_PAUSE_DURATION());
    }

    function test_Pause_NonGuardianCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(CoercionResistantVault.NotGuardian.selector);
        vault.pause();
    }

    function test_Pause_BlocksHotSpend() public {
        vm.prank(guardian1);
        vault.pause();

        // IMPORTANT: capture pausedUntil() BEFORE prank. If we call pausedUntil()
        // inside the abi.encodeWithSelector argument after vm.prank(owner), that
        // external call consumes the prank and hotSpend() runs as address(this),
        // reverting with NotOwnerOrEntryPoint instead of VaultPausedError.
        uint256 until = vault.pausedUntil();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.VaultPausedError.selector,
                until
            )
        );
        vault.hotSpend(payable(recipient), 0.1 ether);
    }

    function test_Pause_BlocksRequestWithdrawal() public {
        vm.prank(guardian1);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert();
        vault.requestWithdrawal(payable(recipient), 1 ether);
    }

    function test_Pause_AllowsCancelWithdrawal() public {
        // Request before pause
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        // Pause
        vm.prank(guardian1);
        vault.pause();

        // Cancel should still work (safety action)
        vm.prank(owner);
        vault.cancelWithdrawal(requestId);

        assertEq(vault.pendingWithdrawalCount(), 0);
    }

    function test_Pause_AllowsApproveWithdrawal() public {
        vm.prank(owner);
        uint256 requestId = vault.requestWithdrawal(payable(recipient), 5 ether);

        vm.prank(guardian1);
        vault.pause();

        // Guardians can still coordinate on pending requests
        vm.prank(guardian2);
        vault.approveWithdrawal(requestId);
    }

    function test_Pause_AutoExpiryAfter24h() public {
        vm.prank(guardian1);
        vault.pause();

        assertTrue(vault.isPaused());

        // Warp past auto-expiry
        vm.warp(block.timestamp + vault.MAX_PAUSE_DURATION() + 1);

        assertFalse(vault.isPaused());

        // Hot spend works again without explicit unpause
        vm.prank(owner);
        vault.hotSpend(payable(recipient), 0.5 ether);
    }

    function test_Pause_ExtendByCallingPauseAgain() public {
        vm.prank(guardian1);
        vault.pause();
        uint256 firstPauseUntil = vault.pausedUntil();

        // Warp 12 hours forward -- pause still active
        vm.warp(block.timestamp + 12 hours);

        // Another guardian extends
        vm.prank(guardian2);
        vault.pause();

        // New deadline should be block.timestamp + 24h (reset)
        assertEq(vault.pausedUntil(), block.timestamp + vault.MAX_PAUSE_DURATION());
        assertGt(vault.pausedUntil(), firstPauseUntil);
    }

    function test_Unpause_RequiresMultisigThreshold() public {
        vm.prank(guardian1);
        vault.pause();

        // First guardian approval
        vm.prank(guardian1);
        vault.unpause();

        // Still paused after 1 approval (threshold is 2)
        assertTrue(vault.isPaused());

        // Second guardian approval
        vm.prank(guardian2);
        vault.unpause();

        // Now unpaused
        assertFalse(vault.isPaused());
        assertEq(vault.pausedUntil(), 0);
    }

    function test_Unpause_SameGuardianCannotApproveTwice() public {
        vm.prank(guardian1);
        vault.pause();

        vm.prank(guardian1);
        vault.unpause();

        vm.prank(guardian1);
        vm.expectRevert();
        vault.unpause();
    }

    function test_Unpause_WhenNotPaused_Reverts() public {
        vm.prank(guardian1);
        vm.expectRevert(CoercionResistantVault.VaultNotPaused.selector);
        vault.unpause();
    }

    // ==============================================
    //  Config timelock -- Spending limit
    // ==============================================

    function test_SetSpendingLimit_Decrease_Immediate() public {
        vm.prank(owner);
        vault.setSpendingLimit(0.5 ether, EPOCH_DURATION);

        assertEq(vault.spendingLimit(), 0.5 ether);
    }

    function test_SetSpendingLimit_Increase_RequiresTimelock() public {
        vm.prank(owner);
        vault.setSpendingLimit(5 ether, EPOCH_DURATION);

        // Still old value
        assertEq(vault.spendingLimit(), SPENDING_LIMIT);

        // Cannot execute before timelock
        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.ConfigChangeNotReady.selector);
        vault.executeSpendingLimitChange();

        // Warp past timelock
        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vault.executeSpendingLimitChange();

        assertEq(vault.spendingLimit(), 5 ether);
    }

    function test_SetSpendingLimit_EpochDurationDecrease_RequiresTimelock() public {
        // Reducing the epoch with the same limit effectively increases spending rate
        vm.prank(owner);
        vault.setSpendingLimit(SPENDING_LIMIT, 1 hours);

        // Not applied yet
        assertEq(vault.epochDuration(), EPOCH_DURATION);

        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vault.executeSpendingLimitChange();

        assertEq(vault.epochDuration(), 1 hours);
    }

    function test_SetSpendingLimit_EpochDurationIncrease_Immediate() public {
        vm.prank(owner);
        vault.setSpendingLimit(SPENDING_LIMIT, 7 days);

        assertEq(vault.epochDuration(), 7 days);
    }

    function test_SetSpendingLimit_CancelPending() public {
        vm.prank(owner);
        vault.setSpendingLimit(5 ether, EPOCH_DURATION);

        // Guardian cancels the pending change (panic button)
        vm.prank(guardian1);
        vault.cancelSpendingLimitChange();

        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.NoActiveConfigChange.selector);
        vault.executeSpendingLimitChange();
    }

    // ==============================================
    //  Config timelock -- Timelock duration
    // ==============================================

    function test_SetTimelockDuration_Increase_Immediate() public {
        vm.prank(owner);
        vault.setTimelockDuration(7 days);

        assertEq(vault.timelockDuration(), 7 days);
    }

    function test_SetTimelockDuration_Decrease_RequiresTimelock() public {
        vm.prank(owner);
        vault.setTimelockDuration(1 days);

        // Still old value
        assertEq(vault.timelockDuration(), TIMELOCK_DURATION);

        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vault.executeTimelockChange();

        assertEq(vault.timelockDuration(), 1 days);
    }

    // ==============================================
    //  Guardian management
    // ==============================================

    function test_GuardianAddition_RequiresTimelock() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(owner);
        vault.setGuardian(newGuardian, true);

        // Not yet added
        assertFalse(vault.isGuardian(newGuardian));

        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vault.executeGuardianChange(newGuardian);

        assertTrue(vault.isGuardian(newGuardian));
        assertEq(vault.guardianCount(), 4);
    }

    function test_GuardianRemoval_BelowThreshold_Reverts() public {
        // Start with 3 guardians, threshold 2
        // Remove one -> 2 guardians, threshold 2 -- OK
        vm.prank(owner);
        vault.setGuardian(guardian3, false);

        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vault.executeGuardianChange(guardian3);

        assertEq(vault.guardianCount(), 2);

        // Try to remove another -> would leave 1 guardian with threshold 2 -- REVERTS
        vm.prank(owner);
        vault.setGuardian(guardian2, false);

        vm.warp(block.timestamp + TIMELOCK_DURATION + 1);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoercionResistantVault.GuardianRemovalWouldBreakThreshold.selector,
                uint256(1),   // guardianList.length - 1 = 2 - 1
                uint256(2)    // multisigThreshold
            )
        );
        vault.executeGuardianChange(guardian2);
    }

    /// @notice Demonstrates the threshold invariant: you cannot reduce
    ///         multisigThreshold below 2 while guardians exist, which protects
    ///         the multisig bypass path from becoming trivially exploitable.
    function test_SetMultisigThreshold_BelowTwo_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.InvalidThreshold.selector);
        vault.setMultisigThreshold(1);
    }

    function test_SetMultisigThreshold_AboveGuardianCount_Reverts() public {
        // Currently 3 guardians, threshold 2. Try to set threshold 5 -- invalid.
        vm.prank(owner);
        vm.expectRevert(CoercionResistantVault.InvalidThreshold.selector);
        vault.setMultisigThreshold(5);
    }

    function test_SetMultisigThreshold_ValidValue_Succeeds() public {
        vm.prank(owner);
        vault.setMultisigThreshold(3);
        assertEq(vault.multisigThreshold(), 3);
    }

    // ==============================================
    //  Deposits & receive
    // ==============================================

    function test_Receive_EmitsDeposited() public {
        uint256 balanceBefore = address(vault).balance;

        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposited(address(this), 1 ether);

        (bool success,) = address(vault).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(vault).balance, balanceBefore + 1 ether);
    }

    function test_Deposit_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposited(address(this), 0.5 ether);

        vault.deposit{value: 0.5 ether}();
    }

    // Event signatures used by vm.expectEmit
    event Deposited(address indexed sender, uint256 amount);
}

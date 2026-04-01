---
eip: XXXX
title: Coercion-Resistant Vault Standard
description: A smart contract wallet standard with spending limits, timelocks, and multisig to protect against physical coercion attacks
author: [Tu nombre] (@tu-github), [Co-autores]
discussions-to: https://ethereum-magicians.org/t/erc-xxxx-coercion-resistant-vault/XXXXX
status: Draft
type: Standards Track
category: ERC
created: 2026-04-01
requires: 165, 4337
---

## Abstract

This ERC defines a standard interface for coercion-resistant vault contracts that partition
a user's balance into two tiers: a "hot" balance available for immediate spending up to a
configurable limit, and a "cold" vault requiring either a timelock delay or multisig approval
to unlock. The design mirrors the delayed-opening safes used by banks and cash-in-transit
companies, where even employees with physical access cannot immediately access the full
contents, rendering physical coercion attacks economically unviable.

## Motivation

Physical attacks against cryptocurrency holders—commonly known as "$5 wrench attacks"—have
risen dramatically. According to publicly maintained databases of known physical attacks
against crypto holders, reported incidents increased by 169% in 2025, with over 70 confirmed
cases worldwide resulting in over $40 million stolen.

Unlike traditional financial systems where banks impose withdrawal limits, wire transfer
delays, and fraud departments that can reverse transactions, self-custodial cryptocurrency
wallets grant immediate, irreversible access to the entire balance to anyone who controls
the private key. This creates a uniquely dangerous situation: attackers can coerce a victim
into transferring their entire net worth in minutes, with no possibility of reversal.

Current mitigation strategies have significant limitations:

- **Decoy/duress wallets**: Rely on the attacker not knowing about hidden funds. Attackers
  who research their targets (increasingly common) may not be satisfied with a small decoy
  balance and may escalate violence.
- **Pure multisig**: Effective but introduces friction for everyday spending and requires
  always-available cosigners.
- **Pure timelock**: Prevents all immediate spending, making the wallet impractical for
  daily use.

This ERC proposes a standard that combines the best of all approaches: immediate access to
a limited "hot" balance for daily spending, with the bulk of funds locked behind timelocks
and/or multisig requirements. The key insight is that even under physical coercion, the
victim can truthfully state: "I can only send you X amount right now. The rest is locked
and I physically cannot access it faster."

This approach:

1. **Removes the incentive** for physical attacks by limiting the immediately extractable
   value.
2. **Provides plausible deniability**: The victim is not lying or hiding funds—the
   constraint is verifiable on-chain.
3. **Allows cancellation**: Pending withdrawals from the cold vault can be cancelled during
   the timelock period, giving the victim time to act after the attacker leaves.
4. **Maintains usability**: Daily spending from the hot balance works without friction.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document
are to be interpreted as described in RFC 2119 and RFC 8174.

### Definitions

- **Owner**: The primary key holder of the vault, capable of spending from the hot balance
  and initiating cold vault withdrawals.
- **Guardian**: A cosigner in the multisig scheme who can approve cold vault withdrawals
  or cancel pending withdrawals.
- **Hot balance**: The portion of funds available for immediate transfer by the owner,
  subject to a rate limit.
- **Cold vault**: The portion of funds requiring a timelock delay or multisig approval
  before transfer.
- **Spending limit**: The maximum amount the owner can transfer from the hot balance within
  a configurable time window (epoch).
- **Timelock period**: The minimum delay between initiating a cold vault withdrawal and
  the funds becoming transferable.
- **Withdrawal request**: A pending transfer from the cold vault, subject to the timelock
  period and cancellable by the owner or any guardian.

### Interface

Every compliant contract MUST implement the following interface:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

interface ICoercionResistantVault {

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when ETH or tokens are deposited into the vault.
    event Deposited(address indexed sender, uint256 amount);

    /// @notice Emitted when the owner spends from the hot balance.
    event HotSpend(address indexed to, uint256 amount);

    /// @notice Emitted when a cold vault withdrawal is requested.
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );

    /// @notice Emitted when a pending withdrawal is executed after timelock.
    event WithdrawalExecuted(uint256 indexed requestId);

    /// @notice Emitted when a pending withdrawal is cancelled.
    event WithdrawalCancelled(uint256 indexed requestId, address cancelledBy);

    /// @notice Emitted when a withdrawal is approved via multisig (bypassing timelock).
    event WithdrawalApprovedByMultisig(uint256 indexed requestId);

    /// @notice Emitted when the spending limit configuration changes.
    event SpendingLimitChanged(uint256 newLimit, uint256 newEpochDuration);

    /// @notice Emitted when the timelock duration changes.
    event TimelockChanged(uint256 newDuration);

    /// @notice Emitted when a guardian is added or removed.
    event GuardianChanged(address indexed guardian, bool added);

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Returns the total balance held by the vault (hot + cold).
    function totalBalance() external view returns (uint256);

    /// @notice Returns the maximum amount the owner can spend immediately.
    function hotBalance() external view returns (uint256);

    /// @notice Returns the amount locked in the cold vault.
    function coldBalance() external view returns (uint256);

    /// @notice Returns the spending limit per epoch.
    function spendingLimit() external view returns (uint256);

    /// @notice Returns the epoch duration in seconds.
    function epochDuration() external view returns (uint256);

    /// @notice Returns the amount already spent in the current epoch.
    function spentInCurrentEpoch() external view returns (uint256);

    /// @notice Returns the remaining spendable amount in the current epoch.
    function remainingHotBudget() external view returns (uint256);

    /// @notice Returns the timelock duration in seconds.
    function timelockDuration() external view returns (uint256);

    /// @notice Returns the required number of multisig approvals for instant withdrawal.
    function multisigThreshold() external view returns (uint256);

    /// @notice Returns true if the address is a registered guardian.
    function isGuardian(address account) external view returns (bool);

    /// @notice Returns details of a pending withdrawal request.
    function getWithdrawalRequest(uint256 requestId)
        external
        view
        returns (
            address to,
            uint256 amount,
            uint256 unlockTime,
            bool executed,
            bool cancelled,
            uint256 approvalCount
        );

    // ──────────────────────────────────────────────
    //  Hot balance operations (owner only)
    // ──────────────────────────────────────────────

    /// @notice Transfer ETH from the hot balance, subject to spending limit.
    /// @dev MUST revert if amount exceeds remainingHotBudget().
    function hotSpend(address payable to, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Cold vault operations
    // ──────────────────────────────────────────────

    /// @notice Request a withdrawal from the cold vault, starting the timelock.
    /// @dev MUST revert if amount exceeds coldBalance(). Only callable by owner.
    /// @return requestId The ID of the created withdrawal request.
    function requestWithdrawal(address payable to, uint256 amount)
        external
        returns (uint256 requestId);

    /// @notice Execute a pending withdrawal after the timelock has expired.
    /// @dev MUST revert if the timelock has not expired or if cancelled.
    function executeWithdrawal(uint256 requestId) external;

    /// @notice Cancel a pending withdrawal. Callable by the owner or any guardian.
    function cancelWithdrawal(uint256 requestId) external;

    /// @notice Approve a pending withdrawal via multisig, bypassing the timelock.
    /// @dev Only callable by guardians. When approvalCount >= multisigThreshold,
    ///      the withdrawal becomes immediately executable.
    function approveWithdrawal(uint256 requestId) external;

    // ──────────────────────────────────────────────
    //  Configuration (owner only, subject to timelock)
    // ──────────────────────────────────────────────

    /// @notice Update the hot balance spending limit.
    /// @dev Increases to the spending limit SHOULD be subject to a timelock delay
    ///      to prevent an attacker from forcing the owner to raise the limit.
    ///      Decreases MAY take effect immediately.
    function setSpendingLimit(uint256 newLimit, uint256 newEpochDuration) external;

    /// @notice Update the timelock duration for cold vault withdrawals.
    /// @dev Decreases to the timelock SHOULD be subject to the current timelock delay.
    ///      Increases MAY take effect immediately.
    function setTimelockDuration(uint256 newDuration) external;

    /// @notice Add or remove a guardian.
    /// @dev Changes to guardians SHOULD be subject to a timelock delay.
    function setGuardian(address guardian, bool active) external;

    /// @notice Set the number of guardian approvals required for instant withdrawal.
    function setMultisigThreshold(uint256 threshold) external;
}
```

### Behavior Requirements

#### Hot Balance and Spending Limits

1. The vault MUST track a `spendingLimit` and an `epochDuration`.
2. The vault MUST track `spentInCurrentEpoch` and reset it when the current epoch expires.
3. `hotSpend()` MUST revert if `amount > remainingHotBudget()`.
4. `remainingHotBudget()` MUST return `min(spendingLimit - spentInCurrentEpoch, address(this).balance)`.
5. The hot balance is NOT a separate pool—it is a rate-limited view of the total balance.
   The cold balance is calculated as `totalBalance - remainingHotBudget()`.

#### Cold Vault Withdrawals

6. `requestWithdrawal()` MUST create a pending request with `unlockTime = block.timestamp + timelockDuration`.
7. `executeWithdrawal()` MUST revert if `block.timestamp < unlockTime`.
8. `executeWithdrawal()` MUST revert if the request has been cancelled.
9. `cancelWithdrawal()` MUST be callable by the owner OR any registered guardian.
10. `cancelWithdrawal()` MUST work at any time before execution, including after the
    timelock expires.

#### Multisig Bypass

11. `approveWithdrawal()` MUST be callable only by registered guardians.
12. Each guardian MUST only be able to approve each request once.
13. When `approvalCount >= multisigThreshold`, the withdrawal MUST become immediately
    executable (timelock bypassed).
14. `multisigThreshold` MUST be at least 2 when guardians are configured.

#### Configuration Security

15. Increases to `spendingLimit` MUST be subject to a timelock delay equal to at least
    the current `timelockDuration`. This prevents an attacker from forcing the victim to
    raise the limit and then drain immediately.
16. Decreases to `timelockDuration` MUST be subject to a delay equal to the current
    `timelockDuration`.
17. Changes to the guardian set MUST be subject to a timelock delay.
18. Decreases to `spendingLimit` and increases to `timelockDuration` MAY take effect
    immediately (these changes make the vault more secure, not less).

### ERC-165 Support

Compliant contracts MUST implement ERC-165 and return `true` for the interface ID of
`ICoercionResistantVault`.

### ERC-4337 Compatibility

Implementations SHOULD be compatible with ERC-4337 account abstraction, allowing the vault
to be used as a smart contract wallet with UserOperations. The hot spend function SHOULD
be callable via UserOp execution, while cold vault operations follow the same timelock/multisig
rules regardless of the execution path.

## Rationale

### Why rate-limited hot balance instead of a fixed hot pool?

A fixed hot pool requires the user to manually "refill" it, adding friction. A rate-limited
approach means the user always has access to their daily budget without any action, while
the bulk of funds remains inaccessible on short notice. The rate limit also means that even
if an attacker keeps the victim coerced for extended periods, the maximum extractable value
grows linearly and slowly.

### Why allow both timelock AND multisig?

Different users have different threat models and social graphs:

- A user with trusted family members or business partners may prefer a 2-of-3 multisig for
  quick access when legitimately needed.
- A user without suitable cosigners may prefer a longer timelock (72h+) as the sole
  protection mechanism.
- Many users will use both: multisig for planned large transactions, timelock as the
  fallback for solo operations.

### Why must configuration changes also be timelocked?

Without this, an attacker could force the victim to: (1) raise the spending limit to
infinity, (2) immediately drain the entire balance. The timelock on configuration changes
closes this attack vector.

### Why can guardians cancel withdrawals?

If an attacker forces a cold vault withdrawal and then leaves (planning to return after the
timelock), a guardian can cancel the withdrawal during the delay period. This gives the
victim and their trusted contacts a window to respond.

### Why not use a duress PIN / panic wallet instead?

Duress-based systems rely on the attacker not knowing about the mechanism. If an attacker
is aware of duress wallets (increasingly likely as they become common), they may torture
the victim further, demanding the "real" wallet. A verifiable on-chain constraint is
superior because:

1. The limitation is publicly auditable—the attacker can verify it themselves.
2. The victim does not need to lie or perform theater under extreme stress.
3. The mechanism works regardless of attacker sophistication.

## Backwards Compatibility

This ERC introduces a new contract standard and does not modify existing standards. It is
fully backwards compatible. Existing wallets can migrate funds to a compliant vault contract
at any time.

## Reference Implementation

See `CoercionResistantVault.sol` in the assets directory for a complete reference
implementation.

## Security Considerations

### Attacker holds victim for extended periods

If an attacker holds a victim for multiple epochs, they can extract `spendingLimit` per
epoch. Implementations SHOULD allow users to set aggressive spending limits (e.g., 0.1 ETH
per 24h) to minimize this risk. A 72-hour timelock combined with a low daily limit means
even sustained coercion yields limited value.

### Attacker targets guardians

If an attacker knows the guardian addresses, they might target guardians to force multisig
approval. Implementations SHOULD recommend that guardian identities remain private.
Guardians MAY be institutional custodians, hardware wallets in bank vaults, or
time-delayed smart contracts themselves.

### Social engineering of guardians

A sophisticated attacker might contact guardians with a plausible story to get their
approval. Guardians SHOULD establish out-of-band verification protocols with the vault
owner (e.g., code words, video calls, in-person verification).

### Griefing via cancellation

A malicious guardian could repeatedly cancel legitimate withdrawal requests. The owner
SHOULD be able to remove guardians, though this action is itself subject to a timelock.
Implementations MAY add a dispute resolution mechanism or require a majority of guardians
to agree on cancellation.

### Front-running and MEV

Withdrawal execution transactions are not time-sensitive in a way that creates significant
MEV opportunities, as the unlock time provides a wide execution window.

### Smart contract risk

As with any smart contract wallet, bugs in the implementation could lead to loss of funds.
Implementations MUST undergo thorough auditing. The simplicity of the interface is
intentional—fewer features mean a smaller attack surface.

### Configuration lock-out

If the owner loses access to their key, the cold vault funds become permanently locked
(no guardian has unilateral withdrawal rights). Implementations SHOULD consider adding a
social recovery mechanism compatible with the vault's security model.

### ERC-20 Token Support

This specification covers native ETH. Implementations SHOULD extend support to ERC-20
tokens with equivalent spending limits and timelock mechanisms per token.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

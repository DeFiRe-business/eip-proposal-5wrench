// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/**
 * @title CoercionResistantVault
 * @notice Reference implementation of ERC-XXXX: Coercion-Resistant Vault Standard.
 * @dev Protects against physical coercion ("$5 wrench attacks") by partitioning
 *      funds into a rate-limited hot balance and a timelocked/multisig cold vault.
 *
 *      Analogy: Like a bank vault with delayed opening. The teller can hand you
 *      cash from the drawer (hot balance), but the vault door is on a timer
 *      (timelock) or requires two keys turned simultaneously (multisig).
 */
contract CoercionResistantVault {

    // ══════════════════════════════════════════════
    //  Types
    // ══════════════════════════════════════════════

    struct WithdrawalRequest {
        address payable to;
        uint256 amount;
        uint256 unlockTime;
        bool executed;
        bool cancelled;
        uint256 approvalCount;
        mapping(address => bool) approvedBy;
    }

    struct PendingConfigChange {
        uint256 newValue;
        uint256 newValue2;       // used for epoch duration in spending limit changes
        uint256 effectiveTime;
        bool active;
    }

    // ══════════════════════════════════════════════
    //  State
    // ══════════════════════════════════════════════

    address public owner;

    // --- Spending limits ---
    uint256 public spendingLimit;       // max wei spendable per epoch
    uint256 public epochDuration;       // epoch length in seconds
    uint256 public currentEpochStart;   // timestamp when current epoch began
    uint256 public spentInCurrentEpoch; // wei spent so far in current epoch

    // --- Cold vault ---
    uint256 public timelockDuration;    // delay in seconds for cold withdrawals
    uint256 public nextRequestId;

    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    // --- Guardians & multisig ---
    mapping(address => bool) public isGuardian;
    address[] public guardianList;
    uint256 public multisigThreshold;

    // --- Pending configuration changes (timelocked) ---
    PendingConfigChange public pendingLimitChange;
    PendingConfigChange public pendingTimelockChange;
    mapping(address => PendingConfigChange) public pendingGuardianChange;

    // ══════════════════════════════════════════════
    //  Events
    // ══════════════════════════════════════════════

    event Deposited(address indexed sender, uint256 amount);
    event HotSpend(address indexed to, uint256 amount);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );
    event WithdrawalExecuted(uint256 indexed requestId);
    event WithdrawalCancelled(uint256 indexed requestId, address cancelledBy);
    event WithdrawalApprovedByMultisig(uint256 indexed requestId);
    event SpendingLimitChanged(uint256 newLimit, uint256 newEpochDuration);
    event TimelockChanged(uint256 newDuration);
    event GuardianChanged(address indexed guardian, bool added);
    event ConfigChangeScheduled(string configType, uint256 effectiveTime);
    event ConfigChangeCancelled(string configType);

    // ══════════════════════════════════════════════
    //  Errors
    // ══════════════════════════════════════════════

    error NotOwner();
    error NotGuardian();
    error NotOwnerOrGuardian();
    error ExceedsHotBudget(uint256 requested, uint256 available);
    error ExceedsColdBalance(uint256 requested, uint256 available);
    error TimelockNotExpired(uint256 unlockTime, uint256 currentTime);
    error RequestAlreadyExecuted(uint256 requestId);
    error RequestAlreadyCancelled(uint256 requestId);
    error AlreadyApproved(uint256 requestId, address guardian);
    error InvalidThreshold();
    error NoActiveConfigChange();
    error ConfigChangeNotReady();
    error TransferFailed();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidDuration();

    // ══════════════════════════════════════════════
    //  Modifiers
    // ══════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyGuardian() {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && !isGuardian[msg.sender])
            revert NotOwnerOrGuardian();
        _;
    }

    // ══════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════

    /**
     * @param _owner           The vault owner address.
     * @param _spendingLimit   Initial hot spending limit per epoch (in wei).
     * @param _epochDuration   Epoch duration in seconds (e.g., 86400 for 24h).
     * @param _timelockDuration Timelock delay for cold withdrawals in seconds.
     * @param _guardians       Initial guardian addresses.
     * @param _multisigThreshold Number of guardian approvals for instant withdrawal.
     */
    constructor(
        address _owner,
        uint256 _spendingLimit,
        uint256 _epochDuration,
        uint256 _timelockDuration,
        address[] memory _guardians,
        uint256 _multisigThreshold
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_epochDuration == 0) revert InvalidDuration();
        if (_timelockDuration == 0) revert InvalidDuration();
        if (_guardians.length > 0 && _multisigThreshold < 2)
            revert InvalidThreshold();
        if (_multisigThreshold > _guardians.length)
            revert InvalidThreshold();

        owner = _owner;
        spendingLimit = _spendingLimit;
        epochDuration = _epochDuration;
        timelockDuration = _timelockDuration;
        currentEpochStart = block.timestamp;

        for (uint256 i = 0; i < _guardians.length; i++) {
            if (_guardians[i] == address(0)) revert ZeroAddress();
            isGuardian[_guardians[i]] = true;
            guardianList.push(_guardians[i]);
            emit GuardianChanged(_guardians[i], true);
        }
        multisigThreshold = _multisigThreshold;
    }

    // ══════════════════════════════════════════════
    //  Receive / Deposit
    // ══════════════════════════════════════════════

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    function deposit() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ══════════════════════════════════════════════
    //  View Functions
    // ══════════════════════════════════════════════

    function totalBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function remainingHotBudget() public view returns (uint256) {
        uint256 spent = _isEpochExpired() ? 0 : spentInCurrentEpoch;
        uint256 budget = spendingLimit > spent ? spendingLimit - spent : 0;
        uint256 bal = address(this).balance;
        return budget < bal ? budget : bal;
    }

    function hotBalance() external view returns (uint256) {
        return remainingHotBudget();
    }

    function coldBalance() external view returns (uint256) {
        uint256 hot = remainingHotBudget();
        uint256 bal = address(this).balance;
        return bal > hot ? bal - hot : 0;
    }

    function guardianCount() external view returns (uint256) {
        return guardianList.length;
    }

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
        )
    {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        return (
            req.to,
            req.amount,
            req.unlockTime,
            req.executed,
            req.cancelled,
            req.approvalCount
        );
    }

    // ══════════════════════════════════════════════
    //  Hot Balance Operations
    // ══════════════════════════════════════════════

    /**
     * @notice Spend from the hot balance, subject to the per-epoch spending limit.
     * @dev Under coercion, the victim can only transfer up to the remaining hot budget.
     *      The attacker can verify this on-chain — there's no deception involved.
     */
    function hotSpend(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        _resetEpochIfExpired();

        uint256 budget = remainingHotBudget();
        if (amount > budget) revert ExceedsHotBudget(amount, budget);

        spentInCurrentEpoch += amount;

        (bool success,) = to.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit HotSpend(to, amount);
    }

    // ══════════════════════════════════════════════
    //  Cold Vault Operations
    // ══════════════════════════════════════════════

    /**
     * @notice Request a withdrawal from the cold vault. Starts the timelock.
     * @dev The attacker would need to hold the victim for the entire timelock
     *      duration (e.g., 72 hours), which is impractical for most attack scenarios.
     *      Additionally, any guardian can cancel during this period.
     */
    function requestWithdrawal(address payable to, uint256 amount)
        external
        onlyOwner
        returns (uint256 requestId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        // Cold balance = total - hot budget
        _resetEpochIfExpired();
        uint256 cold = address(this).balance - remainingHotBudget();
        if (amount > cold) revert ExceedsColdBalance(amount, cold);

        requestId = nextRequestId++;
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        req.to = to;
        req.amount = amount;
        req.unlockTime = block.timestamp + timelockDuration;

        emit WithdrawalRequested(requestId, to, amount, req.unlockTime);
    }

    /**
     * @notice Execute a withdrawal after the timelock has expired.
     * @dev Anyone can call this once the timelock expires (the funds go to
     *      the pre-specified recipient, not the caller).
     */
    function executeWithdrawal(uint256 requestId) external {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.executed) revert RequestAlreadyExecuted(requestId);
        if (req.cancelled) revert RequestAlreadyCancelled(requestId);

        // Check if multisig has approved (bypass timelock) or timelock expired
        bool multisigApproved = multisigThreshold > 0 &&
            req.approvalCount >= multisigThreshold;

        if (!multisigApproved && block.timestamp < req.unlockTime) {
            revert TimelockNotExpired(req.unlockTime, block.timestamp);
        }

        req.executed = true;

        (bool success,) = req.to.call{value: req.amount}("");
        if (!success) revert TransferFailed();

        emit WithdrawalExecuted(requestId);
    }

    /**
     * @notice Cancel a pending withdrawal. The owner or any guardian can cancel.
     * @dev This is the "panic button" — if the victim is released and realizes
     *      the attacker initiated a withdrawal, they (or a guardian notified
     *      by an alert system) can cancel it before it unlocks.
     */
    function cancelWithdrawal(uint256 requestId) external onlyOwnerOrGuardian {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.executed) revert RequestAlreadyExecuted(requestId);
        if (req.cancelled) revert RequestAlreadyCancelled(requestId);

        req.cancelled = true;

        emit WithdrawalCancelled(requestId, msg.sender);
    }

    /**
     * @notice Guardian approves a withdrawal, potentially bypassing the timelock.
     * @dev Used when the owner legitimately needs quick access and can coordinate
     *      with their guardians. The threshold (e.g., 2-of-3) prevents any single
     *      guardian from unilaterally releasing funds.
     */
    function approveWithdrawal(uint256 requestId) external onlyGuardian {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.executed) revert RequestAlreadyExecuted(requestId);
        if (req.cancelled) revert RequestAlreadyCancelled(requestId);
        if (req.approvedBy[msg.sender]) revert AlreadyApproved(requestId, msg.sender);

        req.approvedBy[msg.sender] = true;
        req.approvalCount++;

        emit WithdrawalApprovedByMultisig(requestId);
    }

    // ══════════════════════════════════════════════
    //  Configuration (Timelocked for security)
    // ══════════════════════════════════════════════

    /**
     * @notice Schedule a spending limit increase (subject to timelock).
     * @dev Decreases take effect immediately (they make the vault more secure).
     *      Increases are delayed to prevent an attacker from forcing the owner
     *      to raise the limit and then drain immediately.
     */
    function setSpendingLimit(uint256 newLimit, uint256 newEpochDuration)
        external
        onlyOwner
    {
        if (newEpochDuration == 0) revert InvalidDuration();

        if (newLimit <= spendingLimit) {
            // Decrease: takes effect immediately (more secure)
            spendingLimit = newLimit;
            epochDuration = newEpochDuration;
            emit SpendingLimitChanged(newLimit, newEpochDuration);
        } else {
            // Increase: must wait for timelock
            pendingLimitChange = PendingConfigChange({
                newValue: newLimit,
                newValue2: newEpochDuration,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("spendingLimit", pendingLimitChange.effectiveTime);
        }
    }

    /// @notice Execute a scheduled spending limit increase after the timelock.
    function executeSpendingLimitChange() external onlyOwner {
        if (!pendingLimitChange.active) revert NoActiveConfigChange();
        if (block.timestamp < pendingLimitChange.effectiveTime)
            revert ConfigChangeNotReady();

        spendingLimit = pendingLimitChange.newValue;
        epochDuration = pendingLimitChange.newValue2;
        pendingLimitChange.active = false;

        emit SpendingLimitChanged(spendingLimit, epochDuration);
    }

    /// @notice Cancel a scheduled spending limit change.
    function cancelSpendingLimitChange() external onlyOwnerOrGuardian {
        pendingLimitChange.active = false;
        emit ConfigChangeCancelled("spendingLimit");
    }

    /**
     * @notice Schedule a timelock duration decrease (subject to current timelock).
     * @dev Increases take effect immediately (more secure).
     *      Decreases are delayed to prevent an attacker from shortening the delay.
     */
    function setTimelockDuration(uint256 newDuration) external onlyOwner {
        if (newDuration == 0) revert InvalidDuration();

        if (newDuration >= timelockDuration) {
            // Increase: takes effect immediately (more secure)
            timelockDuration = newDuration;
            emit TimelockChanged(newDuration);
        } else {
            // Decrease: must wait for current timelock
            pendingTimelockChange = PendingConfigChange({
                newValue: newDuration,
                newValue2: 0,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("timelockDuration", pendingTimelockChange.effectiveTime);
        }
    }

    /// @notice Execute a scheduled timelock decrease after the delay.
    function executeTimelockChange() external onlyOwner {
        if (!pendingTimelockChange.active) revert NoActiveConfigChange();
        if (block.timestamp < pendingTimelockChange.effectiveTime)
            revert ConfigChangeNotReady();

        timelockDuration = pendingTimelockChange.newValue;
        pendingTimelockChange.active = false;

        emit TimelockChanged(timelockDuration);
    }

    /// @notice Cancel a scheduled timelock change.
    function cancelTimelockChange() external onlyOwnerOrGuardian {
        pendingTimelockChange.active = false;
        emit ConfigChangeCancelled("timelockDuration");
    }

    /**
     * @notice Schedule a guardian addition/removal (always subject to timelock).
     */
    function setGuardian(address guardian, bool active) external onlyOwner {
        if (guardian == address(0)) revert ZeroAddress();

        pendingGuardianChange[guardian] = PendingConfigChange({
            newValue: active ? 1 : 0,
            newValue2: 0,
            effectiveTime: block.timestamp + timelockDuration,
            active: true
        });
        emit ConfigChangeScheduled("guardian", pendingGuardianChange[guardian].effectiveTime);
    }

    /// @notice Execute a scheduled guardian change after the timelock.
    function executeGuardianChange(address guardian) external onlyOwner {
        PendingConfigChange storage change = pendingGuardianChange[guardian];
        if (!change.active) revert NoActiveConfigChange();
        if (block.timestamp < change.effectiveTime) revert ConfigChangeNotReady();

        bool adding = change.newValue == 1;
        change.active = false;

        if (adding && !isGuardian[guardian]) {
            isGuardian[guardian] = true;
            guardianList.push(guardian);
            emit GuardianChanged(guardian, true);
        } else if (!adding && isGuardian[guardian]) {
            isGuardian[guardian] = false;
            // Remove from list (swap-and-pop)
            for (uint256 i = 0; i < guardianList.length; i++) {
                if (guardianList[i] == guardian) {
                    guardianList[i] = guardianList[guardianList.length - 1];
                    guardianList.pop();
                    break;
                }
            }
            emit GuardianChanged(guardian, false);
        }
    }

    /// @notice Cancel a scheduled guardian change.
    function cancelGuardianChange(address guardian) external onlyOwnerOrGuardian {
        pendingGuardianChange[guardian].active = false;
        emit ConfigChangeCancelled("guardian");
    }

    /// @notice Set multisig threshold. Subject to timelock implicitly via guardian changes.
    function setMultisigThreshold(uint256 threshold) external onlyOwner {
        if (guardianList.length > 0 && threshold < 2) revert InvalidThreshold();
        if (threshold > guardianList.length) revert InvalidThreshold();
        multisigThreshold = threshold;
    }

    // ══════════════════════════════════════════════
    //  Internal
    // ══════════════════════════════════════════════

    function _isEpochExpired() internal view returns (bool) {
        return block.timestamp >= currentEpochStart + epochDuration;
    }

    function _resetEpochIfExpired() internal {
        if (_isEpochExpired()) {
            currentEpochStart = block.timestamp;
            spentInCurrentEpoch = 0;
        }
    }
}

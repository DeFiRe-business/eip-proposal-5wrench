// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/**
 * @title IERC20
 * @notice Minimal ERC-20 interface required by the vault.
 */
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title CoercionResistantVault
 * @notice Reference implementation of ERC-XXXX: Coercion-Resistant Vault Standard.
 * @dev Protects against physical coercion ("$5 wrench attacks") by partitioning
 *      funds into a rate-limited hot balance and a timelocked/multisig cold vault.
 *
 *      Supports both native ETH and ERC-20 tokens. Each token has independent
 *      spending limits and epoch tracking, but shares the vault's timelock,
 *      guardians, and multisig configuration.
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
        address token;          // address(0) = native ETH
        address payable to;
        uint256 amount;
        uint256 unlockTime;
        bool executed;
        bool cancelled;
        uint256 approvalCount;
        mapping(address => bool) approvedBy;
    }

    struct TokenEpochState {
        uint256 spendingLimit;       // max tokens spendable per epoch
        uint256 epochDuration;       // epoch length in seconds
        uint256 currentEpochStart;   // timestamp when current epoch began
        uint256 spentInCurrentEpoch; // tokens spent so far in current epoch
    }

    struct PendingConfigChange {
        uint256 newValue;
        uint256 newValue2;       // used for epoch duration in spending limit changes
        uint256 effectiveTime;
        bool active;
    }

    // ══════════════════════════════════════════════
    //  Constants
    // ══════════════════════════════════════════════

    /// @notice Sentinel value representing native ETH in token-aware functions.
    address public constant ETH = address(0);

    // ══════════════════════════════════════════════
    //  State
    // ══════════════════════════════════════════════

    address public owner;

    // --- ETH spending limits (kept for backwards compat with ETH-only interface) ---
    uint256 public spendingLimit;
    uint256 public epochDuration;
    uint256 public currentEpochStart;
    uint256 public spentInCurrentEpoch;

    // --- Per-token spending limits ---
    mapping(address => TokenEpochState) public tokenEpochs;

    // --- Cold vault ---
    uint256 public timelockDuration;
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
    mapping(address => PendingConfigChange) public pendingTokenLimitChange;

    // ══════════════════════════════════════════════
    //  Events
    // ══════════════════════════════════════════════

    event Deposited(address indexed sender, uint256 amount);
    event TokenDeposited(address indexed token, address indexed sender, uint256 amount);
    event HotSpend(address indexed to, uint256 amount);
    event TokenHotSpend(address indexed token, address indexed to, uint256 amount);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );
    event WithdrawalExecuted(uint256 indexed requestId);
    event WithdrawalCancelled(uint256 indexed requestId, address cancelledBy);
    event WithdrawalApprovedByMultisig(uint256 indexed requestId);
    event SpendingLimitChanged(uint256 newLimit, uint256 newEpochDuration);
    event TokenSpendingLimitChanged(address indexed token, uint256 newLimit, uint256 newEpochDuration);
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
    error TokenNotConfigured(address token);
    error TokenTransferFailed(address token);

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
     * @param _spendingLimit   Initial ETH hot spending limit per epoch (in wei).
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

    /**
     * @notice Deposit ERC-20 tokens into the vault.
     * @dev Caller must have approved this contract to spend `amount` of `token`.
     *      The token MUST have a spending limit configured via setTokenSpendingLimit()
     *      before deposits are useful (otherwise all tokens are in cold vault with
     *      no hot budget).
     */
    function depositToken(address token, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TokenTransferFailed(token);

        emit TokenDeposited(token, msg.sender, amount);
    }

    // ══════════════════════════════════════════════
    //  View Functions — ETH
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

    // ══════════════════════════════════════════════
    //  View Functions — ERC-20 Tokens
    // ══════════════════════════════════════════════

    /// @notice Returns the total token balance held by the vault.
    function totalTokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns the remaining hot budget for a specific token.
    function remainingTokenHotBudget(address token) public view returns (uint256) {
        TokenEpochState storage state = tokenEpochs[token];
        if (state.epochDuration == 0) return 0; // not configured

        uint256 spent = _isTokenEpochExpired(token) ? 0 : state.spentInCurrentEpoch;
        uint256 budget = state.spendingLimit > spent ? state.spendingLimit - spent : 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        return budget < bal ? budget : bal;
    }

    /// @notice Returns the hot balance for a specific token.
    function tokenHotBalance(address token) external view returns (uint256) {
        return remainingTokenHotBudget(token);
    }

    /// @notice Returns the cold (locked) balance for a specific token.
    function tokenColdBalance(address token) external view returns (uint256) {
        uint256 hot = remainingTokenHotBudget(token);
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > hot ? bal - hot : 0;
    }

    /// @notice Returns the spending limit config for a specific token.
    function tokenSpendingLimit(address token)
        external
        view
        returns (uint256 limit, uint256 epoch)
    {
        TokenEpochState storage state = tokenEpochs[token];
        return (state.spendingLimit, state.epochDuration);
    }

    /// @notice Returns the amount already spent in the current epoch for a token.
    function tokenSpentInCurrentEpoch(address token) external view returns (uint256) {
        return tokenEpochs[token].spentInCurrentEpoch;
    }

    // ══════════════════════════════════════════════
    //  View Functions — General
    // ══════════════════════════════════════════════

    function guardianCount() external view returns (uint256) {
        return guardianList.length;
    }

    function getWithdrawalRequest(uint256 requestId)
        external
        view
        returns (
            address token,
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
            req.token,
            req.to,
            req.amount,
            req.unlockTime,
            req.executed,
            req.cancelled,
            req.approvalCount
        );
    }

    // ══════════════════════════════════════════════
    //  Hot Balance Operations — ETH
    // ══════════════════════════════════════════════

    /**
     * @notice Spend ETH from the hot balance, subject to the per-epoch spending limit.
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
    //  Hot Balance Operations — ERC-20
    // ══════════════════════════════════════════════

    /**
     * @notice Spend ERC-20 tokens from the hot balance, subject to per-token
     *         spending limit.
     * @dev Same rate-limiting logic as ETH hotSpend, but per-token.
     *      Token must be configured via setTokenSpendingLimit() first.
     */
    function hotSpendToken(address token, address to, uint256 amount)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        TokenEpochState storage state = tokenEpochs[token];
        if (state.epochDuration == 0) revert TokenNotConfigured(token);

        _resetTokenEpochIfExpired(token);

        uint256 budget = remainingTokenHotBudget(token);
        if (amount > budget) revert ExceedsHotBudget(amount, budget);

        state.spentInCurrentEpoch += amount;

        bool success = IERC20(token).transfer(to, amount);
        if (!success) revert TokenTransferFailed(token);

        emit TokenHotSpend(token, to, amount);
    }

    // ══════════════════════════════════════════════
    //  Cold Vault Operations (unified ETH + ERC-20)
    // ══════════════════════════════════════════════

    /**
     * @notice Request an ETH withdrawal from the cold vault. Starts the timelock.
     */
    function requestWithdrawal(address payable to, uint256 amount)
        external
        onlyOwner
        returns (uint256 requestId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        _resetEpochIfExpired();
        uint256 cold = address(this).balance - remainingHotBudget();
        if (amount > cold) revert ExceedsColdBalance(amount, cold);

        requestId = _createWithdrawalRequest(ETH, to, amount);
    }

    /**
     * @notice Request a token withdrawal from the cold vault. Starts the timelock.
     * @dev The attacker would need to hold the victim for the entire timelock
     *      duration (e.g., 72 hours), which is impractical for most scenarios.
     *      Additionally, any guardian can cancel during this period.
     */
    function requestTokenWithdrawal(address token, address payable to, uint256 amount)
        external
        onlyOwner
        returns (uint256 requestId)
    {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        _resetTokenEpochIfExpired(token);
        uint256 cold = IERC20(token).balanceOf(address(this)) - remainingTokenHotBudget(token);
        if (amount > cold) revert ExceedsColdBalance(amount, cold);

        requestId = _createWithdrawalRequest(token, to, amount);
    }

    /**
     * @notice Execute a withdrawal (ETH or token) after the timelock has expired.
     * @dev Anyone can call this once the timelock expires. The funds go to
     *      the pre-specified recipient, not the caller. Works for both ETH
     *      and token withdrawals — the token address is stored in the request.
     */
    function executeWithdrawal(uint256 requestId) external {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.executed) revert RequestAlreadyExecuted(requestId);
        if (req.cancelled) revert RequestAlreadyCancelled(requestId);

        bool multisigApproved = multisigThreshold > 0 &&
            req.approvalCount >= multisigThreshold;

        if (!multisigApproved && block.timestamp < req.unlockTime) {
            revert TimelockNotExpired(req.unlockTime, block.timestamp);
        }

        req.executed = true;

        if (req.token == ETH) {
            (bool success,) = req.to.call{value: req.amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(req.token).transfer(req.to, req.amount);
            if (!success) revert TokenTransferFailed(req.token);
        }

        emit WithdrawalExecuted(requestId);
    }

    /**
     * @notice Cancel a pending withdrawal (ETH or token).
     * @dev The owner or any guardian can cancel. This is the "panic button."
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
     * @dev Works for both ETH and token withdrawals.
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
    //  Configuration — ETH Spending Limit
    // ══════════════════════════════════════════════

    /**
     * @notice Schedule an ETH spending limit increase (subject to timelock).
     * @dev Decreases take effect immediately (more secure).
     *      Increases are delayed to prevent an attacker from forcing the owner
     *      to raise the limit and then drain immediately.
     */
    function setSpendingLimit(uint256 newLimit, uint256 newEpochDuration)
        external
        onlyOwner
    {
        if (newEpochDuration == 0) revert InvalidDuration();

        if (newLimit <= spendingLimit) {
            spendingLimit = newLimit;
            epochDuration = newEpochDuration;
            emit SpendingLimitChanged(newLimit, newEpochDuration);
        } else {
            pendingLimitChange = PendingConfigChange({
                newValue: newLimit,
                newValue2: newEpochDuration,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("spendingLimit", pendingLimitChange.effectiveTime);
        }
    }

    /// @notice Execute a scheduled ETH spending limit increase.
    function executeSpendingLimitChange() external onlyOwner {
        if (!pendingLimitChange.active) revert NoActiveConfigChange();
        if (block.timestamp < pendingLimitChange.effectiveTime)
            revert ConfigChangeNotReady();

        spendingLimit = pendingLimitChange.newValue;
        epochDuration = pendingLimitChange.newValue2;
        pendingLimitChange.active = false;

        emit SpendingLimitChanged(spendingLimit, epochDuration);
    }

    /// @notice Cancel a scheduled ETH spending limit change.
    function cancelSpendingLimitChange() external onlyOwnerOrGuardian {
        pendingLimitChange.active = false;
        emit ConfigChangeCancelled("spendingLimit");
    }

    // ══════════════════════════════════════════════
    //  Configuration — Token Spending Limits
    // ══════════════════════════════════════════════

    /**
     * @notice Configure or update the spending limit for an ERC-20 token.
     * @dev First-time configuration takes effect immediately (the token had
     *      no hot budget before, so this only adds capability).
     *      Subsequent increases are timelocked. Decreases are immediate.
     * @param token      The ERC-20 token address.
     * @param newLimit   Max tokens spendable per epoch from hot balance.
     * @param newEpochDuration Epoch duration in seconds for this token.
     */
    function setTokenSpendingLimit(
        address token,
        uint256 newLimit,
        uint256 newEpochDuration
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (newEpochDuration == 0) revert InvalidDuration();

        TokenEpochState storage state = tokenEpochs[token];

        // First-time config or decrease: immediate effect
        if (state.epochDuration == 0 || newLimit <= state.spendingLimit) {
            state.spendingLimit = newLimit;
            state.epochDuration = newEpochDuration;
            if (state.currentEpochStart == 0) {
                state.currentEpochStart = block.timestamp;
            }
            emit TokenSpendingLimitChanged(token, newLimit, newEpochDuration);
        } else {
            // Increase: must wait for timelock
            pendingTokenLimitChange[token] = PendingConfigChange({
                newValue: newLimit,
                newValue2: newEpochDuration,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("tokenSpendingLimit", pendingTokenLimitChange[token].effectiveTime);
        }
    }

    /// @notice Execute a scheduled token spending limit increase.
    function executeTokenSpendingLimitChange(address token) external onlyOwner {
        PendingConfigChange storage change = pendingTokenLimitChange[token];
        if (!change.active) revert NoActiveConfigChange();
        if (block.timestamp < change.effectiveTime) revert ConfigChangeNotReady();

        TokenEpochState storage state = tokenEpochs[token];
        state.spendingLimit = change.newValue;
        state.epochDuration = change.newValue2;
        change.active = false;

        emit TokenSpendingLimitChanged(token, state.spendingLimit, state.epochDuration);
    }

    /// @notice Cancel a scheduled token spending limit change.
    function cancelTokenSpendingLimitChange(address token) external onlyOwnerOrGuardian {
        pendingTokenLimitChange[token].active = false;
        emit ConfigChangeCancelled("tokenSpendingLimit");
    }

    // ══════════════════════════════════════════════
    //  Configuration — Timelock
    // ══════════════════════════════════════════════

    /**
     * @notice Schedule a timelock duration decrease (subject to current timelock).
     * @dev Increases take effect immediately (more secure).
     *      Decreases are delayed to prevent an attacker from shortening the delay.
     *      NOTE: Timelock is shared across ETH and all tokens.
     */
    function setTimelockDuration(uint256 newDuration) external onlyOwner {
        if (newDuration == 0) revert InvalidDuration();

        if (newDuration >= timelockDuration) {
            timelockDuration = newDuration;
            emit TimelockChanged(newDuration);
        } else {
            pendingTimelockChange = PendingConfigChange({
                newValue: newDuration,
                newValue2: 0,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("timelockDuration", pendingTimelockChange.effectiveTime);
        }
    }

    /// @notice Execute a scheduled timelock decrease.
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

    // ══════════════════════════════════════════════
    //  Configuration — Guardians
    // ══════════════════════════════════════════════

    /// @notice Schedule a guardian addition/removal (always subject to timelock).
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

    /// @notice Set multisig threshold.
    function setMultisigThreshold(uint256 threshold) external onlyOwner {
        if (guardianList.length > 0 && threshold < 2) revert InvalidThreshold();
        if (threshold > guardianList.length) revert InvalidThreshold();
        multisigThreshold = threshold;
    }

    // ══════════════════════════════════════════════
    //  Internal — ETH epoch
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

    // ══════════════════════════════════════════════
    //  Internal — Token epoch
    // ══════════════════════════════════════════════

    function _isTokenEpochExpired(address token) internal view returns (bool) {
        TokenEpochState storage state = tokenEpochs[token];
        return block.timestamp >= state.currentEpochStart + state.epochDuration;
    }

    function _resetTokenEpochIfExpired(address token) internal {
        if (_isTokenEpochExpired(token)) {
            TokenEpochState storage state = tokenEpochs[token];
            state.currentEpochStart = block.timestamp;
            state.spentInCurrentEpoch = 0;
        }
    }

    // ══════════════════════════════════════════════
    //  Internal — Shared withdrawal request creation
    // ══════════════════════════════════════════════

    function _createWithdrawalRequest(
        address token,
        address payable to,
        uint256 amount
    ) internal returns (uint256 requestId) {
        requestId = nextRequestId++;
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        req.token = token;
        req.to = to;
        req.amount = amount;
        req.unlockTime = block.timestamp + timelockDuration;

        emit WithdrawalRequested(requestId, token, to, amount, req.unlockTime);
    }
}

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
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title PackedUserOperation
 * @notice ERC-4337 v0.7 packed user operation struct.
 */
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

/**
 * @title IAccount
 * @notice Minimal ERC-4337 account interface (v0.7).
 */
interface IAccount {
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}

/**
 * @title IEntryPoint
 * @notice Minimal EntryPoint interface for deposits.
 */
interface IEntryPoint {
    function depositTo(address account) external payable;
    function getDepositInfo(address account)
        external
        view
        returns (uint112 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime);
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
contract CoercionResistantVault is IAccount {

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

    /// @notice Maximum number of concurrent unresolved withdrawal requests.
    /// @dev Prevents unbounded storage growth and DoS via request spam.
    uint256 public constant MAX_PENDING_WITHDRAWALS = 32;

    /// @notice Maximum duration of a single guardian-initiated pause.
    /// @dev After this period the pause auto-expires unless extended.
    uint256 public constant MAX_PAUSE_DURATION = 24 hours;

    // ══════════════════════════════════════════════
    //  ERC-4337
    // ══════════════════════════════════════════════

    /// @notice The canonical ERC-4337 v0.7 EntryPoint.
    IEntryPoint public immutable entryPoint;

    /// @notice Validation success (SIG_VALIDATION_SUCCESS in ERC-4337).
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;

    /// @notice Validation failure (SIG_VALIDATION_FAILED in ERC-4337).
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

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

    /// @notice Number of currently pending (unresolved) withdrawal requests.
    /// @dev Capped at MAX_PENDING_WITHDRAWALS. Decrements on execution or cancellation.
    uint256 public pendingWithdrawalCount;

    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    // --- Guardians & multisig ---
    mapping(address => bool) public isGuardian;
    address[] public guardianList;
    uint256 public multisigThreshold;

    // --- Whitelisted DeFi targets ---
    mapping(address => bool) public whitelistedTargets;

    // --- Emergency pause ---
    /// @notice Timestamp when current pause expires (0 if not paused).
    uint256 public pausedUntil;

    /// @notice Tracks guardian approvals for an active unpause request.
    /// @dev Keyed by (pausedUntil, guardian) to prevent stale approvals across pauses.
    mapping(uint256 => mapping(address => bool)) public unpauseApprovedBy;

    /// @notice Count of unpause approvals for the current pause.
    mapping(uint256 => uint256) public unpauseApprovalCount;

    // --- Pending configuration changes (timelocked) ---
    PendingConfigChange public pendingLimitChange;
    PendingConfigChange public pendingTimelockChange;
    mapping(address => PendingConfigChange) public pendingGuardianChange;
    mapping(address => PendingConfigChange) public pendingTokenLimitChange;
    mapping(address => PendingConfigChange) public pendingWhitelistChange;

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
    event TokenApproval(address indexed token, address indexed spender, uint256 amount);
    event Executed(address indexed target, uint256 value, bytes data, bytes result);
    event BatchExecuted(uint256 count);
    event TargetWhitelisted(address indexed target, bool allowed);
    event WhitelistChangeScheduled(address indexed target, uint256 effectiveTime);
    event WhitelistChangeCancelled(address indexed target);
    event VaultPaused(address indexed by, uint256 until);
    event VaultUnpaused(address indexed by);
    event UnpauseApproved(address indexed guardian, uint256 approvalCount);

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
    error TargetNotWhitelisted(address target);
    error SelfCallNotAllowed();
    error BatchLengthMismatch();
    error ExecutionFailed(address target, bytes data);
    error SpenderNotWhitelisted(address spender);
    error TokenApprovalFailed(address token, address spender);
    error NotEntryPoint();
    error NotOwnerOrEntryPoint();
    error TooManyPendingWithdrawals(uint256 current, uint256 max);
    error GuardianRemovalWouldBreakThreshold(uint256 remaining, uint256 threshold);
    error VaultPausedError(uint256 until);
    error VaultNotPaused();
    error InsufficientUnpauseApprovals(uint256 current, uint256 required);

    // ══════════════════════════════════════════════
    //  Modifiers
    // ══════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner && msg.sender != address(entryPoint))
            revert NotOwnerOrEntryPoint();
        _;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
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

    /// @notice Blocks execution when the vault is paused.
    /// @dev Applied to value-moving operations. Safety actions (cancel, unpause)
    ///      remain callable to allow response during a pause.
    modifier whenNotPaused() {
        if (_isPaused()) revert VaultPausedError(pausedUntil);
        _;
    }

    // ══════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════

    /**
     * @param _entryPoint      The ERC-4337 EntryPoint address (canonical v0.7:
     *                         0x0000000071727De22E5E9d8BAf0edAc6f37da032).
     * @param _owner           The vault owner address (the signer for UserOps).
     * @param _spendingLimit   Initial ETH hot spending limit per epoch (in wei).
     * @param _epochDuration   Epoch duration in seconds (e.g., 86400 for 24h).
     * @param _timelockDuration Timelock delay for cold withdrawals in seconds.
     * @param _guardians       Initial guardian addresses.
     * @param _multisigThreshold Number of guardian approvals for instant withdrawal.
     */
    constructor(
        IEntryPoint _entryPoint,
        address _owner,
        uint256 _spendingLimit,
        uint256 _epochDuration,
        uint256 _timelockDuration,
        address[] memory _guardians,
        uint256 _multisigThreshold
    ) {
        if (address(_entryPoint) == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        entryPoint = _entryPoint;
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
    //  ERC-4337 — Account Validation
    // ══════════════════════════════════════════════

    /**
     * @notice Validate a UserOperation signature and pay prefund to EntryPoint.
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        validationData = _validateSignature(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    /// @notice Deposit ETH to the EntryPoint to pay for future UserOperations.
    function addDeposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Returns the vault's deposit balance at the EntryPoint.
    function getDeposit() external view returns (uint256) {
        (uint112 deposit,,,,) = entryPoint.getDepositInfo(address(this));
        return deposit;
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

    function totalTokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function remainingTokenHotBudget(address token) public view returns (uint256) {
        TokenEpochState storage state = tokenEpochs[token];
        if (state.epochDuration == 0) return 0;

        uint256 spent = _isTokenEpochExpired(token) ? 0 : state.spentInCurrentEpoch;
        uint256 budget = state.spendingLimit > spent ? state.spendingLimit - spent : 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        return budget < bal ? budget : bal;
    }

    function tokenHotBalance(address token) external view returns (uint256) {
        return remainingTokenHotBudget(token);
    }

    function tokenColdBalance(address token) external view returns (uint256) {
        uint256 hot = remainingTokenHotBudget(token);
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > hot ? bal - hot : 0;
    }

    function tokenSpendingLimit(address token)
        external
        view
        returns (uint256 limit, uint256 epoch)
    {
        TokenEpochState storage state = tokenEpochs[token];
        return (state.spendingLimit, state.epochDuration);
    }

    function tokenSpentInCurrentEpoch(address token) external view returns (uint256) {
        return tokenEpochs[token].spentInCurrentEpoch;
    }

    // ══════════════════════════════════════════════
    //  View Functions — General
    // ══════════════════════════════════════════════

    function guardianCount() external view returns (uint256) {
        return guardianList.length;
    }

    /// @notice Returns true if the vault is currently paused.
    function isPaused() external view returns (bool) {
        return _isPaused();
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
     * @notice Spend ETH from the hot balance, subject to per-epoch spending limit.
     */
    function hotSpend(address payable to, uint256 amount)
        external
        onlyOwner
        whenNotPaused
    {
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
     * @notice Spend ERC-20 tokens from the hot balance.
     */
    function hotSpendToken(address token, address to, uint256 amount)
        external
        onlyOwner
        whenNotPaused
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
        whenNotPaused
        returns (uint256 requestId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (pendingWithdrawalCount >= MAX_PENDING_WITHDRAWALS)
            revert TooManyPendingWithdrawals(pendingWithdrawalCount, MAX_PENDING_WITHDRAWALS);

        _resetEpochIfExpired();
        uint256 cold = address(this).balance - remainingHotBudget();
        if (amount > cold) revert ExceedsColdBalance(amount, cold);

        requestId = _createWithdrawalRequest(ETH, to, amount);
    }

    /**
     * @notice Request a token withdrawal from the cold vault.
     */
    function requestTokenWithdrawal(address token, address payable to, uint256 amount)
        external
        onlyOwner
        whenNotPaused
        returns (uint256 requestId)
    {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (pendingWithdrawalCount >= MAX_PENDING_WITHDRAWALS)
            revert TooManyPendingWithdrawals(pendingWithdrawalCount, MAX_PENDING_WITHDRAWALS);

        _resetTokenEpochIfExpired(token);
        uint256 cold = IERC20(token).balanceOf(address(this)) - remainingTokenHotBudget(token);
        if (amount > cold) revert ExceedsColdBalance(amount, cold);

        requestId = _createWithdrawalRequest(token, to, amount);
    }

    /**
     * @notice Execute a withdrawal (ETH or token) after the timelock has expired.
     * @dev Execution is blocked while the vault is paused. The user's expected
     *      flow during a pause is to either wait for unpause or cancel the request.
     *      If urgent liquidity is needed, guardians can unpause via multisig.
     */
    function executeWithdrawal(uint256 requestId) external whenNotPaused {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.executed) revert RequestAlreadyExecuted(requestId);
        if (req.cancelled) revert RequestAlreadyCancelled(requestId);

        bool multisigApproved = multisigThreshold > 0 &&
            req.approvalCount >= multisigThreshold;

        if (!multisigApproved && block.timestamp < req.unlockTime) {
            revert TimelockNotExpired(req.unlockTime, block.timestamp);
        }

        req.executed = true;
        pendingWithdrawalCount--;

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
     * @dev Callable even while paused — this is a safety action.
     */
    function cancelWithdrawal(uint256 requestId) external onlyOwnerOrGuardian {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.executed) revert RequestAlreadyExecuted(requestId);
        if (req.cancelled) revert RequestAlreadyCancelled(requestId);

        req.cancelled = true;
        pendingWithdrawalCount--;

        emit WithdrawalCancelled(requestId, msg.sender);
    }

    /**
     * @notice Guardian approves a withdrawal, potentially bypassing the timelock.
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
    //  Emergency Pause
    // ══════════════════════════════════════════════

    /**
     * @notice Pause the vault. Any single guardian can invoke this.
     * @dev Sets pausedUntil to block.timestamp + MAX_PAUSE_DURATION.
     *      Calling pause() again while paused resets the auto-expiry timer,
     *      allowing guardians to extend the freeze during sustained attacks.
     *      Blocks hotSpend, hotSpendToken, requestWithdrawal, execute,
     *      executeBatch, approveToken, and executeWithdrawal.
     *      Does NOT block cancelWithdrawal, approveWithdrawal, unpause,
     *      view functions, or deposits.
     */
    function pause() external onlyGuardian {
        uint256 newPausedUntil = block.timestamp + MAX_PAUSE_DURATION;
        pausedUntil = newPausedUntil;

        emit VaultPaused(msg.sender, newPausedUntil);
    }

    /**
     * @notice Guardian approval toward unpausing the vault.
     * @dev When approval count reaches multisigThreshold, the vault is unpaused.
     *      Approvals are scoped to the current pausedUntil timestamp, so
     *      approvals from a previous pause do not carry over.
     */
    function unpause() external onlyGuardian {
        if (!_isPaused()) revert VaultNotPaused();

        uint256 pauseKey = pausedUntil;
        if (unpauseApprovedBy[pauseKey][msg.sender]) {
            revert AlreadyApproved(0, msg.sender);
        }

        unpauseApprovedBy[pauseKey][msg.sender] = true;
        unpauseApprovalCount[pauseKey]++;

        emit UnpauseApproved(msg.sender, unpauseApprovalCount[pauseKey]);

        if (unpauseApprovalCount[pauseKey] >= multisigThreshold) {
            pausedUntil = 0;
            emit VaultUnpaused(msg.sender);
        }
    }

    // ══════════════════════════════════════════════
    //  Configuration — ETH Spending Limit
    // ══════════════════════════════════════════════

    /**
     * @notice Update the ETH spending limit and/or epoch duration.
     * @dev Immediate effect when the change is security-neutral or security-increasing:
     *        - Limit decreases or unchanged AND epoch duration increases or unchanged
     *      Otherwise (limit increase OR epoch duration decrease), change is timelocked.
     *      A shorter epoch with the same limit effectively increases spending rate,
     *      which is why duration decreases are also timelocked.
     */
    function setSpendingLimit(uint256 newLimit, uint256 newEpochDuration)
        external
        onlyOwner
    {
        if (newEpochDuration == 0) revert InvalidDuration();

        bool isLimitIncrease = newLimit > spendingLimit;
        bool isDurationDecrease = newEpochDuration < epochDuration;

        if (isLimitIncrease || isDurationDecrease) {
            // Either change weakens security -> timelock required
            pendingLimitChange = PendingConfigChange({
                newValue: newLimit,
                newValue2: newEpochDuration,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("spendingLimit", pendingLimitChange.effectiveTime);
        } else {
            // Decrease or unchanged limit + increase or unchanged duration -> immediate
            spendingLimit = newLimit;
            epochDuration = newEpochDuration;
            emit SpendingLimitChanged(newLimit, newEpochDuration);
        }
    }

    function executeSpendingLimitChange() external onlyOwner {
        if (!pendingLimitChange.active) revert NoActiveConfigChange();
        if (block.timestamp < pendingLimitChange.effectiveTime)
            revert ConfigChangeNotReady();

        spendingLimit = pendingLimitChange.newValue;
        epochDuration = pendingLimitChange.newValue2;
        pendingLimitChange.active = false;

        emit SpendingLimitChanged(spendingLimit, epochDuration);
    }

    function cancelSpendingLimitChange() external onlyOwnerOrGuardian {
        pendingLimitChange.active = false;
        emit ConfigChangeCancelled("spendingLimit");
    }

    // ══════════════════════════════════════════════
    //  Configuration — Token Spending Limits
    // ══════════════════════════════════════════════

    /**
     * @notice Configure or update the spending limit for an ERC-20 token.
     * @dev First-time configuration is immediate (the token had no hot budget).
     *      Subsequent changes follow the same logic as ETH: limit increases or
     *      epoch duration decreases require timelock.
     */
    function setTokenSpendingLimit(
        address token,
        uint256 newLimit,
        uint256 newEpochDuration
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (newEpochDuration == 0) revert InvalidDuration();

        TokenEpochState storage state = tokenEpochs[token];

        if (state.epochDuration == 0) {
            // First-time config: immediate effect
            state.spendingLimit = newLimit;
            state.epochDuration = newEpochDuration;
            state.currentEpochStart = block.timestamp;
            emit TokenSpendingLimitChanged(token, newLimit, newEpochDuration);
            return;
        }

        bool isLimitIncrease = newLimit > state.spendingLimit;
        bool isDurationDecrease = newEpochDuration < state.epochDuration;

        if (isLimitIncrease || isDurationDecrease) {
            pendingTokenLimitChange[token] = PendingConfigChange({
                newValue: newLimit,
                newValue2: newEpochDuration,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit ConfigChangeScheduled("tokenSpendingLimit", pendingTokenLimitChange[token].effectiveTime);
        } else {
            state.spendingLimit = newLimit;
            state.epochDuration = newEpochDuration;
            emit TokenSpendingLimitChanged(token, newLimit, newEpochDuration);
        }
    }

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

    function cancelTokenSpendingLimitChange(address token) external onlyOwnerOrGuardian {
        pendingTokenLimitChange[token].active = false;
        emit ConfigChangeCancelled("tokenSpendingLimit");
    }

    // ══════════════════════════════════════════════
    //  Configuration — Timelock
    // ══════════════════════════════════════════════

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

    function executeTimelockChange() external onlyOwner {
        if (!pendingTimelockChange.active) revert NoActiveConfigChange();
        if (block.timestamp < pendingTimelockChange.effectiveTime)
            revert ConfigChangeNotReady();

        timelockDuration = pendingTimelockChange.newValue;
        pendingTimelockChange.active = false;

        emit TimelockChanged(timelockDuration);
    }

    function cancelTimelockChange() external onlyOwnerOrGuardian {
        pendingTimelockChange.active = false;
        emit ConfigChangeCancelled("timelockDuration");
    }

    // ══════════════════════════════════════════════
    //  Configuration — Guardians
    // ══════════════════════════════════════════════

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

    /**
     * @notice Execute a scheduled guardian change.
     * @dev If removing a guardian, reverts if the removal would leave
     *      guardianList.length < multisigThreshold. Owner must explicitly
     *      reduce multisigThreshold first.
     */
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
            // Guard: removing this guardian would break multisig threshold
            if (guardianList.length - 1 < multisigThreshold) {
                revert GuardianRemovalWouldBreakThreshold(
                    guardianList.length - 1,
                    multisigThreshold
                );
            }

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

    function cancelGuardianChange(address guardian) external onlyOwnerOrGuardian {
        pendingGuardianChange[guardian].active = false;
        emit ConfigChangeCancelled("guardian");
    }

    function setMultisigThreshold(uint256 threshold) external onlyOwner {
        if (guardianList.length > 0 && threshold < 2) revert InvalidThreshold();
        if (threshold > guardianList.length) revert InvalidThreshold();
        multisigThreshold = threshold;
    }

    // ══════════════════════════════════════════════
    //  DeFi Execution — Whitelisted targets only
    // ══════════════════════════════════════════════

    function isWhitelisted(address target) external view returns (bool) {
        return whitelistedTargets[target];
    }

    function approveToken(address token, address spender, uint256 amount)
        external
        onlyOwner
        whenNotPaused
    {
        if (token == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();
        if (!whitelistedTargets[spender]) revert SpenderNotWhitelisted(spender);

        bool success = IERC20(token).approve(spender, amount);
        if (!success) revert TokenApprovalFailed(token, spender);

        emit TokenApproval(token, spender, amount);
    }

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        whenNotPaused
        returns (bytes memory result)
    {
        if (!whitelistedTargets[target]) revert TargetNotWhitelisted(target);
        if (target == address(this)) revert SelfCallNotAllowed();

        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed(target, result);

        emit Executed(target, value, data, result);
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOwner whenNotPaused returns (bytes[] memory results) {
        uint256 len = targets.length;
        if (len != values.length || len != datas.length)
            revert BatchLengthMismatch();

        results = new bytes[](len);

        for (uint256 i = 0; i < len; i++) {
            if (!whitelistedTargets[targets[i]])
                revert TargetNotWhitelisted(targets[i]);
            if (targets[i] == address(this)) revert SelfCallNotAllowed();

            bool success;
            (success, results[i]) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert ExecutionFailed(targets[i], results[i]);

            emit Executed(targets[i], values[i], datas[i], results[i]);
        }

        emit BatchExecuted(len);
    }

    // ══════════════════════════════════════════════
    //  Configuration — Whitelist
    // ══════════════════════════════════════════════

    function setWhitelistedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this)) revert SelfCallNotAllowed();

        if (!allowed && whitelistedTargets[target]) {
            whitelistedTargets[target] = false;
            emit TargetWhitelisted(target, false);
        } else if (allowed && !whitelistedTargets[target]) {
            pendingWhitelistChange[target] = PendingConfigChange({
                newValue: 1,
                newValue2: 0,
                effectiveTime: block.timestamp + timelockDuration,
                active: true
            });
            emit WhitelistChangeScheduled(target, pendingWhitelistChange[target].effectiveTime);
        }
    }

    function executeWhitelistChange(address target) external onlyOwner {
        PendingConfigChange storage change = pendingWhitelistChange[target];
        if (!change.active) revert NoActiveConfigChange();
        if (block.timestamp < change.effectiveTime) revert ConfigChangeNotReady();

        change.active = false;
        whitelistedTargets[target] = true;

        emit TargetWhitelisted(target, true);
    }

    function cancelWhitelistChange(address target) external onlyOwnerOrGuardian {
        pendingWhitelistChange[target].active = false;
        emit WhitelistChangeCancelled(target);
    }

    // ══════════════════════════════════════════════
    //  Internal — Pause
    // ══════════════════════════════════════════════

    function _isPaused() internal view returns (bool) {
        return pausedUntil != 0 && block.timestamp < pausedUntil;
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

        pendingWithdrawalCount++;

        emit WithdrawalRequested(requestId, token, to, amount, req.unlockTime);
    }

    // ══════════════════════════════════════════════
    //  Internal — ERC-4337 signature validation
    // ══════════════════════════════════════════════

    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view returns (uint256 validationData) {
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash)
        );

        bytes calldata sig = userOp.signature;
        if (sig.length != 65) return SIG_VALIDATION_FAILED;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }

        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)
            return SIG_VALIDATION_FAILED;

        address recovered = ecrecover(ethSignedHash, v, r, s);
        if (recovered == address(0) || recovered != owner)
            return SIG_VALIDATION_FAILED;

        return SIG_VALIDATION_SUCCESS;
    }

    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds > 0) {
            (bool success,) = payable(msg.sender).call{
                value: missingAccountFunds,
                gas: type(uint256).max
            }("");
            (success);
        }
    }
}

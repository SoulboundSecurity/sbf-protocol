// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

/**
 * @title IERC20Send — Minimal send-only interface (no transferFrom)
 */
interface IERC20Send {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title IERC20Approve — Minimal approve interface for pull-style integrations
 */
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title ClaimPool
 * @notice Processes anonymous OTU redemptions across multiple tokens
 * @custom:security-contact security@soulbound.finance
 */
contract ClaimPool {
    // ─── Access Control ────────────────────────────────────────────────

    address public operator;           // Backend operator (processes redemptions)
    address public depositPool;        // Only source of inbound funds
    address public gasManager;         // Can use gas fund for DeFi ops
    address public constant ETH = address(0);

    // ─── Per-Token Balances ────────────────────────────────────────────

    mapping(address => uint256) public redemptionBalance;  // token => available for redemptions
    mapping(address => uint256) public gasFundBalance;     // token => gas fund reserve

    // ─── Statistics ────────────────────────────────────────────────────

    uint256 public totalRedemptions;
    mapping(address => uint256) public totalRedeemed;       // token => total redeemed
    mapping(address => uint256) public totalGasFeesCollected;

    // Security
    uint256 public maxBatchSize;
    mapping(bytes32 => bool) public processedRedemptions;   // Double-spend prevention
    mapping(address => bool) public approvedTargets;       // For gas fund operations, whitelist of approved target addresses (defense in depth)

    // ─── Events ────────────────────────────────────────────────────────

    event FundsReceived(address indexed token, uint256 otuAmount, uint256 gasFee);
    event Redeemed(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        bytes32 indexed redemptionHash,
        uint256 timestamp
    );
    event BatchRedeemed(address indexed token, uint256 count, uint256 totalAmount);
    event GasFundUsed(address indexed token, address indexed target, uint256 amount, string purpose);
    event GasFundDeposited(address indexed from, uint256 amount);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event GasManagerChanged(address indexed oldManager, address indexed newManager);
    event DepositPoolSet(address indexed depositPool);
    event TargetWhitelisted(address indexed target, bool approved);

    // ─── Errors ────────────────────────────────────────────────────────

    error UnauthorizedAccess();
    error InvalidAmount();
    error InsufficientBalance();
    error TransferFailed();
    error AlreadyRedeemed();
    error InvalidAddress();
    error InvalidArrayLength();
    error AlreadyConfigured();
    error TargetNotWhitelisted();

    // ─── Modifiers ─────────────────────────────────────────────────────

    modifier onlyOperator() {
        if (msg.sender != operator) revert UnauthorizedAccess();
        _;
    }

    modifier onlyDepositPool() {
        if (msg.sender != depositPool) revert UnauthorizedAccess();
        _;
    }

    modifier onlyGasManager() {
        if (msg.sender != gasManager) revert UnauthorizedAccess();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────

    constructor() {
        operator = msg.sender;
        maxBatchSize = 50;
        emit OperatorChanged(address(0), msg.sender);
    }

    // ─── Fund Reception (from DepositPool only) ────────────────────────

    /**
     * @notice Receive ERC-20 funds from DepositPool with accounting breakdown
     * @param token ERC-20 token address
     * @param otuAmount Amount reserved for OTU redemptions
     * @param gasFee Amount reserved for gas fund
     */
    function receiveFunds(address token, uint256 otuAmount, uint256 gasFee) external onlyDepositPool {
        redemptionBalance[token] += otuAmount;
        gasFundBalance[token] += gasFee;
        totalGasFeesCollected[token] += gasFee;

        emit FundsReceived(token, otuAmount, gasFee);
    }

    /**
     * @notice Receive native ETH from DepositPool
     */
    function receiveFundsETH(uint256 otuAmount, uint256 gasFee) external payable onlyDepositPool {
        if (msg.value != otuAmount + gasFee) revert InvalidAmount();

        redemptionBalance[ETH] += otuAmount;
        gasFundBalance[ETH] += gasFee;
        totalGasFeesCollected[ETH] += gasFee;

        emit FundsReceived(ETH, otuAmount, gasFee);
    }

    // ─── Redemptions ───────────────────────────────────────────────────

    /**
     * @notice Process single OTU redemption
     * @param recipient Address to receive funds (ephemeral — not stored beyond this tx)
     * @param token Token to redeem
     * @param amount Amount to transfer
     * @param redemptionHash Hash of OTU code (idempotency/double-spend prevention)
     */
    function processRedemption(
        address recipient,
        address token,
        uint256 amount,
        bytes32 redemptionHash
    ) external onlyOperator validAddress(recipient) {
        if (amount == 0) revert InvalidAmount();
        if (redemptionBalance[token] < amount) revert InsufficientBalance();
        if (processedRedemptions[redemptionHash]) revert AlreadyRedeemed();

        // CEI pattern
        processedRedemptions[redemptionHash] = true;
        totalRedeemed[token] += amount;
        unchecked { ++totalRedemptions; }
        redemptionBalance[token] -= amount;

        _transfer(token, recipient, amount);

        emit Redeemed(recipient, token, amount, redemptionHash, block.timestamp);
    }

    /**
     * @notice Process batch redemptions for timing obfuscation
     * @param recipients Array of recipient addresses
     * @param token Token to redeem (single token per batch for gas efficiency)
     * @param amounts Array of amounts
     * @param redemptionHashes Array of redemption hashes
     */
    function batchProcessRedemptions(
        address[] calldata recipients,
        address token,
        uint256[] calldata amounts,
        bytes32[] calldata redemptionHashes
    ) external onlyOperator {
        uint256 length = recipients.length;
        if (length == 0 || length > maxBatchSize) revert InvalidArrayLength();
        if (length != amounts.length || length != redemptionHashes.length) revert InvalidArrayLength();

        uint256 totalAmount = 0;
        uint256 processedCount = 0;

        // Pre-calculate total (must match execution loop filter exactly)
        for (uint256 i = 0; i < length;) {
            if (!processedRedemptions[redemptionHashes[i]] && amounts[i] > 0 && recipients[i] != address(0)) {
                totalAmount += amounts[i];
            }
            unchecked { ++i; }
        }
        if (redemptionBalance[token] < totalAmount) revert InsufficientBalance();

        // Process
        uint256 actualTotal = 0;
        for (uint256 i = 0; i < length;) {
            if (processedRedemptions[redemptionHashes[i]] || amounts[i] == 0 || recipients[i] == address(0)) {
                unchecked { ++i; }
                continue;
            }

            processedRedemptions[redemptionHashes[i]] = true;
            redemptionBalance[token] -= amounts[i];
            actualTotal += amounts[i];
            unchecked {
                ++totalRedemptions;
                ++processedCount;
            }

            _transfer(token, recipients[i], amounts[i]);

            emit Redeemed(recipients[i], token, amounts[i], redemptionHashes[i], block.timestamp);
            unchecked { ++i; }
        }

        totalRedeemed[token] += actualTotal;
        emit BatchRedeemed(token, processedCount, actualTotal);
    }

    // ─── Gas Fund Operations ───────────────────────────────────────────

    /**
     * @notice Deposit ETH into gas fund — for swap proceeds or direct top-ups
     */
    function depositGasFundETH() external payable onlyGasManager {
        if (msg.value == 0) revert InvalidAmount();

        gasFundBalance[ETH] += msg.value;

        emit GasFundDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Use gas fund — push-style. Transfers tokens to target, then calls target.
     * @param token Token to use from gas fund (ETH = address(0))
     * @param amount Amount to use
     * @param target Recipient address — must accept pushed tokens directly
     *               (EOA wallets, custom receiver contracts, or any target that does
     *               NOT rely on transferFrom to pull). For pull-style targets like
     *               Aave / Compound / Uniswap, use useGasFundApprove instead.
     * @param data Optional call data executed against target after transfer (no-op if empty)
     * @param purpose Description for audit trail
     */
    function useGasFund(
        address token,
        uint256 amount,
        address target,
        bytes calldata data,
        string calldata purpose
    ) external onlyGasManager validAddress(target) {
        if (amount == 0) revert InvalidAmount();
        if (!approvedTargets[target]) revert TargetNotWhitelisted();
        if (gasFundBalance[token] < amount) revert InsufficientBalance();

        gasFundBalance[token] -= amount;

        if (token == ETH) {
            (bool success,) = target.call{value: amount}(data);
            if (!success) revert TransferFailed();
        } else {
            // For ERC-20 gas fund operations, transfer tokens then call
            bool success = IERC20Send(token).transfer(target, amount);
            if (!success) revert TransferFailed();
            if (data.length > 0) {
                (bool callSuccess,) = target.call(data);
                if (!callSuccess) revert TransferFailed();
            }
        }

        emit GasFundUsed(token, target, amount, purpose);
    }

    /**
     * @notice Use gas fund — pull-style. Grants target an allowance, executes call, resets allowance to zero.
     * @param token ERC-20 token from gas fund (ETH not supported — use useGasFund for native)
     * @param amount Amount to make available to target via allowance
     * @param target Contract that pulls tokens via transferFrom (Aave Pool.supply, Compound cToken.mint,
     *               Uniswap router swaps, etc.)
     * @param data Call data executed against target after approval — required (zero-length reverts)
     * @param purpose Description for audit trail
     * @dev Non-compliant tokens that omit the bool return from approve() (e.g. USDT) are
     *      explicitly NOT supported. The bool return is required by ERC-20; tokens that
     *      omit it will revert the EVM ABI decode and this function will revert. Use a
     *      compliant token or a wrapper. We do not muddy this code path to accommodate
     *      tokens that fail to write proper ERC-20.
     */
    function useGasFundApprove(
        address token,
        uint256 amount,
        address target,
        bytes calldata data,
        string calldata purpose
    ) external onlyGasManager validAddress(target) {
        if (amount == 0) revert InvalidAmount();
        if (!approvedTargets[target]) revert TargetNotWhitelisted();
        if (token == ETH) revert InvalidAddress();
        if (gasFundBalance[token] < amount) revert InsufficientBalance();
        if (data.length == 0) revert InvalidArrayLength();

        gasFundBalance[token] -= amount;

        if (!IERC20Approve(token).approve(target, amount)) revert TransferFailed();

        (bool callSuccess,) = target.call(data);
        if (!callSuccess) revert TransferFailed();

        // Reset allowance to zero — defense in depth against any residual approval
        if (!IERC20Approve(token).approve(target, 0)) revert TransferFailed();

        emit GasFundUsed(token, target, amount, purpose);
    }

    // ─── Internal ──────────────────────────────────────────────────────

    function _transfer(address token, address to, uint256 amount) internal {
        if (token == ETH) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20Send(token).transfer(to, amount);
            if (!success) revert TransferFailed();
        }
    }

    // ─── Admin ─────────────────────────────────────────────────────────

    function setDepositPool(address _depositPool) external onlyOperator validAddress(_depositPool) {
        if (depositPool != address(0)) revert AlreadyConfigured();
        depositPool = _depositPool;
        emit DepositPoolSet(_depositPool);
    }

    function setGasManager(address _gasManager) external onlyOperator validAddress(_gasManager) {
        address old = gasManager;
        gasManager = _gasManager;
        emit GasManagerChanged(old, _gasManager);
    }

    function changeOperator(address newOperator) external onlyOperator validAddress(newOperator) {
        address old = operator;
        operator = newOperator;
        emit OperatorChanged(old, newOperator);
    }

        /**
     * @notice Adds or removes a target address from the whitelist for Gas Manager operations
     * @param target The external contract address to authorize or revoke
     * @param approved Boolean indicating if the target is permitted for interaction
     * @dev Enforces strict protocol boundaries. Prevents arbitrary interactions with token 
     *      contracts to ensure redemption balances remain strictly isolated, while permitting 
     *      the gas fund to route through vetted integrations. This defense-in-depth 
     *      measure ensures the Gas Manager operates within a predictable, restricted execution environment.
     */
    function setApprovedTarget(address target, bool approved) external onlyOperator {
        if (target == address(0)) revert InvalidAddress();
        approvedTargets[target] = approved;
        emit TargetWhitelisted(target, approved);
    }

    // ─── View Functions ────────────────────────────────────────────────

    function getPoolStats(address token) external view returns (
        uint256 totalBalance,
        uint256 redemptionBal,
        uint256 gasFundBal,
        uint256 gasFeesCollected
    ) {
        uint256 balance = token == ETH
            ? address(this).balance
            : IERC20Send(token).balanceOf(address(this));
        return (balance, redemptionBalance[token], gasFundBalance[token], totalGasFeesCollected[token]);
    }

    function isRedeemed(bytes32 redemptionHash) external view returns (bool) {
        return processedRedemptions[redemptionHash];
    }

    // Accept ETH from DepositPool (fund reception) or gasManager (swap proceeds / top-ups)
    receive() external payable {
        if (msg.sender == gasManager) {
            gasFundBalance[ETH] += msg.value;
            emit GasFundDeposited(msg.sender, msg.value);
            return;
        }
        if (msg.sender != depositPool) revert UnauthorizedAccess();
    }
}

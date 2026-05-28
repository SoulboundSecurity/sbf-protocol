// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "./interfaces/ISoulBoundToken.sol";

/**
 * @title IERC20 — Minimal interface for token interactions
 */
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title IClaimPool — Interface for fund reception
 */
interface IClaimPool {
    function receiveFunds(address token, uint256 otuAmount, uint256 gasFee) external;
    function receiveFundsETH(uint256 otuAmount, uint256 gasFee) external payable;
}

/**
 * @title DepositPool
 * @notice Manages multi-token deposits and OTU generation with per-transaction fee attestation
 * @dev SBT-gated access. Fee tier is per-transaction via EIP-712 signed attestation, NOT per-user.
 *      Same user can do charitable OTUs and commercial OTUs from the same account.
 *
 *      Fee flow on generateOTU:
 *        1. Protocol fee → protocolTreasury (direct transfer)
 *        2. OTU amount + gas fee → ClaimPool (via receiveFunds/receiveFundsETH)
 *
 *      Fee structure (on top of OTU amount):
 *        Charitable: 1.00% protocol + 0.25% gas = 1.25% total
 *        Commercial: 2.00% protocol + 0.25% gas = 2.25% total (disabled at launch)
 *
 * @custom:security-contact security@soulbound.finance
 */
contract DepositPool {
    // ─── Types ─────────────────────────────────────────────────────────

    enum FeeTier { CHARITABLE, COMMERCIAL }

    // EIP-712 domain separator components
    bytes32 private immutable DOMAIN_SEPARATOR;
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "OTUAttestation(address depositor,address token,uint256 amount,uint8 feeTier,uint256 nonce,string purpose)"
    );

    // Purpose strings — show in MetaMask signing prompt via EIP-712 typed data
    string private constant CHARITABLE_PURPOSE =
        "I attest this withdrawal is for charitable, donation, or personal gift purposes";
    string private constant COMMERCIAL_PURPOSE =
        "I attest this withdrawal is for commercial or business purposes";
    bytes32 private constant CHARITABLE_PURPOSE_HASH = keccak256(bytes(CHARITABLE_PURPOSE));
    bytes32 private constant COMMERCIAL_PURPOSE_HASH = keccak256(bytes(COMMERCIAL_PURPOSE));

    // ─── Immutables & Config ───────────────────────────────────────────

    ISoulBoundToken public immutable sbtContract;
    address public controller;                    // Multisig for governance

    // Token whitelist
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;
    address public constant ETH = address(0);     // Sentinel for native ETH

    // Fee configuration (basis points)
    uint256 public constant GAS_FEE_BPS = 25;     // 0.25% — always, immutable
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Per-tier protocol fee (modifiable by controller, capped at 5%)
    uint256 public charitableFeeBps = 100;         // 1.00%
    uint256 public commercialFeeBps = 200;         // 2.00%
    bool public commercialEnabled = false;          // Hard-disabled at launch

    // ─── State ─────────────────────────────────────────────────────────

    mapping(address => mapping(address => uint256)) private _balances; // user => token => balance
    mapping(address => uint256) public totalDeposited;                 // token => total
    uint256 public totalOTUsGenerated;

    address public claimPool;
    address public protocolTreasury;

    // ─── Events ────────────────────────────────────────────────────────

    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 newBalance);
    event DepositedETH(address indexed user, uint256 amount, uint256 newBalance);
    event OTUGenerated(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 protocolFee,
        uint256 gasFee,
        FeeTier tier,
        uint256 nonce
    );
    event ClaimPoolSet(address indexed claimPool);
    event ProtocolTreasurySet(address indexed treasury);
    event EmergencyWithdrawal(address indexed user, address indexed token, uint256 amount);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event CommercialToggled(bool enabled);
    event FeesUpdated(uint256 charitableBps, uint256 commercialBps);
    event ControllerTransferred(address indexed oldController, address indexed newController);

    // ─── Errors ────────────────────────────────────────────────────────

    error UnauthorizedAccess();
    error InsufficientBalance();
    error InvalidAmount();
    error TransferFailed();
    error ContractNotConfigured();
    error AlreadyConfigured();
    error InvalidAddress();
    error UnsupportedToken();
    error CommercialDisabled();
    error InvalidAttestation();
    error FeeTooHigh();

    // ─── Modifiers ─────────────────────────────────────────────────────

    modifier onlySBTHolder() {
        if (!sbtContract.hasSBT(msg.sender)) revert UnauthorizedAccess();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert UnauthorizedAccess();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    modifier configured() {
        if (claimPool == address(0) || protocolTreasury == address(0)) revert ContractNotConfigured();
        _;
    }

    modifier tokenSupported(address token) {
        if (!supportedTokens[token]) revert UnsupportedToken();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────

    constructor(address _sbtContract, address _controller)
        validAddress(_sbtContract)
        validAddress(_controller)
    {
        sbtContract = ISoulBoundToken(_sbtContract);
        controller = _controller;

        // Native ETH always supported
        supportedTokens[ETH] = true;
        tokenList.push(ETH);

        // EIP-712 domain separator (immutable, bound to this contract + chain)
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("SoulBound Finance"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    // ─── Token Whitelist ───────────────────────────────────────────────

    function addToken(address token) external onlyController validAddress(token) {
        if (supportedTokens[token]) return;
        supportedTokens[token] = true;
        tokenList.push(token);
        emit TokenAdded(token);
    }

    function removeToken(address token) external onlyController {
        if (token == ETH) revert InvalidAddress();
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    // ─── Deposits (No Fees) ────────────────────────────────────────────

    /**
     * @notice Deposit ERC-20 tokens
     * @param token ERC-20 token address (must be whitelisted)
     * @param amount Amount to deposit (requires prior approval)
     */
    function deposit(address token, uint256 amount)
        external
        onlySBTHolder
        tokenSupported(token)
    {
        if (token == ETH) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        _balances[msg.sender][token] += amount;
        totalDeposited[token] += amount;

        emit Deposited(msg.sender, token, amount, _balances[msg.sender][token]);
    }

    /**
     * @notice Deposit native ETH
     */
    function depositETH() external payable onlySBTHolder {
        if (msg.value == 0) revert InvalidAmount();

        _balances[msg.sender][ETH] += msg.value;
        totalDeposited[ETH] += msg.value;

        emit DepositedETH(msg.sender, msg.value, _balances[msg.sender][ETH]);
    }

    // ─── OTU Generation (Per-Transaction Fee Attestation) ──────────────

    /**
     * @notice Generate OTU with per-transaction fee attestation
     * @param token Token address (address(0) for ETH)
     * @param amount OTU face value — fees are charged ON TOP
     * @param tier CHARITABLE (1% + 0.25%) or COMMERCIAL (2% + 0.25%, when enabled)
     * @param attestationSig EIP-712 signature from user attesting to purpose
     */
    function generateOTU(
        address token,
        uint256 amount,
        FeeTier tier,
        bytes calldata attestationSig
    ) external onlySBTHolder configured tokenSupported(token) {
        if (amount == 0) revert InvalidAmount();
        if (tier == FeeTier.COMMERCIAL && !commercialEnabled) revert CommercialDisabled();

        // Get nonce from SBT (prevents attestation replay)
        (, uint256 currentNonce) = sbtContract.getAccountData(msg.sender);

        // Verify EIP-712 attestation
        _verifyAttestation(msg.sender, token, amount, tier, currentNonce, attestationSig);

        // Calculate fees on top
        uint256 protocolFeeBps = tier == FeeTier.CHARITABLE ? charitableFeeBps : commercialFeeBps;
        uint256 protocolFee = (amount * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 gasFee = (amount * GAS_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalRequired = amount + protocolFee + gasFee;

        if (_balances[msg.sender][token] < totalRequired) revert InsufficientBalance();

        // CEI: update state before external calls
        _balances[msg.sender][token] -= totalRequired;
        totalDeposited[token] -= totalRequired;
        unchecked { ++totalOTUsGenerated; }

        // Increment SBT nonce (invalidates this attestation sig for replay)
        uint256 newNonce = sbtContract.incrementNonce(msg.sender);

        // Distribute: protocol fee → treasury, OTU + gas → ClaimPool
        if (token == ETH) {
            _distributeETH(amount, protocolFee, gasFee);
        } else {
            _distributeERC20(token, amount, protocolFee, gasFee);
        }

        emit OTUGenerated(msg.sender, token, amount, protocolFee, gasFee, tier, newNonce);

        // NOTE: Actual OTU code generated OFF-CHAIN by backend. Never on-chain.
    }

    // ─── Fee Distribution (Internal) ───────────────────────────────────

    function _distributeETH(uint256 otuAmount, uint256 protocolFee, uint256 gasFee) internal {
        // 1. Protocol fee → treasury
        (bool s1,) = protocolTreasury.call{value: protocolFee}("");
        if (!s1) revert TransferFailed();

        // 2. OTU + gas → ClaimPool (explicit function call with accounting)
        IClaimPool(claimPool).receiveFundsETH{value: otuAmount + gasFee}(otuAmount, gasFee);
    }

    function _distributeERC20(address token, uint256 otuAmount, uint256 protocolFee, uint256 gasFee) internal {
        // 1. Protocol fee → treasury
        bool s1 = IERC20(token).transfer(protocolTreasury, protocolFee);
        if (!s1) revert TransferFailed();

        // 2. Tokens → ClaimPool, then accounting call
        uint256 claimAmount = otuAmount + gasFee;
        bool s2 = IERC20(token).transfer(claimPool, claimAmount);
        if (!s2) revert TransferFailed();

        IClaimPool(claimPool).receiveFunds(token, otuAmount, gasFee);
    }

    // ─── EIP-712 Attestation Verification ──────────────────────────────

    function _verifyAttestation(
        address depositor,
        address token,
        uint256 amount,
        FeeTier tier,
        uint256 nonce,
        bytes calldata sig
    ) internal view {
        bytes32 purposeHash = tier == FeeTier.CHARITABLE
            ? CHARITABLE_PURPOSE_HASH
            : COMMERCIAL_PURPOSE_HASH;

        bytes32 structHash = keccak256(abi.encode(
            ATTESTATION_TYPEHASH,
            depositor,
            token,
            amount,
            uint8(tier),
            nonce,
            purposeHash
        ));

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            structHash
        ));

        address recovered = _recoverSigner(digest, sig);
        if (recovered != depositor) revert InvalidAttestation();
    }

    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert InvalidAttestation();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        // EIP-2: restrict s to lower half order to prevent signature malleability
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidAttestation();
        }
        if (v != 27 && v != 28) revert InvalidAttestation();

        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert InvalidAttestation();
        return recovered;
    }

    // ─── Controller Functions ──────────────────────────────────────────

    function setClaimPool(address _claimPool) external onlyController validAddress(_claimPool) {
        if (claimPool != address(0)) revert AlreadyConfigured();
        claimPool = _claimPool;
        emit ClaimPoolSet(_claimPool);
    }

    /**
     * @notice Set protocol treasury (can be updated — not one-time)
     */
    function setProtocolTreasury(address _treasury) external onlyController validAddress(_treasury) {
        protocolTreasury = _treasury;
        emit ProtocolTreasurySet(_treasury);
    }

    function toggleCommercial(bool enabled) external onlyController {
        commercialEnabled = enabled;
        emit CommercialToggled(enabled);
    }

    /**
     * @notice Update fee rates (capped at 500 bps / 5% each)
     * @dev Gas fee is immutable once deployed
     */
    function updateFees(uint256 _charitableBps, uint256 _commercialBps) external onlyController {
        if (_charitableBps > 500 || _commercialBps > 500) revert FeeTooHigh();
        charitableFeeBps = _charitableBps;
        commercialFeeBps = _commercialBps;
        emit FeesUpdated(_charitableBps, _commercialBps);
    }

    function transferController(address _newController) external onlyController validAddress(_newController) {
        address old = controller;
        controller = _newController;
        emit ControllerTransferred(old, _newController);
    }

    // ─── Emergency ─────────────────────────────────────────────────────

    /**
     * @notice Emergency withdrawal — returns user's full balance for a token
     * @param token Token to withdraw (address(0) for ETH)
     * @dev No fees. No token whitelist check — must work even if token is delisted.
     */
    function emergencyWithdraw(address token) external onlySBTHolder {
        uint256 amount = _balances[msg.sender][token];
        if (amount == 0) revert InsufficientBalance();

        _balances[msg.sender][token] = 0;
        totalDeposited[token] -= amount;

        if (token == ETH) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(token).transfer(msg.sender, amount);
            if (!success) revert TransferFailed();
        }

        emit EmergencyWithdrawal(msg.sender, token, amount);
    }

    // ─── View Functions ────────────────────────────────────────────────

    function getBalance(address user, address token) external view returns (uint256) {
        return _balances[user][token];
    }

    /**
     * @notice Calculate fees for a given amount and tier
     * @return protocolFee Protocol fee amount
     * @return gasFee Gas fund fee amount
     * @return totalFees Sum of all fees
     * @return totalRequired OTU amount + all fees (what gets deducted from balance)
     */
    function calculateFees(uint256 amount, FeeTier tier) external view returns (
        uint256 protocolFee,
        uint256 gasFee,
        uint256 totalFees,
        uint256 totalRequired
    ) {
        uint256 protocolBps = tier == FeeTier.CHARITABLE ? charitableFeeBps : commercialFeeBps;
        protocolFee = (amount * protocolBps) / BPS_DENOMINATOR;
        gasFee = (amount * GAS_FEE_BPS) / BPS_DENOMINATOR;
        totalFees = protocolFee + gasFee;
        totalRequired = amount + totalFees;
    }

    function canGenerateOTU(address user, address token, uint256 amount, FeeTier tier) external view returns (bool) {
        if (!sbtContract.hasSBT(user) || amount == 0) return false;
        if (claimPool == address(0) || protocolTreasury == address(0)) return false;
        if (!supportedTokens[token]) return false;
        if (tier == FeeTier.COMMERCIAL && !commercialEnabled) return false;

        uint256 protocolBps = tier == FeeTier.CHARITABLE ? charitableFeeBps : commercialFeeBps;
        uint256 totalRequired = amount + (amount * (protocolBps + GAS_FEE_BPS)) / BPS_DENOMINATOR;
        return _balances[user][token] >= totalRequired;
    }

    function getConfiguration() external view returns (
        bool ready,
        address claimPoolAddr,
        address treasuryAddr
    ) {
        return (
            claimPool != address(0) && protocolTreasury != address(0),
            claimPool,
            protocolTreasury
        );
    }

    function getPoolStats(address token) external view returns (
        uint256 totalDeposits,
        uint256 totalOTUs,
        uint256 poolBalance
    ) {
        uint256 balance = token == ETH
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        return (totalDeposited[token], totalOTUsGenerated, balance);
    }

    function isConfigured() external view returns (bool) {
        return claimPool != address(0) && protocolTreasury != address(0);
    }

    function getTokenList() external view returns (address[] memory) {
        return tokenList;
    }

    /**
     * @notice Get EIP-712 domain separator for frontend signature construction
     */
    function getDomainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    /**
     * @notice Get attestation type hash for frontend signature construction
     */
    function getAttestationTypehash() external pure returns (bytes32) {
        return ATTESTATION_TYPEHASH;
    }

    // Accept ETH (for depositETH)
    receive() external payable {}
}

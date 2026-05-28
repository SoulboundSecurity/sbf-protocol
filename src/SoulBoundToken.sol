// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "./interfaces/ISoulBoundToken.sol";

/**
 * @title SoulBoundToken
 * @notice Non-transferable token representing persistent user identity
 * @custom:security-contact security@soulbound.finance
 */
contract SoulBoundToken is ISoulBoundToken {
    string private constant ACCOUNT_ID_SALT = "YOURSALT";

    struct SBTData {
        bytes32 soulboundId;         // Canonically derived identifier (never raw address)
        bytes32 zkpCommitment;       // Privado ID ZKP commitment hash
        uint256 nonce;               // OTU generation counter (prevents replay)
        uint256 mintedAt;            // Creation timestamp
        bytes32 eulaHash;            // Hash of EULA accepted at mint
        bool exists;                 // Existence flag
    }

    // State variables
    mapping(address => SBTData) private _sbtRegistry;
    uint256 private _totalSBTs;
    address public depositPoolContract;

    // Current EULA — must match at mint time
    bytes32 public currentEulaHash;
    address public controller;

    // Events
    event SBTMinted(
        address indexed owner,
        bytes32 indexed soulboundId,
        bytes32 zkpCommitment,
        bytes32 eulaHash,
        uint256 timestamp
    );
    event NonceIncremented(address indexed owner, uint256 newNonce);
    event DepositPoolSet(address indexed depositPool);
    event EulaUpdated(bytes32 indexed oldHash, bytes32 indexed newHash);
    event ZKPCommitmentUpdated(address indexed owner, bytes32 newCommitment);
    event ControllerTransferred(address indexed oldController, address indexed newController);

    // Errors
    error SBTAlreadyExists();
    error InvalidZKPCommitment();
    error SBTNotFound();
    error UnauthorizedAccess();
    error DepositPoolAlreadySet();
    error InvalidAddress();
    error EulaMismatch();
    error EulaNotSet();

    // Modifiers
    modifier onlyDepositPool() {
        if (msg.sender != depositPoolContract) revert UnauthorizedAccess();
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

    constructor(address _controller) validAddress(_controller) {
        controller = _controller;
    }

    // ─── EULA Management ───────────────────────────────────────────────

    /**
     * @notice Set or update the required EULA hash
     * @param _eulaHash keccak256 hash of the current EULA document
     */
    function setEulaHash(bytes32 _eulaHash) external onlyController {
        if (_eulaHash == bytes32(0)) revert EulaMismatch();
        bytes32 oldHash = currentEulaHash;
        currentEulaHash = _eulaHash;
        emit EulaUpdated(oldHash, _eulaHash);
    }

    // ─── Minting ───────────────────────────────────────────────────────

    /**
     * @notice Mint SBT with EULA acceptance gate. soulboundId is derived canonically from msg.sender.
     * @param _zkpCommitment Privado ID ZKP commitment (can be bytes32(0) if not yet verified)
     * @param _eulaHash Must match currentEulaHash — the transaction signature IS the acceptance
     */
    function mintSBT(
        bytes32 _zkpCommitment,
        bytes32 _eulaHash
    ) external {
        if (_sbtRegistry[msg.sender].exists) revert SBTAlreadyExists();
        if (currentEulaHash == bytes32(0)) revert EulaNotSet();
        if (_eulaHash != currentEulaHash) revert EulaMismatch();

        bytes32 derivedSoulboundId = keccak256(
            abi.encodePacked(msg.sender, ACCOUNT_ID_SALT, block.chainid)
        );

        _sbtRegistry[msg.sender] = SBTData({
            soulboundId: derivedSoulboundId,
            zkpCommitment: _zkpCommitment,
            nonce: 0,
            mintedAt: block.timestamp,
            eulaHash: _eulaHash,
            exists: true
        });

        unchecked { ++_totalSBTs; }

        emit SBTMinted(msg.sender, derivedSoulboundId, _zkpCommitment, _eulaHash, block.timestamp);
    }

    // ─── ZKP Commitment ────────────────────────────────────────────────

    /**
     * @notice Update ZKP commitment after Privado ID verification
     * @param _zkpCommitment New ZKP commitment hash
     */
    function updateZKPCommitment(bytes32 _zkpCommitment) external {
        if (!_sbtRegistry[msg.sender].exists) revert SBTNotFound();
        if (_zkpCommitment == bytes32(0)) revert InvalidZKPCommitment();

        _sbtRegistry[msg.sender].zkpCommitment = _zkpCommitment;
        emit ZKPCommitmentUpdated(msg.sender, _zkpCommitment);
    }

    // ─── Soulbound ID Generation ───────────────────────────────────────

    /**
     * @notice Generate canonical soulboundId for an address (matches mintSBT derivation)
     * @param account Address to generate ID for
     * @return bytes32 Deterministic hash — avoids storing raw addresses
     */
    function generateSoulboundId(address account) external view validAddress(account) returns (bytes32) {
        return keccak256(abi.encodePacked(account, ACCOUNT_ID_SALT, block.chainid));
    }

    // ─── ISoulBoundToken Implementation ────────────────────────────────

    /// @inheritdoc ISoulBoundToken
    function hasSBT(address account) external view override returns (bool) {
        return _sbtRegistry[account].exists;
    }

    /// @inheritdoc ISoulBoundToken
    function getAccountData(address account) external view override returns (bytes32, uint256) {
        if (!_sbtRegistry[account].exists) revert SBTNotFound();
        SBTData storage data = _sbtRegistry[account];
        return (data.soulboundId, data.nonce);
    }

    /// @inheritdoc ISoulBoundToken
    function incrementNonce(address account) external override onlyDepositPool returns (uint256) {
        if (!_sbtRegistry[account].exists) revert SBTNotFound();
        unchecked { ++_sbtRegistry[account].nonce; }
        uint256 newNonce = _sbtRegistry[account].nonce;
        emit NonceIncremented(account, newNonce);
        return newNonce;
    }

    /// @inheritdoc ISoulBoundToken
    function totalSBTs() external view override returns (uint256) {
        return _totalSBTs;
    }

    // ─── Configuration ─────────────────────────────────────────────────

    /**
     * @notice Set deposit pool contract address (one-time only)
     * @param _depositPool Address of the deposit pool contract
     */
    function setDepositPool(address _depositPool) external onlyController validAddress(_depositPool) {
        if (depositPoolContract != address(0)) revert DepositPoolAlreadySet();
        depositPoolContract = _depositPool;
        emit DepositPoolSet(_depositPool);
    }

    /**
     * @notice Transfer controller role (for multisig migration)
     * @param _newController New controller address
     */
    function transferController(address _newController) external onlyController validAddress(_newController) {
        address old = controller;
        controller = _newController;
        emit ControllerTransferred(old, _newController);
    }

    // ─── View Functions ────────────────────────────────────────────────

    /**
     * @notice Get complete SBT data for an account
     */
    function getSBTData(address account) external view returns (
        bytes32 soulboundId,
        bytes32 zkpCommitment,
        uint256 nonce,
        uint256 mintedAt,
        bytes32 eulaHash,
        bool exists
    ) {
        SBTData storage data = _sbtRegistry[account];
        return (data.soulboundId, data.zkpCommitment, data.nonce, data.mintedAt, data.eulaHash, data.exists);
    }

    function isInitialized() external view returns (bool) {
        return depositPoolContract != address(0);
    }
}

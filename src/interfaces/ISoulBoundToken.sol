// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

/**
 * @title ISoulBoundToken
 * @notice Interface for SoulBound Token identity contract
 */
interface ISoulBoundToken {
    /// @notice Whether the account holds an SBT
    function hasSBT(address account) external view returns (bool);

    /// @notice The account's soulboundId and current OTU nonce; reverts if no SBT exists
    function getAccountData(address account) external view returns (bytes32 soulboundId, uint256 nonce);

    /// @notice Advance the account's OTU nonce; DepositPool-only, called once per generateOTU
    function incrementNonce(address account) external returns (uint256);

    /// @notice Count of SBTs ever minted
    function totalSBTs() external view returns (uint256);
}

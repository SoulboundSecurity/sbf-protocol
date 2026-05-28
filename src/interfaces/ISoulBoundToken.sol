// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

/**
 * @title ISoulBoundToken
 * @notice Interface for SoulBound Token identity contract
 */
interface ISoulBoundToken {
    function hasSBT(address account) external view returns (bool);
    function getAccountData(address account) external view returns (bytes32 soulboundId, uint256 nonce);
    function incrementNonce(address account) external returns (uint256);
    function totalSBTs() external view returns (uint256);
}

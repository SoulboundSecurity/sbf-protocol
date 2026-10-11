# SoulBound Finance Protocol — Test Coverage

## Status: All Tests Passing

78 forge unit tests + 24 live chain smoke tests verified against local anvil.

## Forge Unit Tests (78 tests)

### SoulBoundDeployer
- Atomic deployment of full system (SBT + DepositPool + ClaimPool)
- Role handoff verification (controller/operator → deployer EOA)
- Token whitelisting during deploy
- Revert: deploy twice, zero treasury, zero EULA hash

### SoulBoundToken
- SBT minting with EULA acceptance gate
- Stored data integrity (account ID, ZKP commitment, nonce, timestamp, EULA hash)
- ZKP commitment updates
- Nonce increment per OTU generation
- Revert: double mint, zero account ID, wrong EULA, EULA not set, zero EULA hash
- Revert: non-controller sets EULA, deposit pool, transfers controller
- Revert: deposit pool set twice, non-deposit-pool increments nonce
- Revert: getAccountData / updateZKP for non-holders, zero-address constructor

### DepositPool
- ETH deposits (SBT-gated)
- ERC-20 deposits: USDC (6 decimals), USDT (6 decimals), WBTC (8 decimals)
- OTU generation with EIP-712 attestation (ETH + USDC + WBTC)
- Fee distribution: 1% protocol → treasury, 0.25% gas → ClaimPool
- Nonce increment per OTU (replay prevention)
- Fee cap enforcement (max 5% / 500 bps)
- Emergency withdrawal per token type (ETH + USDC + WBTC)
- Emergency withdrawal works after token delisted
- Revert: deposit without SBT, unsupported token, zero amount, ETH via deposit()
- Revert: OTU without SBT, unconfigured, insufficient balance, commercial disabled
- Revert: invalid attestation signature, replayed nonce
- Revert: non-controller admin functions, claimPool set twice, remove ETH, fees above cap
- Revert: emergency withdraw without SBT, zero balance

### ClaimPool
- Single redemption (ETH + USDC) with balance verification
- Batch redemption (ETH) with per-recipient verification
- Double-spend prevention (redemption hash burned)
- Gas fund deposit via depositGasFundETH()
- Gas fund deposit via receive() from gasManager
- Revert: non-operator redemption, zero amount, insufficient balance, zero address
- Revert: batch empty array, mismatched arrays, exceeds max batch size
- Revert: non-gasManager deposit, zero value deposit
- Revert: random address sending ETH via receive()
- Revert: non-gasManager useGasFund, insufficient gas fund balance
- Revert: non-operator admin functions, depositPool set twice
- Revert: non-depositPool receiveFunds/receiveFundsETH, mismatched ETH value

## Live Chain Smoke Test (24 tests)

Executed as real transactions against a fresh anvil deployment with randomised
deployer wallet (different contract addresses every run). Verifies the full
deposit-to-redemption cycle with actual tx hashes and gas metering.

1. Contract verification (5 tests)
2. SBT minting with EULA acceptance (4 tests)
3. ETH deposit — SBT-gated (2 tests)
4. OTU generation with EIP-712 attestation + fee split verification (7 tests)
5. Operator redemption + double-spend prevention (3 tests)
6. Gas fund deposit by gasManager (2 tests)
7. Emergency withdrawal (2 tests)

<img width="418" height="857" alt="Screenshot 2026-03-26 at 16 34 16" src="https://github.com/user-attachments/assets/934e6193-b908-4807-9f56-c0c54b62e62d" />

## Contributing Tests

We do not publish our internal test suite but welcome community-contributed
tests under the terms outlined in [CLA.md](CLA.md). Contributions should
follow the existing contract conventions: forge-std, custom errors for all
revert cases, happy path + revert + edge case coverage per function.

## Pending — v1.0 Role Administration Revision

The ClaimPool controller-role revision (see
[`audits/2026-10-11-internal-role-administration.md`](audits/2026-10-11-internal-role-administration.md))
adds the following cases to the internal suite before the counts above are
current again:

- Revert: non-controller calls `changeOperator`, `setGasManager`,
  `setApprovedTarget`, `setDepositPool` (4 tests)
- Controller rotates operator; old operator loses redemption authority,
  new operator gains it (1 test)
- `deploySystem` role end state: controllers on all three contracts to
  `msg.sender`, ClaimPool operator set to the `_operator` parameter (1 test)

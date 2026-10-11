# SBF Protocol

Private, privacy-preserving transfers on-chain, built for regulatory approval. An open-source protocol that separates identity from redemption, so observers cannot link a deposit to its redemption while every transfer carries a signed, attributable statement of purpose.

Built by [Soulbound Security](https://soulboundsecurity.io). Reference implementation live at [soulbound.finance](https://soulbound.finance) on Arbitrum One since April 2026.

## Overview

Depositors are identity-linked through a non-transferable Soulbound ID (the [`SoulBoundToken`](#soulboundtoken) contract), which carries a zero-knowledge identity commitment. Recipients redeem to a fresh address using a one-time-use (OTU) redemption code. The protocol never records which deposit a redemption corresponds to.

This is not a mixer. Deposits are identity-gated (Soulbound ID plus optional Privado ID zero-knowledge verification), and every OTU generation requires a per-transaction [EIP-712 signed attestation](#fee-model-and-purpose-attestation) of purpose, recorded immutably on-chain. Compliance is structural, not bolted on.

**Core properties:**

- **Compliant by design.** KYC-linkable deposits via zero-knowledge commitment (Privado ID). EULA acceptance cryptographically recorded at mint. Per-transaction purpose attestation on every OTU. Regulators have an audit surface; counterparties do not.
- **Private redemption.** Recipient addresses are ephemeral. No recipient data is stored on-chain or off-chain beyond the redemption transaction itself.
- **Multi-token.** Native ETH plus controller-whitelisted ERC-20s. See [Supported Tokens](docs/PROTOCOL_SPEC.md#supported-tokens).
- **Immutable contracts.** No proxies, no `delegatecall`. [Upgrades](docs/PROTOCOL_SPEC.md#8-upgrade-path) require explicit member migration. Auditable by construction.
- **Unconditional exit.** `emergencyWithdraw` lets any Soulbound ID holder reclaim their full balance at any time, with no fee.

## Architecture

See [§1 System Overview](docs/PROTOCOL_SPEC.md#1-system-overview) for the full contract dependency graph.

```
┌──────────────────────┐
│   SoulBoundToken     │  Identity layer (Soulbound ID). Non-transferable.
│                      │  ZK commitment. EULA gate on mint. Nonce tracks
│                      │  OTU generation.
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│   DepositPool        │  Inflow. Multi-token deposits. Per-tx EIP-712
│                      │  purpose attestation. Splits fees on OTU generation:
│                      │    Protocol fee → Treasury (direct)
│                      │    OTU + gas fee → ClaimPool
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│   ClaimPool          │  Outflow. Operator-processed redemptions.
│                      │  Batch processing. Gas fund, deployable only to
│                      │  whitelisted targets.
└──────────────────────┘

Deployment: SoulBoundDeployer, atomic deploy + link in a single tx.
```

### SoulBoundToken

One Soulbound ID per address. Non-transferable, non-burnable. Holds the member's `encryptedAccountId`, `zkpCommitment` (Privado ID) and EULA acceptance hash. The nonce increments on each OTU generation and provides replay protection for EIP-712 attestations.

ZK commitments can be set post-mint: mint first, verify later. See [§2 SoulBoundToken](docs/PROTOCOL_SPEC.md#2-soulboundtoken).

### DepositPool

Accepts ETH and whitelisted ERC-20s from Soulbound ID holders. No fees on deposit. OTU generation deducts the face value plus protocol and gas fees from the member's internal balance, sends the protocol fee directly to the treasury and forwards the remainder to the ClaimPool. The contract has zero knowledge of the OTU code itself.

See [§3 DepositPool](docs/PROTOCOL_SPEC.md#3-depositpool) and [§4 EIP-712 Fee Attestation](docs/PROTOCOL_SPEC.md#4-eip-712-fee-attestation).

### ClaimPool

Holds redemption funds and the gas reserve. Redemptions are processed by a privileged Operator role, the bridge between off-chain OTU validation and on-chain fund release. Supports single and [batch redemptions](docs/PROTOCOL_SPEC.md#batch-redemption). The gas fund is a separate balance for protocol operations and can be deployed only to Operator-approved targets.

See [§5 ClaimPool](docs/PROTOCOL_SPEC.md#5-claimpool) and [§7 Operator Trust Model](docs/PROTOCOL_SPEC.md#7-operator-trust-model).

## Fee Model and Purpose Attestation

Fees are bound to declared purpose. Every OTU generation requires an EIP-712 signed attestation, which the contract verifies and records on-chain before applying the matching fee tier. No OTU can be generated without one. Fees are charged **on top** of the OTU face value, not deducted from it. See [§3 Fee Structure](docs/PROTOCOL_SPEC.md#fee-structure).

| Declared purpose | Protocol fee | Gas fee | Total | Status |
|------------------|-------------|---------|-------|--------|
| Personal, non-commercial and charitable | 1.00% | 0.25% | 1.25% | Live |
| Commercial and enterprise | 2.00% | 0.25% | 2.25% | Disabled at deployment; enabled only upon regulatory approval |

The gas fee (0.25%) is a contract constant. Protocol fees are adjustable by the controller multisig and hard-capped at 5% per tier in the contract.

## Repository Structure

```
sbf-protocol/
├── src/
│   ├── SoulBoundToken.sol
│   ├── DepositPool.sol
│   ├── ClaimPool.sol
│   ├── SoulBoundDeployer.sol
│   └── interfaces/
│       └── ISoulBoundToken.sol
├── test/
├── scripts/
├── docs/
│   └── PROTOCOL_SPEC.md
├── audits/
├── CLAUDE.md
├── foundry.toml
├── LICENSE
└── README.md
```

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
# Clone
git clone https://github.com/SoulboundSecurity/sbf-protocol.git
cd sbf-protocol

# Build
forge build

# Test
forge test

# Gas report
forge test --gas-report
```

## Deployment

Target chain: **Arbitrum One** (mainnet) / **Arbitrum Sepolia** (testnet).

```bash
# Deploy full system atomically
forge script scripts/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

## Testing

See [TESTING.md](TESTING.md) for full test coverage documentation and contribution guidelines.

## Security

### Review history

| Date | Review | Outcome |
|------|--------|---------|
| May 2026 | Independent third-party review by Gakarot, with mainnet-forked Foundry PoCs | Two findings, both fixed in [`c4d7787`](https://github.com/SoulboundSecurity/sbf-protocol/commit/c4d7787). Full record in [`audits/2026-05-28-gakarot-disclosure.md`](audits/2026-05-28-gakarot-disclosure.md) |
| June to August 2026 | Internal security review | Gas fund target whitelist added to `ClaimPool` ([PR #7](https://github.com/SoulboundSecurity/sbf-protocol/pull/7), merged in [`38e250d`](https://github.com/SoulboundSecurity/sbf-protocol/commit/38e250d210e7869fdf83b786fa8650033a30a534)) |
| September 2026 | Architecture-level protocol security review | Published as [Where Privacy Actually Lives](https://blog.soulbound.finance/p/where-privacy-actually-lives) |
| October 2026 | Full-stack data-flow architecture review (internal): user, money, and points paths traced end to end across the reference platform and protocol, with trust-boundary and key-custody analysis; protocol reviewed at [`cb13cf2`](https://github.com/SoulboundSecurity/sbf-protocol/commit/cb13cf2) | Technical companion published as [Soulbound Finance: Security and Privacy](https://blog.soulbound.finance/p/soulbound-finance-security-and-privacy); `ClaimPool` role administration moved to a dedicated controller role. Full record in [`audits/2026-10-11-internal-role-administration.md`](audits/2026-10-11-internal-role-administration.md) |

Gakarot subsequently joined Soulbound Security as Director of Blockchain Security; later reviews are internal. Further independent third-party assurance will follow alongside our wider certification programme.

To report a vulnerability: **security@soulboundsecurity.io**

### Responsible disclosure log

Accepted vulnerability disclosures, and the changes shipped in response, are recorded in [`audits/`](audits/). Operators deploying forks should review these entries to understand which findings apply to their architecture.

The authentication layer that pairs with this protocol is [SBA-Auth](https://github.com/SoulboundSecurity/SBA-Auth): stateless, wallet-native authentication for high-value, low-volume control surfaces, with on-chain operator enrollment and per-action hardware-confirmed signatures. Its address-bound identity predicate is the off-chain mitigation layer referenced in the May 2026 disclosure above, its contracts follow this protocol's [Role and Trust Model](docs/PROTOCOL_SPEC.md#7-role-and-trust-model), and it ships AGPL-3.0 with a full [specification](https://github.com/SoulboundSecurity/SBA-Auth/blob/main/SPEC.md), [deployment use cases](https://github.com/SoulboundSecurity/SBA-Auth/blob/main/USE_CASES.md), and an internal adversarial review on record in its own audits log.

## Links

- **Website:** [soulboundsecurity.io](https://soulboundsecurity.io)
- **App:** [soulbound.finance](https://soulbound.finance)
- **Research:** [blog.soulbound.finance](https://blog.soulbound.finance)
- **X:** [@soulboundsec](https://x.com/soulboundsec)
- **Commercial, regulatory and legal:** legal@soulboundsecurity.io
- **Protocol security:** security@soulboundsecurity.io

## License

AGPL-3.0. See [LICENSE](LICENSE). Commercial licences are available from Soulbound Security for integrations that cannot adopt AGPL-3.0 terms.

© Soulbound Security Ltd 2026

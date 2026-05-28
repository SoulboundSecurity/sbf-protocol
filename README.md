# SBF Protocol

Compliant private payments on-chain. An open-source primitive for anonymous, cash-like digital asset transfers that preserves regulatory compatibility by design.

Built by [Soulbound Security](https://soulboundsecurity.io).

## Overview

Soulbound Finance enables compliant private payments by separating identity from redemption. Depositors are identity-linked via non-transferable [Soulbound Tokens](#soulboundtoken) and ZKP commitments. Recipients redeem anonymously via One-Time-Use (OTU) bearer codes — no on-chain link between depositor and redeemer.

This is not a mixer. Deposits are identity-gated (SBT + optional Privado ID ZKP), and each OTU generation requires a per-transaction [EIP-712 signed attestation](#eip-712-fee-attestation) of purpose recorded immutably on-chain. Compliance is structurally embedded, not bolted on.

**Core properties:**

- **Compliant by Design** — KYC-linkable deposits via ZKP commitment (Privado ID). EULA acceptance cryptographically recorded at mint. Per-transaction purpose attestation on every OTU. Regulators have an audit surface; counterparties do not.
- **Private Redemption** — Recipient addresses are ephemeral. No recipient data stored on-chain or off-chain beyond the redemption transaction itself.
- **Multi-Token** — USDC, USDT, WBTC, ETH at [launch](docs/PROTOCOL_SPEC.md#supported-tokens). Token whitelist controlled by multisig.
- **Immutable Contracts** — No proxies, no `delegatecall`. [Upgrades](docs/PROTOCOL_SPEC.md#8-upgrade-path) require explicit user migration. Auditable by construction.

## Architecture

See [§1 System Overview](docs/PROTOCOL_SPEC.md#1-system-overview) for the full contract dependency graph.

```
┌──────────────────────┐
│   SoulBoundToken     │  Identity layer. Non-transferable. ZKP commitment.
│   (SBT)              │  EULA gate on mint. Nonce tracks OTU generation.
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│   DepositPool        │  Inflow. Multi-token deposits. Per-tx EIP-712
│                      │  fee attestation. Splits fees on OTU generation:
│                      │    Protocol fee → Treasury (direct)
│                      │    OTU + gas fee → ClaimPool
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│   ClaimPool          │  Outflow. Operator-processed redemptions.
│                      │  Batch processing. Gas fund for DeFi operations.
└──────────────────────┘

Deployment: SoulBoundDeployer — atomic deploy + link in single tx.
```

### SoulBoundToken

One SBT per address. Non-transferable, non-burnable. Holds the user's `encryptedAccountId`, `zkpCommitment` (Privado ID), and EULA acceptance hash. The nonce field increments on each OTU generation and serves as replay protection for EIP-712 attestations.

ZKP commitments can be set post-mint — mint first, verify later. See [§2 SoulBoundToken](docs/PROTOCOL_SPEC.md#2-soulboundtoken).

### DepositPool

Accepts ETH and whitelisted ERC-20s from SBT holders. No fees on deposit. OTU generation deducts the face value plus protocol and gas fees from the user's internal balance, sends the protocol fee directly to the treasury, and forwards the remainder to ClaimPool. The contract has zero knowledge of the OTU code itself.

See [§3 DepositPool](docs/PROTOCOL_SPEC.md#3-depositpool) and [§4 EIP-712 Fee Attestation](docs/PROTOCOL_SPEC.md#4-eip-712-fee-attestation).

### ClaimPool

Holds redemption funds and the gas reserve. Redemptions are processed by a privileged operator role — the bridge between off-chain OTU validation and on-chain fund release. Supports single and [batch redemptions](docs/PROTOCOL_SPEC.md#batch-redemption). The gas fund is a separate balance intended for AAVE yield deployment and protocol operations.

See [§5 ClaimPool](docs/PROTOCOL_SPEC.md#5-claimpool) and [§7 Operator Trust Model](docs/PROTOCOL_SPEC.md#7-operator-trust-model).

## Fee Model

Fees are charged **on top** of the OTU face value, not deducted from it. See [§3 Fee Structure](docs/PROTOCOL_SPEC.md#fee-structure).

| Tier | Protocol Fee | Gas Fee | Total | Status |
|------|-------------|---------|-------|--------|
| Charitable / Donation / Gift | 1.00% | 0.25% | 1.25% | Active |
| Commercial / Enterprise | 2.00% | 0.25% | 2.25% | Disabled at launch |

Fee tier is selected per transaction via EIP-712 signed attestation. The user cryptographically attests to the purpose of each OTU, creating an immutable on-chain record. Gas fee (0.25%) is immutable. Protocol fees are adjustable by controller multisig, capped at 5%.

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

See [TESTING.md](TESTING.md) for full test coverage documentation and
contribution guidelines.

## Security

This protocol has not yet been audited. Use at your own risk.

To report a vulnerability: **security@soulboundsecurity.io**

### Responsible Disclosure Log

Public record of accepted vulnerability disclosures and the changes shipped in
response lives in [`audits/`](audits/). Operators deploying forks should review
these entries to understand which findings apply to their architecture.

For platforms that want the Soulbound Finance-style off-chain mitigations on
top of the on-chain protocol (address-bound identity verification at the auth
boundary), see [SBA-Auth](https://github.com/SoulboundSecurity/SBA-Auth).

## Links

- **Website:** [soulboundsecurity.io](https://soulboundsecurity.io)
- **App:** [soulbound.finance](https://soulbound.finance)
- **Twitter:** [@soulboundsec](https://twitter.com/soulboundsec)
- **Contact:** info@soulboundsecurity.io

## License

AGPL-3.0 — see [LICENSE](LICENSE).

© Soulbound Security LTD 2026

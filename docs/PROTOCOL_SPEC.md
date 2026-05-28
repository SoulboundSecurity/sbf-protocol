# SBF Protocol Specification

**Version:** 1.0
**Chain:** Arbitrum One (mainnet), Arbitrum Sepolia (testnet)
**License:** AGPL-3.0

---

## 1. System Overview

SBF Protocol is a deposit/claim pool system gated by non-transferable Soulbound Tokens. It enables privacy-preserving transfers by separating the deposit event (identity-linked) from the redemption event (anonymous). The on-chain layer handles token custody, fee collection, and operator-processed redemptions. OTU code generation and distribution occur entirely off-chain.

### Contract Dependency Graph

```
SoulBoundToken ◄──── DepositPool ────► ClaimPool
     │                    │                 │
     │                    │                 │
  Identity            Inflow +          Outflow +
  + Nonce           Fee Splitting      Redemptions
                        │
                        ▼
                  Protocol Treasury
```

`SoulBoundDeployer` deploys and links all three contracts atomically in a single transaction.

---

## 2. SoulBoundToken

Non-transferable identity token. One per address. Cannot be burned or transferred.

### State Per Token

| Field | Type | Purpose |
|-------|------|---------|
| `soulboundId` | `bytes32` | Canonical identifier — `keccak256(abi.encodePacked(msg.sender, ACCOUNT_ID_SALT, block.chainid))`. Derived on-chain at mint, not caller-supplied. |
| `zkpCommitment` | `bytes32` | Privado ID ZKP commitment. Updateable by holder. |
| `nonce` | `uint256` | OTU generation counter. Incremented by DepositPool on each `generateOTU`. |
| `mintedAt` | `uint256` | Block timestamp at mint. |
| `eulaHash` | `bytes32` | EULA hash accepted at mint time. |

`ACCOUNT_ID_SALT` is a `private constant` set to `"YOURSALT"` in the upstream
AGPL-3.0 source — **forks SHOULD replace it with a value unique to their
deployment** to prevent cross-deployment identifier collision. The view
function `generateSoulboundId(address)` returns exactly what a fresh mint by
that address would produce (canonical predictor, useful for off-chain dApps).

### Mint Flow

1. Controller sets `currentEulaHash` on the contract.
2. User calls `mintSBT(zkpCommitment, eulaHash)`.
3. Contract verifies: no existing SBT for caller, EULA hash matches current.
4. Contract derives `soulboundId` from `msg.sender + salt + chainid` and stores
   the SBT. The transaction signature constitutes cryptographic EULA acceptance.

The identifier is NOT a caller-supplied parameter. Earlier protocol versions
accepted an arbitrary `bytes32` here, allowing distinct addresses to mint
colliding identifiers — see [audits/2026-05-28-gakarot-disclosure.md](../audits/2026-05-28-gakarot-disclosure.md).

### ZKP Commitment

The `zkpCommitment` field is a placeholder at mint (can be `bytes32(0)`) and is updated post-mint via `updateZKPCommitment()`. Only the SBT holder can update their own commitment. This supports deferred Privado ID verification — mint first, verify later.

### Nonce

Incremented exclusively by DepositPool during OTU generation. Serves as replay prevention for EIP-712 attestation signatures. The nonce value is public but reveals nothing about the OTU itself — only that an OTU was generated.

### Access Control

| Function | Caller |
|----------|--------|
| `mintSBT` | Anyone (one per address) |
| `updateZKPCommitment` | SBT holder only |
| `incrementNonce` | DepositPool contract only |
| `setDepositPool` | Controller (one-time) |
| `setEulaHash` | Controller |
| `transferController` | Controller |

---

## 3. DepositPool

Manages token deposits, OTU generation initiation, fee calculation, and fee distribution.

### Supported Tokens

Native ETH is always supported. ERC-20 tokens are added to a whitelist by the controller. Launch tokens:

| Token | Arbitrum One Address |
|-------|---------------------|
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| USDT | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |
| WBTC | `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` |
| ETH | Native |

### Deposit

No fees on deposit. SBT required.

- ERC-20: `deposit(token, amount)` — requires prior `approve()`.
- ETH: `depositETH()` — send ETH with the call.

Deposits are tracked per-user per-token in internal accounting. Tokens are held by the DepositPool contract.

### OTU Generation

`generateOTU(token, amount, tier, attestationSig)`

This is the on-chain component of OTU creation. It:

1. Verifies the caller holds an SBT.
2. Reads the caller's current nonce from the SBT contract.
3. Verifies the EIP-712 attestation signature (see §4).
4. Calculates fees on top of the OTU face value.
5. Deducts `amount + protocolFee + gasFee` from the user's balance.
6. Increments the SBT nonce (invalidating the attestation sig for replay).
7. Sends `protocolFee` directly to the protocol treasury.
8. Sends `amount + gasFee` to ClaimPool via `receiveFunds` / `receiveFundsETH`.
9. Emits `OTUGenerated` event.

The contract does not generate, store, or have any knowledge of the OTU code itself.

### Fee Structure

Fees are charged **on top** of the OTU amount. A 100 USDC OTU with charitable tier costs 101.25 USDC from the user's balance.

| Component | Charitable | Commercial | Mutable |
|-----------|-----------|------------|---------|
| Protocol fee | 100 bps (1.00%) | 200 bps (2.00%) | Yes, by controller, max 500 bps |
| Gas fee | 25 bps (0.25%) | 25 bps (0.25%) | No, immutable constant |

`commercialEnabled` is `false` at launch. Calls with `FeeTier.COMMERCIAL` revert until the controller enables it.

### Fee Distribution

```
User Balance
    │
    ├── Protocol Fee ──────► Protocol Treasury (direct transfer)
    │
    └── OTU Amount + Gas Fee ──► ClaimPool (via receiveFunds/receiveFundsETH)
```

Protocol fees never pass through ClaimPool.

### Emergency Withdrawal

`emergencyWithdraw(token)` returns the caller's full balance for a given token. No fees. No token whitelist check — works even if the token was delisted after deposit. Requires SBT.

### Access Control

| Function | Caller |
|----------|--------|
| `deposit` / `depositETH` | SBT holder |
| `generateOTU` | SBT holder |
| `emergencyWithdraw` | SBT holder |
| `addToken` / `removeToken` | Controller |
| `setClaimPool` | Controller (one-time) |
| `setProtocolTreasury` | Controller |
| `toggleCommercial` | Controller |
| `updateFees` | Controller |
| `transferController` | Controller |

---

## 4. EIP-712 Fee Attestation

Each OTU generation requires an EIP-712 typed data signature from the caller. This creates a human-readable signing prompt in the wallet and an immutable on-chain record of the attestation.

### Domain

```
EIP712Domain(
    string name = "SoulBound Finance",
    string version = "1",
    uint256 chainId,
    address verifyingContract = <DepositPool address>
)
```

### Attestation Struct

```
OTUAttestation(
    address depositor,
    address token,
    uint256 amount,
    uint8 feeTier,
    uint256 nonce,
    string purpose
)
```

### Purpose Strings

| Tier | Purpose String |
|------|---------------|
| CHARITABLE | `"I attest this withdrawal is for charitable, donation, or personal gift purposes"` |
| COMMERCIAL | `"I attest this withdrawal is for commercial or business purposes"` |

The purpose string is hashed (`keccak256`) in the struct. The wallet displays the full typed data to the user before signing.

### Attestation as Legal Record

The EIP-712 signature creates an immutable on-chain record of the user's
purpose declaration at the moment of OTU generation. If a user selects
CHARITABLE for a commercial transaction, they have cryptographically signed
a false attestation on an immutable ledger. Compliance exposure for false
attestations rests with the signer, not the protocol.

### Replay Prevention

The `nonce` field is the caller's current SBT nonce. After `generateOTU` succeeds, the nonce increments, invalidating the signature for reuse. Each attestation is bound to a specific depositor, token, amount, tier, and nonce — it cannot be reused for a different transaction.

### Signature Validation

- Signature length must be exactly 65 bytes.
- `s` value must be in the lower half of the curve order (EIP-2 malleability protection).
- `v` must be 27 or 28.
- `ecrecover` result must not be `address(0)`.
- Recovered address must match the caller.

---

## 5. ClaimPool

Holds funds for OTU redemptions and the gas fund reserve. Processes redemptions via an operator (backend).

### Fund Reception

ClaimPool receives funds exclusively from DepositPool via two explicit functions:

- `receiveFunds(token, otuAmount, gasFee)` — ERC-20 tokens
- `receiveFundsETH(otuAmount, gasFee)` — native ETH (with `msg.value` validation)

These update per-token accounting:
- `redemptionBalance[token]` — available for OTU redemptions
- `gasFundBalance[token]` — reserved for future DeFi operations (AAVE yield, gas subsidies)

### Redemption

`processRedemption(recipient, token, amount, redemptionHash)`

- Operator-only.
- Checks `redemptionHash` has not been processed (double-spend prevention).
- Deducts from `redemptionBalance[token]`.
- Transfers tokens to recipient.
- Emits `Redeemed` event.

The recipient address is used for the transfer and emitted in the event. It is not stored in any persistent mapping.

### Batch Redemption

`batchProcessRedemptions(recipients[], token, amounts[], redemptionHashes[])`

Processes multiple redemptions in a single transaction. Single token per batch for gas efficiency. Maximum batch size configurable (default: 50). Skips already-processed hashes without reverting.

### Gas Fund

Two flavors for different integration shapes. Gas manager only. Both withdraw
from `gasFundBalance[token]` and execute a call against `target`.

`useGasFund(token, amount, target, data, purpose)` — **push-style.** Transfers
tokens directly to `target`, then calls. Use for targets that accept pushed
tokens: EOA wallets, custom receiver contracts, off-chain swap intermediaries.
ETH supported.

`useGasFundApprove(token, amount, target, data, purpose)` — **pull-style.**
Grants `target` an allowance, executes the call (which is expected to pull via
`transferFrom`), then resets the allowance to zero. Use for any DeFi protocol
that follows the standard ERC-20 allowance pattern: Aave `Pool.supply`,
Compound `cToken.mint`, Uniswap router swaps, etc. ETH not supported (use
`useGasFund` for native).

**Token compliance.** `useGasFundApprove` requires standard ERC-20 `approve`
behavior — the function MUST return `bool`. Non-compliant tokens that omit
the bool return from `approve()` (notably USDT) are explicitly NOT supported
and will revert the EVM ABI decode. The protocol does not muddy this code
path to accommodate tokens that fail to write proper ERC-20.

### Access Control

| Function | Caller |
|----------|--------|
| `receiveFunds` / `receiveFundsETH` | DepositPool only |
| `processRedemption` | Operator |
| `batchProcessRedemptions` | Operator |
| `useGasFund` | Gas manager |
| `useGasFundApprove` | Gas manager |
| `setDepositPool` | Operator (one-time) |
| `setGasManager` | Operator |
| `changeOperator` | Operator |

---

## 6. SoulBoundDeployer

Deploys all three contracts and configures their linkages atomically.

`deploySystem(protocolTreasury, gasManager, eulaHash, tokens[])`

Execution order:

1. Deploy `SoulBoundToken(controller = msg.sender)`
2. Deploy `DepositPool(sbt, controller = msg.sender)`
3. Deploy `ClaimPool()`
4. Link: SBT → DepositPool, DepositPool → ClaimPool + Treasury, ClaimPool → DepositPool + Gas Manager
5. Set EULA hash on SBT
6. Whitelist provided tokens on DepositPool
7. Transfer ClaimPool operator to `msg.sender`

If any step fails, the entire transaction reverts. No partial deployments.

Post-deployment, the deployer EOA holds controller (SBT, DepositPool) and operator (ClaimPool) roles. These should be transferred to a multisig.

---

## 7. Operator Trust Model

The protocol has two privileged roles:

**Controller** (SBT + DepositPool): Can update EULA, modify fee rates (capped), toggle commercial tier, add/remove tokens, set treasury address. Cannot access user funds. Cannot generate OTUs on behalf of users. Cannot process redemptions.

**Operator** (ClaimPool): Can process redemptions and batch redemptions. Can change gas manager. This role is held by the backend application. The operator can send funds from ClaimPool's redemption balance to arbitrary addresses — this is by design, as the operator is the bridge between off-chain OTU validation and on-chain fund transfer.

**Gas Manager** (ClaimPool): Can deploy gas fund to external contracts (AAVE, etc.). Cannot access redemption balance.

The system assumes the operator is honest. A compromised operator could drain the ClaimPool redemption balance. Mitigation: operator key should be held in a secure enclave or HSM, with monitoring on ClaimPool balance and redemption patterns.

---

## 8. Upgrade Path

The contracts are not upgradeable. There are no proxies and no `delegatecall`. To upgrade:

1. Deploy new contract set.
2. Users withdraw from old DepositPool via `emergencyWithdraw`.
3. Users deposit to new DepositPool.
4. Old ClaimPool operator processes remaining redemptions.

This is intentional. Immutable contracts are auditable contracts.
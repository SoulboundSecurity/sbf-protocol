# Responsible Disclosure — Gakarot — 2026-05-28

**Researcher:** Gakarot (a.k.a. NetGakarot)
**Contact:** I.am.gakarot@gmail.com · Discord: `_gakarot` · Telegram: `@NetGakarot`
**Disclosure repo:** https://gist.github.com/NetGakarot/

Two findings against the AGPL-3.0 SoulBound Protocol. Both fixed in this commit.
Issue severity differs by adopter:

- **Soulbound Finance (the funded reference platform):** suffered no security impact
  from either finding due to off-chain mitigations via **SBA-Auth**
  (https://github.com/SoulboundSecurity/SBA-Auth), which enforces address-bound
  identity verification at every auth boundary before any SBT-derived state is
  trusted. The findings did surface platform-side improvements we shipped in
  parallel (salt-list architecture, latest-salt rotation capability).
- **Downstream forks NOT using SBA-Auth:** both findings are critical and the
  fixes in this commit are recommended-or-required for any deployment.

---

## Timeline

**2026-05-26 — Initial disclosure (Gakarot → security@):**

> Hey Team
>
> Hope you're having a good week.
>
> I'm Gakarot, a security researcher specializing in Solidity. I was recently
> looking into the Soulbound Protocol architecture and ended up doing a dive
> on the contracts. I've uncovered 2 vulnerabilities. I've written full mainnet
> forked Foundry PoCs for all of them to prove the exploit paths.
>
> Here is a quick summary of the findings:
>
> - BUG 1: `ClaimPool.useGasFund` bricks documented Aave Yield integration due
>   to "Push vs Pull" token architecture mismatch
> - BUG 2: Architectural bypass of Canonical identity derivation
>
> I know downloading attachments is a bad security practice, so I've uploaded
> the full write-ups to a private GitHub Gist here:
> https://gist.github.com/NetGakarot/7b315ad3bf0698a99c6f945376d635c3
>
> I've included detailed writeups, impact analysis, mitigation suggestions and
> reproducible PoCs for each issue.

**2026-05-27 — Initial response (Chris → Gakarot):**

Acknowledged finding 1 as a documentation issue for Soulbound Finance prod (gas
manager funds Privacy Matrix cover traffic and Network Refunds, not Aave yield),
but noted the structural fix has real value for AGPL-3.0 forks who may want DeFi
integration. Acknowledged finding 2.

**2026-05-27 — Follow-up (Gakarot → Chris):**

> I want to make sure Finding #2 doesn't fall through the cracks, as I believe
> it warrants a closer look from your team.
>
> The core issue: mintSBT accepts `_encryptedAccountId` as raw, unvalidated
> caller input with no uniqueness constraint. The Protocol_Spec.md defines the
> SBT registry as the identity source of truth for the entire system but the
> current implementation allows any caller to inject an arbitrary or colliding
> identifier at mint time. I've verified this against your live production
> contract on Arbitrum.
>
> The impact on your documented architecture:
>
> - `getAccountData` and `getSBTData` can return ambiguous or non-canonical
>   mappings, meaning any off-chain indexer or compliance service consuming
>   these functions cannot trust the data.
> - A uniqueness collision doesn't just break one feature — it makes the
>   registry ambiguous as a whole, which undermines the audit surface and
>   compliance tracking your architecture depends on.
>
> The mitigation is straightforward: remove `_encryptedAccountId` from the
> mintSBT signature and derive it on-chain from `msg.sender`.

**2026-05-28 — Final exchange (Chris → Gakarot):**

Acknowledged the finding is real for the AGPL-3.0 protocol. Soulbound Finance
itself is not affected: SBA-Auth re-derives the expected identifier from the
SIWE-verified wallet address at every auth boundary and denies any session
whose chain-stored identifier doesn't match. Forks NOT using SBA-Auth and
trusting the on-chain stored value as canonical identity get the spoofing /
collision exposure the PoC demonstrates.

Disclosure surfaced a benefit on the platform side: the salt-list rotation
architecture shipped in parallel to age out the public test salt and add
optional cross-chain spoofing prevention. More is better than less.

Resolution: accept the on-chain derivation fix for the AGPL-3.0 protocol.
Reward (10K Soulbound Points) offered to the researcher's nominated SBT.
Standing job offer for contract work.

---

## Finding 1 — `ClaimPool.useGasFund` push-vs-pull token architecture mismatch

**Validity:** confirmed.

**Original code** transfers tokens to `target` then executes a low-level call.
For DeFi pull-style protocols (Aave Pool.supply, Compound cToken.mint, Uniswap
router swaps) that call `transferFrom(msg.sender, address(this), amount)`
inside their entry function, the call reverts — ClaimPool never granted an
allowance.

**Soulbound Finance impact:** none. The gas manager in production is used for
Privacy Matrix cover-traffic funding and Network Refunds, both push-style
flows. The "AAVE yield" mention in NatSpec was aspirational documentation, not
a live integration. Documentation has been corrected.

**Downstream fork impact:** any fork wanting genuine DeFi integration was
blocked by the structural incompatibility. The researcher's PoC demonstrates
the revert against a localized mock Aave.

**Fix shipped in this commit:**

- New `useGasFundApprove(token, amount, target, data, purpose)` function in
  `ClaimPool.sol` — grants `target` an allowance, executes the call, resets
  the allowance to zero (defense-in-depth against residual approval).
- Existing `useGasFund` preserved unchanged for push-style targets
  (backwards-compatible for forks already using it for wallet funding /
  custom receiver contracts).
- New `IERC20Approve` interface for the approve path.
- Explicit non-support of non-compliant tokens (e.g. USDT) that omit the
  bool return from `approve()`. We do not muddy production code to
  accommodate tokens that fail to implement proper ERC-20.

The dual-function design lets fork operators pick by target requirement
without a forced migration.

---

## Finding 2 — Architectural bypass of canonical identity derivation

**Validity:** confirmed.

**Original code** accepted `_encryptedAccountId` as a `bytes32` parameter from
the caller of `mintSBT` with no on-chain check that the value was derived
canonically from `msg.sender`. The `generateEncryptedAccountId` view function
existed but was never invoked at mint — it was advisory only. Two distinct
addresses could mint with identical identifiers; an attacker could compute and
inject the identifier of any wallet.

**Soulbound Finance impact:** none. SBA-Auth derives the canonical expected
identifier from the SIWE-verified wallet address at every backend trust
boundary (`/auth/verify`, `/auth/refresh`, `/account/register`,
`verifyAdminSig`). The chain-stored identifier is treated as a carrier that
must match — forged mints are denied at session establishment. The address
binding closes the impersonation surface regardless of what the contract
allows on-chain.

**Downstream fork impact:** any fork that trusts the on-chain stored identifier
as canonical (off-chain indexers, compliance services, identity mappings,
on-chain-only access control) gets the spoofing / collision exposure. The
researcher's PoC demonstrates two distinct addresses successfully minting with
identical identifiers against the live production contract.

**Fix shipped in this commit:**

- `_encryptedAccountId` removed from the `mintSBT` parameter list. The
  identifier is now derived on-chain inside the function:
  `keccak256(abi.encodePacked(msg.sender, ACCOUNT_ID_SALT, block.chainid))`.
- The struct field, event field, view-function returns, and helper are
  renamed `encryptedAccountId` → `soulboundId` to better describe what the
  value actually is.
- `generateEncryptedAccountId` renamed to `generateSoulboundId` and refactored
  to use the same `ACCOUNT_ID_SALT` constant as `mintSBT`. The view function
  is now genuinely canonical — it returns exactly what a fresh mint by the
  same address would produce.
- `ACCOUNT_ID_SALT` is a `private constant` set to the placeholder `"YOURSALT"`
  in the AGPL-3.0 source. **Forks SHOULD replace this with a value unique to
  their deployment** to prevent cross-deployment identifier collision (a
  wallet's identifier on a different fork using the same salt would equal its
  identifier here).
- Address binding alone provides the uniqueness guarantee — keccak256 over
  distinct `(msg.sender, salt, chainid)` tuples cannot collide, so no
  separate mapping-based collision check is needed.
- `InvalidAccountId` error removed (no longer reachable — there is no
  caller-supplied identifier to validate).

---

## SBA-Auth reference

For platforms wanting the Soulbound Finance-style off-chain mitigations on
top of the on-chain protocol, the SBA-Auth implementation is open source:
https://github.com/SoulboundSecurity/SBA-Auth

SBA-Auth implements the address-bound identity verification described above:
SIWE-verified wallet address as root-of-trust, on-chain stored identifier as
carrier that must match the address-derived expectation, fail-closed at the
auth boundary.

This audit entry exists as a permanent record of the disclosure and as
guidance to downstream operators on which findings apply to them based on
their auth posture.

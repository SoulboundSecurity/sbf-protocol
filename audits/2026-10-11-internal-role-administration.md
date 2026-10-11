# Internal Review — ClaimPool Role Administration — 2026-10-11

**Source:** Internal full-stack data-flow architecture review, October 2026
(user, money, and points paths traced end to end across the reference
platform and protocol, with trust-boundary and key-custody analysis).
Technical companion published as
[Soulbound Finance: Security and Privacy](https://blog.soulbound.finance/p/soulbound-finance-security-and-privacy).
Protocol reviewed at
[`cb13cf2`](https://github.com/SoulboundSecurity/sbf-protocol/commit/cb13cf2).

---

## Finding

`ClaimPool` concentrated role administration on the operator key. Unlike
`SoulBoundToken`, `DepositPool`, and the points contract, `ClaimPool` had no
controller role: `changeOperator`, `setGasManager`, and `setApprovedTarget`
were all `onlyOperator`. Three consequences:

1. **No recovery path.** A compromised operator key could call
   `changeOperator` to an attacker-held address, seizing the redemption
   pipeline irrecoverably. No other role could rotate it back.
2. **Governance mismatch.** The intended governance model places role
   administration under multisig custody. On `ClaimPool` that was not
   structurally true: `changeOperator` carried ownership-transfer
   semantics rather than appointment semantics, so when the operator role
   left the multisig at deployment handoff, rotation authority left with
   it.

## Severity

- **Reference deployment (Soulbound Finance on Arbitrum One):** Medium.
  Operator key compromise is already the recognised critical loss path and
  is mitigated by custody controls (isolated key generation, one-shot load
  into stateless signing infrastructure that signs only redemption batches,
  balance monitoring). The finding removes on-chain recoverability; it
  does not create a new entry point.
- **Downstream forks:** High for any deployment that assumes multisig
  recoverability of the operator role, or that holds the operator key in
  less constrained custody than the reference platform.

## Change

A `controller` role is added to `ClaimPool`, matching the pattern on the
other contracts:

| Function | Was | Now |
|----------|-----|-----|
| `changeOperator` | Operator | Controller |
| `setGasManager` | Operator | Controller |
| `setApprovedTarget` | Operator | Controller |
| `setDepositPool` (one-time) | Operator | Controller |
| `transferController` | — (new) | Controller |

The operator becomes a pure execution key: it processes redemptions and
nothing else. The controller administers roles and the gas fund target
whitelist and can never move funds directly.

Operator rotation is deliberately single-step. A two-step
propose-and-accept pattern was considered and rejected: it would require
the incoming operator key to sign an acceptance transaction from a
general-purpose signing surface, which conflicts with a custody model in
which the key is generated on an isolated system and loaded once into
stateless signing infrastructure. The failure mode two-step guards against
(rotation to a wrong address) is non-terminal under a controller model,
because the controller retains rotation authority and rotates again. See
the access-control section of
[`docs/PROTOCOL_SPEC.md`](../docs/PROTOCOL_SPEC.md) for the full rationale.

`SoulBoundDeployer.deploySystem` gains an `operator` parameter and sets the
role directly to its final value during the atomic deploy, before handing
the `ClaimPool` controller to the deploying address. The operator key signs
nothing during deployment and never transits the deploying EOA.

## Breaking changes for forks

- `deploySystem(protocolTreasury, gasManager, operator, eulaHash, tokens[])`
  — new third parameter.
- `changeOperator` keeps its name and signature; only its caller changes
  from operator to controller.

## Reference deployment status

The contracts live on Arbitrum One are immutable and retain the original
role model; this is visible in the verified on-chain source. Compensating
controls there are custodial, as described under Severity. This revision
applies to new deployments and forks.

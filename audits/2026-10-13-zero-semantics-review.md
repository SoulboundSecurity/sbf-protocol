# Zero-Semantics Review — SoulBound Protocol v1.0 — 2026-10-13

Review of the protocol contracts against the vulnerability class
described in Soulbound Security Research's analysis of the Nomad bridge
incident,
[When Zero Meant Trusted](https://blog.soulbound.finance/p/when-zero-meant-trusted-how-a-default):
default and absent values acquiring privileged meaning at trust gates.
The question asked of every zero, default, and absent storage value, at
every on-chain decision point: *can "no record" ever reach a trust gate
wearing "approved" clothing?*

Scope note: the protocol deliberately accepts caller-supplied data on
several surfaces (redemption hashes, identity commitments) and places
authorization off-chain with the operating platform; the contracts are
permissive pipes plus dedup by design. This review therefore examines
only the on-chain gates, where the vulnerability class lives.

**Outcome: no findings.** Both the deployed Arbitrum One contracts and
the v1.0 revision already encode the rule the incident analysis
prescribes — zero means absence, and absence never passes a trust gate —
at every on-chain decision point.

---

## Verified immune

- **No silent zeros flow out of absent state.** `getAccountData` reverts
  for non-holders rather than returning a zero tuple; `hasSBT` gates on
  an explicit existence flag, never a zero-compare; `incrementNonce`
  reverts for non-holders.
- **Unset configuration is deny-all.** Pre-wiring, zero `claimPool` /
  `protocolTreasury` block OTU generation via the `configured` modifier;
  zero `gasManager` / `depositPool` make their caller-gated functions
  unsatisfiable (no EVM caller is the zero address), including
  ClaimPool's `receive()`. A zero terms hash fails enrollment closed,
  and the setter rejects zero.
- **Zero inputs at the payout gate are skipped, never paid.**
  `batchProcessRedemptions` explicitly skips zero amounts and zero
  recipients in both its pre-sum and execution loops, with array-length
  guards. A zero redemption hash carries no special meaning anywhere:
  it is an ordinary dedup key.
- **No zero can become a role or a whitelisted target.** Every rotation
  function and the gas-fund target whitelist setter are zero-guarded,
  and `deploySystem` validates every initializer parameter (treasury,
  gas manager, operator, terms hash) — the incident checklist's
  "initializer parameters are attack surface," satisfied.
- **The incident's trigger class cannot occur.** The vulnerability was
  born in an upgrade reinterpreting surviving storage. These contracts
  have no proxies, no upgrade path, and no initializers over live
  state; the upgrade story is redeployment (PROTOCOL_SPEC section 8).

## Documented characteristics (deliberate; boundaries enumerated)

| Characteristic | Why it is sound |
| --- | --- |
| `address(0)` means native ETH throughout both pools — the one place zero is a value rather than absence | Every collision point between zero-as-absence and zero-as-ETH is explicitly closed: `deposit()` rejects the zero token (ETH deposits use `depositETH`), `removeToken` refuses to delist ETH, `useGasFundApprove` rejects ETH, and ETH is whitelisted unconditionally at construction so `supportedTokens[address(0)]` can never mean "unset" |
| `processedRedemptions[hash]` defaults false, meaning "payable once" | Inverted polarity from the incident, and correct: the map's only job is non-duplication and it authorizes nothing — value movement requires the operator's signature on the batch, with authorization deliberately off-chain. Absence grants nothing except not-yet-seen |
| `FeeTier` enum zero maps to CHARITABLE, the ungated tier | The polarity runs the safe direction: the gated tier (COMMERCIAL) requires the non-default value and an explicit controller enable, and the tier is always explicit calldata bound into the signed attestation. Forks reordering this enum would move the default to the gated side; do not |
| `setEulaHash` reuses `EulaMismatch` for its zero guard | Cosmetic error-name reuse; behavior is correct (fail closed) |

## Verdict

No changes required. The SBT registry's revert-don't-default pattern is
the origin of the discipline the rest of the Soulbound Security estate
now follows, and the protocol passed the class its own research
published. External review of these conclusions is welcome:
security@soulboundsecurity.io, with findings recorded in this log.

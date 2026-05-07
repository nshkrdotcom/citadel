# Citadel Authority Contract

Status: Phase 6 persistence posture hardened.

## Owns

- frozen Brain-authored `AuthorityDecision.v1` packet ownership
- Phase 4 `Citadel.AuthorityPacketV2.v1` ownership
- platform `Platform.RejectionEnvelope.v1` taxonomy ownership
- platform `Platform.ErrorTaxonomy.v1` formal error class, retry posture, safe
  action, redaction, and runbook ownership
- platform `Platform.InstallationRevisionEpoch.v1` revision/epoch fence
  evidence ownership
- platform `Platform.LeaseRevocation.v1` lease revocation evidence ownership
- authorized `Citadel.OperatorRecoveryAction.v1` envelope ownership
- Phase 6 `AuthorityTenantPropagation.v1` aggregate evidence ownership for
  authority decision, tenant, budget, authorization-scope, lineage,
  idempotency, and lower-facts propagation refs
- `Citadel.AuthorityContract.ExecutionPlaneAuthorityVerifier`, the adapter that
  lets an Execution Plane node host validate Citadel-authored authority refs
- `Citadel.AuthorityContract.PersistencePosture`, the ref-only storage posture
  facade for authority decisions, authority packets, provider auth refs, native
  auth assertion refs, connector binding refs, and audit evidence hash chains
- required field inventory and versioning rule for authority packet successors
- the `extensions["citadel"]` posture for Citadel-only extras
- contract-facing fixtures and validation boundary placement

## Dependencies

- `core/contract_core`
- `execution_plane` package for authority-verifier behaviour and admission
  rejection values
- `ground_plane_persistence_policy` for shared memory-by-default and durable
  profile resolution

## Wave 2 Posture

`AuthorityDecision.v1` is now frozen here against the Brain baseline:

- required shared fields stay first-class
- incompatible field or semantic changes require an explicit successor packet
- Citadel-only extras stay under `extensions["citadel"]`
- fixture-backed drift checks fail immediately on unauthorized mutation

## Phase 4 Posture

`Citadel.AuthorityPacketV2.v1` is the current authority packet surface exposed by
`Citadel.AuthorityContract.packet_name/0` and
`Citadel.AuthorityContract.authority_packet_module/0`. It is intentionally wider
than the frozen Brain V1 packet and carries the enterprise pre-cut envelope:
tenant, installation, actor, resource, idempotency, trace, release manifest,
revision, approval, and policy posture fields.

`Platform.RejectionEnvelope.v1` is the shared fail-closed rejection shape for
denied command, wrong tenant, stale revision, duplicate idempotency key, missing
authority, lower-scope denial, semantic failure, runtime failure, and product
bypass cases. `Citadel.OperatorRecoveryAction.v1` is the bounded operator action
shape for recovery flows; it carries only whitelisted safe action classes and
must be backed by a Citadel decision.

`Platform.ErrorTaxonomy.v1` is the formal platform taxonomy entry for public and
operator-visible failure classes. It binds error code, error class, retry
posture, safe action, redaction class, and runbook path to the same tenant,
installation, actor, resource, authority, idempotency, trace, and release
manifest scope used by the authority and rejection envelopes.

`Platform.InstallationRevisionEpoch.v1` is the Phase 4 revision fence evidence
contract. Accepted fences carry the current installation revision, activation
epoch, lease epoch, node id, fence decision ref, and `stale_reason: "none"`.
Rejected fences must carry explicit stale attempted revision, activation, or
lease epoch evidence before any downstream workflow activity, lower read/write,
or stream attach can proceed.

`Platform.LeaseRevocation.v1` is the Phase 4 lease revocation propagation
contract. It records the revoked lease ref, revocation ref, non-empty lease
scope, cache invalidation ref, post-revocation attempt ref, and lease status so
operators can prove revoked leases are unusable across Mezzanine, Jido
Integration, AppKit, and Execution Plane boundaries.

## Phase 6 M8 Posture

`AuthorityTenantPropagation.v1` keeps the frozen `AuthorityDecision.v1` packet as
the authority primitive and adds an aggregate evidence shape for the production
simulation path. Evidence must carry tenant, authority decision, Mezzanine
authorization scope, no-spend budget, lineage, causation, idempotency, and Jido
Integration lower-facts propagation refs. Missing authority, missing budget,
cross-tenant authorization scope, lower-facts tenant mismatch, direct lower
shortcuts, and harness-only authority assertions fail closed.

## Execution Plane Boundary

The authority verifier checks only the opaque authority reference metadata that
Execution Plane admission needs: reference identity, payload hash, policy
version, decision id, decision hash, audience, and expiry posture. It does not
interpret Brain policy and it does not host lower runtime code.

## Persistence Posture

Citadel authority contracts default to `persistence-profile://mickey_mouse`.
Durable profiles are opt-in storage evidence only: they select ref-only store,
tier, partition, retention, debug-tap, and receipt refs without changing
authority semantics or storing raw credential/provider material. Authority
decisions read optional persisted posture from `extensions["citadel"]`, and
`AuthorityPacketV2.v1` carries optional posture refs for future durable receipt
hand-off.

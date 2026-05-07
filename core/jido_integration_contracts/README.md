# Jido Integration Contracts

This workspace package vendors the higher-order `Jido.Integration.V2` contract
slice that Citadel publishes today.

The slice includes:

- shared lineage packets:
  `SubjectRef`, `EvidenceRef`, `GovernanceRef`, `ReviewProjection`,
  `DerivedStateAttachment`
- durable submission packets:
  `CanonicalJson`, `SubmissionIdentity`, `AuthorityAuditEnvelope`,
  `ExecutionGovernanceProjection`, `SubmissionAcceptance`,
  `SubmissionRejection`, `BrainInvocation`
- the copied upstream validation helpers:
  `Contracts` and `Schema`

The package exists so the welded `citadel` Hex artifact remains self-contained
and publishable even while the wider upstream contracts package is not yet
available as a Hex dependency.

Citadel code must still treat this vendored package as a local runtime boundary.
Cross-repo coercion belongs in `Citadel.JidoIntegrationBridge.LineageCodec`.

`ExecutionGovernanceProjection` carries
`sandbox.acceptable_attestation` into the runtime and gateway shadows so the
Spine can build Execution Plane admission requests without inferring a hidden
local fallback.

## Persistence Documentation

See `docs/persistence.md` for tiers, defaults, adapters, unsupported selections, config examples, restart claims, durability claims, debug sidecar behavior, redaction guarantees, migration or preflight behavior, and no-bypass scope when applicable.

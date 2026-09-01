# Shared Contract Dependency Strategy

Jido Integration owns the higher-order `Jido.Integration.V2` shared contracts
in `../jido_integration/core/contracts`. Citadel declares that package through
the tuple-first Mix Workspace Ops seam; it does not carry a local mirror of the
`jido_integration_contracts` OTP app.

OuterBrain owns the Context ABI in `../outer_brain/core/context_abi`. Citadel's
`core/context_authority_contract` consumes that package through the same seam so
Context ABI packet structs and owner-local failure reason codes remain
single-owner.

## Packages Using The Shared Contract Slice

The public Citadel packages that rely on these shared modules declare committed
Hex requirements and allow an invocation-scoped MWO overlay to select managed
development coordinates:

- `core/citadel_governance`
- `bridges/invocation_bridge`
- `bridges/jido_integration_bridge`
- `bridges/projection_bridge`
- `core/conformance`
- `core/context_authority_contract` consumes `:outer_brain_context_abi` for
  Context ABI packets and `OuterBrain.ContextABI.Failure`

## Consumed Modules

The canonical package currently provides the shared modules Citadel publishes
across its runtime-facing seams:

- lineage packets:
  `Jido.Integration.V2.SubjectRef`,
  `Jido.Integration.V2.EvidenceRef`,
  `Jido.Integration.V2.GovernanceRef`,
  `Jido.Integration.V2.ReviewProjection`,
  `Jido.Integration.V2.DerivedStateAttachment`
- durable submission packets:
  `Jido.Integration.V2.CanonicalJson`,
  `Jido.Integration.V2.SubmissionIdentity`,
  `Jido.Integration.V2.AuthorityAuditEnvelope`,
  `Jido.Integration.V2.ExecutionGovernanceProjection`,
  `Jido.Integration.V2.SubmissionAcceptance`,
  `Jido.Integration.V2.SubmissionRejection`,
  `Jido.Integration.V2.BrainInvocation`
- shared validation helpers:
  `Jido.Integration.V2.Contracts`,
  the shared schema helper module from the `jido_integration_contracts`
  package

## Publication Rule

The welded `citadel` artifact emits `:jido_integration_contracts` as a normal
external dependency. Local development resolves that dependency to the sibling
Jido Integration checkout; published artifacts resolve it through the published
package or configured Git source.

That keeps the OTP app identity single-owner and prevents Citadel from
publishing a second package that defines `Jido.Integration.V2.*` modules.

The executable proof is
`test/citadel/jido_contract_home_verification_test.exs`, which verifies that the
canonical sibling package exists, owns `app: :jido_integration_contracts`, and
that Citadel no longer tracks `core/jido_integration_contracts`.

## Legacy Generated Artifact Disposition

The former `core/jido_integration_v2_contracts`,
`:jido_integration_v2_contracts`, and Citadel-local
`core/jido_integration_contracts` package names are retired. They must not
appear as tracked Citadel package paths, the current `dist/hex/citadel`
projection, or the current `dist/release_bundles/citadel` release bundle.

Any remaining `jido_integration_v2_contracts` path under ignored
`/dist/archive/` output is non-publishable generated history only. It is not a
dependency source, not a current projection input, and not release evidence.
`test/citadel/jido_contract_legacy_artifact_scan_test.exs` is the guard for
this disposition.

## Consumer Dependency Proof

Workspace consumers that directly compile against the shared contracts use
`workspace_dep({:jido_integration_contracts, "~> 0.1.0"})`. The allowed direct
consumers are
`core/citadel_governance`, `core/conformance`, `bridges/invocation_bridge`,
`bridges/jido_integration_bridge`, and `bridges/projection_bridge`.

Managed source selection belongs to the portfolio catalog, operator ledger, and
MWO overlay. Each committed tuple remains valid with ordinary standalone Mix.
The direct `citadel_domain_surface` package is not part of the default welded
Citadel artifact; when its lock references the shared contracts, it pins the
upstream Git repository with sparse `core/contracts` checkout.

`test/citadel/jido_contract_consumer_dependency_test.exs` enforces those
consumer modes and rejects independent local forks.

## Runtime Rule

The external shared package is still a boundary, not a license to mix
authoritative downstream structs freely into Citadel internals.

Citadel-owned bridge code must reconstruct shared lineage packets through
`Citadel.JidoIntegrationBridge.LineageCodec` before local bridge consumers
touch them.

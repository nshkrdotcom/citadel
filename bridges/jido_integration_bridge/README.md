# Citadel Jido Integration Bridge

Status: durable submission bridge slice.

## Owns

- Citadel-owned `ExecutionIntentEnvelope.V2 -> Jido.Integration.V2.BrainInvocation`
  projection
- the single mandatory shared-lineage coercion choke point for Citadel-local
  vendored `Jido.Integration.V2` structs
- the configurable downstream transport seam used by
  `Citadel.InvocationBridge`

## Dependencies

- `core/citadel_governance`
- `core/authority_contract`
- `core/execution_governance_contract`
- `bridges/invocation_bridge`
- `core/jido_integration_contracts`

## Posture

- bridge ownership stays in `citadel`
- the runtime-facing shared packet family stays `Jido.Integration.V2`
- transport is pluggable; packet projection and lineage coercion stay pure
- governed execution envelopes do not select transport from application env;
  production callers pass an explicit transport module for the single
  downstream effect
- the carried `session_id` is frozen lineage required by the shared contracts,
  not HostIngress session-continuity ownership
- typed `{:accepted, ...}` and `{:rejected, ...}` results stay synchronous;
  durable retry ownership remains upstream
- duplicate acceptances stay explicit in the typed `SubmissionAcceptance.status`
  field so replay-safe retries can remain idempotent without extra local queues

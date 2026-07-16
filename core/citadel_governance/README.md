# Citadel Governance

Status: durable authority owner.

## Owns

- pure values, compilers, reducers, and projectors
- the Postgres authority ledger for decision sessions, decisions, scoped
  grants, expiry/revocation truth, and policy continuity
- scope, service-admission, session-binding, and boundary-intent logic
- deterministic wrappers that must remain runtime-owner-free
- `Citadel.DecisionHash`
- the Citadel-owned `InvocationRequest`, `BoundaryIntent`, and `TopologyIntent` seam
- `Citadel.Governance.SubstrateIngress`, the pure substrate-origin compiler
  consumed by Mezzanine without host session continuity
- `Citadel.Governance.DurableAuthority`, the only durable ingress for authority
  facts consumed by governed provider and tool effects

## Dependencies

- `core/contract_core`
- canonical `jido_integration_contracts`
- `core/authority_contract`
- `core/observability_contract`
- `core/policy_packs`

## Authority posture

Wave 2 freezes the public carrier shapes before deeper runtime behavior:

- `Citadel.DecisionHash` computes `decision_hash` from normalized shared
  `AuthorityDecision.v1` packets through `core/contract_core`
- `Citadel.InvocationRequest` is a Citadel seam, not an import of the current
  downstream `Jido.Integration.V2.InvocationRequest`
- `InvocationRequest.authority_packet` is explicitly the shared
  `AuthorityDecision.v1` packet
- structured ingress stays explicit through provenance refs or hashes; raw NL
  is not the kernel contract
- substrate-origin ingress is library-shaped: it selects policy, derives the
  decision hash, builds the authority packet, and emits the lower invocation
  request/outbox entry without `Citadel.HostIngress`, `SessionServer`,
  `SessionDirectory`, or persisted host-session continuity
- substrate-origin ingress also applies the selected policy pack's
  `ExecutionPolicy`, compiling sandbox, egress, approval, allowed-tool,
  allowed-operation, workspace-mutability, placement, and budget posture into
  `ExecutionGovernance.v1`
- governance compilation rejects lower posture downgrades before outbox
  publication; lower packages receive the exact policy projection rather than
  recomputing product-local safety settings
- decisions and grants commit atomically in the Citadel Postgres database
- grant reconstruction verifies the frozen contract and persisted digests;
  malformed or partial state fails closed
- verification serializes against revocation, and closing a decision session
  revokes all of its active grants
- memory, no-op, fixture, and caller-supplied authority stores are not production
  selections

## Hardening

Wave 10 adversarial hardening is package-local and runnable through normal Mix flows:

```bash
mix hardening.adversarial
mix hardening.mutation
mix hardening
```

- `mix hardening.adversarial` runs the hostile-input property suite in `test/citadel/governance_adversarial_test.exs`
- `mix hardening.mutation` runs build-failing mutation checks over `intent_envelope`, `decision_values`, `kernel_values`, and `runtime_values`
- `mix hardening` runs both gates

## Persistence Documentation

See `docs/persistence.md` for tiers, defaults, adapters, unsupported selections, config examples, restart claims, durability claims, debug sidecar behavior, redaction guarantees, migration or preflight behavior, and no-bypass scope when applicable.

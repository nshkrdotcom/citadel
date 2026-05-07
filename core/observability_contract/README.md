# Citadel Observability Contract

Status: Phase 4 audit and observability contract owner.

## Owns

- Citadel trace vocabulary ownership
- low-cardinality telemetry naming ownership
- backend-neutral observability conventions
- `Platform.AuditHashChain.v1` immutable audit-chain evidence ownership
- `Platform.ObservabilityCardinalityBounds.v1` metric, trace, audit, and
  incident export cardinality bounds ownership

## Dependencies

- `core/contract_core`

## Phase 4 Posture

The package owns operator- and release-facing observability contracts without
coupling them to a backend. Audit evidence is append-only, hash-linked, scoped
to tenant/installation/resource/authority/idempotency/trace/release refs, and
must fail closed if actor or hash-chain continuity evidence is missing.

## Persistence Documentation

See `docs/persistence.md` for tiers, defaults, adapters, unsupported selections, config examples, restart claims, durability claims, debug sidecar behavior, redaction guarantees, migration or preflight behavior, and no-bypass scope when applicable.

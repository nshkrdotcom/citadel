# Citadel Provider Auth Fabric

Owner phase: Phase 2 / ADDL-PHASE-04.

This package owns the contract-level provider auth fabric. It registers
provider accounts, issues credential-handle refs, prepares lease and
materialization requests, revokes handles, emits audit maps, and enforces
ref-family separation.

The package is intentionally ref-only. It never reads env vars, native login
files, token stores, singleton clients, or SDK defaults as governed authority.

Phase 6 adds ref-only persistence posture to registrations, credential handles,
leases, and emitted audit events. The default profile is
`persistence-profile://mickey_mouse`; durable profiles are explicit storage
evidence and never authorize raw secret, provider payload, or credential body
persistence.

## QC

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

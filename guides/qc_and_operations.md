# Citadel QC And Operations

Release: `0.1.0` (2026-08-10).

## Local Commands

```bash
mix deps.get
mix ci
```

Run package-local tests for authority, policy, conformance, and bridge changes,
then root `mix ci` before commit.

## Scanner And Proof Obligations

Citadel changes must keep these obligations green:

- authority and execution-governance contract tests;
- Context ABI authority resolver fixtures for unresolved evidence,
  cross-tenant evidence, and verified authority refs;
- policy pack downgrade-rejection tests;
- host-ingress and substrate-ingress bridge tests;
- StackLab governance, tenant, connector, and proof-matrix checks where the
  change crosses repo boundaries;
- no Regex usage in touched code/tests;
- no dynamic atom construction from runtime input;
- every signal, lease, partition, or boundary worker is supervised.

## Secrets And Live Providers

Citadel carries credential posture and lease refs, not raw secrets. GitHub or
Linear credentials are materialized below Citadel through Jido Integration
leases and live product/proof commands.

If a live acceptance command exercises Citadel authority for GitHub or Linear,
prefix that command with:

```bash
~/scripts/with_bash_secrets
```

## Tenant, Observability, And Replay

Authority decisions, host-ingress packets, governance projections, and trace
events must carry tenant, authority, operation, binding, credential posture,
and evidence refs. AITrace receives observability events; Citadel must emit
enough structured facts to prove authorization without raw provider payloads.

## Documentation Checks

After doc edits, run:

```bash
test -f README.md
find guides -maxdepth 1 -type f -name '*.md' -print | sort
git diff --check -- README.md guides
```

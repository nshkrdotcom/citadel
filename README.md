<p align="center">
  <img src="assets/citadel.svg" alt="Citadel" width="220" />
</p>

# Citadel

Citadel is the host-local Brain kernel for a generic agentic OS. It accepts structured ingress at the kernel boundary, compiles Brain policy and planning decisions, preserves host-local session continuity, and projects Brain-authored packets toward the shared `jido_integration` contracts layer.

This repository is now aligned to the packet-defined non-umbrella workspace. The old single-package scaffold is gone; the package graph and ownership boundaries are the source of truth.

The workspace now also carries a separately publishable northbound typed surface
package:

- `surfaces/citadel_domain_surface`
- public namespace: `Citadel.DomainSurface`
- role: typed host-facing command, query, route, and capability boundary above
  the Citadel kernel

## Stack Position

```text
host surfaces / shells
  -> Citadel
      -> jido_integration
          -> execution plane
              -> providers, runtimes, services, connectors
```

Citadel owns:

- canonical Brain context construction
- structured ingress handling at `IntentEnvelope`
- objective, plan, topology, and authority compilation
- host-local session continuity and runtime coordination
- projection into shared authority, invocation, review, and derived-state seams

Citadel does not own:

- durable run, attempt, approval, review, or artifact truth
- lower execution transports or provider runtimes
- raw credential lifecycle
- raw natural-language interpretation
- product-shell UI or channel state

For governed execution, Citadel authors the Brain-side governance packet and
authority reference. `ExecutionGovernance.v1` now requires
`sandbox.acceptable_attestation`, so a Brain decision names the target
attestation classes it is willing to admit instead of relying on implicit local
fallback. Citadel also provides an `ExecutionPlane.Authority.Verifier`
implementation that node hosts may register to validate Citadel authority refs;
that does not make Citadel a lane host or execution node.

The coding-ops policy pack now carries explicit execution posture: minimum
sandbox level, maximum egress, approval mode, allowed tools and operations,
workspace mutability, command classes, and local/remote placement intents.
`Citadel.Governance.SubstrateIngress` compiles that posture into
`ExecutionGovernance.v1` and rejects sandbox, egress, approval, tool,
operation, or placement downgrades before lower submission.

## Workspace

```text
citadel/
  core/
    contract_core/
    jido_integration_contracts/
    authority_contract/
    execution_governance_contract/
    observability_contract/
    policy_packs/
    citadel_governance/
    citadel_kernel/
    conformance/
  bridges/
    invocation_bridge/
    query_bridge/
    signal_bridge/
    boundary_bridge/
    host_ingress_bridge/
    projection_bridge/
    trace_bridge/
  apps/
    coding_assist/
    operator_assist/
    host_surface_harness/
  surfaces/
    citadel_domain_surface/
```

Package ownership is explicit:

- `core/*` owns values, contracts, policy packs, runtime coordination, and conformance.
- `bridges/*` owns adapter code only.
- `apps/*` owns thin proof-app composition shells and stays above the kernel.
- `surfaces/*` owns northbound publishable typed surfaces that sit above the
  kernel without becoming second cores.

The third proof app, `apps/host_surface_harness`, is part of the workspace from day one. It exists to prove host/kernel seams, multi-session behavior, and structured ingress above Citadel without pushing those concerns into the core.

The public structured host-ingress seam now lives in
`bridges/host_ingress_bridge`. That package owns the typed host-facing request
context, accepted-result contract, pure invocation compiler, and the public
`Citadel.HostIngress` facade that host applications call before the lower
`jido_integration` seam.

## Toolchain And Build

Citadel is pinned to Elixir `~> 1.19` and OTP 28. The repo-level `.tool-versions` file tracks the exact bootstrap pair:

- `elixir 1.19.5-otp-28`
- `erlang 28.3`

The root Mix project is a tooling-only workspace orchestrator. Wave 1 materializes the packet-pinned workspace tooling and dependency posture explicitly:

- `{:blitz, "~> 0.2.0", runtime: false}` for workspace fanout
- `{:weld, "~> 0.7.2", runtime: false}` for repo-local package projection and release preparation
- `{:jcs, "~> 0.2.0"}` in `core/contract_core` for RFC 8785 / JCS ownership

Common commands:

```bash
mix deps.get
mix monorepo.deps.get
mix monorepo.compile
mix monorepo.test
```

Static analysis and build hardening commands:

```bash
mix lint.packet_seams
mix lint.strict
mix monorepo.dialyzer
mix static.analysis
mix ci
```

Governance adversarial hardening commands:

```bash
mix hardening.governance.adversarial
mix hardening.governance.mutation
mix hardening.governance
```

- `mix hardening.governance.adversarial` runs the Wave 10 property suites in `core/citadel_governance` and `core/policy_packs`
- `mix hardening.governance.mutation` runs build-failing mutation checks for the same governance packages
- `mix hardening.governance` runs both gates

The Wave 9 hardening posture is enforced in code and CI:

- `mix lint.packet_seams` fails on `String.to_atom/1` anywhere in packet-critical workspace paths and blocks raw `map()` or `keyword()` public seam specs on the tracked ingress, bridge, runtime, and trace modules.
- `mix lint.strict` runs a curated high-signal Credo config across the workspace libraries instead of style-noise checks that do not protect packet seams.
- `mix static.analysis` also runs the `citadel_domain_surface` package-local
  seam lint and strict lint so the northbound typed boundary keeps its own
  publication discipline inside the monorepo.
- `mix monorepo.dialyzer` fans out `mix dialyzer --halt-exit-status` across the real workspace graph through Blitz, so any Dialyzer warning fails the build.
- `.github/workflows/ci.yml` runs format, compile, packet seam lint, strict lint, Dialyzer, and tests as separate CI steps.

Publication is now finalized as a derivative workspace boundary. The repo-local
Weld manifest lives at `packaging/weld/citadel.exs`, projects the public
`citadel` artifact in package-projection mode, keeps `apps/*`,
`core/conformance`, and `surfaces/citadel_domain_surface` out of the default
artifact, carries the
`core/jido_integration_contracts` slice in-workspace, and preserves package
ownership instead of flattening the workspace into a monolith.

The welded artifact declares the `execution_plane` package dependency so the
authority verifier boundary is explicit. During local in-flight workspace
development this may resolve to the sibling Execution Plane checkout at
`core/execution_plane`; formal publication should use the published
`execution_plane` package.

Common publication commands:

```bash
mix release.prepare
mix release.track
mix release.archive
```

`mix release.track` updates the orphan-backed `projection/citadel` branch so
downstream repos can pin a real generated-source ref before any formal release
boundary exists.

## Shared Contract Strategy

Citadel now carries the higher-order `Jido.Integration.V2` lineage contract
slice as an in-workspace package at `core/jido_integration_contracts`.

That package provides the shared modules the public Citadel surface publishes
today:

- `Jido.Integration.V2.SubjectRef`
- `Jido.Integration.V2.EvidenceRef`
- `Jido.Integration.V2.GovernanceRef`
- `Jido.Integration.V2.ReviewProjection`
- `Jido.Integration.V2.DerivedStateAttachment`

Keeping that slice inside the workspace lets the welded `citadel` artifact stay
self-contained and Hex-buildable while preserving the shared public module
names.

## Documentation

The packet that drives this repo lives at:

- `/home/home/p/g/n/mezzanine/nshkrdotcom/docs/20260409/citadel_ground_up_design_docset`

Local workspace docs now live in:

- `README.md`
- `docs/README.md`
- `docs/workspace_topology.md`
- `docs/shared_contract_dependency_strategy.md`
- package-level `README.md` files under every `core/*`, `bridges/*`, `apps/*`,
  and `surfaces/*` package

## Fault Injection Harness

The canonical Docker-based Toxiproxy harness remains at `dev/docker/toxiproxy`.

```bash
docker compose -f dev/docker/toxiproxy/docker-compose.yml -p citadel-toxiproxy up -d
dev/docker/toxiproxy/verify.sh
mix hardening.infrastructure_faults
```

## Temporal developer environment

Temporal runtime development is managed from `/home/home/p/g/n/mezzanine`
through the repo-owned `just` workflow. Do not start ad hoc Temporal processes
or rely on the `temporal` CLI as the implementation runbook.

## Native Temporal development substrate

Temporal runtime development is managed from `/home/home/p/g/n/mezzanine` through the repo-owned `just` workflow, not by manually starting ad hoc Temporal processes.

Use:

```bash
cd /home/home/p/g/n/mezzanine
just dev-up
just dev-status
just dev-logs
just temporal-ui
```

Expected local contract: `127.0.0.1:7233`, UI `http://127.0.0.1:8233`, namespace `default`, native service `mezzanine-temporal-dev.service`, persistent state `~/.local/share/temporal/dev-server.db`.

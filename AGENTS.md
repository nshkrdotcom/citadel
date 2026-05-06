# Monorepo Project Map

- `./apps/coding_assist/mix.exs`: Thin coding-focused proof app shell for Citadel
- `./apps/host_surface_harness/mix.exs`: Thin host/kernel seam proof harness for Citadel
- `./apps/operator_assist/mix.exs`: Thin operator workflow proof app shell for Citadel
- `./bridges/boundary_bridge/mix.exs`: Boundary lifecycle adapters for Citadel
- `./bridges/host_ingress_bridge/mix.exs`: Citadel-owned public structured host-ingress bridge
- `./bridges/invocation_bridge/mix.exs`: Invocation handoff adapters for Citadel
- `./bridges/jido_integration_bridge/mix.exs`: Citadel-owned lower-gateway bridge adapters
- `./bridges/projection_bridge/mix.exs`: Review and derived-state publication adapters for Citadel
- `./bridges/query_bridge/mix.exs`: Durable-state rehydration adapters for Citadel
- `./bridges/signal_bridge/mix.exs`: Signal ingress normalization adapters for Citadel
- `./bridges/trace_bridge/mix.exs`: Trace publication adapters for Citadel
- `./core/authority_contract/mix.exs`: Brain-authored authority packet ownership for Citadel
- `./core/citadel_governance/mix.exs`: Stateless governance values and deterministic policy compilation for Citadel
- `./core/citadel_kernel/mix.exs`: Host-stateful session continuity and runtime coordination for Citadel
- `./core/conformance/mix.exs`: Black-box conformance and composition coverage for Citadel
- `./core/contract_core/mix.exs`: Neutral value helpers and canonical JSON ownership for Citadel
- `./core/execution_governance_contract/mix.exs`: Execution governance packet ownership for Citadel
- `./core/jido_integration_contracts/mix.exs`: Citadel-local higher-order Jido Integration V2 contract slice
- `./core/observability_contract/mix.exs`: Trace and telemetry contract ownership for Citadel
- `./core/policy_packs/mix.exs`: Policy pack ownership and selection surfaces for Citadel
- `./mix.exs`: Tooling root for the Citadel non-umbrella monorepo
- `./surfaces/citadel_domain_surface/mix.exs`: Typed host-facing domain surface package above the Citadel kernel

Generated Weld output under `dist/hex/citadel/mix.exs` is not a source
workspace project. Treat it as generated publication output and verify it with
Weld/Citadel gates when publication metadata changes.

# AGENTS.md

## Onboarding

Read `ONBOARDING.md` first for the repo's one-screen ownership, first command,
and proof path.

## Execution Plane dependency wiring

- `core/authority_contract` consumes the publishable Execution Plane substrate
  at `../../../execution_plane/core/execution_plane` for local sibling
  development.
- Citadel Weld/local git fallback must keep `subdir: "core/execution_plane"`
  when it points at the sibling Execution Plane git checkout.
- Do not point `:execution_plane` at the sibling repo root without that subdir.
  The root is the non-published Blitz workspace project, not the Hex package.

## Temporal developer environment

Temporal CLI is implicitly available on this workstation as `temporal` for local durable-workflow development. Do not make repo code silently depend on that implicit machine state; prefer explicit scripts, documented versions, and README-tracked ergonomics work.

## Native Temporal development substrate

When Temporal runtime behavior is required, use the stack substrate in `/home/home/p/g/n/mezzanine`:

```bash
just dev-up
just dev-status
just dev-logs
just temporal-ui
```

Do not invent raw `temporal server start-dev` commands for normal work. Do not reset local Temporal state unless the user explicitly approves `just temporal-reset-confirm`.

<!-- gn-ten:repo-agent:start repo=citadel source_sha=ab276c0640772b73065ab12bf05d77be51f1bb67 -->
# citadel Agent Instructions Draft

## Owns

- Typed Brain kernel.
- DomainSurface.
- Policy packets.
- Authority posture.
- Structured host ingress.
- Governance compilation.

## Does Not Own

- Durable run/review truth.
- Connector credential lifecycle.
- Lower execution lanes.
- Raw natural-language interpretation.
- Product UI.

## Allowed Dependencies

- GroundPlane refs.
- Jido Integration contract seams.
- Execution Plane authority verifier contracts where explicitly intended.
- AITrace observability contracts.

## Forbidden Imports

- Product modules.
- Raw provider SDK calls.
- Mezzanine persistence internals.

## Verification

- `mix ci`
- Packet seam lint.
- Governance hardening tests when policy or authority changes.

## Escalation

If a decision requires durable truth, hand it to Mezzanine/Jido Integration
instead of adding persistence ownership here.
<!-- gn-ten:repo-agent:end -->

## Blitz 0.3.0 operational note

Root workspace Blitz uses published Hex `~> 0.3.0` by default; `.blitz/` is committed compact impact state after green QC. Source and `mix.exs` changes cascade through reverse workspace dependencies; docs-only changes should stay owner-local.

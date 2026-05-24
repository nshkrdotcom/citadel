# Workspace Topology

Citadel is a non-umbrella Elixir monorepo with explicit package ownership.

## Core Packages

- `core/contract_core`: neutral identifiers, host-local refs, and RFC 8785 / JCS canonicalization helpers
- `core/authority_contract`: Brain-authored `AuthorityDecision.v1` schema ownership
- `core/context_authority_contract`: Context ABI authority grants, model-class
  allowlist verdicts, route-policy authorization, payload-mode gates, and
  promotion/rollback authority checks
- `core/execution_governance_contract`: brain-authored `ExecutionGovernance.v1` packet ownership
- `core/observability_contract`: trace and telemetry vocabulary ownership
- `core/policy_packs`: policy pack definitions and normalization helpers
- `core/citadel_governance`: pure values, compilers, reducers, and projectors
- `core/citadel_kernel`: runtime coordination, session continuity, and local ownership processes
- `core/conformance`: black-box conformance and composition coverage

## Bridge Packages

- `bridges/invocation_bridge`: invocation handoff and lower-seam alignment placeholder
- `bridges/jido_integration_bridge`: Citadel-owned lower-gateway durable submission adapter
- `bridges/query_bridge`: durable-state rehydration adapters
- `bridges/signal_bridge`: signal ingress normalization adapters
- `bridges/boundary_bridge`: boundary lifecycle and metadata adapters
- `bridges/projection_bridge`: shared review and derived-state publication adapters
- `bridges/trace_bridge`: AITrace-facing trace publication adapters

Bridge packages stay vertical. They depend on core and runtime surfaces, not on sibling bridges.

## App Packages

- `apps/coding_assist`: thin coding-focused proof app shell
- `apps/operator_assist`: thin operator workflow proof app shell
- `apps/host_surface_harness`: thin host/kernel seam proof app with baseline direct `IntentEnvelope` construction

App packages remain composition shells. They do not become second cores.

## Surface Packages

- `surfaces/citadel_domain_surface`: typed host-facing command, query, route,
  admin, and capability surface above the Citadel kernel

Surface packages remain northbound publishable boundaries. They are not kernel
core packages and they are not bridge packages.

## Publication Posture

Publication remains derivative of the workspace architecture, but the default
public artifact is now explicit:

- repo-local Weld manifest: `packaging/weld/citadel.exs`
- artifact id and package name: `citadel`
- mode: package projection, not monolith
- roots: `core/citadel_kernel`, `core/connector_binding`,
  `core/context_authority_contract`, and `core/provider_auth_fabric`
- selected bridge closure: all `bridges/*`
- excluded by default: `apps/*`, `core/conformance`,
  `surfaces/citadel_domain_surface`, and the root tooling project

The welded artifact keeps the source workspace authoritative. It projects the
runtime-facing core packages and selected bridges without collapsing ownership
or turning proof packages into runtime dependencies. Shared
`Jido.Integration.V2` contracts remain owned by the Jido Integration package and
are declared as an external dependency.

`surfaces/citadel_domain_surface` remains directly publishable as its own
workspace package rather than being absorbed into the default welded `citadel`
artifact.

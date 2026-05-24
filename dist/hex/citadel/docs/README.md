# Citadel Docs

This directory now tracks the packet-aligned repo documentation for the Citadel workspace.

Start here:

- [`../README.md`](../README.md) for the workspace overview and build commands
- [`../README.md`](../README.md#toolchain-and-build) for the Wave 9 static-analysis and CI commands
- [`workspace_topology.md`](./workspace_topology.md) for package boundaries and ownership
- [`publication.md`](./publication.md) for the welded artifact boundary and release flow
- [`shared_contract_dependency_strategy.md`](./shared_contract_dependency_strategy.md) for the canonical `:jido_integration_contracts` dependency posture
- [`../core/context_authority_contract/README.md`](../core/context_authority_contract/README.md) for Context ABI authority grants and verdicts
- `../surfaces/citadel_domain_surface/README.md` for the northbound typed
  surface package that now lives inside the Citadel workspace

The older single-package and "AI Empire" design notes were removed because they no longer describe the workspace that this repo is building.

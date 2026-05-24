# Publication

Citadel publishes a welded public artifact as a derivative of the workspace
graph.

## Default Artifact

- manifest: `packaging/weld/citadel.exs`
- artifact id: `citadel`
- mode: package projection
- roots: `core/citadel_kernel`, `core/connector_binding`,
  `core/context_authority_contract`, and `core/provider_auth_fabric`
- selected bridge closure: all `bridges/*`
- excluded by default: `apps/*`, `core/conformance`,
  `surfaces/citadel_domain_surface`, and the root tooling project

That default shape keeps the runtime-facing product packages public without
collapsing package ownership into a monolith.

## Direct Surface Publication

The workspace also contains `surfaces/citadel_domain_surface` as a separately
publishable northbound package.

That package is intentionally not part of the default welded `citadel`
artifact. It remains a direct package publication concern so the Citadel kernel
artifact and the typed host-facing surface can evolve on distinct publication
tracks inside the same monorepo.

## Release Flow

Use the repo-local Weld manifest instead of hand-built packaging steps:

```bash
mix dist.generated.verify
mix release.prepare
mix release.track
mix release.archive
```

`dist/hex/citadel` is retained generated distribution output, not a second
source tree. `mix dist.generated.verify` runs `mix weld.verify` to regenerate
that package projection and then checks `git diff --exit-code --
dist/hex/citadel`, so CI fails if checked-in distribution files drift from the
workspace source graph.

`mix release.track` updates the orphan-backed `projection/citadel` branch so
downstream repos can pin a real generated-source ref before any formal release
boundary exists.

`mix weld.verify` is the packet-facing publication gate. It projects the
artifact, runs verification against the generated package, and confirms that
workspace-external dependencies are canonicalized to publishable dependency
declarations. The higher-order `Jido.Integration.V2` contract package is owned
by Jido Integration and declared as `:jido_integration_contracts`; the generated
`citadel` artifact must not embed a Citadel-local copy of those modules.

## Ownership Rule

The welded artifact does not redefine the workspace architecture.

- `core/*` packages except `core/conformance` remain the public core surface;
  Context ABI authority is owned by `core/context_authority_contract`
- bridge packages remain bridge packages inside the projection
- `apps/*` stay proof shells above the kernel and are not published by default
- `surfaces/citadel_domain_surface` remains a direct package publication unit,
  not part of the default welded runtime artifact
- the root workspace project stays tooling-only

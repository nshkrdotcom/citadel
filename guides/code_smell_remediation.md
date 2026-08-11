# Citadel Code Smell Remediation

Release: `0.1.0` (2026-08-10).

This guide records the repo-local implementation posture after the GN-TEN code
smell remediation pass.

## What Changed

- Checked-in distribution duplication is treated as generated output, not
  source of truth.
- Signal ingress responsibilities are split so routing, validation, state, and
  projection are not owned by one GenServer.
- Session directory mutable state is owned explicitly rather than hidden in
  `:persistent_term`.
- Runtime contract mega-files are split into smaller authority, observability,
  boundary, and host-facing values.
- Library code no longer starts dependencies implicitly; processes must be
  supervised by the owning application.
- Partition worker public starts are narrowed to supervised entrypoints.

## Maintainer Rules

- Citadel owns authority and governance truth, not lower execution or product
  lifecycle truth.
- Runtime state must have a named owner and supervision path.
- Do not add compatibility aliases that bypass supervision or authority
  verification.

## QC

Use the repo root gate:

```bash
mix ci
```

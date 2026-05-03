# Citadel Trace Bridge

Status: Wave 5 contract frozen, hardened for Wave 8 publication closure.

## Owns

- trace publication adapter placement
- backend-facing span and event shaping
- observability export bridge seams
- stable translation from normalized `Citadel.TraceEnvelope` values into AITrace

## Dependencies

- `core/citadel_kernel`
- `core/observability_contract`
- `core/citadel_governance`
- `AITrace`

## Current Posture

The bridge now consumes normalized `Citadel.TraceEnvelope` values only and
keeps AITrace-specific export concerns outside the core packages.

- required trace families remain event-shaped
- completed spans stay additive and one-shot; there is no open-span API
- governed publication uses explicit adapter or legacy-exporter options rather
  than ambient application env
- best-effort post-commit publication stays in runtime via `TracePublisher`
- the welded public artifact includes this bridge without leaking AITrace into
  the core package graph

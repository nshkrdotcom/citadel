# Citadel Native Auth Assertion

Owner phase: Phase 2 / ADDL-PHASE-05.

This package owns non-secret native auth assertion refs for CLI and
SDK-native auth roots. It records that an external authority inspected or
selected a native auth source, but it never stores raw tokens, auth JSON,
OAuth refresh tokens, API keys, private local paths, or provider payloads.

## Contract

- Assertions are ref-only.
- Provider family, provider account, native subject, target, issuer, and
  evidence refs are required.
- Secret-shaped fields are rejected before an assertion is built.
- Summaries are safe for authority packets, audit, AppKit DTOs, and traces.
- Phase 6 summaries include ref-only persistence posture. Memory is the default
  profile; durable profiles are storage evidence only and still reject raw native
  auth files, tokens, auth JSON, and provider payloads.

## QC

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

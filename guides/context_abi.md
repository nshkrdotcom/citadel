# Citadel Context ABI Authority

Release: `0.1.0` (2026-08-10).

Citadel owns the authority decision attached to Context ABI packets. It does
not build context packets, render prompts, execute models, or reduce workflow
truth.

## Owned Outputs

- context authority grant refs;
- deny/fail-closed verdicts for context compile and render requests;
- policy bundle and schema refs attached to grants;
- expiry and freshness posture for portable authority evidence.

## Handoff

Mezzanine requests authority before admitting or dispatching governed AI work.
OuterBrain receives authority evidence as refs and policy facts, not product
session state or raw prompts. Jido Integration receives only invocation refs and
credential/authority posture from Mezzanine.

When a caller supplies an evidence resolver, Citadel verifies that the
authority ref resolves and that the resolved evidence tenant matches the
request tenant. Unresolved or cross-tenant evidence fails closed with a bounded
authority failure reason. Tests may still use the ref-only fixture posture when
no resolver is supplied.

Citadel must remain a pure authority owner. StackLab proves the full path, but
Citadel package tests must prove grant validation, expiry, redaction bounds, and
fail-closed behavior.

## Local QC

```bash
mix ci
```

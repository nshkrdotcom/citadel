# Citadel Context ABI Authority

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

Citadel must remain a pure authority owner. StackLab proves the full path, but
Citadel package tests must prove grant validation, expiry, redaction bounds, and
fail-closed behavior.

## Local QC

```bash
mix ci
```

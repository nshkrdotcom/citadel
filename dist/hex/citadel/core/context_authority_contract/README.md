# Citadel Context Authority Contract

Citadel Context Authority owns the policy-facing authority seam for
OuterBrain Context ABI packets.

It answers whether a compiled context packet can be used for a tenant, actor,
route policy, model class allowlist, payload mode, redaction class, and
promotion/rollback operation. It emits bounded grant refs and owner-local
`OuterBrain.ContextABI.Failure` values. It does not compile context, admit
workflow truth, render prompts, invoke models, or write traces.

## Public Modules

- `Citadel.ContextAuthority`
- `Citadel.ContextAuthority.Authorizer`
- `Citadel.ContextAuthority.PolicyAuthorizer`
- `Citadel.ContextAuthority.AuthorityRequest`
- `Citadel.ContextAuthority.Grant`
- `Citadel.ContextAuthority.RuntimeDeps`

## Boundary Rules

- Inputs are Context ABI packets and ref-only authority requests.
- Raw prompts, memory bodies, provider payloads, credentials, and lower store
  values are not authority payloads.
- Model class and route policy verdicts are explicit.
- Tenant mismatches, stale policy windows, redaction downgrades, unadmitted
  trust classes, and disallowed promotion/rollback operations fail closed.

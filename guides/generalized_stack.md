# Citadel Generalized Stack Boundary

## Responsibility

Citadel owns authority compilation, policy posture, Brain/kernel context,
host-ingress contracts, substrate ingress governance, connector binding
authority, observability contracts, and downgrade rejection.

It does not own durable product workflow rows, connector SDK execution, runtime
lanes, credential storage, product UI, or primitive persistence rules.

## Public Interfaces

Primary package groups:

- `core/authority_contract`, `core/execution_governance_contract`,
  `core/context_authority_contract`, `core/observability_contract`, and
  `core/contract_core`;
- `core/policy_packs`, `core/citadel_governance`, `core/citadel_kernel`,
  `core/conformance`, `core/connector_binding`, `core/provider_auth_fabric`,
  and `core/native_auth_assertion`;
- bridge packages for invocation, query, signal, boundary, host ingress,
  projection, trace, and Jido Integration;
- `surfaces/citadel_domain_surface` and proof apps.

## Dependency Rules

Allowed dependencies:

- Jido Integration contracts for lower gateway and connector binding facts;
- GroundPlane primitive refs when governance needs shared lower identifiers;
- AITrace/observability contracts for proof and replay evidence;
- AppKit/domain surfaces only at northbound typed boundaries.

Forbidden dependencies:

- product-specific policy defaults in generic packs;
- direct connector SDK calls;
- raw credential material in governance packets;
- provider-default lower dispatch from policy code;
- unsupervised processes in signal, lease, or boundary workers.

## Provider Vocabulary Zoning

Provider terms may exist in provider auth fabric, connector binding resources,
native auth assertions, receipts, and traces. Generic authority decisions should
name operation classes, posture, binding refs, manifest refs, credential lease
refs, and allowed tool classes.

## Extravaganza Cutover Proof

Extravaganza's governed live proof uses Citadel as the authority boundary for
issue-tracker source admission, source publication, source-tool execution,
coding-runtime turns, proposed-change evidence, and proposed-change cleanup.
The proof expects route evidence to include authority refs alongside binding,
manifest, credential-lease, lower-request, receipt, projection, evidence, and
trace refs.

Citadel does not decide by closed provider family branches in generic policy.
Provider-specific facts can appear in provider auth fabric, connector-binding
data, receipts, traces, and product terminology. Generic policy packs should
continue to express allowed operation classes, posture, tool classes, sandbox
and egress posture, approval mode, and binding/manifest constraints.

## Migration And Cleanup Ownership

Citadel cleanup work removes provider-specific generic policy, bridge
shortcuts, duplicated provider family classifiers, stale host-ingress shapes,
and obsolete conformance fixtures only after replacement contracts and
StackLab/Citadel tests are green.

## Context ABI Authority

`core/context_authority_contract` is the Citadel-owned seam for Context ABI
packets. It authorizes context access, model class allowlists, route policies,
payload modes, redaction posture, promotion, and rollback using ref-only
requests and grants. It does not compile context packets, render prompts,
invoke models, or record durable workflow truth.

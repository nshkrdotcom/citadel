# Citadel Connector Binding

Owner phase: Phase 3 / ADDL-PHASE-06.

This package owns connector binding identity at the registry layer. A binding
is separate from provider account identity, credential handles, credential
leases, tenant refs, target refs, attach grants, and operation-policy refs.

The package is ref-only. It rejects raw credential material, raw provider
payloads, unmanaged env auth, native auth files, singleton clients, and default
clients.

## QC

```bash
ASDF_ELIXIR_VERSION=1.19.5-otp-28 mix format --check-formatted
ASDF_ELIXIR_VERSION=1.19.5-otp-28 mix compile --warnings-as-errors
ASDF_ELIXIR_VERSION=1.19.5-otp-28 mix test
```

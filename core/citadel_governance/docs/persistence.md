# Citadel Governance Persistence

Citadel owns durable authority decisions, scoped grants, revocations, and
decision-session lifecycle in its dedicated Postgres database. The production
host supervises `Citadel.Governance.Persistence.child_spec/1`, runs migrations
from `priv/repo/migrations`, and requires `preflight!/0` before advertising any
governed effect.

## Production profile

The supported profiles are `:integration_postgres` and `:ops_durable`; both use
`Citadel.Governance.Repo`. Memory, no-op, fixture, static-success, and custom
backend selections are rejected. There is no fallback when Postgres or the
canonical schema is unavailable.

```elixir
children = [
  Citadel.Governance.Persistence.child_spec(
    profile: :ops_durable,
    repo_options: [url: database_url]
  )
]

:ok = Citadel.Governance.Persistence.preflight!()
```

Release configuration supplies credentials to the Repo. Runtime library code
does not read the environment or credential files.

## Durable facts and invariants

- a decision session pins tenant, subject, and policy epoch;
- a permitted decision and its exact scoped grant commit atomically;
- decisions and revocation events are append-only;
- a grant permits one database-enforced `active -> revoked` transition;
- verification locks, reconstructs, digest-checks, and contract-validates the
  current grant before evaluating exact scope and expiry;
- closing a decision session revokes every active grant in the same transaction;
- secret-bearing or oversized decision/grant payloads are rejected before
  persistence.

The ledger stores authority facts and safe references only. Provider secrets,
credentials, raw prompts, provider payloads, auth headers, signed URLs, and
product review state are not Citadel persistence.

## Local database QC

```bash
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
mix test test/citadel/durable_authority_test.exs
```

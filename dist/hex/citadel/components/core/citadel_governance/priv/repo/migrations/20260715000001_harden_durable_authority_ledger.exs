defmodule Citadel.Governance.Repo.Migrations.HardenDurableAuthorityLedger do
  use Ecto.Migration

  def change do
    create(
      constraint(:citadel_scoped_grants, :citadel_scoped_grants_payload_check,
        check:
          "NOT (grant_payload ?| ARRAY['status', 'issued_at', 'expires_at', " <>
            "'revocation_ref', 'revoked_at'])"
      )
    )
  end
end

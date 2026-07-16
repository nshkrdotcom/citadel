defmodule Citadel.Governance.Repo do
  @moduledoc "Postgres owner for durable Citadel authority facts."

  use Ecto.Repo,
    otp_app: :citadel_governance,
    adapter: Ecto.Adapters.Postgres
end

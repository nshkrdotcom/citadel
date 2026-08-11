import Config

config :citadel_governance, Citadel.Governance.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("CITADEL_GOVERNANCE_TEST_DATABASE", "citadel_governance_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2,
  log: false

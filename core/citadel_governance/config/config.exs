import Config

config :citadel_governance,
  ecto_repos: [Citadel.Governance.Repo]

import_config "#{config_env()}.exs"

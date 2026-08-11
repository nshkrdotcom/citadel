import Config

import_config "sources/core_citadel_governance/config.exs"

config :citadel,
  ecto_repos: [Citadel.Governance.Repo]

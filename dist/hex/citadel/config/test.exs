import Config

import_config "sources/core_citadel_governance/test.exs"

config :citadel_governance, Citadel.Governance.Repo,
  priv: Path.expand("../components/core/citadel_governance/priv/repo", __DIR__)

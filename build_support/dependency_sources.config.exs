%{
  deps: %{
    aitrace: %{
      path: "../AITrace",
      github: %{repo: "nshkrdotcom/AITrace", branch: "main"},
      hex: "~> 0.1.0",
      opts: [override: true],
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    execution_plane: %{
      path: "../execution_plane/core/execution_plane",
      github: %{
        repo: "nshkrdotcom/execution_plane",
        branch: "main",
        subdir: "core/execution_plane"
      },
      hex: "~> 0.1.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    ground_plane_persistence_policy: %{
      path: "../ground_plane/core/persistence_policy",
      github: %{
        repo: "nshkrdotcom/ground_plane",
        branch: "main",
        subdir: "core/persistence_policy"
      },
      hex: "~> 0.1.0",
      opts: [override: true],
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    outer_brain_context_abi: %{
      path: "../outer_brain/core/context_abi",
      github: %{
        repo: "nshkrdotcom/outer_brain",
        branch: "main",
        subdir: "core/context_abi"
      },
      hex: "~> 0.1.0",
      opts: [override: true],
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    jido_integration_contracts: %{
      path: "../jido_integration/core/contracts",
      github: %{
        repo: "agentjido/jido_integration",
        branch: "main",
        subdir: "core/contracts"
      },
      hex: "~> 0.1.0",
      opts: [override: true],
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    jido_integration_provider_classification: %{
      path: "../jido_integration/core/provider_classification",
      github: %{
        repo: "agentjido/jido_integration",
        branch: "main",
        subdir: "core/provider_classification"
      },
      hex: "~> 0.1.0",
      opts: [override: true],
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    }
  }
}

defmodule Citadel.Build.DependencyResolver do
  @moduledoc """
  Centralized workspace dependency resolver for Citadel packages and Weld
  projections.
  """

  @repo_root Path.expand("../../..", __DIR__)
  @default_jido_integration_contracts_path Path.expand(
                                             "../jido_integration/core/contracts",
                                             @repo_root
                                           )
  @published_jido_integration_contracts_requirement "~> 0.1.0"
  @default_aitrace_path Path.expand("../AITrace", @repo_root)
  @published_aitrace_requirement "~> 0.1.0"
  @default_execution_plane_path Path.expand("../execution_plane", @repo_root)
  @execution_plane_package_subdir "core/execution_plane"
  @published_execution_plane_requirement "~> 0.1.0"
  @default_ground_plane_path Path.expand("../ground_plane", @repo_root)
  @ground_plane_persistence_policy_subdir "core/persistence_policy"
  @published_ground_plane_persistence_policy_requirement "~> 0.1.0"

  def jido_integration_contracts(opts \\ []) do
    case jido_integration_contracts_source() do
      {:path, path} ->
        {:jido_integration_contracts, Keyword.merge([path: path, override: true], opts)}

      {:hex, requirement} ->
        {:jido_integration_contracts, requirement, opts}
    end
  end

  def jido_integration_contracts_source do
    case resolve_contracts_path() do
      nil -> {:hex, @published_jido_integration_contracts_requirement}
      path -> {:path, path}
    end
  end

  def published_jido_integration_contracts_requirement do
    @published_jido_integration_contracts_requirement
  end

  def aitrace(opts \\ []) do
    case aitrace_source() do
      {:path, path} ->
        {:aitrace, Keyword.merge([path: path, override: true], opts)}

      {:hex, requirement} ->
        {:aitrace, requirement, opts}
    end
  end

  def aitrace_source do
    case resolve_aitrace_path() do
      nil -> {:hex, @published_aitrace_requirement}
      path -> {:path, path}
    end
  end

  def published_aitrace_requirement do
    @published_aitrace_requirement
  end

  def execution_plane_weld_dependency do
    case resolve_execution_plane_path() do
      nil ->
        [
          requirement: @published_execution_plane_requirement,
          opts: []
        ]

      path ->
        [
          requirement: nil,
          opts: [git: "file://#{path}", subdir: @execution_plane_package_subdir]
        ]
    end
  end

  def local_execution_plane_weld_dependency? do
    not is_nil(resolve_execution_plane_path())
  end

  def ground_plane_persistence_policy_weld_dependency do
    case resolve_ground_plane_path() do
      nil ->
        [
          requirement: @published_ground_plane_persistence_policy_requirement,
          opts: []
        ]

      path ->
        [
          requirement: nil,
          opts: [
            git: "file://#{path}",
            subdir: @ground_plane_persistence_policy_subdir,
            override: true
          ]
        ]
    end
  end

  def local_ground_plane_persistence_policy_weld_dependency? do
    not is_nil(resolve_ground_plane_path())
  end

  defp resolve_contracts_path do
    if contracts_path_resolution_disabled?() do
      nil
    else
      [
        explicit_contracts_path(),
        jido_integration_root_path(),
        @default_jido_integration_contracts_path
      ]
      |> Enum.find_value(&existing_path/1)
    end
  end

  defp resolve_aitrace_path do
    if aitrace_path_resolution_disabled?() do
      nil
    else
      [
        explicit_aitrace_path(),
        @default_aitrace_path
      ]
      |> Enum.find_value(&existing_path/1)
    end
  end

  defp resolve_execution_plane_path do
    existing_path(@default_execution_plane_path)
  end

  defp resolve_ground_plane_path do
    existing_path(@default_ground_plane_path)
  end

  defp explicit_contracts_path do
    case System.get_env("CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH") do
      nil -> nil
      value when value in ["", "0", "false", "disabled", "published"] -> nil
      value -> value
    end
  end

  defp jido_integration_root_path do
    case System.get_env("JIDO_INTEGRATION_PATH") do
      nil -> nil
      value when value in ["", "0", "false", "disabled"] -> nil
      value -> Path.join(value, "core/contracts")
    end
  end

  defp explicit_aitrace_path do
    case System.get_env("AITRACE_PATH") do
      nil -> nil
      value when value in ["", "0", "false", "disabled", "published"] -> nil
      value -> value
    end
  end

  defp existing_path(nil), do: nil

  defp existing_path(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      expanded
    else
      nil
    end
  end

  defp contracts_path_resolution_disabled? do
    case System.get_env("CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH") do
      value when is_binary(value) and value not in ["", "0", "false", "disabled", "published"] ->
        false

      value when value in ["0", "false", "disabled", "published"] ->
        true

      _other ->
        disabled_env?(System.get_env("JIDO_INTEGRATION_PATH"))
    end
  end

  defp aitrace_path_resolution_disabled? do
    disabled_env?(System.get_env("AITRACE_PATH"))
  end

  defp disabled_env?(value) when value in ["0", "false", "disabled", "published"], do: true
  defp disabled_env?(_value), do: false
end

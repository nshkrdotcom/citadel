defmodule Citadel.Build.DependencyResolver do
  @moduledoc """
  Centralized workspace dependency resolver for Citadel packages and Weld
  projections.
  """

  unless Code.ensure_loaded?(DependencySources) do
    Code.require_file("../../../build_support/dependency_sources.exs", __DIR__)
  end

  @repo_root Path.expand("../../..", __DIR__)
  @published_jido_integration_contracts_requirement "~> 0.1.0"
  @published_jido_integration_provider_classification_requirement "~> 0.1.0"
  @published_aitrace_requirement "~> 0.2.0"
  @published_execution_plane_requirement "~> 0.3.0"
  @published_ground_plane_contracts_requirement "~> 0.1.0"
  @published_ground_plane_persistence_policy_requirement "~> 0.1.0"
  @published_outer_brain_context_abi_requirement "~> 0.1.0"
  @weld_git_sources %{
    execution_plane: [
      repo_root: Path.expand("../execution_plane", @repo_root),
      subdir: "core/execution_plane"
    ],
    ground_plane_contracts: [
      repo_root: Path.expand("../ground_plane", @repo_root),
      subdir: "core/ground_plane_contracts"
    ],
    ground_plane_persistence_policy: [
      repo_root: Path.expand("../ground_plane", @repo_root),
      subdir: "core/persistence_policy"
    ],
    jido_integration_contracts: [
      repo_root: Path.expand("../jido_integration", @repo_root),
      subdir: "core/contracts"
    ],
    jido_integration_provider_classification: [
      repo_root: Path.expand("../jido_integration", @repo_root),
      subdir: "core/provider_classification"
    ],
    outer_brain_context_abi: [
      repo_root: Path.expand("../outer_brain", @repo_root),
      subdir: "core/context_abi"
    ]
  }

  def jido_integration_contracts(opts \\ []) do
    external_dep(:jido_integration_contracts, opts)
  end

  def jido_integration_provider_classification(opts \\ []) do
    external_dep(:jido_integration_provider_classification, opts)
  end

  def jido_integration_contracts_source do
    source_for(:jido_integration_contracts)
  end

  def jido_integration_contracts_weld_dependency do
    weld_dependency(:jido_integration_contracts)
  end

  def jido_integration_provider_classification_weld_dependency do
    weld_dependency(:jido_integration_provider_classification)
  end

  def published_jido_integration_contracts_requirement do
    @published_jido_integration_contracts_requirement
  end

  def published_jido_integration_provider_classification_requirement do
    @published_jido_integration_provider_classification_requirement
  end

  def aitrace(opts \\ []) do
    external_dep(:aitrace, opts)
  end

  def aitrace_source do
    source_for(:aitrace)
  end

  def published_aitrace_requirement do
    @published_aitrace_requirement
  end

  def published_execution_plane_requirement do
    @published_execution_plane_requirement
  end

  def published_ground_plane_contracts_requirement do
    @published_ground_plane_contracts_requirement
  end

  def published_ground_plane_persistence_policy_requirement do
    @published_ground_plane_persistence_policy_requirement
  end

  def published_outer_brain_context_abi_requirement do
    @published_outer_brain_context_abi_requirement
  end

  def execution_plane(opts \\ []) do
    external_dep(:execution_plane, opts)
  end

  def ground_plane_contracts(opts \\ []) do
    external_dep(:ground_plane_contracts, opts)
  end

  def ground_plane_persistence_policy(opts \\ []) do
    external_dep(:ground_plane_persistence_policy, opts)
  end

  def outer_brain_context_abi(opts \\ []) do
    external_dep(:outer_brain_context_abi, opts)
  end

  def execution_plane_weld_dependency do
    weld_dependency(:execution_plane)
  end

  def ground_plane_contracts_weld_dependency do
    weld_dependency(:ground_plane_contracts)
  end

  def local_execution_plane_weld_dependency? do
    local_dependency?(:execution_plane)
  end

  def local_ground_plane_contracts_weld_dependency? do
    local_dependency?(:ground_plane_contracts)
  end

  def ground_plane_persistence_policy_weld_dependency do
    weld_dependency(:ground_plane_persistence_policy)
  end

  def outer_brain_context_abi_weld_dependency do
    weld_dependency(:outer_brain_context_abi)
  end

  def local_ground_plane_persistence_policy_weld_dependency? do
    local_dependency?(:ground_plane_persistence_policy)
  end

  def local_outer_brain_context_abi_weld_dependency? do
    local_dependency?(:outer_brain_context_abi)
  end

  defp external_dep(app, opts) do
    # DependencySources is a required .exs build helper, not a compiled app module.
    DependencySources
    |> apply(:dep, [app, @repo_root, opts])
    |> expand_path_dep()
  end

  defp source_for(app) do
    case external_dep(app, []) do
      {^app, opts} when is_list(opts) ->
        cond do
          path = opts[:path] ->
            {:path, path}

          github = opts[:github] ->
            {:github, github, Keyword.take(opts, [:branch, :ref, :tag, :subdir])}
        end

      {^app, requirement} when is_binary(requirement) ->
        {:hex, requirement}

      {^app, requirement, opts} when is_binary(requirement) ->
        {:hex, requirement, opts}
    end
  end

  defp weld_dependency(app) do
    case external_dep(app, []) do
      {^app, opts} when is_list(opts) ->
        [requirement: nil, opts: weld_opts(app, opts)]

      {^app, requirement} when is_binary(requirement) ->
        [requirement: requirement, opts: []]

      {^app, requirement, opts} when is_binary(requirement) ->
        [requirement: requirement, opts: opts]
    end
  end

  defp local_dependency?(app) do
    match?({:path, _path}, source_for(app))
  end

  defp weld_opts(app, opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, _path} ->
        case @weld_git_sources[app] do
          nil ->
            Keyword.delete(opts, :path)

          source ->
            opts
            |> Keyword.delete(:path)
            |> Keyword.put(:git, "file://#{source[:repo_root]}")
            |> Keyword.put(:subdir, source[:subdir])
        end

      :error ->
        opts
    end
  end

  defp expand_path_dep({app, opts}) when is_list(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} -> {app, Keyword.put(opts, :path, Path.expand(path, @repo_root))}
      :error -> {app, opts}
    end
  end

  defp expand_path_dep(dep), do: dep
end

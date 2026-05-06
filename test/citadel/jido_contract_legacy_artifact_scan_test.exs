defmodule Citadel.JidoContractLegacyArtifactScanTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @legacy_path_fragment "jido_integration_v2_contracts"
  @current_path_fragment "jido_integration_contracts"
  @publishable_dist_roots [
    "dist/hex/citadel",
    "dist/release_bundles/citadel"
  ]

  test "tracked source paths do not publish the legacy contract package name" do
    assert tracked_paths_with(@legacy_path_fragment) == []

    assert Enum.any?(
             tracked_paths_with(@current_path_fragment),
             &String.starts_with?(&1, "core/jido_integration_contracts/")
           )
  end

  test "current publishable generated roots do not carry legacy contract paths" do
    offenders =
      @publishable_dist_roots
      |> Enum.flat_map(&paths_containing(&1, @legacy_path_fragment))
      |> Enum.sort()

    assert offenders == []
  end

  test "ignored archive legacy paths are classified as generated history" do
    archive_paths = paths_containing("dist/archive", @legacy_path_fragment)

    assert Enum.all?(archive_paths, &git_ignored?/1)

    strategy =
      @repo_root
      |> Path.join("docs/shared_contract_dependency_strategy.md")
      |> File.read!()

    assert String.contains?(strategy, "`jido_integration_v2_contracts`")
    assert String.contains?(strategy, "non-publishable generated history")
  end

  test "projection lock is generated and not tracked source" do
    lock_path = "dist/hex/citadel/projection.lock.json"

    assert tracked_paths_with(lock_path) == [] or deleted_paths_with(lock_path) == [lock_path]
    assert git_ignored?(lock_path)
  end

  defp tracked_paths_with(fragment) do
    {output, 0} = System.cmd("git", ["ls-files"], cd: @repo_root, stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, fragment))
  end

  defp deleted_paths_with(fragment) do
    {output, 0} = System.cmd("git", ["ls-files", "--deleted"], cd: @repo_root)

    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, fragment))
  end

  defp paths_containing(root, fragment) do
    absolute_root = Path.join(@repo_root, root)

    if File.exists?(absolute_root) do
      absolute_root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @repo_root))
      |> Enum.filter(&String.contains?(&1, fragment))
    else
      []
    end
  end

  defp git_ignored?(path) do
    case System.cmd("git", ["check-ignore", "--quiet", "--no-index", path],
           cd: @repo_root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _other -> false
    end
  end
end

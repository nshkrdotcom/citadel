defmodule Citadel.WorkspaceDependencyTest do
  use ExUnit.Case, async: true

  alias Citadel.Workspace

  @workspace_source Path.expand("../../lib/citadel/workspace.ex", __DIR__)

  test "publication declarations are static and do not select development sources" do
    source = File.read!(@workspace_source)

    refute String.contains?(source, "System.get_env")
    refute String.contains?(source, "System.fetch_env")
    refute String.contains?(source, "System.put_env")
    refute String.contains?(source, "System.delete_env")

    declarations = Workspace.publication_dependency_declarations()

    for {_app, declaration} <- declarations do
      assert {:ok, _requirement} = Version.parse_requirement(declaration[:requirement])
      refute Keyword.has_key?(declaration[:opts], :path)
      refute Keyword.has_key?(declaration[:opts], :git)
      refute Keyword.has_key?(declaration[:opts], :github)
    end
  end
end

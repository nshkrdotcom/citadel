defmodule Citadel.ReleaseDocsTest do
  use ExUnit.Case, async: true

  @docs_paths [
    "README.md",
    "docs/publication.md"
  ]

  test "release docs describe the projection tracking workflow" do
    Enum.each(@docs_paths, fn path ->
      doc = File.read!(path)

      assert String.contains?(doc, "mix release.prepare"),
             "#{path} must describe bundle preparation explicitly"

      assert String.contains?(doc, "mix release.track"),
             "#{path} must describe projection tracking explicitly"

      assert String.contains?(doc, "mix release.archive"),
             "#{path} must describe bundle archival explicitly"

      assert String.contains?(doc, "projection/citadel"),
             "#{path} must describe the projection branch explicitly"
    end)
  end
end

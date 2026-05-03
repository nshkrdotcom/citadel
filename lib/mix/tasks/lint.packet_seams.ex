defmodule Mix.Tasks.Lint.PacketSeams do
  use Mix.Task

  @shortdoc "Fails on packet-hostile atom creation and untyped seam specs"

  @string_to_atom_pattern ~r/String\.to_atom\s*\(/
  @untyped_seam_spec_pattern ~r/@(?:spec|callback)\s+(?:submit(?:_[a-z_]+)?|fetch(?:_[a-z_]+)?|normalize(?:_[a-z_]+)?|publish(?:_[a-z_]+)?|put_memory_record|get_memory_record|rank_memory_records)\b.*(?:map\(\)|keyword\(\))/
  @invocation_request_constructor_pattern ~r/@spec\s+new!?\b.*(?:map\(\)|keyword\(\))/

  @impl Mix.Task
  def run(_args) do
    atom_hits =
      Citadel.Workspace.static_analysis_paths()
      |> Enum.flat_map(&source_files_for_path/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file(&1, @string_to_atom_pattern, :unsafe_atom_creation))

    untyped_spec_hits =
      Citadel.Workspace.packet_seam_spec_paths()
      |> Enum.flat_map(&scan_file(&1, @untyped_seam_spec_pattern, :untyped_packet_seam_spec))

    constructor_hits =
      scan_file(
        "core/citadel_governance/lib/citadel/invocation_request.ex",
        @invocation_request_constructor_pattern,
        :untyped_packet_seam_spec
      )

    findings = atom_hits ++ untyped_spec_hits ++ constructor_hits

    if findings == [] do
      Mix.shell().info("packet seam lint passed")
      :ok
    else
      Mix.shell().error("packet seam lint failed:")

      Enum.each(findings, fn %{path: path, line: line, kind: kind, text: text} ->
        Mix.shell().error("#{path}:#{line}: #{render_kind(kind)}")
        Mix.shell().error("  #{text}")
      end)

      Mix.raise(
        "remove packet-hostile seam patterns; use explicit bounded mappings, existing atoms, or typed seam inputs instead"
      )
    end
  end

  defp source_files_for_path(path) do
    [Path.join(path, "**/*.ex"), Path.join(path, "**/*.exs")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
  end

  defp scan_file(path, pattern, kind) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(pattern, line) do
        [%{path: path, line: line_number, kind: kind, text: String.trim(line)}]
      else
        []
      end
    end)
  end

  defp render_kind(:unsafe_atom_creation),
    do: "unsafe string-to-atom conversion is forbidden in packet-critical workspace paths"

  defp render_kind(:untyped_packet_seam_spec),
    do: "public seam specs may not fall back to raw map()/keyword() wrappers"
end

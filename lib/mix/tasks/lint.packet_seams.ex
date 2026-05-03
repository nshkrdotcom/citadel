defmodule Mix.Tasks.Lint.PacketSeams do
  use Mix.Task

  @shortdoc "Fails on packet-hostile atom creation and untyped seam specs"

  @seam_function_prefixes ["submit", "fetch", "normalize", "publish"]
  @seam_function_names ["put_memory_record", "get_memory_record", "rank_memory_records"]

  @impl Mix.Task
  def run(_args) do
    atom_hits =
      Citadel.Workspace.static_analysis_paths()
      |> Enum.flat_map(&source_files_for_path/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file(&1, :unsafe_atom_creation))

    untyped_spec_hits =
      Citadel.Workspace.packet_seam_spec_paths()
      |> Enum.flat_map(&scan_file(&1, :untyped_packet_seam_spec))

    constructor_hits =
      scan_file(
        "core/citadel_governance/lib/citadel/invocation_request.ex",
        :invocation_request_constructor_spec,
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

  defp scan_file(path, kind), do: scan_file(path, kind, kind)

  defp scan_file(path, match_kind, report_kind) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if line_matches?(match_kind, line) do
        [%{path: path, line: line_number, kind: report_kind, text: String.trim(line)}]
      else
        []
      end
    end)
  end

  defp line_matches?(:unsafe_atom_creation, line) do
    line
    |> String.replace(" ", "")
    |> String.contains?(Enum.join(["String", ".", "to_atom", "("]))
  end

  defp line_matches?(:untyped_packet_seam_spec, line) do
    spec_line?(line) and seam_function_line?(line) and raw_wrapper_type?(line)
  end

  defp line_matches?(:invocation_request_constructor_spec, line) do
    spec_line?(line) and constructor_spec_line?(line) and raw_wrapper_type?(line)
  end

  defp spec_line?(line), do: String.contains?(line, ["@spec ", "@callback "])

  defp seam_function_line?(line) do
    Enum.any?(@seam_function_names, &String.contains?(line, &1)) or
      Enum.any?(@seam_function_prefixes, fn prefix ->
        String.contains?(line, "#{prefix}(") or String.contains?(line, "#{prefix}_")
      end)
  end

  defp constructor_spec_line?(line),
    do: String.contains?(line, ["new(", "new!(", "new (", "new! ("])

  defp raw_wrapper_type?(line), do: String.contains?(line, ["map()", "keyword()"])

  defp render_kind(:unsafe_atom_creation),
    do: "unsafe string-to-atom conversion is forbidden in packet-critical workspace paths"

  defp render_kind(:untyped_packet_seam_spec),
    do: "public seam specs may not fall back to raw map()/keyword() wrappers"
end

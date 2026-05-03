defmodule Mix.Tasks.Lint.PacketSeams do
  use Mix.Task

  @shortdoc "Audits packet-critical Citadel.DomainSurface seams"

  @moduledoc """
  Audits the packet-critical `Citadel.DomainSurface` seam modules for forbidden public
  spec shapes and unsafe atom creation.
  """

  @critical_modules MapSet.new([
                      "Citadel.DomainSurface",
                      "Citadel.DomainSurface.Router",
                      "Citadel.DomainSurface.Command",
                      "Citadel.DomainSurface.Query",
                      "Citadel.DomainSurface.Admin",
                      "Citadel.DomainSurface.Error",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter",
                      "Citadel.DomainSurface.Adapters.IntegrationAdapter",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter.Config",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter.Accepted",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter.RequestContext",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter.HostIngressSurface",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter.QueryBridgeSurface",
                      "Citadel.DomainSurface.Adapters.CitadelAdapter.SessionDirectoryMaintenance",
                      "Citadel.DomainSurface.Examples.ArticlePublishing",
                      "Citadel.DomainSurface.Examples.ProvingGround"
                    ])

  @unsafe_to_atom_message """
  Unsafe string-to-atom conversion is forbidden on Domain boundary sources.
  Use existing atoms or explicit typed decoding before the public seam.
  """

  @impl Mix.Task
  def run(_args) do
    violations =
      "lib/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&inspect_file/1)

    case violations do
      [] ->
        Mix.shell().info("lint.packet_seams: ok")

      _ ->
        Enum.each(violations, fn violation -> Mix.shell().error(violation) end)
        Mix.raise("packet seam lint failed")
    end
  end

  defp inspect_file(file) do
    source = File.read!(file)
    ast = Code.string_to_quoted!(source, columns: true)

    unsafe_to_atom_violations(file, ast) ++ module_violations(file, ast, [])
  rescue
    error ->
      ["#{file}:1 failed to parse for packet seam lint: #{Exception.message(error)}"]
  end

  defp unsafe_to_atom_violations(file, ast) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _, [:String]}, :to_atom]}, _, [_arg]} = node, acc ->
          line = Keyword.get(meta, :line, 1)
          {node, ["#{file}:#{line} #{@unsafe_to_atom_message}" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(violations)
  end

  defp module_violations(file, ast, parents) do
    case ast do
      {:defmodule, _meta, [module_ast, [do: body]]} ->
        module = module_name(module_ast, parents)
        next_parents = String.split(module, ".")

        current =
          if MapSet.member?(@critical_modules, module) do
            audit_public_defs(file, module, body)
          else
            []
          end

        current ++ module_violations(file, body, next_parents)

      {:__block__, _, forms} ->
        Enum.flat_map(forms, &module_violations(file, &1, parents))

      _ ->
        []
    end
  end

  defp audit_public_defs(file, module, body) do
    body
    |> module_forms()
    |> Enum.reduce({MapSet.new(), %{}, []}, fn form, acc ->
      audit_public_def_form(form, file, module, acc)
    end)
    |> elem(2)
  end

  defp audit_public_def_form(
         {:@, _meta, [{:spec, _spec_meta, [spec_ast]}]},
         file,
         module,
         {documented, pending, violations}
       ) do
    case spec_signature(spec_ast) do
      nil ->
        {documented, pending, violations}

      signature ->
        spec_violations = generic_type_violations(file, module, signature, spec_ast)
        {documented, Map.put(pending, signature, true), violations ++ spec_violations}
    end
  end

  defp audit_public_def_form(
         {:def, meta, [head | _tail]},
         file,
         module,
         {documented, pending, violations}
       ) do
    signature = function_signature(head)
    line = Keyword.get(meta, :line, 1)

    handle_public_def_signature(signature, line, file, module, documented, pending, violations)
  end

  defp audit_public_def_form(_form, _file, _module, acc), do: acc

  defp handle_public_def_signature(
         nil,
         _line,
         _file,
         _module,
         documented,
         pending,
         violations
       ),
       do: {documented, pending, violations}

  defp handle_public_def_signature(
         signature,
         _line,
         _file,
         _module,
         documented,
         pending,
         violations
       )
       when is_map_key(pending, signature),
       do: {MapSet.put(documented, signature), Map.delete(pending, signature), violations}

  defp handle_public_def_signature(
         signature,
         line,
         file,
         module,
         documented,
         pending,
         violations
       ) do
    if MapSet.member?(documented, signature) do
      {documented, pending, violations}
    else
      message =
        "#{file}:#{line} #{inspect(module)} is missing an explicit @spec for #{format_signature(signature)}"

      {documented, pending, violations ++ [message]}
    end
  end

  defp generic_type_violations(file, module, signature, spec_ast) do
    {_ast, violations} =
      Macro.prewalk(spec_ast, [], fn
        {:map, meta, []} = node, acc ->
          line = Keyword.get(meta, :line, 1)

          message =
            "#{file}:#{line} #{inspect(module)} @spec for #{format_signature(signature)} uses generic map(); prefer a named or shaped boundary type"

          {node, [message | acc]}

        {:term, meta, []} = node, acc ->
          line = Keyword.get(meta, :line, 1)

          message =
            "#{file}:#{line} #{inspect(module)} @spec for #{format_signature(signature)} uses generic term(); prefer a named boundary type"

          {node, [message | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(violations)
  end

  defp module_name({:__aliases__, _, parts}, parents) do
    [parents, Enum.map(parts, &Atom.to_string/1)]
    |> List.flatten()
    |> Enum.join(".")
  end

  defp module_name(atom, parents) when is_atom(atom) do
    [parents, [Atom.to_string(atom)]]
    |> List.flatten()
    |> Enum.join(".")
  end

  defp module_forms({:__block__, _, forms}), do: forms
  defp module_forms(nil), do: []
  defp module_forms(form), do: [form]

  defp spec_signature({:when, _, [spec, _guards]}), do: spec_signature(spec)
  defp spec_signature({:"::", _, [head, _return]}), do: function_signature(head)
  defp spec_signature(_other), do: nil

  defp function_signature({:when, _, [head, _guards]}), do: function_signature(head)

  defp function_signature({name, _, args}) when is_atom(name) do
    {name, length(args || [])}
  end

  defp function_signature(_other), do: nil

  defp format_signature({name, arity}), do: "#{name}/#{arity}"
end

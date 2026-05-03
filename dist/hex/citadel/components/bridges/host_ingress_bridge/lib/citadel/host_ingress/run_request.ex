defmodule Citadel.HostIngress.RunRequest do
  @moduledoc """
  Stable higher-order run-lowering contract for callers that should not build
  raw `Citadel.IntentEnvelope` packets themselves.
  """

  @allowed_scope_preferences [:required, :preferred]
  @allowed_boundary_requirements [:reuse_existing, :fresh_or_reuse, :fresh_only, :no_boundary]
  @allowed_session_modes [:attached, :detached, :stateless]
  @allowed_coordination_modes [:single_target, :parallel_fanout, :local_only]

  @type attrs :: keyword() | %{optional(atom() | String.t()) => term()}

  @type t :: %__MODULE__{
          run_request_id: String.t(),
          capability_id: String.t(),
          objective: String.t(),
          subject_selectors: [String.t()],
          result_kind: String.t(),
          scope: map(),
          target: map(),
          constraints: map(),
          execution: map(),
          risk_hints: [map()],
          success_criteria: [map()],
          resolution_provenance: map(),
          extensions: map()
        }

  @enforce_keys [
    :run_request_id,
    :capability_id,
    :objective,
    :subject_selectors,
    :result_kind,
    :scope,
    :target,
    :constraints,
    :execution,
    :risk_hints,
    :success_criteria,
    :resolution_provenance,
    :extensions
  ]
  defstruct @enforce_keys

  @spec new!(t()) :: t()
  def new!(%__MODULE__{} = request), do: request

  @spec new!(attrs()) :: t()
  def new!(attrs) do
    attrs = Map.new(attrs)
    target = normalize_target(required_map!(attrs, :target))
    execution = normalize_execution(required_map!(attrs, :execution), target)

    %__MODULE__{
      run_request_id: required_string!(attrs, :run_request_id),
      capability_id: required_string!(attrs, :capability_id),
      objective: required_string!(attrs, :objective),
      subject_selectors: string_list(attrs, :subject_selectors, ["primary"], allow_empty?: false),
      result_kind: optional_string(attrs, :result_kind, "runtime_submission"),
      scope: normalize_scope(required_map!(attrs, :scope)),
      target: target,
      constraints: normalize_constraints(optional_map(attrs, :constraints, %{}), target),
      execution: execution,
      risk_hints: map_list(attrs, :risk_hints, []),
      success_criteria:
        normalize_success_criteria(
          map_list(attrs, :success_criteria, []),
          optional_string(attrs, :result_kind, "runtime_submission")
        ),
      resolution_provenance:
        normalize_resolution_provenance(optional_map(attrs, :resolution_provenance, %{})),
      extensions: optional_map(attrs, :extensions, %{})
    }
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = request) do
    %{
      run_request_id: request.run_request_id,
      capability_id: request.capability_id,
      objective: request.objective,
      subject_selectors: request.subject_selectors,
      result_kind: request.result_kind,
      scope: request.scope,
      target: request.target,
      constraints: request.constraints,
      execution: request.execution,
      risk_hints: request.risk_hints,
      success_criteria: request.success_criteria,
      resolution_provenance: request.resolution_provenance,
      extensions: request.extensions
    }
  end

  defp normalize_scope(scope) do
    %{
      scope_kind: required_string!(scope, :scope_kind),
      scope_id: required_string!(scope, :scope_id),
      workspace_root: optional_string(scope, :workspace_root),
      environment: optional_string(scope, :environment),
      preference:
        enum_value(scope, :preference, @allowed_scope_preferences, :required, "scope.preference")
    }
  end

  defp normalize_target(target) do
    %{
      target_kind: required_string!(target, :target_kind),
      target_id: required_string!(target, :target_id),
      service_id: required_string!(target, :service_id),
      boundary_class: required_string!(target, :boundary_class),
      session_mode_preference:
        enum_value(
          target,
          :session_mode_preference,
          @allowed_session_modes,
          :attached,
          "target.session_mode_preference"
        ),
      coordination_mode_preference:
        enum_value(
          target,
          :coordination_mode_preference,
          @allowed_coordination_modes,
          :single_target,
          "target.coordination_mode_preference"
        ),
      routing_tags: string_list(target, :routing_tags, ["primary"])
    }
  end

  defp normalize_constraints(constraints, target) do
    %{
      boundary_requirement:
        enum_value(
          constraints,
          :boundary_requirement,
          @allowed_boundary_requirements,
          :fresh_or_reuse,
          "constraints.boundary_requirement"
        ),
      allowed_boundary_classes:
        string_list(constraints, :allowed_boundary_classes, [target.boundary_class]),
      allowed_service_ids: string_list(constraints, :allowed_service_ids, [target.service_id]),
      forbidden_service_ids: string_list(constraints, :forbidden_service_ids, []),
      max_steps: positive_integer(constraints, :max_steps, 1),
      review_required: boolean_value(constraints, :review_required, false)
    }
  end

  defp normalize_execution(execution, target) do
    family = optional_string(execution, :execution_intent_family, "process")

    %{
      execution_intent_family: family,
      execution_intent: required_map!(execution, :execution_intent),
      allowed_operations: string_list(execution, :allowed_operations, [], allow_empty?: false),
      allowed_tools: string_list(execution, :allowed_tools, []),
      effect_classes: string_list(execution, :effect_classes, []),
      workspace_mutability: optional_string(execution, :workspace_mutability, "read_write"),
      placement_intent: optional_string(execution, :placement_intent, "host_local"),
      downstream_scope:
        optional_string(execution, :downstream_scope, "#{family}:#{target.target_id}"),
      step_id: optional_string(execution, :step_id)
    }
  end

  defp normalize_success_criteria([], result_kind) do
    [
      %{
        criterion_kind: :completion,
        metric: "runtime_submission_completed",
        target: %{"result_kind" => result_kind},
        required: true,
        extensions: %{}
      }
    ]
  end

  defp normalize_success_criteria(criteria, _result_kind), do: criteria

  defp normalize_resolution_provenance(provenance) do
    %{
      source_kind: optional_string(provenance, :source_kind, "higher_order_run_request"),
      resolver_kind: optional_string(provenance, :resolver_kind),
      resolver_version: optional_string(provenance, :resolver_version),
      prompt_version: optional_string(provenance, :prompt_version),
      policy_version: optional_string(provenance, :policy_version),
      confidence: float_value(provenance, :confidence, 1.0),
      ambiguity_flags: string_list(provenance, :ambiguity_flags, []),
      raw_input_refs: string_list(provenance, :raw_input_refs, []),
      raw_input_hashes: string_list(provenance, :raw_input_hashes, []),
      extensions: optional_map(provenance, :extensions, %{})
    }
  end

  defp required_string!(attrs, key) do
    case fetch(attrs, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" do
          trimmed
        else
          raise ArgumentError,
                "run request #{inspect(key)} must be a non-empty string, got: #{inspect(value)}"
        end

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp optional_string(attrs, key, default \\ nil) do
    case fetch(attrs, key) do
      nil ->
        default

      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" do
          trimmed
        else
          raise ArgumentError,
                "run request #{inspect(key)} must be a non-empty string or nil, got: #{inspect(value)}"
        end

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a non-empty string or nil, got: #{inspect(value)}"
    end
  end

  defp required_map!(attrs, key) do
    case fetch(attrs, key) do
      %{} = value ->
        value

      value ->
        raise ArgumentError, "run request #{inspect(key)} must be a map, got: #{inspect(value)}"
    end
  end

  defp optional_map(attrs, key, default) do
    case fetch(attrs, key) do
      nil ->
        default

      %{} = value ->
        value

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a map or nil, got: #{inspect(value)}"
    end
  end

  defp string_list(attrs, key, default, opts \\ []) do
    allow_empty? = Keyword.get(opts, :allow_empty?, true)

    values =
      case fetch(attrs, key) do
        nil ->
          default

        value when is_list(value) ->
          Enum.map(value, &normalize_string_item!(&1, key))

        value ->
          raise ArgumentError,
                "run request #{inspect(key)} must be a list, got: #{inspect(value)}"
      end
      |> Enum.uniq()

    if values == [] and not allow_empty? do
      raise ArgumentError, "run request #{inspect(key)} must not be empty"
    else
      values
    end
  end

  defp map_list(attrs, key, default) do
    case fetch(attrs, key) do
      nil ->
        default

      value when is_list(value) ->
        Enum.map(value, fn
          %{} = item ->
            item

          other ->
            raise ArgumentError,
                  "run request #{inspect(key)} entries must be maps, got: #{inspect(other)}"
        end)

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a list of maps, got: #{inspect(value)}"
    end
  end

  defp enum_value(attrs, key, allowed, default, label) do
    case fetch(attrs, key) do
      nil ->
        default

      value when is_binary(value) ->
        allowed
        |> enum_string_map()
        |> Map.fetch(value)
        |> case do
          {:ok, atom_value} ->
            atom_value

          :error ->
            raise ArgumentError,
                  "run request #{label} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
        end

      value ->
        if value in allowed do
          value
        else
          raise ArgumentError,
                "run request #{label} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
        end
    end
  end

  defp boolean_value(attrs, key, default) do
    case fetch(attrs, key) do
      nil ->
        default

      value when is_boolean(value) ->
        value

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a boolean, got: #{inspect(value)}"
    end
  end

  defp positive_integer(attrs, key, default) do
    case fetch(attrs, key) do
      nil ->
        default

      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp float_value(attrs, key, default) do
    case fetch(attrs, key) do
      nil ->
        default

      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value ->
        raise ArgumentError,
              "run request #{inspect(key)} must be a number, got: #{inspect(value)}"
    end
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp enum_string_map(allowed), do: Map.new(allowed, &{Atom.to_string(&1), &1})

  defp normalize_string_item!(value, _key) when is_atom(value), do: Atom.to_string(value)

  defp normalize_string_item!(value, key) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      raise ArgumentError, "run request #{inspect(key)} entries must be non-empty strings"
    else
      trimmed
    end
  end

  defp normalize_string_item!(value, key) do
    raise ArgumentError,
          "run request #{inspect(key)} entries must be atoms or strings, got: #{inspect(value)}"
  end
end

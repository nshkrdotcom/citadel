defmodule Citadel.PolicyPacks.Selector do
  @moduledoc """
  Explicit policy-pack selector inputs.
  """

  alias Citadel.ContractCore.Value

  @schema [
    tenant_ids: {:list, :string},
    scope_kinds: {:list, :string},
    environments: {:list, :string},
    default?: :boolean,
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          tenant_ids: [String.t()],
          scope_kinds: [String.t()],
          environments: [String.t()],
          default?: boolean(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = selector) do
    selector
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.Selector", @fields)

    %__MODULE__{
      tenant_ids:
        Value.optional(
          attrs,
          :tenant_ids,
          "Citadel.PolicyPacks.Selector",
          fn value ->
            Value.unique_strings!(value, "Citadel.PolicyPacks.Selector.tenant_ids")
          end,
          []
        ),
      scope_kinds:
        Value.optional(
          attrs,
          :scope_kinds,
          "Citadel.PolicyPacks.Selector",
          fn value ->
            Value.unique_strings!(value, "Citadel.PolicyPacks.Selector.scope_kinds")
          end,
          []
        ),
      environments:
        Value.optional(
          attrs,
          :environments,
          "Citadel.PolicyPacks.Selector",
          fn value ->
            Value.unique_strings!(value, "Citadel.PolicyPacks.Selector.environments")
          end,
          []
        ),
      default?:
        Value.optional(
          attrs,
          :default?,
          "Citadel.PolicyPacks.Selector",
          fn value ->
            Value.boolean!(value, "Citadel.PolicyPacks.Selector.default?")
          end,
          false
        ),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.Selector",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.Selector.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = selector) do
    %{
      tenant_ids: selector.tenant_ids,
      scope_kinds: selector.scope_kinds,
      environments: selector.environments,
      default?: selector.default?,
      extensions: selector.extensions
    }
  end

  def matches?(%__MODULE__{default?: true}, _attrs), do: true

  def matches?(%__MODULE__{} = selector, attrs) do
    selector = new!(selector)
    attrs = normalize_match_inputs!(attrs)

    match_dimension?(selector.tenant_ids, attrs.tenant_id) and
      match_dimension?(selector.scope_kinds, attrs.scope_kind) and
      match_dimension?(selector.environments, attrs.environment)
  end

  defp match_dimension?([], _value), do: true
  defp match_dimension?(values, value), do: value in values

  defp normalize_match_inputs!(attrs) do
    attrs =
      Value.normalize_attrs!(
        attrs,
        "Citadel.PolicyPacks.Selector matches input",
        [:tenant_id, :scope_kind, :environment, :policy_epoch]
      )

    %{
      tenant_id:
        Value.required(
          attrs,
          :tenant_id,
          "Citadel.PolicyPacks.Selector matches input",
          fn value ->
            Value.string!(value, "Citadel.PolicyPacks.Selector matches input.tenant_id")
          end
        ),
      scope_kind:
        Value.required(
          attrs,
          :scope_kind,
          "Citadel.PolicyPacks.Selector matches input",
          fn value ->
            Value.string!(value, "Citadel.PolicyPacks.Selector matches input.scope_kind")
          end
        ),
      environment:
        Value.optional(
          attrs,
          :environment,
          "Citadel.PolicyPacks.Selector matches input",
          fn value ->
            Value.string!(value, "Citadel.PolicyPacks.Selector matches input.environment")
          end,
          nil
        )
    }
  end
end

defmodule Citadel.PolicyPacks.Profiles do
  @moduledoc """
  Explicit decision-shaping profiles selected from one policy pack.
  """

  alias Citadel.ContractCore.Value

  @schema [
    trust_profile: :string,
    approval_profile: :string,
    egress_profile: :string,
    workspace_profile: :string,
    resource_profile: :string,
    boundary_class: :string,
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          trust_profile: String.t(),
          approval_profile: String.t(),
          egress_profile: String.t(),
          workspace_profile: String.t(),
          resource_profile: String.t(),
          boundary_class: String.t(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.Profiles", @fields)

    %__MODULE__{
      trust_profile:
        Value.required(attrs, :trust_profile, "Citadel.PolicyPacks.Profiles", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Profiles.trust_profile")
        end),
      approval_profile:
        Value.required(attrs, :approval_profile, "Citadel.PolicyPacks.Profiles", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Profiles.approval_profile")
        end),
      egress_profile:
        Value.required(attrs, :egress_profile, "Citadel.PolicyPacks.Profiles", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Profiles.egress_profile")
        end),
      workspace_profile:
        Value.required(attrs, :workspace_profile, "Citadel.PolicyPacks.Profiles", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Profiles.workspace_profile")
        end),
      resource_profile:
        Value.required(attrs, :resource_profile, "Citadel.PolicyPacks.Profiles", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Profiles.resource_profile")
        end),
      boundary_class:
        Value.required(attrs, :boundary_class, "Citadel.PolicyPacks.Profiles", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Profiles.boundary_class")
        end),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.Profiles",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.Profiles.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = profiles) do
    %{
      trust_profile: profiles.trust_profile,
      approval_profile: profiles.approval_profile,
      egress_profile: profiles.egress_profile,
      workspace_profile: profiles.workspace_profile,
      resource_profile: profiles.resource_profile,
      boundary_class: profiles.boundary_class,
      extensions: profiles.extensions
    }
  end

  @doc """
  Returns the stable policy-stage surface used by Citadel selectors and upper consumers.
  """
  def policy_surface(%__MODULE__{} = profiles) do
    %{
      trust_profile: profiles.trust_profile,
      approval_profile: profiles.approval_profile,
      egress_profile: profiles.egress_profile,
      workspace_profile: profiles.workspace_profile,
      resource_profile: profiles.resource_profile,
      boundary_class: profiles.boundary_class
    }
  end
end

defmodule Citadel.PolicyPacks.ExecutionPolicy do
  @moduledoc """
  Policy-owned execution posture compiled into governance packets.
  """

  alias Citadel.ContractCore.Value

  @sandbox_levels ["strict", "standard", "none"]
  @egress_policies ["blocked", "restricted", "open"]
  @approval_modes ["manual", "auto", "none"]
  @workspace_mutabilities ["read_only", "read_write", "ephemeral"]
  @placement_intents ["host_local", "remote_scope", "remote_workspace", "ephemeral_session"]
  @execution_families ["process", "http", "json_rpc", "service"]

  @schema [
    minimum_sandbox_level: :string,
    maximum_egress: :string,
    approval_mode: :string,
    acceptable_attestation: {:list, :string},
    allowed_tools: {:list, :string},
    allowed_operations: {:list, :string},
    effect_classes: {:list, :string},
    command_classes: {:list, :string},
    workspace_mutability: :string,
    placement_intents: {:list, :string},
    execution_families: {:list, :string},
    wall_clock_budget_ms: :non_neg_integer,
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          minimum_sandbox_level: String.t(),
          maximum_egress: String.t(),
          approval_mode: String.t(),
          acceptable_attestation: [String.t()],
          allowed_tools: [String.t()],
          allowed_operations: [String.t()],
          effect_classes: [String.t()],
          command_classes: [String.t()],
          workspace_mutability: String.t(),
          placement_intents: [String.t()],
          execution_families: [String.t()],
          wall_clock_budget_ms: non_neg_integer() | nil,
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = policy) do
    policy
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.ExecutionPolicy", @fields)

    %__MODULE__{
      minimum_sandbox_level:
        enum_string(
          attrs,
          :minimum_sandbox_level,
          @sandbox_levels,
          "strict",
          "minimum_sandbox_level"
        ),
      maximum_egress:
        enum_string(attrs, :maximum_egress, @egress_policies, "restricted", "maximum_egress"),
      approval_mode: enum_string(attrs, :approval_mode, @approval_modes, "auto", "approval_mode"),
      acceptable_attestation:
        optional_strings(attrs, :acceptable_attestation, ["local-erlexec-weak"]),
      allowed_tools: optional_strings(attrs, :allowed_tools, []),
      allowed_operations: optional_strings(attrs, :allowed_operations, []),
      effect_classes: optional_strings(attrs, :effect_classes, []),
      command_classes: optional_strings(attrs, :command_classes, []),
      workspace_mutability:
        enum_string(
          attrs,
          :workspace_mutability,
          @workspace_mutabilities,
          "read_write",
          "workspace_mutability"
        ),
      placement_intents:
        enum_string_list(
          attrs,
          :placement_intents,
          @placement_intents,
          ["host_local"],
          "placement_intents"
        ),
      execution_families:
        enum_string_list(
          attrs,
          :execution_families,
          @execution_families,
          ["process"],
          "execution_families"
        ),
      wall_clock_budget_ms:
        Value.optional(
          attrs,
          :wall_clock_budget_ms,
          "Citadel.PolicyPacks.ExecutionPolicy",
          fn value ->
            Value.non_neg_integer!(
              value,
              "Citadel.PolicyPacks.ExecutionPolicy.wall_clock_budget_ms"
            )
          end,
          nil
        ),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.ExecutionPolicy",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.ExecutionPolicy.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = policy) do
    %{
      minimum_sandbox_level: policy.minimum_sandbox_level,
      maximum_egress: policy.maximum_egress,
      approval_mode: policy.approval_mode,
      acceptable_attestation: policy.acceptable_attestation,
      allowed_tools: policy.allowed_tools,
      allowed_operations: policy.allowed_operations,
      effect_classes: policy.effect_classes,
      command_classes: policy.command_classes,
      workspace_mutability: policy.workspace_mutability,
      placement_intents: policy.placement_intents,
      execution_families: policy.execution_families,
      wall_clock_budget_ms: policy.wall_clock_budget_ms,
      extensions: policy.extensions
    }
  end

  defp enum_string(attrs, key, allowed, default, label) do
    value =
      Value.optional(
        attrs,
        key,
        "Citadel.PolicyPacks.ExecutionPolicy",
        fn value ->
          Value.string!(value, "Citadel.PolicyPacks.ExecutionPolicy.#{label}")
        end,
        default
      )

    if value in allowed do
      value
    else
      raise ArgumentError,
            "Citadel.PolicyPacks.ExecutionPolicy.#{label} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
    end
  end

  defp enum_string_list(attrs, key, allowed, default, label) do
    values = optional_strings(attrs, key, default)

    invalid = Enum.reject(values, &(&1 in allowed))

    if invalid == [] do
      values
    else
      raise ArgumentError,
            "Citadel.PolicyPacks.ExecutionPolicy.#{label} contains unsupported values: #{inspect(invalid)}"
    end
  end

  defp optional_strings(attrs, key, default) do
    Value.optional(
      attrs,
      key,
      "Citadel.PolicyPacks.ExecutionPolicy",
      fn value ->
        Value.unique_strings!(value, "Citadel.PolicyPacks.ExecutionPolicy.#{key}")
      end,
      default
    )
  end
end

defmodule Citadel.PolicyPacks.RejectionPolicy do
  @moduledoc """
  Pure policy inputs for rejection retryability and publication classification.
  """

  alias Citadel.ContractCore.Value

  @schema [
    denial_audit_reason_codes: {:list, :string},
    derived_state_reason_codes: {:list, :string},
    runtime_change_reason_codes: {:list, :string},
    governance_change_reason_codes: {:list, :string},
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          denial_audit_reason_codes: [String.t()],
          derived_state_reason_codes: [String.t()],
          runtime_change_reason_codes: [String.t()],
          governance_change_reason_codes: [String.t()],
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = policy) do
    policy
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.RejectionPolicy", @fields)

    %__MODULE__{
      denial_audit_reason_codes:
        Value.optional(
          attrs,
          :denial_audit_reason_codes,
          "Citadel.PolicyPacks.RejectionPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.RejectionPolicy.denial_audit_reason_codes"
            )
          end,
          []
        ),
      derived_state_reason_codes:
        Value.optional(
          attrs,
          :derived_state_reason_codes,
          "Citadel.PolicyPacks.RejectionPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.RejectionPolicy.derived_state_reason_codes"
            )
          end,
          []
        ),
      runtime_change_reason_codes:
        Value.optional(
          attrs,
          :runtime_change_reason_codes,
          "Citadel.PolicyPacks.RejectionPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.RejectionPolicy.runtime_change_reason_codes"
            )
          end,
          []
        ),
      governance_change_reason_codes:
        Value.optional(
          attrs,
          :governance_change_reason_codes,
          "Citadel.PolicyPacks.RejectionPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.RejectionPolicy.governance_change_reason_codes"
            )
          end,
          []
        ),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.RejectionPolicy",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.RejectionPolicy.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = policy) do
    %{
      denial_audit_reason_codes: policy.denial_audit_reason_codes,
      derived_state_reason_codes: policy.derived_state_reason_codes,
      runtime_change_reason_codes: policy.runtime_change_reason_codes,
      governance_change_reason_codes: policy.governance_change_reason_codes,
      extensions: policy.extensions
    }
  end
end

defmodule Citadel.PolicyPacks.PromptVersionPolicy do
  @moduledoc """
  Prompt artifact bindings owned by a policy pack.
  """

  alias Citadel.ContractCore.Value

  @schema [
    allowed_prompt_refs: {:list, :string},
    allowed_revision_range: {:map, :json},
    ab_variant_refs: {:list, :string},
    rollback_requires_authority?: :boolean,
    eval_evidence_required?: :boolean,
    guard_evidence_required?: :boolean,
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          allowed_prompt_refs: [String.t()],
          allowed_revision_range: map(),
          ab_variant_refs: [String.t()],
          rollback_requires_authority?: boolean(),
          eval_evidence_required?: boolean(),
          guard_evidence_required?: boolean(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = policy) do
    policy
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.PromptVersionPolicy", @fields)

    %__MODULE__{
      allowed_prompt_refs:
        Value.optional(
          attrs,
          :allowed_prompt_refs,
          "Citadel.PolicyPacks.PromptVersionPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.PromptVersionPolicy.allowed_prompt_refs"
            )
          end,
          []
        ),
      allowed_revision_range:
        Value.optional(
          attrs,
          :allowed_revision_range,
          "Citadel.PolicyPacks.PromptVersionPolicy",
          fn value ->
            Value.json_object!(
              value,
              "Citadel.PolicyPacks.PromptVersionPolicy.allowed_revision_range"
            )
          end,
          %{}
        ),
      ab_variant_refs:
        Value.optional(
          attrs,
          :ab_variant_refs,
          "Citadel.PolicyPacks.PromptVersionPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.PromptVersionPolicy.ab_variant_refs"
            )
          end,
          []
        ),
      rollback_requires_authority?: boolean_option(attrs, :rollback_requires_authority?, true),
      eval_evidence_required?: boolean_option(attrs, :eval_evidence_required?, true),
      guard_evidence_required?: boolean_option(attrs, :guard_evidence_required?, true),
      extensions: json_option(attrs, :extensions, %{})
    }
  end

  def dump(%__MODULE__{} = policy) do
    %{
      allowed_prompt_refs: policy.allowed_prompt_refs,
      allowed_revision_range: policy.allowed_revision_range,
      ab_variant_refs: policy.ab_variant_refs,
      rollback_requires_authority?: policy.rollback_requires_authority?,
      eval_evidence_required?: policy.eval_evidence_required?,
      guard_evidence_required?: policy.guard_evidence_required?,
      extensions: policy.extensions
    }
  end

  defp boolean_option(attrs, field, default) do
    Value.optional(
      attrs,
      field,
      "Citadel.PolicyPacks.PromptVersionPolicy",
      fn value -> Value.boolean!(value, "Citadel.PolicyPacks.PromptVersionPolicy.#{field}") end,
      default
    )
  end

  defp json_option(attrs, field, default) do
    Value.optional(
      attrs,
      field,
      "Citadel.PolicyPacks.PromptVersionPolicy",
      fn value ->
        Value.json_object!(value, "Citadel.PolicyPacks.PromptVersionPolicy.#{field}")
      end,
      default
    )
  end
end

defmodule Citadel.PolicyPacks.GuardrailChainPolicy do
  @moduledoc """
  Guardrail detector-chain bindings owned by a policy pack.
  """

  alias Citadel.ContractCore.Value

  @redaction_postures ["pass", "partial", "excerpt_only", "no_export", "block"]
  @schema [
    guard_chain_ref: :string,
    detector_refs: {:list, :string},
    redaction_posture_floor: :string,
    operator_override_authority_refs: {:list, :string},
    fail_closed?: :boolean,
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          guard_chain_ref: String.t(),
          detector_refs: [String.t()],
          redaction_posture_floor: String.t(),
          operator_override_authority_refs: [String.t()],
          fail_closed?: boolean(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = policy) do
    policy
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.GuardrailChainPolicy", @fields)

    posture =
      Value.optional(
        attrs,
        :redaction_posture_floor,
        "Citadel.PolicyPacks.GuardrailChainPolicy",
        fn value ->
          Value.string!(value, "Citadel.PolicyPacks.GuardrailChainPolicy.redaction_posture_floor")
        end,
        "partial"
      )

    if posture not in @redaction_postures do
      raise ArgumentError,
            "Citadel.PolicyPacks.GuardrailChainPolicy.redaction_posture_floor must be one of #{inspect(@redaction_postures)}, got: #{inspect(posture)}"
    end

    %__MODULE__{
      guard_chain_ref:
        Value.required(
          attrs,
          :guard_chain_ref,
          "Citadel.PolicyPacks.GuardrailChainPolicy",
          fn value ->
            Value.string!(value, "Citadel.PolicyPacks.GuardrailChainPolicy.guard_chain_ref")
          end
        ),
      detector_refs:
        Value.optional(
          attrs,
          :detector_refs,
          "Citadel.PolicyPacks.GuardrailChainPolicy",
          fn value ->
            Value.unique_strings!(value, "Citadel.PolicyPacks.GuardrailChainPolicy.detector_refs")
          end,
          []
        ),
      redaction_posture_floor: posture,
      operator_override_authority_refs:
        Value.optional(
          attrs,
          :operator_override_authority_refs,
          "Citadel.PolicyPacks.GuardrailChainPolicy",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.GuardrailChainPolicy.operator_override_authority_refs"
            )
          end,
          []
        ),
      fail_closed?:
        Value.optional(
          attrs,
          :fail_closed?,
          "Citadel.PolicyPacks.GuardrailChainPolicy",
          fn value ->
            Value.boolean!(value, "Citadel.PolicyPacks.GuardrailChainPolicy.fail_closed?")
          end,
          true
        ),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.GuardrailChainPolicy",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.GuardrailChainPolicy.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = policy) do
    %{
      guard_chain_ref: policy.guard_chain_ref,
      detector_refs: policy.detector_refs,
      redaction_posture_floor: policy.redaction_posture_floor,
      operator_override_authority_refs: policy.operator_override_authority_refs,
      fail_closed?: policy.fail_closed?,
      extensions: policy.extensions
    }
  end
end

defmodule Citadel.PolicyPacks.BudgetOverridePermission do
  @moduledoc """
  Bounded operator budget override permission.
  """

  alias Citadel.ContractCore.Value

  @budget_classes ["production", "replay", "eval", "simulation", "infrastructure"]
  @schema [
    permission_ref: :string,
    operator_role_refs: {:list, :string},
    budget_classes: {:list, :string},
    max_duration_seconds: :non_neg_integer,
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          permission_ref: String.t(),
          operator_role_refs: [String.t()],
          budget_classes: [String.t()],
          max_duration_seconds: pos_integer(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = permission) do
    permission
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.BudgetOverridePermission", @fields)

    permission = %__MODULE__{
      permission_ref:
        Value.required(
          attrs,
          :permission_ref,
          "Citadel.PolicyPacks.BudgetOverridePermission",
          fn value ->
            Value.string!(value, "Citadel.PolicyPacks.BudgetOverridePermission.permission_ref")
          end
        ),
      operator_role_refs:
        Value.required(
          attrs,
          :operator_role_refs,
          "Citadel.PolicyPacks.BudgetOverridePermission",
          fn value ->
            Value.unique_strings!(
              value,
              "Citadel.PolicyPacks.BudgetOverridePermission.operator_role_refs",
              allow_empty?: false
            )
          end
        ),
      budget_classes: budget_classes(attrs),
      max_duration_seconds:
        Value.required(
          attrs,
          :max_duration_seconds,
          "Citadel.PolicyPacks.BudgetOverridePermission",
          fn value ->
            Value.positive_integer!(
              value,
              "Citadel.PolicyPacks.BudgetOverridePermission.max_duration_seconds"
            )
          end
        ),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.BudgetOverridePermission",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.BudgetOverridePermission.extensions")
          end,
          %{}
        )
    }

    if permission.max_duration_seconds <= 3_600 do
      permission
    else
      raise ArgumentError,
            "Citadel.PolicyPacks.BudgetOverridePermission.max_duration_seconds must be bounded"
    end
  end

  def dump(%__MODULE__{} = permission) do
    %{
      permission_ref: permission.permission_ref,
      operator_role_refs: permission.operator_role_refs,
      budget_classes: permission.budget_classes,
      max_duration_seconds: permission.max_duration_seconds,
      extensions: permission.extensions
    }
  end

  defp budget_classes(attrs) do
    classes =
      Value.required(
        attrs,
        :budget_classes,
        "Citadel.PolicyPacks.BudgetOverridePermission",
        fn value ->
          Value.unique_strings!(
            value,
            "Citadel.PolicyPacks.BudgetOverridePermission.budget_classes",
            allow_empty?: false
          )
        end
      )

    invalid = Enum.reject(classes, &(&1 in @budget_classes))

    if invalid == [] do
      classes
    else
      raise ArgumentError,
            "Citadel.PolicyPacks.BudgetOverridePermission.budget_classes contains unsupported values: #{inspect(invalid)}"
    end
  end
end

defmodule Citadel.PolicyPacks.BudgetPolicy do
  @moduledoc """
  Budget policy block selected with a policy pack.
  """

  alias Citadel.ContractCore.Value
  alias Citadel.PolicyPacks.BudgetOverridePermission

  @period_classes ["per_run", "per_skill", "per_day", "per_tenant", "per_authority"]
  @exhaustion_behaviors ["fail_closed", "operator_override_required"]
  @schema [
    scope_key_ref: :string,
    period_class: :string,
    hard_cap_class: :string,
    soft_cap_class: :string,
    default_exhaustion_behavior: :string,
    override_permissions: {:list, {:struct, BudgetOverridePermission}},
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          scope_key_ref: String.t(),
          period_class: String.t(),
          hard_cap_class: String.t(),
          soft_cap_class: String.t(),
          default_exhaustion_behavior: String.t(),
          override_permissions: [BudgetOverridePermission.t()],
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = policy) do
    policy
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.BudgetPolicy", @fields)

    %__MODULE__{
      scope_key_ref:
        Value.required(attrs, :scope_key_ref, "Citadel.PolicyPacks.BudgetPolicy", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.BudgetPolicy.scope_key_ref")
        end),
      period_class:
        enum_string(attrs, :period_class, @period_classes, "Citadel.PolicyPacks.BudgetPolicy"),
      hard_cap_class:
        Value.required(attrs, :hard_cap_class, "Citadel.PolicyPacks.BudgetPolicy", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.BudgetPolicy.hard_cap_class")
        end),
      soft_cap_class:
        Value.required(attrs, :soft_cap_class, "Citadel.PolicyPacks.BudgetPolicy", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.BudgetPolicy.soft_cap_class")
        end),
      default_exhaustion_behavior:
        enum_string(
          attrs,
          :default_exhaustion_behavior,
          @exhaustion_behaviors,
          "Citadel.PolicyPacks.BudgetPolicy"
        ),
      override_permissions: override_permissions(attrs),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.BudgetPolicy",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.BudgetPolicy.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = policy) do
    %{
      scope_key_ref: policy.scope_key_ref,
      period_class: policy.period_class,
      hard_cap_class: policy.hard_cap_class,
      soft_cap_class: policy.soft_cap_class,
      default_exhaustion_behavior: policy.default_exhaustion_behavior,
      override_permissions:
        Enum.map(policy.override_permissions, &BudgetOverridePermission.dump/1),
      extensions: policy.extensions
    }
  end

  defp enum_string(attrs, field, allowed, context) do
    value =
      Value.required(attrs, field, context, fn value ->
        Value.string!(value, "#{context}.#{field}")
      end)

    if value in allowed do
      value
    else
      raise ArgumentError, "#{context}.#{field} must be one of #{inspect(allowed)}"
    end
  end

  defp override_permissions(attrs) do
    permissions =
      Value.required(attrs, :override_permissions, "Citadel.PolicyPacks.BudgetPolicy", fn value ->
        Value.list!(
          value,
          "Citadel.PolicyPacks.BudgetPolicy.override_permissions",
          &BudgetOverridePermission.new!/1,
          allow_empty?: false
        )
      end)

    refs = Enum.map(permissions, & &1.permission_ref)

    if refs == Enum.uniq(refs) do
      permissions
    else
      raise ArgumentError,
            "Citadel.PolicyPacks.BudgetPolicy.override_permissions must not be ambiguous"
    end
  end
end

defmodule Citadel.PolicyPacks.PolicyPack do
  @moduledoc """
  One explicit policy pack plus its selector, profile set, and rejection policy.
  """

  alias Citadel.ContractCore.Value
  alias Citadel.PolicyPacks.BudgetPolicy
  alias Citadel.PolicyPacks.ExecutionPolicy
  alias Citadel.PolicyPacks.GuardrailChainPolicy
  alias Citadel.PolicyPacks.Profiles
  alias Citadel.PolicyPacks.PromptVersionPolicy
  alias Citadel.PolicyPacks.RejectionPolicy
  alias Citadel.PolicyPacks.Selector

  @schema [
    pack_id: :string,
    policy_version: :string,
    policy_epoch: :non_neg_integer,
    priority: :non_neg_integer,
    selector: {:struct, Selector},
    profiles: {:struct, Profiles},
    execution_policy: {:struct, ExecutionPolicy},
    prompt_version_policy: {:struct, PromptVersionPolicy},
    guardrail_chain_policy: {:struct, GuardrailChainPolicy},
    budget_policy: {:struct, BudgetPolicy},
    rejection_policy: {:struct, RejectionPolicy},
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          pack_id: String.t(),
          policy_version: String.t(),
          policy_epoch: non_neg_integer(),
          priority: non_neg_integer(),
          selector: Selector.t(),
          profiles: Profiles.t(),
          execution_policy: ExecutionPolicy.t() | nil,
          prompt_version_policy: PromptVersionPolicy.t() | nil,
          guardrail_chain_policy: GuardrailChainPolicy.t() | nil,
          budget_policy: BudgetPolicy.t() | nil,
          rejection_policy: RejectionPolicy.t(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(%__MODULE__{} = pack) do
    pack
    |> dump()
    |> new!()
  end

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.PolicyPack", @fields)

    %__MODULE__{
      pack_id:
        Value.required(attrs, :pack_id, "Citadel.PolicyPacks.PolicyPack", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.PolicyPack.pack_id")
        end),
      policy_version:
        Value.required(attrs, :policy_version, "Citadel.PolicyPacks.PolicyPack", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.PolicyPack.policy_version")
        end),
      policy_epoch:
        Value.required(attrs, :policy_epoch, "Citadel.PolicyPacks.PolicyPack", fn value ->
          Value.non_neg_integer!(value, "Citadel.PolicyPacks.PolicyPack.policy_epoch")
        end),
      priority:
        Value.optional(
          attrs,
          :priority,
          "Citadel.PolicyPacks.PolicyPack",
          fn value ->
            Value.non_neg_integer!(value, "Citadel.PolicyPacks.PolicyPack.priority")
          end,
          0
        ),
      selector:
        Value.required(attrs, :selector, "Citadel.PolicyPacks.PolicyPack", fn value ->
          Value.module!(value, Selector, "Citadel.PolicyPacks.PolicyPack.selector")
        end),
      profiles:
        Value.required(attrs, :profiles, "Citadel.PolicyPacks.PolicyPack", fn value ->
          Value.module!(value, Profiles, "Citadel.PolicyPacks.PolicyPack.profiles")
        end),
      execution_policy:
        Value.optional(
          attrs,
          :execution_policy,
          "Citadel.PolicyPacks.PolicyPack",
          fn value ->
            Value.module!(
              value,
              ExecutionPolicy,
              "Citadel.PolicyPacks.PolicyPack.execution_policy"
            )
          end,
          nil
        ),
      prompt_version_policy:
        Value.optional(
          attrs,
          :prompt_version_policy,
          "Citadel.PolicyPacks.PolicyPack",
          fn value ->
            Value.module!(
              value,
              PromptVersionPolicy,
              "Citadel.PolicyPacks.PolicyPack.prompt_version_policy"
            )
          end,
          nil
        ),
      guardrail_chain_policy:
        Value.optional(
          attrs,
          :guardrail_chain_policy,
          "Citadel.PolicyPacks.PolicyPack",
          fn value ->
            Value.module!(
              value,
              GuardrailChainPolicy,
              "Citadel.PolicyPacks.PolicyPack.guardrail_chain_policy"
            )
          end,
          nil
        ),
      budget_policy:
        Value.optional(
          attrs,
          :budget_policy,
          "Citadel.PolicyPacks.PolicyPack",
          fn value ->
            Value.module!(value, BudgetPolicy, "Citadel.PolicyPacks.PolicyPack.budget_policy")
          end,
          nil
        ),
      rejection_policy:
        Value.required(attrs, :rejection_policy, "Citadel.PolicyPacks.PolicyPack", fn value ->
          Value.module!(value, RejectionPolicy, "Citadel.PolicyPacks.PolicyPack.rejection_policy")
        end),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.PolicyPack",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.PolicyPack.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = pack) do
    %{
      pack_id: pack.pack_id,
      policy_version: pack.policy_version,
      policy_epoch: pack.policy_epoch,
      priority: pack.priority,
      selector: Selector.dump(pack.selector),
      profiles: Profiles.dump(pack.profiles),
      execution_policy: dump_execution_policy(pack.execution_policy),
      prompt_version_policy: dump_prompt_version_policy(pack.prompt_version_policy),
      guardrail_chain_policy: dump_guardrail_chain_policy(pack.guardrail_chain_policy),
      budget_policy: dump_budget_policy(pack.budget_policy),
      rejection_policy: RejectionPolicy.dump(pack.rejection_policy),
      extensions: pack.extensions
    }
  end

  defp dump_execution_policy(nil), do: nil
  defp dump_execution_policy(%ExecutionPolicy{} = policy), do: ExecutionPolicy.dump(policy)
  defp dump_prompt_version_policy(nil), do: nil

  defp dump_prompt_version_policy(%PromptVersionPolicy{} = policy),
    do: PromptVersionPolicy.dump(policy)

  defp dump_guardrail_chain_policy(nil), do: nil

  defp dump_guardrail_chain_policy(%GuardrailChainPolicy{} = policy),
    do: GuardrailChainPolicy.dump(policy)

  defp dump_budget_policy(nil), do: nil
  defp dump_budget_policy(%BudgetPolicy{} = policy), do: BudgetPolicy.dump(policy)

  def matches?(%__MODULE__{} = pack, attrs) do
    pack = new!(pack)
    Selector.matches?(pack.selector, attrs)
  end
end

defmodule Citadel.PolicyPacks.Selection do
  @moduledoc """
  Deterministic output of policy-pack profile selection.
  """

  alias Citadel.ContractCore.Value
  alias Citadel.PolicyPacks.BudgetPolicy
  alias Citadel.PolicyPacks.ExecutionPolicy
  alias Citadel.PolicyPacks.GuardrailChainPolicy
  alias Citadel.PolicyPacks.Profiles
  alias Citadel.PolicyPacks.PromptVersionPolicy
  alias Citadel.PolicyPacks.RejectionPolicy

  @schema [
    pack_id: :string,
    policy_version: :string,
    policy_epoch: :non_neg_integer,
    priority: :non_neg_integer,
    profiles: {:struct, Profiles},
    execution_policy: {:struct, ExecutionPolicy},
    prompt_version_policy: {:struct, PromptVersionPolicy},
    guardrail_chain_policy: {:struct, GuardrailChainPolicy},
    budget_policy: {:struct, BudgetPolicy},
    rejection_policy: {:struct, RejectionPolicy},
    extensions: {:map, :json}
  ]
  @fields Keyword.keys(@schema)

  @type t :: %__MODULE__{
          pack_id: String.t(),
          policy_version: String.t(),
          policy_epoch: non_neg_integer(),
          priority: non_neg_integer(),
          profiles: Profiles.t(),
          execution_policy: ExecutionPolicy.t() | nil,
          prompt_version_policy: PromptVersionPolicy.t() | nil,
          guardrail_chain_policy: GuardrailChainPolicy.t() | nil,
          budget_policy: BudgetPolicy.t() | nil,
          rejection_policy: RejectionPolicy.t(),
          extensions: map()
        }

  @enforce_keys @fields
  defstruct @fields

  def schema, do: @schema

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.PolicyPacks.Selection", @fields)

    %__MODULE__{
      pack_id:
        Value.required(attrs, :pack_id, "Citadel.PolicyPacks.Selection", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Selection.pack_id")
        end),
      policy_version:
        Value.required(attrs, :policy_version, "Citadel.PolicyPacks.Selection", fn value ->
          Value.string!(value, "Citadel.PolicyPacks.Selection.policy_version")
        end),
      policy_epoch:
        Value.required(attrs, :policy_epoch, "Citadel.PolicyPacks.Selection", fn value ->
          Value.non_neg_integer!(value, "Citadel.PolicyPacks.Selection.policy_epoch")
        end),
      priority:
        Value.required(attrs, :priority, "Citadel.PolicyPacks.Selection", fn value ->
          Value.non_neg_integer!(value, "Citadel.PolicyPacks.Selection.priority")
        end),
      profiles:
        Value.required(attrs, :profiles, "Citadel.PolicyPacks.Selection", fn value ->
          Value.module!(value, Profiles, "Citadel.PolicyPacks.Selection.profiles")
        end),
      execution_policy:
        Value.optional(
          attrs,
          :execution_policy,
          "Citadel.PolicyPacks.Selection",
          fn value ->
            Value.module!(
              value,
              ExecutionPolicy,
              "Citadel.PolicyPacks.Selection.execution_policy"
            )
          end,
          nil
        ),
      prompt_version_policy:
        Value.optional(
          attrs,
          :prompt_version_policy,
          "Citadel.PolicyPacks.Selection",
          fn value ->
            Value.module!(
              value,
              PromptVersionPolicy,
              "Citadel.PolicyPacks.Selection.prompt_version_policy"
            )
          end,
          nil
        ),
      guardrail_chain_policy:
        Value.optional(
          attrs,
          :guardrail_chain_policy,
          "Citadel.PolicyPacks.Selection",
          fn value ->
            Value.module!(
              value,
              GuardrailChainPolicy,
              "Citadel.PolicyPacks.Selection.guardrail_chain_policy"
            )
          end,
          nil
        ),
      budget_policy:
        Value.optional(
          attrs,
          :budget_policy,
          "Citadel.PolicyPacks.Selection",
          fn value ->
            Value.module!(value, BudgetPolicy, "Citadel.PolicyPacks.Selection.budget_policy")
          end,
          nil
        ),
      rejection_policy:
        Value.required(attrs, :rejection_policy, "Citadel.PolicyPacks.Selection", fn value ->
          Value.module!(value, RejectionPolicy, "Citadel.PolicyPacks.Selection.rejection_policy")
        end),
      extensions:
        Value.optional(
          attrs,
          :extensions,
          "Citadel.PolicyPacks.Selection",
          fn value ->
            Value.json_object!(value, "Citadel.PolicyPacks.Selection.extensions")
          end,
          %{}
        )
    }
  end

  def dump(%__MODULE__{} = selection) do
    %{
      pack_id: selection.pack_id,
      policy_version: selection.policy_version,
      policy_epoch: selection.policy_epoch,
      priority: selection.priority,
      profiles: Profiles.dump(selection.profiles),
      execution_policy: dump_execution_policy(selection.execution_policy),
      prompt_version_policy: dump_prompt_version_policy(selection.prompt_version_policy),
      guardrail_chain_policy: dump_guardrail_chain_policy(selection.guardrail_chain_policy),
      budget_policy: dump_budget_policy(selection.budget_policy),
      rejection_policy: RejectionPolicy.dump(selection.rejection_policy),
      extensions: selection.extensions
    }
  end

  defp dump_execution_policy(nil), do: nil
  defp dump_execution_policy(%ExecutionPolicy{} = policy), do: ExecutionPolicy.dump(policy)
  defp dump_prompt_version_policy(nil), do: nil

  defp dump_prompt_version_policy(%PromptVersionPolicy{} = policy),
    do: PromptVersionPolicy.dump(policy)

  defp dump_guardrail_chain_policy(nil), do: nil

  defp dump_guardrail_chain_policy(%GuardrailChainPolicy{} = policy),
    do: GuardrailChainPolicy.dump(policy)

  defp dump_budget_policy(nil), do: nil
  defp dump_budget_policy(%BudgetPolicy{} = policy), do: BudgetPolicy.dump(policy)
end

defmodule Citadel.PolicyPacks do
  @moduledoc """
  Explicit policy-pack definitions and deterministic profile selection.
  """

  alias Citadel.ContractCore.Value
  alias Citadel.PolicyPacks.BudgetPolicy
  alias Citadel.PolicyPacks.ExecutionPolicy
  alias Citadel.PolicyPacks.PolicyPack
  alias Citadel.PolicyPacks.Selection

  @manifest %{
    package: :citadel_policy_packs,
    layer: :core,
    status: :wave_3_policy_packs_frozen,
    owns: [
      :policy_pack_values,
      :profile_selection,
      :rejection_policy_inputs,
      :policy_epoch_inputs
    ],
    internal_dependencies: [:citadel_contract_core],
    external_dependencies: []
  }

  @selection_input_fields [:tenant_id, :scope_kind, :environment, :policy_epoch]

  @type selection_input :: %{
          required(:tenant_id) => String.t(),
          required(:scope_kind) => String.t(),
          optional(:environment) => String.t(),
          optional(:policy_epoch) => non_neg_integer()
        }

  @spec selection_inputs() :: [atom()]
  def selection_inputs, do: @selection_input_fields

  @spec manifest() :: map()
  def manifest, do: @manifest

  @spec select_profile!([PolicyPack.t() | map()], map() | keyword()) :: Selection.t()
  def select_profile!(packs, attrs) when is_list(packs) do
    attrs = normalize_selection_inputs!(attrs)

    selected_pack =
      packs
      |> Enum.map(&PolicyPack.new!/1)
      |> Enum.filter(&PolicyPack.matches?(&1, attrs))
      |> Enum.sort_by(&{-&1.priority, &1.pack_id})
      |> List.first()

    case selected_pack do
      nil ->
        raise ArgumentError,
              "no policy pack matched tenant_id=#{inspect(attrs.tenant_id)} scope_kind=#{inspect(attrs.scope_kind)} environment=#{inspect(attrs.environment)}"

      %PolicyPack{} = pack ->
        Selection.new!(%{
          pack_id: pack.pack_id,
          policy_version: pack.policy_version,
          policy_epoch: pack.policy_epoch,
          priority: pack.priority,
          profiles: pack.profiles,
          execution_policy: pack.execution_policy,
          prompt_version_policy: pack.prompt_version_policy,
          guardrail_chain_policy: pack.guardrail_chain_policy,
          budget_policy: pack.budget_policy,
          rejection_policy: pack.rejection_policy,
          extensions: pack.extensions
        })
    end
  end

  @spec select_profile([PolicyPack.t() | map()], map() | keyword()) ::
          {:ok, Selection.t()} | {:error, Exception.t()}
  def select_profile(packs, attrs) do
    {:ok, select_profile!(packs, attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec stable_selection_ordering() :: :priority_desc_then_pack_id_asc
  def stable_selection_ordering, do: :priority_desc_then_pack_id_asc

  @spec coding_ops_standard_pack!(keyword()) :: PolicyPack.t()
  def coding_ops_standard_pack!(opts \\ []) when is_list(opts) do
    policy_version = Keyword.get(opts, :policy_version, "coding-ops-2026-04-25")
    policy_epoch = Keyword.get(opts, :policy_epoch, 1)

    PolicyPack.new!(%{
      pack_id: Keyword.get(opts, :pack_id, "coding-ops-standard"),
      policy_version: policy_version,
      policy_epoch: policy_epoch,
      priority: Keyword.get(opts, :priority, 100),
      selector:
        Keyword.get(opts, :selector, %{
          tenant_ids: Keyword.get(opts, :tenant_ids, []),
          scope_kinds: Keyword.get(opts, :scope_kinds, []),
          environments: Keyword.get(opts, :environments, []),
          default?: Keyword.get(opts, :default?, true),
          extensions: %{}
        }),
      profiles: %{
        trust_profile: "trusted_operator",
        approval_profile: "manual",
        egress_profile: "restricted",
        workspace_profile: "coding_workspace",
        resource_profile: "standard",
        boundary_class: "workspace_session",
        extensions: %{}
      },
      execution_policy: coding_ops_standard_execution_policy!(),
      prompt_version_policy: coding_ops_standard_prompt_version_policy!(),
      guardrail_chain_policy: coding_ops_standard_guardrail_chain_policy!(),
      budget_policy: coding_ops_standard_budget_policy!(),
      rejection_policy: %{
        denial_audit_reason_codes: [
          "policy_denied",
          "approval_missing",
          "sandbox_downgrade",
          "egress_downgrade",
          "approval_downgrade",
          "tool_not_allowed",
          "operation_not_allowed",
          "unsupported_placement_intent"
        ],
        derived_state_reason_codes: ["planning_failed"],
        runtime_change_reason_codes: ["scope_unavailable", "service_hidden", "boundary_stale"],
        governance_change_reason_codes: ["approval_missing", "stale_authority_epoch"],
        extensions: %{}
      },
      extensions: %{"policy_family" => "coding_ops", "policy_version" => policy_version}
    })
  end

  @spec coding_ops_standard_execution_policy!() :: ExecutionPolicy.t()
  def coding_ops_standard_execution_policy! do
    ExecutionPolicy.new!(%{
      minimum_sandbox_level: "strict",
      maximum_egress: "restricted",
      approval_mode: "manual",
      acceptable_attestation: ["local-erlexec-weak"],
      allowed_tools: [
        "bash",
        "git",
        "read_repo",
        "write_patch",
        "codex.session.start",
        "codex.session.turn",
        "codex.session.stream",
        "codex.session.status",
        "codex.session.cancel",
        "github.pr.create",
        "github.pr.update",
        "github.pr.review.create",
        "linear.issue.update",
        "linear.comment.create",
        "linear.comment.update"
      ],
      allowed_operations: [
        "shell.exec",
        "read_repo",
        "write_patch",
        "codex.session.start",
        "codex.session.turn",
        "codex.session.stream",
        "codex.session.status",
        "codex.session.cancel",
        "github.pr.create",
        "github.pr.update",
        "github.pr.review.create",
        "linear.issue.update",
        "linear.comment.create",
        "linear.comment.update"
      ],
      effect_classes: ["filesystem", "process", "network"],
      command_classes: [
        "repo_read",
        "repo_write",
        "test_execution",
        "source_publish",
        "pull_request"
      ],
      workspace_mutability: "read_write",
      placement_intents: ["host_local", "remote_workspace"],
      execution_families: ["process"],
      wall_clock_budget_ms: 300_000,
      extensions: %{"non_interactive" => %{"approval_default" => "manual"}}
    })
  end

  @spec coding_ops_standard_prompt_version_policy!() ::
          Citadel.PolicyPacks.PromptVersionPolicy.t()
  def coding_ops_standard_prompt_version_policy! do
    Citadel.PolicyPacks.PromptVersionPolicy.new!(%{
      allowed_prompt_refs: ["prompt://coding-ops/standard/system"],
      allowed_revision_range: %{
        "prompt://coding-ops/standard/system" => %{"min" => 1, "max" => 1}
      },
      ab_variant_refs: [],
      rollback_requires_authority?: true,
      eval_evidence_required?: true,
      guard_evidence_required?: true,
      extensions: %{"policy_family" => "coding_ops_prompt"}
    })
  end

  @spec coding_ops_standard_guardrail_chain_policy!() ::
          Citadel.PolicyPacks.GuardrailChainPolicy.t()
  def coding_ops_standard_guardrail_chain_policy! do
    Citadel.PolicyPacks.GuardrailChainPolicy.new!(%{
      guard_chain_ref: "guard-chain://coding-ops/standard/default",
      detector_refs: [
        "detector://pii_reference",
        "detector://jailbreak_reference",
        "detector://schema_shape_reference",
        "detector://length_bounds"
      ],
      redaction_posture_floor: "partial",
      operator_override_authority_refs: ["authority://operator-review/coding-ops"],
      fail_closed?: true,
      extensions: %{"policy_family" => "coding_ops_guard"}
    })
  end

  @spec coding_ops_standard_budget_policy!() :: BudgetPolicy.t()
  def coding_ops_standard_budget_policy! do
    BudgetPolicy.new!(%{
      scope_key_ref: "budget-scope://coding-ops/default",
      period_class: "per_run",
      hard_cap_class: "redacted_above_ceiling",
      soft_cap_class: "redacted_below_floor",
      default_exhaustion_behavior: "fail_closed",
      override_permissions: [
        %{
          permission_ref: "permission://budget/override",
          operator_role_refs: ["role://operator/coding-ops-budget-override"],
          budget_classes: ["production", "replay", "eval", "infrastructure"],
          max_duration_seconds: 3_600,
          extensions: %{"policy_family" => "coding_ops_budget_override"}
        }
      ],
      extensions: %{"policy_family" => "coding_ops_budget"}
    })
  end

  defp normalize_selection_inputs!(attrs) do
    attrs =
      Value.normalize_attrs!(
        attrs,
        "Citadel.PolicyPacks selection input",
        @selection_input_fields
      )

    %{
      tenant_id:
        Value.required(attrs, :tenant_id, "Citadel.PolicyPacks selection input", fn value ->
          Value.string!(value, "Citadel.PolicyPacks selection input.tenant_id")
        end),
      scope_kind:
        Value.required(attrs, :scope_kind, "Citadel.PolicyPacks selection input", fn value ->
          Value.string!(value, "Citadel.PolicyPacks selection input.scope_kind")
        end),
      environment:
        Value.optional(
          attrs,
          :environment,
          "Citadel.PolicyPacks selection input",
          fn value ->
            Value.string!(value, "Citadel.PolicyPacks selection input.environment")
          end,
          nil
        ),
      policy_epoch:
        Value.optional(
          attrs,
          :policy_epoch,
          "Citadel.PolicyPacks selection input",
          fn value ->
            Value.non_neg_integer!(value, "Citadel.PolicyPacks selection input.policy_epoch")
          end,
          nil
        )
    }
  end
end

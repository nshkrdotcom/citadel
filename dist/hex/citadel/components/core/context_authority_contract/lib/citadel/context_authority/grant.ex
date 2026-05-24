defmodule Citadel.ContextAuthority.Grant do
  @moduledoc """
  Citadel context authority grant carried from authority evaluation to packet admission.
  """

  alias Citadel.ContractCore.Value
  alias Citadel.ContextAuthority.AuthorityRequest

  @required_fields [
    :authority_ref,
    :tenant_ref,
    :allowed_model_classes,
    :route_policy_ref,
    :expires_at,
    :trace_ref
  ]

  @optional_fields [
    :payload_mode,
    :redaction_class,
    :data_use,
    :operation,
    :evidence_refs,
    :metadata
  ]

  @fields @required_fields ++ @optional_fields

  @enforce_keys @required_fields
  defstruct @fields

  @type t :: %__MODULE__{
          authority_ref: String.t(),
          tenant_ref: String.t(),
          allowed_model_classes: [String.t()],
          route_policy_ref: String.t(),
          expires_at: DateTime.t() | nil,
          trace_ref: String.t(),
          payload_mode: AuthorityRequest.payload_mode(),
          redaction_class: AuthorityRequest.redaction_class(),
          data_use: String.t(),
          operation: AuthorityRequest.operation(),
          evidence_refs: [String.t()],
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = grant), do: grant |> dump() |> new()

  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(t() | map() | keyword()) :: t()
  def new!(%__MODULE__{} = grant), do: grant |> dump() |> new!()

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel.ContextAuthority.Grant", @fields)

    %__MODULE__{
      authority_ref: required_string(attrs, :authority_ref),
      tenant_ref: required_string(attrs, :tenant_ref),
      allowed_model_classes: required_strings(attrs, :allowed_model_classes),
      route_policy_ref: required_string(attrs, :route_policy_ref),
      expires_at: optional_datetime(attrs, :expires_at),
      trace_ref: required_string(attrs, :trace_ref),
      payload_mode: optional_payload_mode(attrs),
      redaction_class: optional_redaction_class(attrs),
      data_use: optional_string(attrs, :data_use, "model_context"),
      operation: optional_operation(attrs),
      evidence_refs: optional_strings(attrs, :evidence_refs),
      metadata: optional_map(attrs, :metadata)
    }
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = grant) do
    %{
      authority_ref: grant.authority_ref,
      tenant_ref: grant.tenant_ref,
      allowed_model_classes: grant.allowed_model_classes,
      route_policy_ref: grant.route_policy_ref,
      expires_at: datetime_to_iso8601(grant.expires_at),
      trace_ref: grant.trace_ref,
      payload_mode: grant.payload_mode,
      redaction_class: grant.redaction_class,
      data_use: grant.data_use,
      operation: grant.operation,
      evidence_refs: grant.evidence_refs,
      metadata: grant.metadata
    }
  end

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, %DateTime{}), do: false

  def expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp required_string(attrs, field) do
    Value.required(attrs, field, "Citadel.ContextAuthority.Grant", fn value ->
      Value.string!(value, "Citadel.ContextAuthority.Grant.#{field}")
    end)
  end

  defp optional_string(attrs, field, default) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.Grant",
      fn value -> Value.string!(value, "Citadel.ContextAuthority.Grant.#{field}") end,
      default
    )
  end

  defp required_strings(attrs, field) do
    Value.required(attrs, field, "Citadel.ContextAuthority.Grant", fn value ->
      Value.unique_strings!(value, "Citadel.ContextAuthority.Grant.#{field}", allow_empty?: false)
    end)
  end

  defp optional_strings(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.Grant",
      fn value -> Value.unique_strings!(value, "Citadel.ContextAuthority.Grant.#{field}") end,
      []
    )
  end

  defp optional_datetime(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.Grant",
      fn value -> Value.datetime!(value, "Citadel.ContextAuthority.Grant.#{field}") end,
      nil
    )
  end

  defp optional_payload_mode(attrs) do
    Value.optional(
      attrs,
      :payload_mode,
      "Citadel.ContextAuthority.Grant",
      fn value ->
        Value.enum!(
          value,
          AuthorityRequest.payload_modes(),
          "Citadel.ContextAuthority.Grant.payload_mode"
        )
      end,
      :refs_only
    )
  end

  defp optional_redaction_class(attrs) do
    Value.optional(
      attrs,
      :redaction_class,
      "Citadel.ContextAuthority.Grant",
      fn value ->
        Value.enum!(
          value,
          AuthorityRequest.redaction_classes(),
          "Citadel.ContextAuthority.Grant.redaction_class"
        )
      end,
      :tenant_sensitive
    )
  end

  defp optional_operation(attrs) do
    Value.optional(
      attrs,
      :operation,
      "Citadel.ContextAuthority.Grant",
      fn value ->
        Value.enum!(
          value,
          AuthorityRequest.operations(),
          "Citadel.ContextAuthority.Grant.operation"
        )
      end,
      :context_access
    )
  end

  defp optional_map(attrs, field) do
    Value.optional(
      attrs,
      field,
      "Citadel.ContextAuthority.Grant",
      fn value -> Value.json_object!(value, "Citadel.ContextAuthority.Grant.#{field}") end,
      %{}
    )
  end

  defp datetime_to_iso8601(nil), do: nil
  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end

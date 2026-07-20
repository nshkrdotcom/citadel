defmodule Citadel.PolicyPacks.ModelInvocationPolicy do
  @moduledoc """
  Immutable compiled policy artifact for one bounded managed-model journey.

  The artifact contains only release-supplied policy facts. Evaluation is pure:
  time and request identity are supplied as normalized facts by the caller.
  """

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.ContractCore.Value

  @compiler_ref "compiler://citadel/model-invocation-policy/v1"
  @max_source_bytes 32_768
  @fields [
    :artifact_ref,
    :activation_ref,
    :policy_version,
    :compiler_ref,
    :source_digest,
    :provider_family,
    :allowed_models,
    :allowed_operations,
    :max_grant_ttl_seconds
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          artifact_ref: String.t(),
          activation_ref: String.t(),
          policy_version: pos_integer(),
          compiler_ref: String.t(),
          source_digest: String.t(),
          provider_family: String.t(),
          allowed_models: [String.t()],
          allowed_operations: [String.t()],
          max_grant_ttl_seconds: pos_integer()
        }

  @spec new!(map() | keyword() | t()) :: t()
  def new!(%__MODULE__{} = policy), do: policy |> dump() |> new!()

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel model invocation policy", @fields)

    policy = %__MODULE__{
      artifact_ref: required_string(attrs, :artifact_ref),
      activation_ref: required_string(attrs, :activation_ref),
      policy_version: required_positive_integer(attrs, :policy_version),
      compiler_ref: required_string(attrs, :compiler_ref),
      source_digest: required_digest(attrs, :source_digest),
      provider_family: required_string(attrs, :provider_family),
      allowed_models: required_strings(attrs, :allowed_models),
      allowed_operations: required_strings(attrs, :allowed_operations),
      max_grant_ttl_seconds: required_positive_integer(attrs, :max_grant_ttl_seconds)
    }

    if source_digest(source(policy)) == policy.source_digest do
      policy
    else
      raise ArgumentError, "Citadel model invocation policy source digest mismatch"
    end
  end

  @spec synapse_gemini_turn!() :: t()
  def synapse_gemini_turn! do
    source = %{
      artifact_ref: "policy-artifact://citadel/synapse/gemini-turn/v1",
      activation_ref: "policy-activation://nshkr/synapse/gemini-turn/v1",
      policy_version: 1,
      compiler_ref: @compiler_ref,
      provider_family: "google_gemini",
      allowed_models: ["gemini-2.5-flash"],
      allowed_operations: ["generate_content", "stream_generate_content"],
      max_grant_ttl_seconds: 120
    }

    source
    |> Map.put(:source_digest, source_digest(source))
    |> new!()
  end

  @spec evaluate(t(), map()) :: :permitted | {:denied, atom()}
  def evaluate(%__MODULE__{} = policy, input) when is_map(input) do
    cond do
      Map.get(input, :provider_family) != policy.provider_family ->
        {:denied, :provider_not_allowed}

      Map.get(input, :model_ref) not in policy.allowed_models ->
        {:denied, :model_not_allowed}

      Map.get(input, :operation_class) not in policy.allowed_operations ->
        {:denied, :operation_not_allowed}

      invalid_ttl?(policy, input) ->
        {:denied, :grant_ttl_not_allowed}

      true ->
        :permitted
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = policy), do: Map.from_struct(policy)

  @spec source(t()) :: map()
  def source(%__MODULE__{} = policy), do: policy |> dump() |> Map.delete(:source_digest)

  @spec source_digest(map()) :: String.t()
  def source_digest(source) when is_map(source) do
    canonical =
      CanonicalJson.encode_inline!(source,
        max_bytes: @max_source_bytes,
        label: "Citadel model invocation policy source"
      )

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp invalid_ttl?(policy, %{
         issued_at: %DateTime{} = issued_at,
         expires_at: %DateTime{} = expires_at
       }) do
    ttl = DateTime.diff(expires_at, issued_at, :second)
    ttl <= 0 or ttl > policy.max_grant_ttl_seconds
  end

  defp invalid_ttl?(_policy, _input), do: true

  defp required_string(attrs, field) do
    Value.required(attrs, field, "Citadel model invocation policy", fn value ->
      Value.string!(value, "Citadel model invocation policy.#{field}")
    end)
  end

  defp required_strings(attrs, field) do
    Value.required(attrs, field, "Citadel model invocation policy", fn value ->
      Value.unique_strings!(value, "Citadel model invocation policy.#{field}",
        allow_empty?: false
      )
    end)
  end

  defp required_positive_integer(attrs, field) do
    Value.required(attrs, field, "Citadel model invocation policy", fn value ->
      Value.positive_integer!(value, "Citadel model invocation policy.#{field}")
    end)
  end

  defp required_digest(attrs, field) do
    digest = required_string(attrs, field)

    if String.match?(digest, ~r/\Asha256:[0-9a-f]{64}\z/) do
      digest
    else
      raise ArgumentError, "Citadel model invocation policy.#{field} must be a SHA-256 digest"
    end
  end
end

defmodule Citadel.PolicyPacks.ToolEffectPolicy do
  @moduledoc """
  Immutable policy artifact for the first reviewed Codex file effect.

  The policy is deliberately narrower than the general coding-operations pack:
  it admits one named-file create-or-replace operation in an isolated disposable
  workspace and requires an exact review binding.
  """

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.ContractCore.Value

  @compiler_ref "compiler://citadel/tool-effect-policy/v1"
  @max_source_bytes 32_768
  @max_ref_bytes 4_096
  @wildcards ["*", "?", "[", "]", "{", "}"]
  @fields [
    :artifact_ref,
    :activation_ref,
    :policy_version,
    :compiler_ref,
    :source_digest,
    :provider_family,
    :capability_id,
    :workspace_policy,
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
          capability_id: String.t(),
          workspace_policy: String.t(),
          allowed_operations: [String.t()],
          max_grant_ttl_seconds: pos_integer()
        }

  @spec new!(map() | keyword() | t()) :: t()
  def new!(%__MODULE__{} = policy), do: policy |> dump() |> new!()

  def new!(attrs) do
    attrs = Value.normalize_attrs!(attrs, "Citadel tool effect policy", @fields)

    policy = %__MODULE__{
      artifact_ref: required_string(attrs, :artifact_ref),
      activation_ref: required_string(attrs, :activation_ref),
      policy_version: required_positive_integer(attrs, :policy_version),
      compiler_ref: required_string(attrs, :compiler_ref),
      source_digest: required_digest(attrs, :source_digest),
      provider_family: required_string(attrs, :provider_family),
      capability_id: required_string(attrs, :capability_id),
      workspace_policy: required_string(attrs, :workspace_policy),
      allowed_operations: required_strings(attrs, :allowed_operations),
      max_grant_ttl_seconds: required_positive_integer(attrs, :max_grant_ttl_seconds)
    }

    if source_digest(source(policy)) == policy.source_digest do
      policy
    else
      raise ArgumentError, "Citadel tool effect policy source digest mismatch"
    end
  end

  @spec synapse_codex_reviewed_write!() :: t()
  def synapse_codex_reviewed_write! do
    source = %{
      artifact_ref: "policy-artifact://citadel/synapse/codex-reviewed-write/v1",
      activation_ref: "policy-activation://nshkr/synapse/codex-reviewed-write/v1",
      policy_version: 1,
      compiler_ref: @compiler_ref,
      provider_family: "codex",
      capability_id: "codex.session.turn",
      workspace_policy: "isolated_disposable_workspace",
      allowed_operations: ["create_or_replace"],
      max_grant_ttl_seconds: 300
    }

    source
    |> Map.put(:source_digest, source_digest(source))
    |> new!()
  end

  @spec evaluate(t(), map()) :: :permit_with_review | {:denied, atom()}
  def evaluate(%__MODULE__{} = policy, input) when is_map(input) do
    cond do
      Map.get(input, :provider_family) != policy.provider_family ->
        {:denied, :provider_not_allowed}

      Map.get(input, :capability_id) != policy.capability_id ->
        {:denied, :capability_not_allowed}

      Map.get(input, :workspace_policy) != policy.workspace_policy ->
        {:denied, :workspace_policy_not_allowed}

      Map.get(input, :operation_class) not in policy.allowed_operations ->
        {:denied, :operation_not_allowed}

      not safe_ref?(Map.get(input, :provider_account_ref)) ->
        {:denied, :provider_account_not_allowed}

      not safe_ref?(Map.get(input, :credential_lease_ref)) ->
        {:denied, :credential_lease_not_allowed}

      not safe_ref?(Map.get(input, :managed_session_ref)) ->
        {:denied, :managed_session_not_allowed}

      not safe_ref?(Map.get(input, :review_ref)) ->
        {:denied, :review_not_allowed}

      not safe_ref?(Map.get(input, :workspace_ref)) ->
        {:denied, :workspace_not_allowed}

      not safe_relative_path?(Map.get(input, :relative_path)) ->
        {:denied, :relative_path_not_allowed}

      not safe_ref?(Map.get(input, :operation_ref)) ->
        {:denied, :operation_ref_not_allowed}

      not safe_ref?(Map.get(input, :target_ref)) ->
        {:denied, :target_not_allowed}

      not safe_ref?(Map.get(input, :attempt_ref)) ->
        {:denied, :attempt_not_allowed}

      not safe_ref?(Map.get(input, :effect_ref)) ->
        {:denied, :effect_not_allowed}

      invalid_ttl?(policy, input) ->
        {:denied, :grant_ttl_not_allowed}

      true ->
        :permit_with_review
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
        label: "Citadel tool effect policy source"
      )

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp safe_relative_path?(path) when is_binary(path) do
    String.valid?(path) and String.printable?(path) and path == String.trim(path) and
      byte_size(path) <= 4_096 and
      not String.starts_with?(path, ["/", "~"]) and
      not String.contains?(path, ["\\", <<0>> | @wildcards]) and
      path
      |> String.split("/", trim: false)
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp safe_relative_path?(_path), do: false

  defp safe_ref?(value) when is_binary(value) do
    String.valid?(value) and String.printable?(value) and value == String.trim(value) and
      value != "" and byte_size(value) <= @max_ref_bytes and
      not String.contains?(value, [<<0>> | @wildcards])
  end

  defp safe_ref?(_value), do: false

  defp invalid_ttl?(policy, %{
         issued_at: %DateTime{} = issued_at,
         expires_at: %DateTime{} = expires_at
       }) do
    ttl_microseconds = DateTime.diff(expires_at, issued_at, :microsecond)

    ttl_microseconds <= 0 or
      ttl_microseconds >
        System.convert_time_unit(policy.max_grant_ttl_seconds, :second, :microsecond)
  end

  defp invalid_ttl?(_policy, _input), do: true

  defp required_string(attrs, field) do
    Value.required(attrs, field, "Citadel tool effect policy", fn value ->
      Value.string!(value, "Citadel tool effect policy.#{field}")
    end)
  end

  defp required_strings(attrs, field) do
    Value.required(attrs, field, "Citadel tool effect policy", fn value ->
      Value.unique_strings!(value, "Citadel tool effect policy.#{field}", allow_empty?: false)
    end)
  end

  defp required_positive_integer(attrs, field) do
    Value.required(attrs, field, "Citadel tool effect policy", fn value ->
      Value.positive_integer!(value, "Citadel tool effect policy.#{field}")
    end)
  end

  defp required_digest(attrs, field) do
    digest = required_string(attrs, field)

    if String.match?(digest, ~r/\Asha256:[0-9a-f]{64}\z/) do
      digest
    else
      raise ArgumentError, "Citadel tool effect policy.#{field} must be a SHA-256 digest"
    end
  end
end

defmodule Citadel.ModelGrant do
  @moduledoc """
  Model-invocation projection of the frozen `Citadel.ScopedGrant` contract.

  The projection is valid only when the underlying grant contains the exact
  model scope and no additional or missing scope fields.
  """

  alias Citadel.ScopedGrant

  @scope_fields [
    :provider_family,
    :account_ref,
    :model_ref,
    :operation_class,
    :context_ref,
    :context_digest,
    :attempt_ref,
    :fence_ref
  ]
  @fields [
    :decision_ref,
    :grant_ref,
    :input_digest,
    :policy_ref,
    :policy_version,
    :tenant_ref,
    :actor_ref,
    :subject_ref,
    :account_ref,
    :provider_family,
    :model_ref,
    :operation_ref,
    :operation_class,
    :context_ref,
    :context_digest,
    :attempt_ref,
    :effect_ref,
    :fence_token,
    :issued_at,
    :expires_at,
    :status
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec from_scoped(ScopedGrant.t()) :: {:ok, t()} | {:error, :invalid_model_grant}
  def from_scoped(%ScopedGrant{} = grant) do
    with "model_inference" <- grant.capability_id,
         {:ok, scope} <- exact_scope(grant.scope) do
      {:ok,
       struct!(__MODULE__, %{
         decision_ref: grant.decision_ref,
         grant_ref: grant.grant_ref,
         input_digest: grant.input_snapshot_hash,
         policy_ref: grant.policy_artifact_ref,
         policy_version: grant.policy_version,
         tenant_ref: grant.tenant_ref,
         actor_ref: grant.actor_ref,
         subject_ref: grant.subject_ref,
         account_ref: scope.account_ref,
         provider_family: scope.provider_family,
         model_ref: scope.model_ref,
         operation_ref: grant.operation_ref,
         operation_class: scope.operation_class,
         context_ref: scope.context_ref,
         context_digest: scope.context_digest,
         attempt_ref: scope.attempt_ref,
         effect_ref: grant.effect_ref,
         fence_token: scope.fence_ref,
         issued_at: grant.issued_at,
         expires_at: grant.expires_at,
         status: grant.status
       })}
    else
      _other -> {:error, :invalid_model_grant}
    end
  end

  @spec scope_fields() :: [atom()]
  def scope_fields, do: @scope_fields

  @spec scoped_authority(t()) :: map()
  def scoped_authority(%__MODULE__{} = grant) do
    %{
      provider_family: grant.provider_family,
      account_ref: grant.account_ref,
      model_ref: grant.model_ref,
      operation_class: grant.operation_class,
      context_ref: grant.context_ref,
      context_digest: grant.context_digest,
      attempt_ref: grant.attempt_ref,
      fence_ref: grant.fence_token
    }
  end

  defp exact_scope(scope) when is_map(scope) do
    normalized =
      Enum.reduce_while(scope, %{}, fn
        {key, value}, acc when is_atom(key) ->
          {:cont, Map.put(acc, key, value)}

        {key, value}, acc when is_binary(key) ->
          case Enum.find(@scope_fields, &(Atom.to_string(&1) == key)) do
            nil -> {:halt, :error}
            field -> {:cont, Map.put(acc, field, value)}
          end

        _entry, _acc ->
          {:halt, :error}
      end)

    if is_map(normalized) and Enum.sort(Map.keys(normalized)) == Enum.sort(@scope_fields) and
         Enum.all?(Map.values(normalized), &present_string?/1) and
         digest?(normalized.context_digest) do
      {:ok, normalized}
    else
      {:error, :invalid_model_grant}
    end
  end

  defp exact_scope(_scope), do: {:error, :invalid_model_grant}
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp digest?(value), do: is_binary(value) and String.match?(value, ~r/\Asha256:[0-9a-f]{64}\z/)
end

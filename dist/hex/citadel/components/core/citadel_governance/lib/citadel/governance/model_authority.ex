defmodule Citadel.Governance.ModelAuthority do
  @moduledoc """
  Deterministic decision, durable issuance, and exact verification for one
  governed model invocation.

  This service does not inspect credentials or call providers. It resolves a
  pinned policy artifact against caller-supplied facts and persists the exact
  decision/grant through `Citadel.Governance.DurableAuthority`.
  """

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.Governance.DurableAuthority
  alias Citadel.GrantVerificationError
  alias Citadel.ModelGrant
  alias Citadel.PolicyPacks.ModelInvocationPolicy
  alias Citadel.ScopedGrant

  @max_input_bytes 65_536
  @issue_fields [
    :session_ref,
    :decision_ref,
    :grant_ref,
    :tenant_ref,
    :actor_ref,
    :subject_ref,
    :provider_family,
    :account_ref,
    :model_ref,
    :operation_ref,
    :operation_class,
    :context_ref,
    :context_digest,
    :attempt_ref,
    :effect_ref,
    :fence_token,
    :issued_at,
    :expires_at
  ]
  @binding_fields [
    :decision_ref,
    :input_digest,
    :policy_ref,
    :policy_version,
    :tenant_ref,
    :actor_ref,
    :subject_ref,
    :provider_family,
    :account_ref,
    :model_ref,
    :operation_ref,
    :operation_class,
    :context_ref,
    :context_digest,
    :attempt_ref,
    :effect_ref,
    :fence_token
  ]

  @type outcome ::
          %{
            required(:result) => :permitted,
            required(:decision) => struct(),
            required(:grant) => ModelGrant.t()
          }
          | %{
              required(:result) => :denied,
              required(:reason) => atom(),
              required(:decision) => struct()
            }

  @spec evaluate_and_persist(map() | keyword(), ModelInvocationPolicy.t()) ::
          {:ok, outcome()} | {:error, term()}
  def evaluate_and_persist(attrs, %ModelInvocationPolicy{} = policy) do
    with {:ok, input} <- normalize_issue(attrs),
         {:ok, _session} <-
           DurableAuthority.open_session(%{
             session_ref: input.session_ref,
             tenant_ref: input.tenant_ref,
             subject_ref: input.subject_ref,
             policy_epoch: policy.policy_version,
             opened_at: input.issued_at
           }) do
      persist_evaluation(input, policy, ModelInvocationPolicy.evaluate(policy, input))
    end
  end

  @spec input_digest(map() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def input_digest(attrs) do
    with {:ok, input} <- normalize_issue(attrs) do
      {:ok, digest(input_snapshot(input))}
    end
  end

  @spec fetch_grant(String.t()) :: {:ok, ModelGrant.t()} | {:error, term()}
  def fetch_grant(grant_ref) when is_binary(grant_ref) do
    with {:ok, grant} <- DurableAuthority.fetch_grant(grant_ref),
         {:ok, model_grant} <- ModelGrant.from_scoped(grant) do
      {:ok, model_grant}
    end
  end

  @spec verify_grant(String.t(), map() | keyword(), DateTime.t()) ::
          :ok | {:error, GrantVerificationError.t()} | {:error, term()}
  def verify_grant(grant_ref, expected, %DateTime{} = now) when is_binary(grant_ref) do
    with {:ok, expected} <- normalize_binding(expected),
         {:ok, scoped_grant} <- DurableAuthority.fetch_grant(grant_ref),
         {:ok, model_grant} <- ModelGrant.from_scoped(scoped_grant),
         :ok <- exact_model_binding(model_grant, expected),
         :ok <- DurableAuthority.verify_grant(grant_ref, scoped_expected(scoped_grant), now) do
      :ok
    else
      {:error, :invalid_model_grant_binding} ->
        verification_error(grant_ref, :scope_mismatch, :model_grant_binding_mismatch)

      {:error, :invalid_model_grant} ->
        verification_error(grant_ref, :invalid, :invalid_reconstructed_model_grant)

      {:error, _reason} = error ->
        error
    end
  end

  def verify_grant(grant_ref, _expected, _now) when is_binary(grant_ref),
    do: verification_error(grant_ref, :invalid, :invalid_model_grant_verification)

  @spec revoke_grant(String.t(), map() | keyword()) :: {:ok, ModelGrant.t()} | {:error, term()}
  def revoke_grant(grant_ref, attrs) when is_binary(grant_ref) do
    with {:ok, scoped_grant} <- DurableAuthority.revoke_grant(grant_ref, attrs),
         {:ok, model_grant} <- ModelGrant.from_scoped(scoped_grant) do
      {:ok, model_grant}
    end
  end

  defp persist_evaluation(input, policy, evaluation) do
    result = if evaluation == :permitted, do: "permitted", else: "denied"
    reason = if evaluation == :permitted, do: nil, else: elem(evaluation, 1)
    input_snapshot = input_snapshot(input)
    input_digest = digest(input_snapshot)

    payload = %{
      "input_snapshot" => input_snapshot,
      "input_digest" => input_digest,
      "policy_artifact" => ModelInvocationPolicy.dump(policy),
      "policy_source" => ModelInvocationPolicy.source(policy),
      "result" => result,
      "reason" => reason
    }

    decision_attrs = %{
      decision_ref: input.decision_ref,
      decision_hash: digest(payload),
      input_snapshot_hash: input_digest,
      policy_artifact_ref: policy.artifact_ref,
      policy_version: policy.policy_version,
      result: result,
      decision_payload: payload,
      decided_at: input.issued_at
    }

    case evaluation do
      :permitted ->
        issue_permitted(input, policy, decision_attrs)

      {:denied, reason} ->
        with {:ok, decision} <-
               DurableAuthority.record_decision(input.session_ref, decision_attrs) do
          {:ok, %{result: :denied, reason: reason, decision: decision}}
        end
    end
  end

  defp issue_permitted(input, policy, decision_attrs) do
    scoped_grant =
      ScopedGrant.new!(%{
        contract_version: 1,
        grant_ref: input.grant_ref,
        decision_ref: input.decision_ref,
        decision_hash: decision_attrs.decision_hash,
        policy_artifact_ref: policy.artifact_ref,
        policy_version: policy.policy_version,
        input_snapshot_hash: decision_attrs.input_snapshot_hash,
        tenant_ref: input.tenant_ref,
        actor_ref: input.actor_ref,
        subject_ref: input.subject_ref,
        effect_ref: input.effect_ref,
        operation_ref: input.operation_ref,
        capability_id: "model_inference",
        scope: scope(input),
        obligations: [
          %{"type" => "record_provider_attempt", "attempt_ref" => input.attempt_ref},
          %{"type" => "enforce_credential_fence", "fence_ref" => input.fence_token}
        ],
        result: "permitted",
        issued_at: input.issued_at,
        expires_at: input.expires_at,
        status: "active"
      })

    with {:ok, %{decision: decision, grant: persisted}} <-
           DurableAuthority.issue_grant(input.session_ref, decision_attrs, scoped_grant),
         {:ok, model_grant} <- ModelGrant.from_scoped(persisted) do
      {:ok, %{result: :permitted, decision: decision, grant: model_grant}}
    end
  end

  defp normalize_issue(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize_exact(attrs, @issue_fields)

    with true <- is_map(attrs),
         true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@issue_fields),
         true <-
           Enum.all?(
             @issue_fields -- [:issued_at, :expires_at, :context_digest],
             &present?(attrs[&1])
           ),
         true <- digest?(attrs.context_digest),
         true <- is_struct(attrs.issued_at, DateTime),
         true <- is_struct(attrs.expires_at, DateTime),
         :gt <- DateTime.compare(attrs.expires_at, attrs.issued_at) do
      {:ok,
       attrs
       |> Map.update!(:issued_at, &DateTime.truncate(&1, :microsecond))
       |> Map.update!(:expires_at, &DateTime.truncate(&1, :microsecond))}
    else
      _other -> {:error, :invalid_model_authority_input}
    end
  end

  defp normalize_issue(_attrs), do: {:error, :invalid_model_authority_input}

  defp normalize_binding(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize_exact(attrs, @binding_fields)

    with true <- is_map(attrs),
         true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@binding_fields),
         true <-
           Enum.all?(
             @binding_fields -- [:policy_version, :input_digest, :context_digest],
             &present?(attrs[&1])
           ),
         true <- is_integer(attrs.policy_version) and attrs.policy_version > 0,
         true <- digest?(attrs.input_digest),
         true <- digest?(attrs.context_digest) do
      {:ok, attrs}
    else
      _other -> {:error, :invalid_model_grant_binding}
    end
  end

  defp normalize_binding(_attrs), do: {:error, :invalid_model_grant_binding}

  defp atomize_exact(attrs, fields) do
    attrs = Map.new(attrs)

    Enum.reduce_while(attrs, %{}, fn {key, value}, acc ->
      case normalize_key(key, fields) do
        nil ->
          {:halt, :error}

        field ->
          if Map.has_key?(acc, field),
            do: {:halt, :error},
            else: {:cont, Map.put(acc, field, value)}
      end
    end)
  rescue
    _error -> :error
  end

  defp normalize_key(key, fields) when is_atom(key), do: if(key in fields, do: key)

  defp normalize_key(key, fields) when is_binary(key),
    do: Enum.find(fields, &(Atom.to_string(&1) == key))

  defp normalize_key(_key, _fields), do: nil

  defp input_snapshot(input) do
    input
    |> Map.take(@issue_fields -- [:session_ref, :decision_ref, :grant_ref])
    |> Map.put(:fence_ref, input.fence_token)
    |> Map.delete(:fence_token)
    |> Map.update!(:issued_at, &DateTime.to_iso8601/1)
    |> Map.update!(:expires_at, &DateTime.to_iso8601/1)
  end

  defp scope(input) do
    %{
      provider_family: input.provider_family,
      account_ref: input.account_ref,
      model_ref: input.model_ref,
      operation_class: input.operation_class,
      context_ref: input.context_ref,
      context_digest: input.context_digest,
      attempt_ref: input.attempt_ref,
      fence_ref: input.fence_token
    }
  end

  defp scoped_expected(scoped_grant) do
    %{
      tenant_ref: scoped_grant.tenant_ref,
      actor_ref: scoped_grant.actor_ref,
      subject_ref: scoped_grant.subject_ref,
      effect_ref: scoped_grant.effect_ref,
      operation_ref: scoped_grant.operation_ref,
      capability_id: "model_inference",
      scope: scoped_grant.scope
    }
  end

  defp exact_model_binding(model_grant, expected) do
    actual = Map.take(Map.from_struct(model_grant), @binding_fields)
    if actual == expected, do: :ok, else: {:error, :invalid_model_grant_binding}
  end

  defp digest(value) do
    canonical =
      CanonicalJson.encode_inline!(value,
        max_bytes: @max_input_bytes,
        label: "Citadel model authority input"
      )

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp verification_error(grant_ref, category, reason) do
    {:error, %GrantVerificationError{grant_ref: grant_ref, category: category, reason: reason}}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp digest?(value), do: is_binary(value) and String.match?(value, ~r/\Asha256:[0-9a-f]{64}\z/)
end

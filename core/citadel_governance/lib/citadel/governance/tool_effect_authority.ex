defmodule Citadel.Governance.ToolEffectAuthority do
  @moduledoc """
  Durable authority for one reviewed Codex named-file effect.

  This is a narrow service over the frozen `Citadel.ScopedGrant` contract. It
  binds the authority decision, Mezzanine review, Jido account/lease generation,
  ASM session generation, workspace, target, operation, and reviewed content.
  It never accepts credential material or selects an execution route.
  """

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.Governance.DurableAuthority
  alias Citadel.GrantVerificationError
  alias Citadel.PolicyPacks.ToolEffectPolicy
  alias Citadel.ScopedGrant

  @max_input_bytes 65_536
  @max_ref_bytes 4_096
  @wildcards ["*", "?", "[", "]", "{", "}"]
  @issue_fields [
    :session_ref,
    :decision_ref,
    :grant_ref,
    :tenant_ref,
    :actor_ref,
    :subject_ref,
    :provider_family,
    :provider_account_ref,
    :credential_lease_ref,
    :credential_generation,
    :managed_session_ref,
    :session_generation,
    :review_ref,
    :workspace_policy,
    :workspace_ref,
    :workspace_root_digest,
    :relative_path,
    :operation_ref,
    :operation_class,
    :capability_id,
    :reviewed_content_digest,
    :target_ref,
    :attempt_ref,
    :effect_ref,
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
    :provider_account_ref,
    :credential_lease_ref,
    :credential_generation,
    :managed_session_ref,
    :session_generation,
    :review_ref,
    :workspace_policy,
    :workspace_ref,
    :workspace_root_digest,
    :relative_path,
    :operation_ref,
    :operation_class,
    :capability_id,
    :reviewed_content_digest,
    :target_ref,
    :attempt_ref,
    :effect_ref
  ]
  @scope_fields [
    "authority_decision_ref",
    "input_digest",
    "policy_ref",
    "policy_version",
    "provider_family",
    "provider_account_ref",
    "credential_lease_ref",
    "credential_generation",
    "managed_session_ref",
    "session_generation",
    "review_ref",
    "workspace_policy",
    "workspace_ref",
    "workspace_root_digest",
    "relative_path",
    "operation_class",
    "reviewed_content_digest",
    "target_ref",
    "attempt_ref"
  ]

  @type outcome ::
          %{
            required(:result) => :permit_with_review,
            required(:decision) => struct(),
            required(:grant) => ScopedGrant.t()
          }
          | %{
              required(:result) => :denied,
              required(:reason) => atom(),
              required(:decision) => struct()
            }

  @spec evaluate_and_persist(map() | keyword(), ToolEffectPolicy.t()) ::
          {:ok, outcome()} | {:error, term()}
  def evaluate_and_persist(attrs, %ToolEffectPolicy{} = policy) do
    with {:ok, input} <- normalize_issue(attrs),
         {:ok, _session} <-
           DurableAuthority.open_session(%{
             session_ref: input.session_ref,
             tenant_ref: input.tenant_ref,
             subject_ref: input.subject_ref,
             policy_epoch: policy.policy_version,
             opened_at: input.issued_at
           }) do
      persist_evaluation(input, policy, ToolEffectPolicy.evaluate(policy, input))
    end
  end

  @spec input_digest(map() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def input_digest(attrs) do
    with {:ok, input} <- normalize_issue(attrs) do
      {:ok, digest(input_snapshot(input))}
    end
  end

  @spec fetch_grant(String.t()) :: {:ok, ScopedGrant.t()} | {:error, term()}
  def fetch_grant(grant_ref) when is_binary(grant_ref) do
    with {:ok, grant} <- DurableAuthority.fetch_grant(grant_ref),
         :ok <- validate_tool_grant(grant) do
      {:ok, grant}
    end
  end

  @spec verify_grant(String.t(), map() | keyword(), DateTime.t()) ::
          :ok | {:error, GrantVerificationError.t()} | {:error, term()}
  def verify_grant(grant_ref, expected, %DateTime{} = now) when is_binary(grant_ref) do
    with {:ok, expected} <- normalize_binding(expected),
         {:ok, grant} <- DurableAuthority.fetch_grant(grant_ref),
         :ok <- validate_tool_grant(grant) do
      DurableAuthority.verify_grant(grant_ref, scoped_expected(expected), now)
    else
      {:error, :invalid_tool_effect_grant} ->
        verification_error(grant_ref, :invalid, :invalid_reconstructed_tool_effect_grant)

      {:error, _reason} = error ->
        error
    end
  end

  def verify_grant(grant_ref, _expected, _now) when is_binary(grant_ref),
    do: verification_error(grant_ref, :invalid, :invalid_tool_effect_grant_verification)

  @spec revoke_grant(String.t(), map() | keyword()) ::
          {:ok, ScopedGrant.t()} | {:error, term()}
  def revoke_grant(grant_ref, attrs) when is_binary(grant_ref) do
    with {:ok, _grant} <- fetch_grant(grant_ref),
         {:ok, revoked} <- DurableAuthority.revoke_grant(grant_ref, attrs),
         :ok <- validate_tool_grant(revoked) do
      {:ok, revoked}
    end
  end

  defp persist_evaluation(input, policy, evaluation) do
    {result, reason} =
      case evaluation do
        :permit_with_review -> {"permitted", nil}
        {:denied, denied_reason} -> {"denied", denied_reason}
      end

    input_snapshot = input_snapshot(input)
    input_digest = digest(input_snapshot)

    payload = %{
      "decision_mode" => "permit_with_review",
      "input_snapshot" => input_snapshot,
      "input_digest" => input_digest,
      "policy_artifact" => ToolEffectPolicy.dump(policy),
      "policy_source" => ToolEffectPolicy.source(policy),
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
      :permit_with_review ->
        issue_permitted(input, policy, decision_attrs)

      {:denied, denied_reason} ->
        with {:ok, decision} <-
               DurableAuthority.record_decision(input.session_ref, decision_attrs) do
          {:ok, %{result: :denied, reason: denied_reason, decision: decision}}
        end
    end
  end

  defp issue_permitted(input, policy, decision_attrs) do
    input_digest = decision_attrs.input_snapshot_hash

    scoped_grant =
      ScopedGrant.new!(%{
        contract_version: 1,
        grant_ref: input.grant_ref,
        decision_ref: input.decision_ref,
        decision_hash: decision_attrs.decision_hash,
        policy_artifact_ref: policy.artifact_ref,
        policy_version: policy.policy_version,
        input_snapshot_hash: input_digest,
        tenant_ref: input.tenant_ref,
        actor_ref: input.actor_ref,
        subject_ref: input.subject_ref,
        effect_ref: input.effect_ref,
        operation_ref: input.operation_ref,
        capability_id: input.capability_id,
        scope: scope(input, policy, input_digest),
        obligations: obligations(input),
        result: "permitted",
        issued_at: input.issued_at,
        expires_at: input.expires_at,
        status: "active"
      })

    with {:ok, %{decision: decision, grant: persisted}} <-
           DurableAuthority.issue_grant(input.session_ref, decision_attrs, scoped_grant) do
      {:ok, %{result: :permit_with_review, decision: decision, grant: persisted}}
    end
  end

  defp normalize_issue(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize_exact(attrs, @issue_fields)
    ref_fields = @issue_fields -- digest_integer_and_time_fields()

    with true <- is_map(attrs),
         true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@issue_fields),
         true <- Enum.all?(ref_fields, &present?(attrs[&1])),
         true <- digest?(attrs.workspace_root_digest),
         true <- digest?(attrs.reviewed_content_digest),
         true <- positive_integer?(attrs.credential_generation),
         true <- positive_integer?(attrs.session_generation),
         true <- is_struct(attrs.issued_at, DateTime),
         true <- is_struct(attrs.expires_at, DateTime),
         :gt <- DateTime.compare(attrs.expires_at, attrs.issued_at) do
      {:ok,
       attrs
       |> Map.update!(:issued_at, &DateTime.truncate(&1, :microsecond))
       |> Map.update!(:expires_at, &DateTime.truncate(&1, :microsecond))}
    else
      _other -> {:error, :invalid_tool_effect_authority_input}
    end
  end

  defp normalize_issue(_attrs), do: {:error, :invalid_tool_effect_authority_input}

  defp normalize_binding(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize_exact(attrs, @binding_fields)

    with true <- is_map(attrs),
         true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@binding_fields),
         true <-
           Enum.all?(
             @binding_fields --
               [
                 :policy_version,
                 :credential_generation,
                 :session_generation,
                 :input_digest,
                 :workspace_root_digest,
                 :reviewed_content_digest
               ],
             &present?(attrs[&1])
           ),
         true <- positive_integer?(attrs.policy_version),
         true <- positive_integer?(attrs.credential_generation),
         true <- positive_integer?(attrs.session_generation),
         true <- digest?(attrs.input_digest),
         true <- digest?(attrs.workspace_root_digest),
         true <- digest?(attrs.reviewed_content_digest) do
      {:ok, attrs}
    else
      _other -> {:error, :invalid_tool_effect_grant_binding}
    end
  end

  defp normalize_binding(_attrs), do: {:error, :invalid_tool_effect_grant_binding}

  defp validate_tool_grant(%ScopedGrant{} = grant) do
    with "codex.session.turn" <- grant.capability_id,
         scope when is_map(scope) <- grant.scope,
         true <- Enum.sort(Map.keys(scope)) == Enum.sort(@scope_fields),
         "codex" <- scope["provider_family"],
         "isolated_disposable_workspace" <- scope["workspace_policy"],
         "create_or_replace" <- scope["operation_class"],
         true <- scope["authority_decision_ref"] == grant.decision_ref,
         true <- scope["policy_ref"] == grant.policy_artifact_ref,
         true <- scope["policy_version"] == grant.policy_version,
         true <- scope["input_digest"] == grant.input_snapshot_hash,
         true <- digest?(scope["workspace_root_digest"]),
         true <- digest?(scope["reviewed_content_digest"]),
         true <- positive_integer?(scope["credential_generation"]),
         true <- positive_integer?(scope["session_generation"]),
         true <- exact_relative_path?(scope["relative_path"]),
         true <- exact_scope_refs?(grant, scope),
         true <- grant.obligations == obligations_from_grant(grant, scope) do
      :ok
    else
      _other -> {:error, :invalid_tool_effect_grant}
    end
  end

  defp input_snapshot(input) do
    input
    |> Map.take(@issue_fields -- [:session_ref, :decision_ref, :grant_ref])
    |> Map.update!(:issued_at, &DateTime.to_iso8601/1)
    |> Map.update!(:expires_at, &DateTime.to_iso8601/1)
  end

  defp scope(input, policy, input_digest) do
    %{
      "authority_decision_ref" => input.decision_ref,
      "input_digest" => input_digest,
      "policy_ref" => policy.artifact_ref,
      "policy_version" => policy.policy_version,
      "provider_family" => input.provider_family,
      "provider_account_ref" => input.provider_account_ref,
      "credential_lease_ref" => input.credential_lease_ref,
      "credential_generation" => input.credential_generation,
      "managed_session_ref" => input.managed_session_ref,
      "session_generation" => input.session_generation,
      "review_ref" => input.review_ref,
      "workspace_policy" => input.workspace_policy,
      "workspace_ref" => input.workspace_ref,
      "workspace_root_digest" => input.workspace_root_digest,
      "relative_path" => input.relative_path,
      "operation_class" => input.operation_class,
      "reviewed_content_digest" => input.reviewed_content_digest,
      "target_ref" => input.target_ref,
      "attempt_ref" => input.attempt_ref
    }
  end

  defp obligations(input) do
    [
      %{
        "type" => "require_authorized_review",
        "review_ref" => input.review_ref,
        "authority_decision_ref" => input.decision_ref
      },
      %{
        "type" => "enforce_pinned_generations",
        "credential_lease_ref" => input.credential_lease_ref,
        "credential_generation" => input.credential_generation,
        "managed_session_ref" => input.managed_session_ref,
        "session_generation" => input.session_generation
      },
      %{
        "type" => "verify_reviewed_file",
        "workspace_ref" => input.workspace_ref,
        "relative_path" => input.relative_path,
        "reviewed_content_digest" => input.reviewed_content_digest,
        "target_ref" => input.target_ref
      },
      %{
        "type" => "cleanup_isolated_materialization",
        "credential_lease_ref" => input.credential_lease_ref,
        "managed_session_ref" => input.managed_session_ref
      }
    ]
  end

  defp obligations_from_grant(grant, scope) do
    [
      %{
        "type" => "require_authorized_review",
        "review_ref" => scope["review_ref"],
        "authority_decision_ref" => grant.decision_ref
      },
      %{
        "type" => "enforce_pinned_generations",
        "credential_lease_ref" => scope["credential_lease_ref"],
        "credential_generation" => scope["credential_generation"],
        "managed_session_ref" => scope["managed_session_ref"],
        "session_generation" => scope["session_generation"]
      },
      %{
        "type" => "verify_reviewed_file",
        "workspace_ref" => scope["workspace_ref"],
        "relative_path" => scope["relative_path"],
        "reviewed_content_digest" => scope["reviewed_content_digest"],
        "target_ref" => scope["target_ref"]
      },
      %{
        "type" => "cleanup_isolated_materialization",
        "credential_lease_ref" => scope["credential_lease_ref"],
        "managed_session_ref" => scope["managed_session_ref"]
      }
    ]
  end

  defp exact_scope_refs?(grant, scope) do
    [
      grant.grant_ref,
      grant.decision_ref,
      grant.policy_artifact_ref,
      grant.tenant_ref,
      grant.actor_ref,
      grant.subject_ref,
      grant.effect_ref,
      grant.operation_ref,
      scope["provider_account_ref"],
      scope["credential_lease_ref"],
      scope["managed_session_ref"],
      scope["review_ref"],
      scope["workspace_ref"],
      scope["target_ref"],
      scope["attempt_ref"]
    ]
    |> Enum.all?(&exact_ref?/1)
  end

  defp scoped_expected(expected) do
    %{
      tenant_ref: expected.tenant_ref,
      actor_ref: expected.actor_ref,
      subject_ref: expected.subject_ref,
      effect_ref: expected.effect_ref,
      operation_ref: expected.operation_ref,
      capability_id: expected.capability_id,
      scope: %{
        "authority_decision_ref" => expected.decision_ref,
        "input_digest" => expected.input_digest,
        "policy_ref" => expected.policy_ref,
        "policy_version" => expected.policy_version,
        "provider_family" => expected.provider_family,
        "provider_account_ref" => expected.provider_account_ref,
        "credential_lease_ref" => expected.credential_lease_ref,
        "credential_generation" => expected.credential_generation,
        "managed_session_ref" => expected.managed_session_ref,
        "session_generation" => expected.session_generation,
        "review_ref" => expected.review_ref,
        "workspace_policy" => expected.workspace_policy,
        "workspace_ref" => expected.workspace_ref,
        "workspace_root_digest" => expected.workspace_root_digest,
        "relative_path" => expected.relative_path,
        "operation_class" => expected.operation_class,
        "reviewed_content_digest" => expected.reviewed_content_digest,
        "target_ref" => expected.target_ref,
        "attempt_ref" => expected.attempt_ref
      }
    }
  end

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

  defp digest(value) do
    canonical =
      CanonicalJson.encode_inline!(value,
        max_bytes: @max_input_bytes,
        label: "Citadel tool effect authority input"
      )

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp digest_integer_and_time_fields do
    [
      :workspace_root_digest,
      :reviewed_content_digest,
      :credential_generation,
      :session_generation,
      :issued_at,
      :expires_at
    ]
  end

  defp verification_error(grant_ref, category, reason) do
    {:error, %GrantVerificationError{grant_ref: grant_ref, category: category, reason: reason}}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp digest?(value), do: is_binary(value) and String.match?(value, ~r/\Asha256:[0-9a-f]{64}\z/)

  defp exact_ref?(value) when is_binary(value) do
    String.valid?(value) and String.printable?(value) and value == String.trim(value) and
      value != "" and byte_size(value) <= @max_ref_bytes and
      not String.contains?(value, [<<0>> | @wildcards])
  end

  defp exact_ref?(_value), do: false

  defp exact_relative_path?(path) when is_binary(path) do
    String.valid?(path) and String.printable?(path) and path == String.trim(path) and
      byte_size(path) <= @max_ref_bytes and
      not String.starts_with?(path, ["/", "~"]) and
      not String.contains?(path, ["\\", <<0>> | @wildcards]) and
      path
      |> String.split("/", trim: false)
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp exact_relative_path?(_path), do: false
end

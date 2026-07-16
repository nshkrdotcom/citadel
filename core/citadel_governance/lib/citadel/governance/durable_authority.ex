defmodule Citadel.Governance.DurableAuthority do
  @moduledoc """
  Sole durable ingress for Citadel decisions, scoped grants, and revocations.

  Decisions and grants are committed atomically. Verification locks the grant
  row before reconstruction so a concurrent revocation cannot be admitted out
  of order. Stored facts are reconstructed and revalidated against the frozen
  `Citadel.ScopedGrant` contract on every read.
  """

  import Ecto.Query

  alias Citadel.Governance.DurableSchemas.AuthorityDecision
  alias Citadel.Governance.DurableSchemas.DecisionSession
  alias Citadel.Governance.DurableSchemas.GrantRevocation
  alias Citadel.Governance.DurableSchemas.ScopedGrantRecord
  alias Citadel.Governance.Repo
  alias Citadel.Governance.SafePayload
  alias Citadel.GrantVerificationError
  alias Citadel.ScopedGrant

  @decision_fields [
    :decision_ref,
    :decision_hash,
    :input_snapshot_hash,
    :policy_artifact_ref,
    :policy_version,
    :result,
    :decision_payload,
    :decided_at
  ]

  @spec open_session(map() | keyword()) :: {:ok, DecisionSession.t()} | {:error, term()}
  def open_session(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, attrs} <- normalize_session(attrs) do
      with_store(fn ->
        case Repo.insert(DecisionSession.create_changeset(attrs)) do
          {:ok, session} -> {:ok, session}
          {:error, changeset} -> resolve_session_replay(attrs, changeset)
        end
      end)
    end
  end

  @spec record_decision(String.t(), map() | keyword()) ::
          {:ok, AuthorityDecision.t()} | {:error, term()}
  def record_decision(session_ref, decision_attrs) when is_binary(session_ref) do
    with {:ok, decision_attrs} <- normalize_decision(decision_attrs) do
      if decision_attrs.result == "permitted" do
        {:error, :permitted_decision_requires_atomic_grant}
      else
        with_store(fn ->
          transaction(fn ->
            session = lock_open_session!(session_ref)

            case Repo.get(AuthorityDecision, decision_attrs.decision_ref) do
              nil ->
                persist_decision!(session, decision_attrs)

              %AuthorityDecision{} = decision ->
                assert_decision_replay!(decision, session_ref, decision_attrs)
                decision
            end
          end)
        end)
      end
    end
  end

  @spec issue_grant(String.t(), map() | keyword(), ScopedGrant.t() | map() | keyword()) ::
          {:ok, %{decision: AuthorityDecision.t(), grant: ScopedGrant.t()}} | {:error, term()}
  def issue_grant(session_ref, decision_attrs, grant_attrs) when is_binary(session_ref) do
    with {:ok, decision_attrs} <- normalize_decision(decision_attrs),
         {:ok, grant} <- ScopedGrant.new(grant_attrs),
         :ok <- validate_issue(decision_attrs, grant) do
      with_store(fn ->
        transaction(fn ->
          session = lock_open_session!(session_ref)
          validate_session_scope!(session, grant)

          case {Repo.get(AuthorityDecision, grant.decision_ref),
                Repo.get(ScopedGrantRecord, grant.grant_ref)} do
            {nil, nil} ->
              decision = persist_decision!(session, decision_attrs)
              record = persist_grant!(grant)
              %{decision: decision, grant: reconstruct_grant!(record, decision, nil)}

            {%AuthorityDecision{} = decision, %ScopedGrantRecord{} = record} ->
              assert_decision_replay!(decision, session_ref, decision_attrs)
              reconstructed = reconstruct_grant!(record, decision, revocation_for(record))

              unless ScopedGrant.digest(reconstructed) == ScopedGrant.digest(grant) do
                Repo.rollback(:grant_identity_conflict)
              end

              %{decision: decision, grant: reconstructed}

            _partial ->
              Repo.rollback(:authority_ledger_corrupt)
          end
        end)
        |> map_issue_result()
      end)
    end
  end

  @spec fetch_grant(String.t()) :: {:ok, ScopedGrant.t()} | {:error, term()}
  def fetch_grant(grant_ref) when is_binary(grant_ref) do
    with_store(fn ->
      transaction(fn ->
        {record, decision, revocation} = load_grant_for_update!(grant_ref)
        reconstruct_grant!(record, decision, revocation)
      end)
    end)
  end

  @spec verify_grant(String.t(), map() | keyword(), DateTime.t()) ::
          :ok | {:error, GrantVerificationError.t()} | {:error, term()}
  def verify_grant(grant_ref, expected, %DateTime{} = now) when is_binary(grant_ref) do
    with_store(fn ->
      case transaction(fn ->
             {record, decision, revocation} = load_grant_for_update!(grant_ref)

             session =
               Repo.get(DecisionSession, decision.session_ref) ||
                 Repo.rollback(:authority_ledger_corrupt)

             if session.status != "open" do
               Repo.rollback(:decision_session_closed)
             end

             reconstruct_grant!(record, decision, revocation)
           end) do
        {:ok, grant} ->
          ScopedGrant.verify(grant, expected, now)

        {:error, :decision_session_closed} ->
          verification_error(grant_ref, :revoked, :decision_session_closed)

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec revoke_grant(String.t(), map() | keyword()) :: {:ok, ScopedGrant.t()} | {:error, term()}
  def revoke_grant(grant_ref, attrs) when is_binary(grant_ref) do
    with {:ok, attrs} <- normalize_revocation(attrs) do
      with_store(fn ->
        transaction(fn -> revoke_locked_grant!(grant_ref, attrs) end)
      end)
    end
  end

  @spec close_session(String.t(), pos_integer(), map() | keyword()) ::
          {:ok, DecisionSession.t()} | {:error, term()}
  def close_session(session_ref, expected_revision, attrs)
      when is_binary(session_ref) and is_integer(expected_revision) and expected_revision > 0 do
    with {:ok, close_attrs} <- normalize_close(attrs) do
      with_store(fn ->
        transaction(fn ->
          session = lock_session!(session_ref)

          cond do
            session.status != "open" ->
              Repo.rollback(:decision_session_closed)

            session.lifecycle_revision != expected_revision ->
              Repo.rollback(:stale_session_revision)

            true ->
              :ok
          end

          revoke_open_session_grants!(session_ref, close_attrs.closed_at)

          changes = %{
            status: "closed",
            lifecycle_revision: expected_revision,
            closed_at: close_attrs.closed_at,
            close_reason_ref: close_attrs.reason_ref
          }

          case Repo.update(DecisionSession.close_changeset(session, changes)) do
            {:ok, closed} -> closed
            {:error, _changeset} -> Repo.rollback(:invalid_session_close)
          end
        end)
      end)
    end
  end

  defp normalize_session(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> atomize_known([:session_ref, :tenant_ref, :subject_ref, :policy_epoch, :opened_at])

    with :ok <-
           exact_keys(attrs, [:session_ref, :tenant_ref, :subject_ref, :policy_epoch, :opened_at]),
         :ok <- present_refs(attrs, [:session_ref, :tenant_ref, :subject_ref]),
         true <- is_integer(attrs.policy_epoch) and attrs.policy_epoch > 0,
         true <- is_struct(attrs.opened_at, DateTime) do
      {:ok,
       attrs
       |> Map.put(:status, "open")
       |> Map.put(:lifecycle_revision, 1)
       |> Map.update!(:opened_at, &DateTime.truncate(&1, :microsecond))}
    else
      _other -> {:error, :invalid_decision_session}
    end
  end

  defp normalize_decision(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> Map.new() |> atomize_known(@decision_fields)

    with :ok <- exact_keys(attrs, @decision_fields),
         :ok <- present_refs(attrs, [:decision_ref, :policy_artifact_ref]),
         true <- hash?(attrs.decision_hash),
         true <- hash?(attrs.input_snapshot_hash),
         true <- is_integer(attrs.policy_version) and attrs.policy_version > 0,
         result when result in ["permitted", "denied", "review_required"] <-
           normalize_result(attrs.result),
         true <- is_struct(attrs.decided_at, DateTime),
         {:ok, payload} <- SafePayload.normalize(attrs.decision_payload) do
      {:ok,
       attrs
       |> Map.put(:result, result)
       |> Map.put(:decision_payload, payload)
       |> Map.update!(:decided_at, &DateTime.truncate(&1, :microsecond))}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_authority_decision}
    end
  end

  defp normalize_revocation(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> Map.new() |> atomize_known([:revocation_ref, :revoked_at, :reason_ref])

    with :ok <- exact_keys(attrs, [:revocation_ref, :revoked_at, :reason_ref]),
         :ok <- present_refs(attrs, [:revocation_ref, :reason_ref]),
         true <- is_struct(attrs.revoked_at, DateTime) do
      {:ok, Map.update!(attrs, :revoked_at, &DateTime.truncate(&1, :microsecond))}
    else
      _other -> {:error, :invalid_grant_revocation}
    end
  end

  defp normalize_close(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> Map.new() |> atomize_known([:closed_at, :reason_ref])

    with :ok <- exact_keys(attrs, [:closed_at, :reason_ref]),
         :ok <- present_refs(attrs, [:reason_ref]),
         true <- is_struct(attrs.closed_at, DateTime) do
      {:ok,
       %{
         closed_at: DateTime.truncate(attrs.closed_at, :microsecond),
         reason_ref: attrs.reason_ref
       }}
    else
      _other -> {:error, :invalid_session_close}
    end
  end

  defp validate_issue(decision, grant) do
    if grant.status == "active",
      do: validate_decision_grant_binding(decision, grant),
      else: {:error, :grant_must_be_issued_active}
  end

  defp validate_decision_grant_binding(decision, grant) do
    cond do
      decision.result != "permitted" ->
        {:error, :grant_requires_permitted_decision}

      decision.decision_ref != grant.decision_ref ->
        {:error, :decision_grant_mismatch}

      decision.decision_hash != grant.decision_hash ->
        {:error, :decision_grant_mismatch}

      decision.input_snapshot_hash != grant.input_snapshot_hash ->
        {:error, :decision_grant_mismatch}

      decision.policy_artifact_ref != grant.policy_artifact_ref ->
        {:error, :decision_grant_mismatch}

      decision.policy_version != grant.policy_version ->
        {:error, :decision_grant_mismatch}

      DateTime.compare(decision.decided_at, grant.issued_at) == :gt ->
        {:error, :grant_precedes_decision}

      true ->
        :ok
    end
  end

  defp validate_session_scope!(session, grant) do
    if session.tenant_ref != grant.tenant_ref or session.subject_ref != grant.subject_ref or
         session.policy_epoch != grant.policy_version do
      Repo.rollback(:decision_session_scope_mismatch)
    end
  end

  defp persist_decision!(session, attrs) do
    attrs = Map.put(attrs, :session_ref, session.session_ref)

    case Repo.insert(AuthorityDecision.changeset(attrs)) do
      {:ok, decision} -> decision
      {:error, _changeset} -> Repo.rollback(:authority_decision_conflict)
    end
  end

  defp persist_grant!(grant) do
    {:ok, payload} =
      grant
      |> ScopedGrant.dump()
      |> Map.drop([:status, :issued_at, :expires_at, :revocation_ref, :revoked_at])
      |> SafePayload.normalize()

    digest = ScopedGrant.digest(grant)

    attrs = %{
      grant_ref: grant.grant_ref,
      decision_ref: grant.decision_ref,
      tenant_ref: grant.tenant_ref,
      subject_ref: grant.subject_ref,
      issued_digest: digest,
      current_digest: digest,
      grant_payload: payload,
      status: "active",
      issued_at: DateTime.truncate(grant.issued_at, :microsecond),
      expires_at: DateTime.truncate(grant.expires_at, :microsecond),
      revision: 1
    }

    case Repo.insert(ScopedGrantRecord.issue_changeset(attrs)) do
      {:ok, record} -> record
      {:error, _changeset} -> Repo.rollback(:scoped_grant_conflict)
    end
  end

  defp revoke_locked_grant!(grant_ref, attrs) do
    {record, decision, revocation} = load_grant_for_update!(grant_ref)
    grant = reconstruct_grant!(record, decision, revocation)

    case grant.status do
      "active" -> persist_revocation!(record, grant, attrs)
      "revoked" -> assert_revocation_replay!(grant, revocation, attrs)
    end
  end

  defp persist_revocation!(record, grant, attrs) do
    case ScopedGrant.revoke(grant, attrs.revocation_ref, attrs.revoked_at) do
      {:ok, revoked} ->
        revocation_attrs = %{
          revocation_ref: attrs.revocation_ref,
          grant_ref: grant.grant_ref,
          revoked_at: attrs.revoked_at,
          reason_ref: attrs.reason_ref
        }

        case Repo.insert(GrantRevocation.changeset(revocation_attrs)) do
          {:ok, _revocation} -> :ok
          {:error, _changeset} -> Repo.rollback(:grant_revocation_conflict)
        end

        changes = %{
          current_digest: ScopedGrant.digest(revoked),
          status: "revoked",
          revocation_ref: attrs.revocation_ref,
          revoked_at: attrs.revoked_at,
          revision: record.revision
        }

        case Repo.update(ScopedGrantRecord.revoke_changeset(record, changes)) do
          {:ok, updated} ->
            reconstruct_grant!(
              updated,
              Repo.get!(AuthorityDecision, record.decision_ref),
              Repo.get!(GrantRevocation, attrs.revocation_ref)
            )

          {:error, _changeset} ->
            Repo.rollback(:grant_revocation_conflict)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp revoke_open_session_grants!(session_ref, closed_at) do
    from(g in ScopedGrantRecord,
      join: d in AuthorityDecision,
      on: d.decision_ref == g.decision_ref,
      where: d.session_ref == ^session_ref and g.status == "active",
      select: g.grant_ref,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Enum.each(fn grant_ref ->
      digest =
        :crypto.hash(:sha256, session_ref <> <<0>> <> grant_ref) |> Base.encode16(case: :lower)

      revoke_locked_grant!(grant_ref, %{
        revocation_ref: "revocation://citadel/session-close/#{digest}",
        revoked_at: closed_at,
        reason_ref: "reason://citadel/decision-session-closed"
      })
    end)
  end

  defp load_grant_for_update!(grant_ref) do
    record =
      Repo.one(from(g in ScopedGrantRecord, where: g.grant_ref == ^grant_ref, lock: "FOR UPDATE")) ||
        Repo.rollback(:grant_not_found)

    decision =
      Repo.get(AuthorityDecision, record.decision_ref) || Repo.rollback(:authority_ledger_corrupt)

    {record, decision, revocation_for(record)}
  end

  defp revocation_for(%ScopedGrantRecord{status: "active", revocation_ref: nil}), do: nil

  defp revocation_for(%ScopedGrantRecord{status: "revoked", revocation_ref: ref})
       when is_binary(ref),
       do: Repo.get(GrantRevocation, ref)

  defp revocation_for(_record), do: :invalid

  defp reconstruct_grant!(record, decision, revocation) do
    with :ok <- validate_persisted_grant_payload(record.grant_payload),
         attrs <-
           record.grant_payload
           |> Map.put("status", record.status)
           |> Map.put("issued_at", record.issued_at)
           |> Map.put("expires_at", record.expires_at)
           |> put_nullable("revocation_ref", record.revocation_ref)
           |> put_nullable("revoked_at", record.revoked_at),
         {:ok, grant} <- ScopedGrant.new(attrs),
         :ok <- validate_issued_grant(record),
         true <- grant.grant_ref == record.grant_ref,
         true <- grant.decision_ref == record.decision_ref,
         true <- grant.tenant_ref == record.tenant_ref,
         true <- grant.subject_ref == record.subject_ref,
         true <- grant.decision_hash == decision.decision_hash,
         true <- grant.input_snapshot_hash == decision.input_snapshot_hash,
         true <- grant.policy_artifact_ref == decision.policy_artifact_ref,
         true <- grant.policy_version == decision.policy_version,
         :ok <- validate_decision_grant_binding(decision, grant),
         :ok <- validate_reconstructed_session(decision, grant),
         true <- ScopedGrant.digest(grant) == record.current_digest,
         :ok <- validate_revocation_record(grant, revocation) do
      grant
    else
      _other -> Repo.rollback(:invalid_reconstructed_grant)
    end
  end

  defp validate_revocation_record(%ScopedGrant{status: "active"}, nil), do: :ok

  defp validate_revocation_record(
         %ScopedGrant{status: "revoked"} = grant,
         %GrantRevocation{} = revocation
       ) do
    if grant.revocation_ref == revocation.revocation_ref and
         grant.grant_ref == revocation.grant_ref and
         DateTime.compare(grant.revoked_at, revocation.revoked_at) == :eq and
         present_ref?(revocation.reason_ref),
       do: :ok,
       else: {:error, :invalid_revocation_record}
  end

  defp validate_revocation_record(_grant, _revocation), do: {:error, :invalid_revocation_record}

  defp validate_issued_grant(record) do
    attrs =
      record.grant_payload
      |> Map.put("status", "active")
      |> Map.put("issued_at", record.issued_at)
      |> Map.put("expires_at", record.expires_at)
      |> Map.delete("revocation_ref")
      |> Map.delete("revoked_at")

    case ScopedGrant.new(attrs) do
      {:ok, grant} ->
        if ScopedGrant.digest(grant) == record.issued_digest,
          do: :ok,
          else: {:error, :invalid_issued_grant_digest}

      {:error, _reason} ->
        {:error, :invalid_issued_grant}
    end
  end

  defp validate_persisted_grant_payload(payload) when is_map(payload) do
    lifecycle_keys = ~w(status issued_at expires_at revocation_ref revoked_at)

    if Enum.any?(lifecycle_keys, &Map.has_key?(payload, &1)),
      do: {:error, :duplicated_grant_lifecycle_fact},
      else: :ok
  end

  defp validate_persisted_grant_payload(_payload), do: {:error, :invalid_grant_payload}

  defp validate_reconstructed_session(decision, grant) do
    case Repo.get(DecisionSession, decision.session_ref) do
      %DecisionSession{} = session ->
        if session.tenant_ref == grant.tenant_ref and
             session.subject_ref == grant.subject_ref and
             session.policy_epoch == grant.policy_version,
           do: :ok,
           else: {:error, :decision_session_scope_mismatch}

      nil ->
        {:error, :decision_session_not_found}
    end
  end

  defp lock_open_session!(session_ref) do
    session = lock_session!(session_ref)
    if session.status == "open", do: session, else: Repo.rollback(:decision_session_closed)
  end

  defp lock_session!(session_ref) do
    Repo.one(from(s in DecisionSession, where: s.session_ref == ^session_ref, lock: "FOR UPDATE")) ||
      Repo.rollback(:decision_session_not_found)
  end

  defp resolve_session_replay(attrs, _changeset) do
    case Repo.get(DecisionSession, attrs.session_ref) do
      %DecisionSession{} = session ->
        expected =
          Map.take(attrs, [:session_ref, :tenant_ref, :subject_ref, :policy_epoch, :opened_at])

        actual = Map.take(session, Map.keys(expected))

        cond do
          actual != expected -> {:error, :decision_session_conflict}
          session.status != "open" -> {:error, :decision_session_closed}
          true -> {:ok, session}
        end

      nil ->
        {:error, :invalid_decision_session}
    end
  end

  defp assert_decision_replay!(decision, session_ref, attrs) do
    expected =
      attrs |> Map.put(:session_ref, session_ref) |> Map.take([:session_ref | @decision_fields])

    actual = Map.take(decision, Map.keys(expected))

    unless expected == actual, do: Repo.rollback(:authority_decision_conflict)
  end

  defp assert_revocation_replay!(grant, %GrantRevocation{} = revocation, attrs) do
    if grant.revocation_ref == attrs.revocation_ref and
         DateTime.compare(grant.revoked_at, attrs.revoked_at) == :eq and
         revocation.reason_ref == attrs.reason_ref,
       do: grant,
       else: Repo.rollback(:grant_already_revoked)
  end

  defp assert_revocation_replay!(_grant, _revocation, _attrs),
    do: Repo.rollback(:invalid_reconstructed_grant)

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_issue_result({:ok, result}), do: {:ok, result}
  defp map_issue_result({:error, reason}), do: {:error, reason}

  defp with_store(fun) do
    fun.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :authority_store_unavailable}
  catch
    :exit, _reason -> {:error, :authority_store_unavailable}
  end

  defp atomize_known(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      string_key = Atom.to_string(key)

      cond do
        Map.has_key?(acc, key) and Map.has_key?(acc, string_key) ->
          acc
          |> Map.delete(string_key)
          |> Map.put(:__duplicate_authority_field__, true)

        Map.has_key?(acc, string_key) ->
          {value, rest} = Map.pop!(acc, string_key)
          Map.put(rest, key, value)

        true ->
          acc
      end
    end)
  end

  defp exact_keys(attrs, fields) do
    if MapSet.new(Map.keys(attrs)) == MapSet.new(fields),
      do: :ok,
      else: {:error, :unexpected_authority_fields}
  end

  defp present_refs(attrs, fields) do
    if Enum.all?(fields, fn field -> attrs |> Map.get(field) |> present_ref?() end),
      do: :ok,
      else: {:error, :invalid_authority_reference}
  end

  defp present_ref?(value), do: is_binary(value) and String.trim(value) != ""

  defp hash?("sha256:" <> hash), do: hash?(hash)
  defp hash?(hash), do: is_binary(hash) and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  defp normalize_result(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_result(value), do: value

  defp put_nullable(map, key, nil), do: Map.delete(map, key)
  defp put_nullable(map, key, value), do: Map.put(map, key, value)

  defp verification_error(grant_ref, category, reason) do
    {:error, %GrantVerificationError{grant_ref: grant_ref, category: category, reason: reason}}
  end
end

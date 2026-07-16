defmodule Citadel.Governance.DurableAuthorityTest do
  use ExUnit.Case, async: false

  alias Citadel.Governance.DurableAuthority
  alias Citadel.Governance.Persistence
  alias Citadel.Governance.Repo
  alias Citadel.GrantVerificationError
  alias Citadel.ScopedGrant

  @hash String.duplicate("a", 64)
  @input_hash "sha256:" <> String.duplicate("b", 64)
  @opened_at ~U[2026-07-15 12:00:00.000000Z]
  @issued_at ~U[2026-07-15 12:01:00.000000Z]
  @expires_at ~U[2026-07-15 12:10:00.000000Z]

  setup_all do
    start_supervised!(Repo)
    migrations = Application.app_dir(:citadel_governance, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "atomically persists and reconstructs the exact decision and grant" do
    session_ref = unique_ref("session")
    grant_ref = unique_ref("grant")
    decision_ref = unique_ref("decision")

    assert {:ok, _session} = DurableAuthority.open_session(session_attrs(session_ref))

    grant = grant(grant_ref, decision_ref, session_ref)

    assert {:ok, %{grant: persisted}} =
             DurableAuthority.issue_grant(session_ref, decision_attrs(decision_ref), grant)

    assert persisted == grant
    assert {:ok, ^grant} = DurableAuthority.fetch_grant(grant_ref)
    assert :ok = DurableAuthority.verify_grant(grant_ref, expected(grant), @issued_at)
    assert :ok = Persistence.preflight()

    assert {:ok, %{grant: ^grant}} =
             DurableAuthority.issue_grant(session_ref, decision_attrs(decision_ref), grant)
  end

  test "revocation is durable, idempotent only for the exact event, and fails closed" do
    {session_ref, grant} = persist_grant!()
    revoked_at = ~U[2026-07-15 12:02:00.000000Z]

    attrs = %{
      revocation_ref: unique_ref("revocation"),
      revoked_at: revoked_at,
      reason_ref: "reason://citadel/operator-revoked"
    }

    assert {:ok, %ScopedGrant{status: "revoked"} = revoked} =
             DurableAuthority.revoke_grant(grant.grant_ref, attrs)

    assert revoked.revocation_ref == attrs.revocation_ref
    assert {:ok, ^revoked} = DurableAuthority.revoke_grant(grant.grant_ref, attrs)

    assert {:error, %GrantVerificationError{category: :revoked}} =
             DurableAuthority.verify_grant(grant.grant_ref, expected(grant), revoked_at)

    assert {:error, :grant_already_revoked} =
             DurableAuthority.revoke_grant(grant.grant_ref, %{
               attrs
               | revocation_ref: unique_ref("revocation-other")
             })

    assert {:error, :grant_already_revoked} =
             DurableAuthority.revoke_grant(grant.grant_ref, %{
               attrs
               | reason_ref: "reason://citadel/different-reason"
             })

    assert {:ok, _session} = DurableAuthority.close_session(session_ref, 1, close_attrs())
  end

  test "closing a decision session revokes every active grant" do
    {session_ref, grant} = persist_grant!()

    assert {:ok, closed} = DurableAuthority.close_session(session_ref, 1, close_attrs())
    assert closed.status == "closed"
    assert closed.lifecycle_revision == 2

    assert {:ok, %ScopedGrant{status: "revoked"}} =
             DurableAuthority.fetch_grant(grant.grant_ref)

    assert {:error, %GrantVerificationError{category: :revoked}} =
             DurableAuthority.verify_grant(
               grant.grant_ref,
               expected(grant),
               ~U[2026-07-15 12:04:00.000000Z]
             )

    assert {:error, :decision_session_closed} =
             DurableAuthority.close_session(session_ref, 2, close_attrs())

    assert {:error, :decision_session_closed} =
             DurableAuthority.open_session(session_attrs(session_ref))
  end

  test "rejects mismatched decisions, secret payloads, and expired grants" do
    session_ref = unique_ref("session")
    assert {:ok, _session} = DurableAuthority.open_session(session_attrs(session_ref))

    decision_ref = unique_ref("decision")
    grant = grant(unique_ref("grant"), decision_ref, session_ref)

    assert {:error, :decision_grant_mismatch} =
             DurableAuthority.issue_grant(
               session_ref,
               %{decision_attrs(decision_ref) | decision_hash: String.duplicate("c", 64)},
               grant
             )

    assert {:error, :decision_session_scope_mismatch} =
             DurableAuthority.issue_grant(
               session_ref,
               %{decision_attrs(decision_ref) | policy_version: 8},
               %{grant | policy_version: 8}
             )

    assert {:error, {:secret_key_forbidden, "api_key"}} =
             DurableAuthority.issue_grant(
               session_ref,
               put_in(decision_attrs(decision_ref), [:decision_payload, "api-key"], "sentinel"),
               grant
             )

    assert {:ok, %{grant: persisted}} =
             DurableAuthority.issue_grant(session_ref, decision_attrs(decision_ref), grant)

    assert {:error, %GrantVerificationError{category: :expired}} =
             DurableAuthority.verify_grant(persisted.grant_ref, expected(grant), @expires_at)

    assert {:error, :permitted_decision_requires_atomic_grant} =
             DurableAuthority.record_decision(
               session_ref,
               decision_attrs(unique_ref("decision-without-grant"))
             )
  end

  test "rejects non-durable persistence profiles" do
    assert_raise ArgumentError, ~r/requires a durable Postgres profile/, fn ->
      Persistence.child_spec(profile: :memory)
    end

    assert %{start: {Repo, :start_link, [[]]}} =
             Persistence.child_spec(profile: :integration_postgres)
  end

  test "persists denied decisions without creating an alternate permitted ingress" do
    session_ref = unique_ref("session")
    decision_ref = unique_ref("decision")
    assert {:ok, _session} = DurableAuthority.open_session(session_attrs(session_ref))

    denied = %{decision_attrs(decision_ref) | result: "denied"}

    assert {:ok, decision} = DurableAuthority.record_decision(session_ref, denied)
    assert decision.result == "denied"
    assert {:ok, ^decision} = DurableAuthority.record_decision(session_ref, denied)
  end

  test "tampered reconstructed state fails closed" do
    {_session_ref, grant} = persist_grant!()

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_scoped_grants DISABLE TRIGGER citadel_scoped_grants_restrict_update",
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE citadel_scoped_grants SET current_digest = $1 WHERE grant_ref = $2",
      ["sha256:" <> String.duplicate("f", 64), grant.grant_ref]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_scoped_grants ENABLE TRIGGER citadel_scoped_grants_restrict_update",
      []
    )

    assert {:error, :invalid_reconstructed_grant} =
             DurableAuthority.fetch_grant(grant.grant_ref)
  end

  test "duplicated lifecycle facts in persisted payload fail closed" do
    {_session_ref, grant} = persist_grant!()

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_scoped_grants DROP CONSTRAINT citadel_scoped_grants_payload_check",
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_scoped_grants DISABLE TRIGGER citadel_scoped_grants_restrict_update",
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE citadel_scoped_grants " <>
        "SET grant_payload = grant_payload || '{\"status\": \"active\"}'::jsonb " <>
        "WHERE grant_ref = $1",
      [grant.grant_ref]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_scoped_grants ENABLE TRIGGER citadel_scoped_grants_restrict_update",
      []
    )

    assert {:error, :invalid_reconstructed_grant} =
             DurableAuthority.fetch_grant(grant.grant_ref)
  end

  test "a reconstructed grant fails closed when its decision no longer permits it" do
    {_session_ref, grant} = persist_grant!()

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_authority_decisions " <>
        "DISABLE TRIGGER citadel_authority_decisions_immutable",
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE citadel_authority_decisions SET result = 'denied' WHERE decision_ref = $1",
      [grant.decision_ref]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE citadel_authority_decisions " <>
        "ENABLE TRIGGER citadel_authority_decisions_immutable",
      []
    )

    assert {:error, :invalid_reconstructed_grant} =
             DurableAuthority.fetch_grant(grant.grant_ref)
  end

  defp persist_grant! do
    session_ref = unique_ref("session")
    decision_ref = unique_ref("decision")
    grant = grant(unique_ref("grant"), decision_ref, session_ref)

    {:ok, _session} = DurableAuthority.open_session(session_attrs(session_ref))

    {:ok, %{grant: persisted}} =
      DurableAuthority.issue_grant(session_ref, decision_attrs(decision_ref), grant)

    {session_ref, persisted}
  end

  defp session_attrs(session_ref) do
    %{
      session_ref: session_ref,
      tenant_ref: "tenant://acme",
      subject_ref: subject_ref(session_ref),
      policy_epoch: 7,
      opened_at: @opened_at
    }
  end

  defp decision_attrs(decision_ref) do
    %{
      decision_ref: decision_ref,
      decision_hash: @hash,
      input_snapshot_hash: @input_hash,
      policy_artifact_ref: "artifact://citadel/policy/7",
      policy_version: 7,
      result: "permitted",
      decision_payload: %{
        "authority_packet_ref" => "authority://citadel/packet/7",
        "obligations" => [%{"type" => "record_usage"}]
      },
      decided_at: @issued_at
    }
  end

  defp grant(grant_ref, decision_ref, session_ref) do
    ScopedGrant.new!(%{
      contract_version: 1,
      grant_ref: grant_ref,
      decision_ref: decision_ref,
      decision_hash: @hash,
      policy_artifact_ref: "artifact://citadel/policy/7",
      policy_version: 7,
      input_snapshot_hash: @input_hash,
      tenant_ref: "tenant://acme",
      actor_ref: "actor://synapse/operator",
      subject_ref: subject_ref(session_ref),
      effect_ref: unique_ref("effect"),
      operation_ref: "operation://jido/governed-effect",
      capability_id: "governed.effect",
      scope: %{"target_ref" => "target://nshkr/local", "fence" => 19},
      obligations: [%{"type" => "record_usage", "required" => true}],
      result: "permitted",
      issued_at: @issued_at,
      expires_at: @expires_at,
      status: "active"
    })
  end

  defp expected(grant) do
    Map.take(grant, [
      :tenant_ref,
      :actor_ref,
      :subject_ref,
      :effect_ref,
      :operation_ref,
      :capability_id,
      :scope
    ])
  end

  defp close_attrs do
    %{
      closed_at: ~U[2026-07-15 12:03:00.000000Z],
      reason_ref: "reason://citadel/decision-session-complete"
    }
  end

  defp subject_ref(session_ref), do: "subject://#{URI.encode_www_form(session_ref)}"
  defp unique_ref(kind), do: "#{kind}://citadel/#{System.unique_integer([:positive])}"
end

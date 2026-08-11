defmodule Citadel.Governance.Repo.Migrations.CreateDurableAuthorityLedger do
  use Ecto.Migration

  def up do
    create table(:citadel_decision_sessions, primary_key: false) do
      add(:session_ref, :text, primary_key: true)
      add(:tenant_ref, :text, null: false)
      add(:subject_ref, :text, null: false)
      add(:policy_epoch, :bigint, null: false)
      add(:status, :text, null: false)
      add(:lifecycle_revision, :bigint, null: false, default: 1)
      add(:opened_at, :utc_datetime_usec, null: false)
      add(:closed_at, :utc_datetime_usec)
      add(:close_reason_ref, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:citadel_decision_sessions, [:tenant_ref, :subject_ref]))

    create(
      constraint(:citadel_decision_sessions, :citadel_decision_sessions_policy_epoch_positive,
        check: "policy_epoch > 0"
      )
    )

    create(
      constraint(:citadel_decision_sessions, :citadel_decision_sessions_lifecycle_check,
        check:
          "(status = 'open' AND closed_at IS NULL AND close_reason_ref IS NULL) OR " <>
            "(status = 'closed' AND closed_at IS NOT NULL AND close_reason_ref IS NOT NULL)"
      )
    )

    create table(:citadel_authority_decisions, primary_key: false) do
      add(:decision_ref, :text, primary_key: true)

      add(
        :session_ref,
        references(:citadel_decision_sessions,
          column: :session_ref,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      add(:decision_hash, :text, null: false)
      add(:input_snapshot_hash, :text, null: false)
      add(:policy_artifact_ref, :text, null: false)
      add(:policy_version, :bigint, null: false)
      add(:result, :text, null: false)
      add(:decision_payload, :map, null: false)
      add(:decided_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:citadel_authority_decisions, [:decision_hash]))
    create(index(:citadel_authority_decisions, [:session_ref, :decided_at]))

    create(
      constraint(:citadel_authority_decisions, :citadel_authority_decisions_result_check,
        check: "result IN ('permitted', 'denied', 'review_required')"
      )
    )

    create table(:citadel_scoped_grants, primary_key: false) do
      add(:grant_ref, :text, primary_key: true)

      add(
        :decision_ref,
        references(:citadel_authority_decisions,
          column: :decision_ref,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      add(:tenant_ref, :text, null: false)
      add(:subject_ref, :text, null: false)
      add(:issued_digest, :text, null: false)
      add(:current_digest, :text, null: false)
      add(:grant_payload, :map, null: false)
      add(:status, :text, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revocation_ref, :text)
      add(:revoked_at, :utc_datetime_usec)
      add(:revision, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:citadel_scoped_grants, [:decision_ref]))
    create(index(:citadel_scoped_grants, [:tenant_ref, :subject_ref, :status]))
    create(index(:citadel_scoped_grants, [:expires_at]))

    create(
      constraint(:citadel_scoped_grants, :citadel_scoped_grants_lifecycle_check,
        check:
          "(status = 'active' AND revocation_ref IS NULL AND revoked_at IS NULL) OR " <>
            "(status = 'revoked' AND revocation_ref IS NOT NULL AND revoked_at IS NOT NULL)"
      )
    )

    create(
      constraint(:citadel_scoped_grants, :citadel_scoped_grants_expiry_check,
        check: "expires_at > issued_at"
      )
    )

    create table(:citadel_grant_revocations, primary_key: false) do
      add(:revocation_ref, :text, primary_key: true)

      add(
        :grant_ref,
        references(:citadel_scoped_grants,
          column: :grant_ref,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      add(:revoked_at, :utc_datetime_usec, null: false)
      add(:reason_ref, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:citadel_grant_revocations, [:grant_ref]))

    execute("""
    CREATE FUNCTION citadel_reject_immutable_authority_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'Citadel authority facts are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER citadel_authority_decisions_immutable
    BEFORE UPDATE OR DELETE ON citadel_authority_decisions
    FOR EACH ROW EXECUTE FUNCTION citadel_reject_immutable_authority_mutation()
    """)

    execute("""
    CREATE TRIGGER citadel_grant_revocations_immutable
    BEFORE UPDATE OR DELETE ON citadel_grant_revocations
    FOR EACH ROW EXECUTE FUNCTION citadel_reject_immutable_authority_mutation()
    """)

    execute("""
    CREATE FUNCTION citadel_restrict_decision_session_update()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Citadel decision sessions cannot be deleted';
      END IF;

      IF OLD.session_ref IS DISTINCT FROM NEW.session_ref
         OR OLD.tenant_ref IS DISTINCT FROM NEW.tenant_ref
         OR OLD.subject_ref IS DISTINCT FROM NEW.subject_ref
         OR OLD.policy_epoch IS DISTINCT FROM NEW.policy_epoch
         OR OLD.opened_at IS DISTINCT FROM NEW.opened_at
         OR OLD.inserted_at IS DISTINCT FROM NEW.inserted_at THEN
        RAISE EXCEPTION 'Citadel decision session identity is immutable';
      END IF;

      IF OLD.status <> 'open' OR NEW.status <> 'closed'
         OR NEW.lifecycle_revision <> OLD.lifecycle_revision + 1 THEN
        RAISE EXCEPTION 'Citadel decision session permits only one open-to-closed transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER citadel_decision_sessions_restrict_mutation
    BEFORE UPDATE OR DELETE ON citadel_decision_sessions
    FOR EACH ROW EXECUTE FUNCTION citadel_restrict_decision_session_update()
    """)

    execute("""
    CREATE FUNCTION citadel_restrict_grant_update()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Citadel scoped grants cannot be deleted';
      END IF;

      IF OLD.grant_ref IS DISTINCT FROM NEW.grant_ref
         OR OLD.decision_ref IS DISTINCT FROM NEW.decision_ref
         OR OLD.tenant_ref IS DISTINCT FROM NEW.tenant_ref
         OR OLD.subject_ref IS DISTINCT FROM NEW.subject_ref
         OR OLD.issued_digest IS DISTINCT FROM NEW.issued_digest
         OR OLD.grant_payload IS DISTINCT FROM NEW.grant_payload
         OR OLD.issued_at IS DISTINCT FROM NEW.issued_at
         OR OLD.expires_at IS DISTINCT FROM NEW.expires_at
         OR OLD.inserted_at IS DISTINCT FROM NEW.inserted_at THEN
        RAISE EXCEPTION 'Citadel scoped grant identity is immutable';
      END IF;

      IF OLD.status <> 'active' OR NEW.status <> 'revoked' OR NEW.revision <> OLD.revision + 1 THEN
        RAISE EXCEPTION 'Citadel scoped grant permits only one active-to-revoked transition';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER citadel_scoped_grants_restrict_update
    BEFORE UPDATE OR DELETE ON citadel_scoped_grants
    FOR EACH ROW EXECUTE FUNCTION citadel_restrict_grant_update()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS citadel_scoped_grants_restrict_update ON citadel_scoped_grants"
    )

    execute("DROP FUNCTION IF EXISTS citadel_restrict_grant_update()")

    execute(
      "DROP TRIGGER IF EXISTS citadel_decision_sessions_restrict_mutation ON citadel_decision_sessions"
    )

    execute("DROP FUNCTION IF EXISTS citadel_restrict_decision_session_update()")

    execute(
      "DROP TRIGGER IF EXISTS citadel_grant_revocations_immutable ON citadel_grant_revocations"
    )

    execute(
      "DROP TRIGGER IF EXISTS citadel_authority_decisions_immutable ON citadel_authority_decisions"
    )

    execute("DROP FUNCTION IF EXISTS citadel_reject_immutable_authority_mutation()")
    drop(table(:citadel_grant_revocations))
    drop(table(:citadel_scoped_grants))
    drop(table(:citadel_authority_decisions))
    drop(table(:citadel_decision_sessions))
  end
end

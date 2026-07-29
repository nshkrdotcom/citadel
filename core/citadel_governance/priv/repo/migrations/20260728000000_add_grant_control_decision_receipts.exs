defmodule Citadel.Governance.Repo.Migrations.AddGrantControlDecisionReceipts do
  use Ecto.Migration

  def up do
    create table(:citadel_grant_control_receipts, primary_key: false) do
      add(:receipt_ref, :text, primary_key: true)

      add(
        :grant_ref,
        references(:citadel_scoped_grants,
          column: :grant_ref,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :authority_decision_ref,
        references(:citadel_authority_decisions,
          column: :decision_ref,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      add(:effect_ref, :text, null: false)
      add(:operation_ref, :text, null: false)
      add(:attempt_ref, :text, null: false)
      add(:boundary_ref, :text, null: false)
      add(:request_hash, :text, null: false)
      add(:grant_digest, :text, null: false)
      add(:policy_epoch, :bigint, null: false)
      add(:grant_revision, :bigint, null: false)
      add(:session_revision, :bigint, null: false)
      add(:result, :text, null: false)
      add(:reason, :text, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:grant_expires_at, :utc_datetime_usec, null: false)
      add(:deadline_at, :utc_datetime_usec, null: false)

      add(
        :revocation_ref,
        references(:citadel_grant_revocations,
          column: :revocation_ref,
          type: :text,
          on_delete: :restrict
        )
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(
        :citadel_grant_control_receipts,
        [:grant_ref, :attempt_ref, :boundary_ref],
        name: :citadel_grant_control_receipts_checkpoint_index
      )
    )

    create(index(:citadel_grant_control_receipts, [:grant_ref, :observed_at]))

    create(
      constraint(
        :citadel_grant_control_receipts,
        :citadel_grant_control_receipts_result_check,
        check: "result IN ('permitted', 'denied')"
      )
    )

    create(
      constraint(
        :citadel_grant_control_receipts,
        :citadel_grant_control_receipts_reason_check,
        check:
          "reason IN ('exact_authority_verified', 'authority_session_closed', " <>
            "'grant_revoked', 'grant_expired', 'deadline_elapsed', " <>
            "'deadline_exceeds_grant', 'exact_scope_mismatch')"
      )
    )

    create(
      constraint(
        :citadel_grant_control_receipts,
        :citadel_grant_control_receipts_decision_check,
        check:
          "(result = 'permitted' AND reason = 'exact_authority_verified' " <>
            "AND revocation_ref IS NULL) OR " <>
            "(result = 'denied' AND reason <> 'exact_authority_verified')"
      )
    )

    create(
      constraint(
        :citadel_grant_control_receipts,
        :citadel_grant_control_receipts_revision_check,
        check: "policy_epoch > 0 AND grant_revision > 0 AND session_revision > 0"
      )
    )

    execute("""
    CREATE TRIGGER citadel_grant_control_receipts_immutable
    BEFORE UPDATE OR DELETE ON citadel_grant_control_receipts
    FOR EACH ROW EXECUTE FUNCTION citadel_reject_immutable_authority_mutation()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS citadel_grant_control_receipts_immutable " <>
        "ON citadel_grant_control_receipts"
    )

    drop(table(:citadel_grant_control_receipts))
  end
end

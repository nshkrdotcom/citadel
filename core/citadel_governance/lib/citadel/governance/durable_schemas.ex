defmodule Citadel.Governance.DurableSchemas.DecisionSession do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:session_ref, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @type t :: %__MODULE__{}

  schema "citadel_decision_sessions" do
    field(:tenant_ref, :string)
    field(:subject_ref, :string)
    field(:policy_epoch, :integer)
    field(:status, :string)
    field(:lifecycle_revision, :integer)
    field(:opened_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    field(:close_reason_ref, :string)
    timestamps()
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :session_ref,
      :tenant_ref,
      :subject_ref,
      :policy_epoch,
      :status,
      :lifecycle_revision,
      :opened_at
    ])
    |> validate_required([
      :session_ref,
      :tenant_ref,
      :subject_ref,
      :policy_epoch,
      :status,
      :lifecycle_revision,
      :opened_at
    ])
    |> validate_number(:policy_epoch, greater_than: 0)
    |> validate_number(:lifecycle_revision, greater_than: 0)
    |> validate_inclusion(:status, ["open"])
    |> unique_constraint(:session_ref, name: :citadel_decision_sessions_pkey)
  end

  def close_changeset(session, attrs) do
    session
    |> cast(attrs, [:status, :lifecycle_revision, :closed_at, :close_reason_ref])
    |> validate_required([:status, :lifecycle_revision, :closed_at, :close_reason_ref])
    |> validate_inclusion(:status, ["closed"])
    |> optimistic_lock(:lifecycle_revision)
  end
end

defmodule Citadel.Governance.DurableSchemas.AuthorityDecision do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:decision_ref, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @type t :: %__MODULE__{}

  schema "citadel_authority_decisions" do
    field(:session_ref, :string)
    field(:decision_hash, :string)
    field(:input_snapshot_hash, :string)
    field(:policy_artifact_ref, :string)
    field(:policy_version, :integer)
    field(:result, :string)
    field(:decision_payload, :map)
    field(:decided_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :decision_ref,
      :session_ref,
      :decision_hash,
      :input_snapshot_hash,
      :policy_artifact_ref,
      :policy_version,
      :result,
      :decision_payload,
      :decided_at
    ])
    |> validate_required([
      :decision_ref,
      :session_ref,
      :decision_hash,
      :input_snapshot_hash,
      :policy_artifact_ref,
      :policy_version,
      :result,
      :decision_payload,
      :decided_at
    ])
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_inclusion(:result, ~w(permitted denied review_required))
    |> unique_constraint(:decision_ref, name: :citadel_authority_decisions_pkey)
    |> foreign_key_constraint(:session_ref)
  end
end

defmodule Citadel.Governance.DurableSchemas.ScopedGrantRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:grant_ref, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @type t :: %__MODULE__{}

  schema "citadel_scoped_grants" do
    field(:decision_ref, :string)
    field(:tenant_ref, :string)
    field(:subject_ref, :string)
    field(:issued_digest, :string)
    field(:current_digest, :string)
    field(:grant_payload, :map)
    field(:status, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revocation_ref, :string)
    field(:revoked_at, :utc_datetime_usec)
    field(:revision, :integer)
    timestamps()
  end

  def issue_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :grant_ref,
      :decision_ref,
      :tenant_ref,
      :subject_ref,
      :issued_digest,
      :current_digest,
      :grant_payload,
      :status,
      :issued_at,
      :expires_at,
      :revision
    ])
    |> validate_required([
      :grant_ref,
      :decision_ref,
      :tenant_ref,
      :subject_ref,
      :issued_digest,
      :current_digest,
      :grant_payload,
      :status,
      :issued_at,
      :expires_at,
      :revision
    ])
    |> validate_inclusion(:status, ["active"])
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint(:grant_ref, name: :citadel_scoped_grants_pkey)
    |> foreign_key_constraint(:decision_ref)
  end

  def revoke_changeset(grant, attrs) do
    grant
    |> cast(attrs, [:current_digest, :status, :revocation_ref, :revoked_at, :revision])
    |> validate_required([:current_digest, :status, :revocation_ref, :revoked_at, :revision])
    |> validate_inclusion(:status, ["revoked"])
    |> optimistic_lock(:revision)
  end
end

defmodule Citadel.Governance.DurableSchemas.GrantRevocation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:revocation_ref, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @type t :: %__MODULE__{}

  schema "citadel_grant_revocations" do
    field(:grant_ref, :string)
    field(:revoked_at, :utc_datetime_usec)
    field(:reason_ref, :string)
    timestamps()
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:revocation_ref, :grant_ref, :revoked_at, :reason_ref])
    |> validate_required([:revocation_ref, :grant_ref, :revoked_at, :reason_ref])
    |> unique_constraint(:revocation_ref, name: :citadel_grant_revocations_pkey)
    |> unique_constraint(:grant_ref)
    |> foreign_key_constraint(:grant_ref)
  end
end

defmodule Citadel.Governance.DurableSchemas.GrantControlDecisionReceipt do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:receipt_ref, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @type t :: %__MODULE__{}

  schema "citadel_grant_control_receipts" do
    field(:grant_ref, :string)
    field(:authority_decision_ref, :string)
    field(:effect_ref, :string)
    field(:operation_ref, :string)
    field(:attempt_ref, :string)
    field(:boundary_ref, :string)
    field(:request_hash, :string)
    field(:grant_digest, :string)
    field(:policy_epoch, :integer)
    field(:grant_revision, :integer)
    field(:session_revision, :integer)
    field(:result, :string)
    field(:reason, :string)
    field(:observed_at, :utc_datetime_usec)
    field(:grant_expires_at, :utc_datetime_usec)
    field(:deadline_at, :utc_datetime_usec)
    field(:revocation_ref, :string)
    timestamps()
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :receipt_ref,
      :grant_ref,
      :authority_decision_ref,
      :effect_ref,
      :operation_ref,
      :attempt_ref,
      :boundary_ref,
      :request_hash,
      :grant_digest,
      :policy_epoch,
      :grant_revision,
      :session_revision,
      :result,
      :reason,
      :observed_at,
      :grant_expires_at,
      :deadline_at,
      :revocation_ref
    ])
    |> validate_required([
      :receipt_ref,
      :grant_ref,
      :authority_decision_ref,
      :effect_ref,
      :operation_ref,
      :attempt_ref,
      :boundary_ref,
      :request_hash,
      :grant_digest,
      :policy_epoch,
      :grant_revision,
      :session_revision,
      :result,
      :reason,
      :observed_at,
      :grant_expires_at,
      :deadline_at
    ])
    |> validate_inclusion(:result, ~w(permitted denied))
    |> validate_number(:policy_epoch, greater_than: 0)
    |> validate_number(:grant_revision, greater_than: 0)
    |> validate_number(:session_revision, greater_than: 0)
    |> unique_constraint(:receipt_ref, name: :citadel_grant_control_receipts_pkey)
    |> unique_constraint([:grant_ref, :attempt_ref, :boundary_ref],
      name: :citadel_grant_control_receipts_checkpoint_index
    )
    |> foreign_key_constraint(:grant_ref)
  end
end

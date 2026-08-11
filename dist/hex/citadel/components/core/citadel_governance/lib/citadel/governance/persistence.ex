defmodule Citadel.Governance.Persistence do
  @moduledoc """
  Production child specification and schema preflight for Citadel authority truth.

  Citadel has one production persistence implementation: its Postgres repo. A
  memory, no-op, fixture, or caller-supplied backend is not a valid selection.
  The production host must supervise this child and run `preflight!/0` before
  advertising governed effects.
  """

  alias Citadel.Governance.Repo

  @profiles [:integration_postgres, :ops_durable]
  @migration_version 20_260_728_000_000
  @tables ~w(
    citadel_decision_sessions
    citadel_authority_decisions
    citadel_scoped_grants
    citadel_grant_revocations
    citadel_grant_control_receipts
  )
  @triggers MapSet.new([
              {"citadel_authority_decisions", "citadel_authority_decisions_immutable"},
              {"citadel_decision_sessions", "citadel_decision_sessions_restrict_mutation"},
              {"citadel_grant_control_receipts", "citadel_grant_control_receipts_immutable"},
              {"citadel_grant_revocations", "citadel_grant_revocations_immutable"},
              {"citadel_scoped_grants", "citadel_scoped_grants_restrict_update"}
            ])

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    profile = Keyword.fetch!(opts, :profile)

    unless profile in @profiles do
      raise ArgumentError,
            "Citadel governance requires a durable Postgres profile, got: #{inspect(profile)}"
    end

    Repo.child_spec(Keyword.get(opts, :repo_options, []))
  end

  @spec preflight() :: :ok | {:error, term()}
  def preflight do
    placeholders = Enum.map_join(1..length(@tables), ", ", &"$#{&1}")

    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT to_regclass(name) FROM unnest(ARRAY[#{placeholders}]) AS tables(name)",
           @tables
         ) do
      {:ok, %{rows: rows}} ->
        if Enum.all?(rows, fn [table] -> not is_nil(table) end) do
          verify_schema_version_and_triggers()
        else
          {:error, :authority_schema_missing}
        end

      {:error, _reason} ->
        {:error, :authority_store_unavailable}
    end
  end

  defp verify_schema_version_and_triggers do
    sql = """
    SELECT
      EXISTS(SELECT 1 FROM schema_migrations WHERE version = $1),
      c.relname,
      t.tgname
    FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    WHERE NOT t.tgisinternal AND t.tgname = ANY($2)
    """

    trigger_names = Enum.map(@triggers, &elem(&1, 1))

    case Ecto.Adapters.SQL.query(Repo, sql, [@migration_version, trigger_names]) do
      {:ok, %{rows: rows}} ->
        migration_present? = Enum.all?(rows, fn [present?, _table, _trigger] -> present? end)

        triggers =
          rows
          |> Enum.map(fn [_present?, table, trigger] -> {table, trigger} end)
          |> MapSet.new()

        if migration_present? and MapSet.equal?(triggers, @triggers),
          do: :ok,
          else: {:error, :authority_schema_missing}

      {:error, _reason} ->
        {:error, :authority_schema_missing}
    end
  end

  @spec preflight!() :: :ok
  def preflight! do
    case preflight() do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Citadel governance persistence preflight failed: #{inspect(reason)}"
    end
  end
end

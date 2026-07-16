defmodule Citadel.GrantVerificationError do
  @moduledoc "Bounded, secret-free scoped-grant verification error."

  @enforce_keys [:category, :reason, :grant_ref]
  defstruct [:category, :reason, :grant_ref]

  @type t :: %__MODULE__{
          category: :invalid | :expired | :revoked | :scope_mismatch,
          reason: atom(),
          grant_ref: String.t()
        }
end

defmodule Citadel.ScopedGrant do
  @moduledoc """
  Persistable authority grant for one exact model or governed tool effect.

  Citadel owns this authority fact. Provider credentials, product review state,
  and execution receipts remain opaque references owned elsewhere.
  """

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.GrantVerificationError

  @statuses ~w(active revoked)
  @results ~w(permitted)
  @max_digest_input_bytes 65_536
  @sensitive_keys MapSet.new(~w(
    access_token api_key auth_root authorization bearer_token client_secret config_root
    credential credential_material env home material password private_key raw_credential
    refresh_token secret secret_value token token_value
  ))
  @sensitive_suffixes ~w(
    _access_token _api_key _bearer_token _client_secret _credential _credential_material
    _material _password _private_key _refresh_token _secret _secret_value _token _token_value
  )
  @fields [
    :contract_version,
    :grant_ref,
    :decision_ref,
    :decision_hash,
    :policy_artifact_ref,
    :policy_version,
    :input_snapshot_hash,
    :tenant_ref,
    :actor_ref,
    :subject_ref,
    :effect_ref,
    :operation_ref,
    :capability_id,
    :scope,
    :obligations,
    :result,
    :issued_at,
    :expires_at,
    :status,
    :revocation_ref,
    :revoked_at
  ]
  @required @fields -- [:revocation_ref, :revoked_at]
  @enforce_keys @required
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = grant), do: validate(grant)

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, :invalid_scoped_grant}
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_known_fields(attrs) do
      grant = %__MODULE__{
        contract_version: value(attrs, :contract_version, 1),
        grant_ref: value(attrs, :grant_ref),
        decision_ref: value(attrs, :decision_ref),
        decision_hash: value(attrs, :decision_hash),
        policy_artifact_ref: value(attrs, :policy_artifact_ref),
        policy_version: value(attrs, :policy_version),
        input_snapshot_hash: value(attrs, :input_snapshot_hash),
        tenant_ref: value(attrs, :tenant_ref),
        actor_ref: value(attrs, :actor_ref),
        subject_ref: value(attrs, :subject_ref),
        effect_ref: value(attrs, :effect_ref),
        operation_ref: value(attrs, :operation_ref),
        capability_id: value(attrs, :capability_id),
        scope: value(attrs, :scope),
        obligations: value(attrs, :obligations, []),
        result: normalize_string(value(attrs, :result)),
        issued_at: value(attrs, :issued_at),
        expires_at: value(attrs, :expires_at),
        status: normalize_string(value(attrs, :status, "active")),
        revocation_ref: value(attrs, :revocation_ref),
        revoked_at: value(attrs, :revoked_at)
      }

      validate(grant)
    end
  end

  def new(_attrs), do: {:error, :invalid_scoped_grant}

  @spec new!(map() | keyword() | t()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, grant} -> grant
      {:error, reason} -> raise ArgumentError, "invalid scoped grant: #{inspect(reason)}"
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = grant) do
    grant
    |> Map.from_struct()
    |> Map.reject(fn {_key, nested} -> is_nil(nested) end)
  end

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = grant) do
    canonical =
      CanonicalJson.encode_inline!(dump(grant),
        max_bytes: @max_digest_input_bytes,
        label: "Citadel.ScopedGrant.v1"
      )

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  @spec verify(t(), map() | keyword(), DateTime.t()) :: :ok | {:error, GrantVerificationError.t()}
  def verify(%__MODULE__{} = grant, expected, %DateTime{} = now)
      when is_map(expected) do
    case validate(grant) do
      {:ok, _validated_grant} ->
        if valid_expected_keys?(expected),
          do: verify_valid(grant, expected, now),
          else: verification_error(grant, :invalid, :invalid_expected_scope)

      {:error, _reason} ->
        verification_error(grant, :invalid, :invalid_grant)
    end
  end

  def verify(%__MODULE__{} = grant, expected, %DateTime{} = now) when is_list(expected) do
    if Keyword.keyword?(expected),
      do: verify(grant, Map.new(expected), now),
      else: verification_error(grant, :invalid, :invalid_expected_scope)
  end

  def verify(%__MODULE__{} = grant, _expected, _now),
    do: verification_error(grant, :invalid, :invalid_verification_request)

  defp verify_valid(grant, expected, now) do
    cond do
      grant.status == "revoked" ->
        verification_error(grant, :revoked, :grant_revoked)

      DateTime.compare(grant.expires_at, now) != :gt ->
        verification_error(grant, :expired, :grant_expired)

      not exact_match?(grant, expected) ->
        verification_error(grant, :scope_mismatch, :exact_scope_mismatch)

      true ->
        :ok
    end
  end

  @spec revoke(t(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def revoke(%__MODULE__{status: "active"} = grant, revocation_ref, %DateTime{} = revoked_at)
      when is_binary(revocation_ref) and revocation_ref != "" do
    new(%{grant | status: "revoked", revocation_ref: revocation_ref, revoked_at: revoked_at})
  end

  def revoke(%__MODULE__{}, _revocation_ref, %DateTime{}),
    do: {:error, :invalid_grant_transition}

  def revoke(%__MODULE__{}, _revocation_ref, _revoked_at),
    do: {:error, :invalid_grant_transition}

  defp validate(%__MODULE__{} = grant) do
    refs = [
      grant.grant_ref,
      grant.decision_ref,
      grant.policy_artifact_ref,
      grant.tenant_ref,
      grant.actor_ref,
      grant.subject_ref,
      grant.effect_ref,
      grant.operation_ref
    ]

    with true <- grant.contract_version == 1,
         true <- Enum.all?(refs, &present_string?/1),
         true <- present_string?(grant.capability_id),
         true <- hash?(grant.decision_hash),
         true <- hash?(grant.input_snapshot_hash),
         true <- is_integer(grant.policy_version) and grant.policy_version > 0,
         true <- grant.result in @results,
         true <- grant.status in @statuses,
         true <- is_struct(grant.issued_at, DateTime),
         true <- is_struct(grant.expires_at, DateTime),
         true <- DateTime.compare(grant.expires_at, grant.issued_at) == :gt,
         :ok <- validate_safe_term(grant.scope),
         :ok <- validate_obligations(grant.obligations),
         :ok <- validate_digestable(grant),
         :ok <- validate_revocation(grant) do
      {:ok, grant}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_scoped_grant}
    end
  end

  defp validate_known_fields(attrs) do
    allowed = MapSet.new(Enum.flat_map(@fields, &[&1, Atom.to_string(&1)]))

    if Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, :invalid_scoped_grant}
  end

  defp validate_obligations(obligations) when is_list(obligations) do
    Enum.reduce_while(obligations, :ok, fn obligation, :ok ->
      case validate_safe_term(obligation) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_obligations(_obligations), do: {:error, :invalid_grant_obligations}

  defp validate_safe_term(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      with {:ok, normalized_key} <- normalize_safe_key(key),
           false <- sensitive_key?(normalized_key),
           :ok <- validate_safe_term(nested) do
        {:cont, :ok}
      else
        true -> {:halt, {:error, {:secret_key_forbidden, normalized_key(key)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_safe_term(values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate_safe_term(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_safe_term(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_safe_term(_value), do: {:error, :non_serializable_grant_value}

  defp validate_digestable(grant) do
    CanonicalJson.encode_inline!(dump(grant),
      max_bytes: @max_digest_input_bytes,
      label: "Citadel.ScopedGrant.v1"
    )

    :ok
  rescue
    _error -> {:error, :invalid_grant_digest_input}
  end

  defp sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, key) or String.starts_with?(key, "raw_") or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(key, &1))
  end

  defp normalize_safe_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_safe_key()

  defp normalize_safe_key(key) when is_binary(key) do
    if String.valid?(key) do
      normalized =
        key
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_")

      if normalized == "", do: {:error, :invalid_grant_key}, else: {:ok, normalized}
    else
      {:error, :invalid_grant_key}
    end
  end

  defp normalize_safe_key(_key), do: {:error, :invalid_grant_key}

  defp normalized_key(key) do
    case normalize_safe_key(key) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> "invalid"
    end
  end

  defp validate_revocation(%__MODULE__{status: "active", revocation_ref: nil, revoked_at: nil}),
    do: :ok

  defp validate_revocation(%__MODULE__{
         issued_at: %DateTime{} = issued_at,
         status: "revoked",
         revocation_ref: ref,
         revoked_at: %DateTime{} = revoked_at
       })
       when is_binary(ref) and ref != "" do
    if DateTime.compare(revoked_at, issued_at) in [:eq, :gt],
      do: :ok,
      else: {:error, :invalid_grant_revocation}
  end

  defp validate_revocation(_grant), do: {:error, :invalid_grant_revocation}

  defp exact_match?(grant, expected) do
    fields = [
      :tenant_ref,
      :actor_ref,
      :subject_ref,
      :effect_ref,
      :operation_ref,
      :capability_id,
      :scope
    ]

    exact_expected_fields?(expected, fields) and
      Enum.all?(fields, fn field ->
        case fetch_expected(expected, field) do
          {:ok, value} -> Map.fetch!(grant, field) == value
          :error -> false
        end
      end)
  end

  defp exact_expected_fields?(expected, fields) do
    expected_keys = expected |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    field_keys = fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    expected_keys == field_keys
  end

  defp valid_expected_keys?(expected) do
    Enum.all?(Map.keys(expected), fn
      key when is_atom(key) -> true
      key when is_binary(key) -> String.valid?(key)
      _key -> false
    end)
  end

  defp fetch_expected(expected, field) do
    case Map.fetch(expected, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(expected, Atom.to_string(field))
    end
  end

  defp verification_error(grant, category, reason) do
    grant_ref = if present_string?(grant.grant_ref), do: grant.grant_ref, else: "unavailable"

    {:error, %GrantVerificationError{category: category, reason: reason, grant_ref: grant_ref}}
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp hash?("sha256:" <> hex), do: valid_hex_hash?(hex)
  defp hash?(hex), do: valid_hex_hash?(hex)

  defp valid_hex_hash?(hex),
    do: is_binary(hex) and byte_size(hex) == 64 and String.match?(hex, ~r/\A[0-9a-f]{64}\z/)
end

defmodule Citadel.GrantEnforcementReceipt do
  @moduledoc "Receipt proving an exact scoped grant was enforced at an effect boundary."

  @results ~w(enforced denied)
  @fields [
    :receipt_ref,
    :grant_ref,
    :decision_ref,
    :effect_ref,
    :operation_ref,
    :attempt_ref,
    :boundary_ref,
    :result,
    :enforced_at
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(%__MODULE__{} = receipt), do: receipt |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, :invalid_grant_enforcement_receipt}
  end

  def new(attrs) when is_map(attrs) do
    receipt = %__MODULE__{
      receipt_ref: value(attrs, :receipt_ref),
      grant_ref: value(attrs, :grant_ref),
      decision_ref: value(attrs, :decision_ref),
      effect_ref: value(attrs, :effect_ref),
      operation_ref: value(attrs, :operation_ref),
      attempt_ref: value(attrs, :attempt_ref),
      boundary_ref: value(attrs, :boundary_ref),
      result: normalize_string(value(attrs, :result)),
      enforced_at: value(attrs, :enforced_at)
    }

    refs = Map.take(receipt, @fields -- [:result, :enforced_at]) |> Map.values()

    if known_fields?(attrs) and Enum.all?(refs, &(is_binary(&1) and String.trim(&1) != "")) and
         receipt.result in @results and is_struct(receipt.enforced_at, DateTime) do
      {:ok, receipt}
    else
      {:error, :invalid_grant_enforcement_receipt}
    end
  end

  def new(_attrs), do: {:error, :invalid_grant_enforcement_receipt}

  def new!(attrs) do
    case new(attrs) do
      {:ok, receipt} -> receipt
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp known_fields?(attrs) do
    allowed = MapSet.new(Enum.flat_map(@fields, &[&1, Atom.to_string(&1)]))
    Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end

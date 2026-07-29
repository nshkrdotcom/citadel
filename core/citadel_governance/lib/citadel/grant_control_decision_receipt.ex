defmodule Citadel.GrantControlDecisionReceipt do
  @moduledoc """
  Immutable, secret-free result of one current-authority and deadline decision.

  The receipt records hashes and opaque references only. It is evidence of the
  decision made at `observed_at`; callers must request a new decision at each
  effect checkpoint and must never treat receipt readback as fresh authority.
  """

  alias Citadel.ContractCore.CanonicalJson

  @results ~w(permitted denied)
  @reasons ~w(
    exact_authority_verified
    authority_session_closed
    grant_revoked
    grant_expired
    deadline_elapsed
    deadline_exceeds_grant
    exact_scope_mismatch
  )
  @fields [
    :contract_version,
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
  ]
  @required @fields -- [:revocation_ref]
  @enforce_keys @required
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = receipt), do: validate(receipt)

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, :invalid_grant_control_decision_receipt}
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- known_fields(attrs) do
      receipt = %__MODULE__{
        contract_version: value(attrs, :contract_version, 1),
        receipt_ref: value(attrs, :receipt_ref),
        grant_ref: value(attrs, :grant_ref),
        authority_decision_ref: value(attrs, :authority_decision_ref),
        effect_ref: value(attrs, :effect_ref),
        operation_ref: value(attrs, :operation_ref),
        attempt_ref: value(attrs, :attempt_ref),
        boundary_ref: value(attrs, :boundary_ref),
        request_hash: value(attrs, :request_hash),
        grant_digest: value(attrs, :grant_digest),
        policy_epoch: value(attrs, :policy_epoch),
        grant_revision: value(attrs, :grant_revision),
        session_revision: value(attrs, :session_revision),
        result: normalize_string(value(attrs, :result)),
        reason: normalize_string(value(attrs, :reason)),
        observed_at: value(attrs, :observed_at),
        grant_expires_at: value(attrs, :grant_expires_at),
        deadline_at: value(attrs, :deadline_at),
        revocation_ref: value(attrs, :revocation_ref)
      }

      validate(receipt)
    end
  end

  def new(_attrs), do: {:error, :invalid_grant_control_decision_receipt}

  @spec new!(map() | keyword() | t()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, receipt} -> receipt
      {:error, reason} -> raise ArgumentError, "invalid grant control receipt: #{inspect(reason)}"
    end
  end

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = receipt) do
    canonical =
      receipt
      |> Map.from_struct()
      |> Map.reject(fn {_key, nested} -> is_nil(nested) end)
      |> CanonicalJson.encode_inline!(
        max_bytes: 16_384,
        label: "Citadel.GrantControlDecisionReceipt.v1"
      )

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp validate(%__MODULE__{} = receipt) do
    refs =
      receipt
      |> Map.take([
        :receipt_ref,
        :grant_ref,
        :authority_decision_ref,
        :effect_ref,
        :operation_ref,
        :attempt_ref,
        :boundary_ref
      ])
      |> Map.values()

    with true <- receipt.contract_version == 1,
         true <- Enum.all?(refs, &present_ref?/1),
         true <- hash?(receipt.request_hash),
         true <- hash?(receipt.grant_digest),
         true <- positive_integer?(receipt.policy_epoch),
         true <- positive_integer?(receipt.grant_revision),
         true <- positive_integer?(receipt.session_revision),
         true <- receipt.result in @results,
         true <- receipt.reason in @reasons,
         true <- is_struct(receipt.observed_at, DateTime),
         true <- is_struct(receipt.grant_expires_at, DateTime),
         true <- is_struct(receipt.deadline_at, DateTime),
         true <- is_nil(receipt.revocation_ref) or present_ref?(receipt.revocation_ref),
         :ok <- validate_result_reason(receipt) do
      {:ok, receipt}
    else
      _other -> {:error, :invalid_grant_control_decision_receipt}
    end
  end

  defp validate_result_reason(%__MODULE__{
         result: "permitted",
         reason: "exact_authority_verified",
         revocation_ref: nil
       }),
       do: :ok

  defp validate_result_reason(%__MODULE__{
         result: "denied",
         reason: reason,
         revocation_ref: revocation_ref
       })
       when reason in ["authority_session_closed", "grant_revoked"] and
              is_binary(revocation_ref) and revocation_ref != "",
       do: :ok

  defp validate_result_reason(%__MODULE__{
         result: "denied",
         reason: reason,
         revocation_ref: nil
       })
       when reason in [
              "grant_expired",
              "deadline_elapsed",
              "deadline_exceeds_grant",
              "exact_scope_mismatch"
            ],
       do: :ok

  defp validate_result_reason(_receipt), do: {:error, :invalid_result_reason}

  defp known_fields(attrs) do
    allowed = MapSet.new(Enum.flat_map(@fields, &[&1, Atom.to_string(&1)]))

    if Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, :invalid_grant_control_decision_receipt}
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp present_ref?(value), do: is_binary(value) and String.trim(value) != ""
  defp hash?("sha256:" <> hash), do: hash?(hash)
  defp hash?(hash), do: is_binary(hash) and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
end

defmodule Citadel.NativeAuthAssertion do
  @moduledoc """
  Ref-only native auth assertion contract.
  """

  @provider_families [
    "amp",
    "claude",
    "codex",
    "gemini",
    "graphql",
    "http",
    "inference",
    "realtime"
  ]
  @auth_source_kinds [
    :api_token_file,
    :app_server_login,
    :mcp_oauth_state,
    :native_cli_login,
    :oauth_token_store,
    :service_identity
  ]
  @path_classes [
    :materialized_config_root,
    :none,
    :redacted_private_path,
    :sandbox_relative,
    :target_bound
  ]
  @redaction_classes [
    :native_auth_metadata,
    :provider_account_metadata,
    :redacted_path_metadata,
    :target_bound_metadata
  ]

  @required_fields [
    :assertion_ref,
    :provider_family,
    :provider_account_ref,
    :native_subject_ref,
    :account_fingerprint,
    :auth_source_kind,
    :token_file_path_class,
    :cli_config_home_class,
    :selected_profile,
    :target_ref,
    :target_binding_ref,
    :issued_by_ref,
    :validated_at,
    :revocation_epoch,
    :redaction_class,
    :proof_hash,
    :evidence_ref
  ]

  @forbidden_fields [
    :api_key,
    :auth_json,
    :home_path,
    :oauth_refresh_token,
    :private_key,
    :provider_payload,
    :raw_token,
    :refresh_token,
    :secret,
    :token_path
  ]

  @enforce_keys @required_fields
  defstruct @required_fields ++ [expires_at: nil, metadata: %{}]

  @type t :: %__MODULE__{
          assertion_ref: String.t(),
          provider_family: String.t(),
          provider_account_ref: String.t(),
          native_subject_ref: String.t(),
          account_fingerprint: String.t(),
          auth_source_kind: atom(),
          token_file_path_class: atom(),
          cli_config_home_class: atom(),
          selected_profile: String.t(),
          target_ref: String.t(),
          target_binding_ref: String.t(),
          issued_by_ref: String.t(),
          validated_at: DateTime.t() | String.t(),
          expires_at: DateTime.t() | String.t() | nil,
          revocation_epoch: non_neg_integer(),
          redaction_class: atom(),
          proof_hash: String.t(),
          evidence_ref: String.t(),
          metadata: map()
        }

  @spec provider_families() :: [String.t()]
  def provider_families, do: @provider_families

  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @spec forbidden_fields() :: [atom()]
  def forbidden_fields, do: @forbidden_fields

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_forbidden(attrs),
         :ok <- require_fields(attrs),
         {:ok, provider_family} <- provider_family(Map.get(attrs, :provider_family)),
         {:ok, auth_source_kind} <- enum_value(attrs, :auth_source_kind, @auth_source_kinds),
         {:ok, token_file_path_class} <-
           enum_value(attrs, :token_file_path_class, @path_classes),
         {:ok, cli_config_home_class} <- enum_value(attrs, :cli_config_home_class, @path_classes),
         {:ok, redaction_class} <- enum_value(attrs, :redaction_class, @redaction_classes),
         {:ok, revocation_epoch} <- revocation_epoch(Map.get(attrs, :revocation_epoch)) do
      {:ok,
       %__MODULE__{
         assertion_ref: string!(attrs, :assertion_ref),
         provider_family: provider_family,
         provider_account_ref: string!(attrs, :provider_account_ref),
         native_subject_ref: string!(attrs, :native_subject_ref),
         account_fingerprint: string!(attrs, :account_fingerprint),
         auth_source_kind: auth_source_kind,
         token_file_path_class: token_file_path_class,
         cli_config_home_class: cli_config_home_class,
         selected_profile: string!(attrs, :selected_profile),
         target_ref: string!(attrs, :target_ref),
         target_binding_ref: string!(attrs, :target_binding_ref),
         issued_by_ref: string!(attrs, :issued_by_ref),
         validated_at: timestamp!(attrs, :validated_at),
         expires_at: optional_timestamp(attrs, :expires_at),
         revocation_epoch: revocation_epoch,
         redaction_class: redaction_class,
         proof_hash: string!(attrs, :proof_hash),
         evidence_ref: string!(attrs, :evidence_ref),
         metadata: safe_metadata(Map.get(attrs, :metadata, %{}))
       }}
    end
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, assertion} -> assertion
      {:error, error} -> raise error
    end
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = assertion) do
    %{
      assertion_ref: assertion.assertion_ref,
      provider_family: assertion.provider_family,
      provider_account_ref: assertion.provider_account_ref,
      native_subject_ref: assertion.native_subject_ref,
      account_fingerprint: assertion.account_fingerprint,
      auth_source_kind: assertion.auth_source_kind,
      token_file_path_class: assertion.token_file_path_class,
      cli_config_home_class: assertion.cli_config_home_class,
      selected_profile: assertion.selected_profile,
      target_ref: assertion.target_ref,
      target_binding_ref: assertion.target_binding_ref,
      issued_by_ref: assertion.issued_by_ref,
      validated_at: assertion.validated_at,
      expires_at: assertion.expires_at,
      revocation_epoch: assertion.revocation_epoch,
      redaction_class: assertion.redaction_class,
      proof_hash: assertion.proof_hash,
      evidence_ref: assertion.evidence_ref,
      metadata: assertion.metadata
    }
  end

  @spec secret_material?(term()) :: boolean()
  def secret_material?(attrs) when is_map(attrs) or is_list(attrs) do
    attrs
    |> normalize()
    |> forbidden_hits()
    |> Enum.empty?()
    |> Kernel.not()
  end

  def secret_material?(_attrs), do: false

  defp normalize(attrs) when is_map(attrs), do: attrs
  defp normalize(attrs) when is_list(attrs), do: Map.new(attrs)

  defp reject_forbidden(attrs) do
    case forbidden_hits(attrs) do
      [] ->
        :ok

      fields ->
        {:error,
         ArgumentError.exception(
           "native auth assertion rejects secret fields: #{join_fields(fields)}"
         )}
    end
  end

  defp forbidden_hits(attrs) when is_map(attrs) do
    direct_hits =
      @forbidden_fields
      |> Enum.filter(fn field -> has_field?(attrs, field) end)

    metadata_hits =
      attrs
      |> Map.get(:metadata, %{})
      |> metadata_forbidden_hits()

    Enum.uniq(direct_hits ++ metadata_hits)
  end

  defp metadata_forbidden_hits(metadata) when is_map(metadata) do
    @forbidden_fields
    |> Enum.filter(fn field -> has_field?(metadata, field) end)
  end

  defp metadata_forbidden_hits(_metadata), do: []

  defp require_fields(attrs) do
    missing =
      @required_fields
      |> Enum.reject(fn field -> present?(field_value(attrs, field)) end)

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         ArgumentError.exception("native auth assertion missing refs: #{join_fields(fields)}")}
    end
  end

  defp provider_family(value) when value in @provider_families, do: {:ok, value}

  defp provider_family(value) do
    {:error,
     ArgumentError.exception("unsupported native auth provider family: #{inspect(value)}")}
  end

  defp enum_value(attrs, field, allowed) do
    value = field_value(attrs, field)

    if value in allowed do
      {:ok, value}
    else
      {:error,
       ArgumentError.exception(
         "#{field} must be one of #{join_atoms(allowed)}, got: #{inspect(value)}"
       )}
    end
  end

  defp revocation_epoch(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp revocation_epoch(value) do
    {:error,
     ArgumentError.exception(
       "revocation_epoch must be a non-negative integer, got: #{inspect(value)}"
     )}
  end

  defp safe_metadata(metadata) when is_map(metadata), do: metadata
  defp safe_metadata(_metadata), do: %{}

  defp string!(attrs, field) do
    case field_value(attrs, field) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "#{field} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp timestamp!(attrs, field) do
    value = field_value(attrs, field)

    cond do
      match?(%DateTime{}, value) -> value
      is_binary(value) and value != "" -> value
      true -> raise ArgumentError, "#{field} must be a timestamp, got: #{inspect(value)}"
    end
  end

  defp optional_timestamp(attrs, field) do
    value = field_value(attrs, field)

    cond do
      is_nil(value) -> nil
      match?(%DateTime{}, value) -> value
      is_binary(value) and value != "" -> value
      true -> raise ArgumentError, "#{field} must be a timestamp, got: #{inspect(value)}"
    end
  end

  defp field_value(attrs, field) do
    Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
  end

  defp has_field?(attrs, field) do
    Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
  end

  defp present?(value), do: not empty?(value)

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(value) when is_map(value), do: map_size(value) == 0
  defp empty?(_value), do: false

  defp join_fields(fields) do
    fields
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end

  defp join_atoms(atoms) do
    atoms
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end
end

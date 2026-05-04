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

  @required_fields [
    :assertion_ref,
    :provider_family,
    :provider_account_ref,
    :native_subject_ref,
    :target_ref,
    :issued_by_ref,
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
  defstruct @required_fields ++ [metadata: %{}]

  @type t :: %__MODULE__{
          assertion_ref: String.t(),
          provider_family: String.t(),
          provider_account_ref: String.t(),
          native_subject_ref: String.t(),
          target_ref: String.t(),
          issued_by_ref: String.t(),
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
         {:ok, provider_family} <- provider_family(Map.get(attrs, :provider_family)) do
      {:ok,
       %__MODULE__{
         assertion_ref: string!(attrs, :assertion_ref),
         provider_family: provider_family,
         provider_account_ref: string!(attrs, :provider_account_ref),
         native_subject_ref: string!(attrs, :native_subject_ref),
         target_ref: string!(attrs, :target_ref),
         issued_by_ref: string!(attrs, :issued_by_ref),
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
      target_ref: assertion.target_ref,
      issued_by_ref: assertion.issued_by_ref,
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

  defp safe_metadata(metadata) when is_map(metadata), do: metadata
  defp safe_metadata(_metadata), do: %{}

  defp string!(attrs, field) do
    case field_value(attrs, field) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "#{field} must be a non-empty string, got: #{inspect(value)}"
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
end

defmodule Citadel.Governance.SafePayload do
  @moduledoc false

  alias Citadel.ContractCore.CanonicalJson

  @max_bytes 1_000_000
  @sensitive_keys MapSet.new(~w(
    access_token api_key auth authorization bearer_token client_secret credential
    credential_material database_url password private_key raw_credential refresh_token
    secret secret_value signed_url token token_value
  ))
  @sensitive_suffixes ~w(
    _access_token _api_key _bearer_token _client_secret _credential _credential_material
    _database_url _password _private_key _refresh_token _secret _secret_value _signed_url
    _token _token_value
  )

  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(value) when is_map(value) do
    with {:ok, normalized} <- normalize_value(value),
         :ok <- bounded(normalized) do
      {:ok, normalized}
    end
  end

  def normalize(_value), do: {:error, :invalid_decision_payload}

  defp normalize_value(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp normalize_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key),
           false <- sensitive_key?(key),
           {:ok, nested} <- normalize_value(nested) do
        {:cont, {:ok, Map.put(acc, key, nested)}}
      else
        true -> {:halt, {:error, {:secret_key_forbidden, normalized_key(key)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_value(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp normalize_value(value) when is_boolean(value) or is_nil(value), do: {:ok, value}
  defp normalize_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_value(value)
       when is_binary(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp normalize_value(_value), do: {:error, :non_serializable_decision_payload}

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    if String.valid?(key) and String.trim(key) != "",
      do: {:ok, key},
      else: {:error, :invalid_decision_payload_key}
  end

  defp normalize_key(_key), do: {:error, :invalid_decision_payload_key}

  defp sensitive_key?(key) do
    normalized = normalized_key(key)

    MapSet.member?(@sensitive_keys, normalized) or String.starts_with?(normalized, "raw_") or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(normalized, &1))
  end

  defp normalized_key(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp bounded(payload) do
    CanonicalJson.encode_inline!(payload,
      max_bytes: @max_bytes,
      label: "Citadel durable authority payload"
    )

    :ok
  rescue
    _error -> {:error, :decision_payload_too_large}
  end
end

defmodule Citadel.ConnectorBinding do
  @moduledoc """
  Ref-only connector binding identity model.
  """

  alias Citadel.AuthorityContract.PersistencePosture

  @provider_families [
    "amp",
    "claude",
    "cli",
    "codex",
    "gemini",
    "github",
    "graphql",
    "http",
    "inference",
    "linear",
    "notion",
    "realtime"
  ]

  @provider_account_statuses [
    :known,
    :asserted,
    :unknown,
    :unavailable,
    :revoked,
    :rotated
  ]

  @lifecycles [
    :installed,
    :configured,
    :validated,
    :active,
    :suspended,
    :revoked,
    :rotated,
    :deleted
  ]

  @required_refs [
    :tenant_ref,
    :policy_revision_ref,
    :provider_ref,
    :provider_family,
    :provider_account_ref,
    :provider_account_status,
    :connector_instance_ref,
    :connector_binding_ref,
    :credential_handle_ref,
    :target_ref,
    :attach_grant_ref,
    :operation_policy_ref,
    :evidence_ref,
    :redaction_ref
  ]

  @optional_refs [:credential_lease_ref]

  @forbidden_material [
    :api_key,
    :auth_json,
    :authorization_header,
    :default_client,
    :env,
    :home_path,
    :native_auth_file,
    :provider_payload,
    :raw_secret,
    :raw_token,
    :refresh_token,
    :singleton_client,
    :target_credentials,
    :token,
    :token_file
  ]

  @ref_prefixes %{
    tenant_ref: "tenant://",
    policy_revision_ref: "policy-revision://",
    provider_ref: "provider://",
    provider_account_ref: "provider-account://",
    connector_instance_ref: "connector-instance://",
    connector_binding_ref: "connector-binding://",
    credential_handle_ref: "credential-handle://",
    credential_lease_ref: "credential-lease://",
    target_ref: "target://",
    attach_grant_ref: "attach-grant://",
    operation_policy_ref: "operation-policy://",
    evidence_ref: "evidence://",
    redaction_ref: "redaction://"
  }

  defmodule Binding do
    @moduledoc false

    @binding_fields [
      :tenant_ref,
      :policy_revision_ref,
      :provider_ref,
      :provider_family,
      :provider_account_ref,
      :provider_account_status,
      :connector_instance_ref,
      :connector_binding_ref,
      :credential_handle_ref,
      :target_ref,
      :attach_grant_ref,
      :operation_policy_ref,
      :evidence_ref,
      :redaction_ref
    ]

    @enforce_keys @binding_fields
    defstruct @binding_fields ++
                [
                  :credential_lease_ref,
                  lifecycle: :installed,
                  persistence_posture: nil,
                  metadata: %{},
                  binding_schema: "Citadel.ConnectorBinding.v1"
                ]
  end

  @type binding :: %Binding{}

  @spec provider_families() :: [String.t()]
  def provider_families, do: @provider_families

  @spec provider_account_statuses() :: [atom()]
  def provider_account_statuses, do: @provider_account_statuses

  @spec lifecycles() :: [atom()]
  def lifecycles, do: @lifecycles

  @spec required_refs() :: [atom()]
  def required_refs, do: @required_refs

  @spec forbidden_material() :: [atom()]
  def forbidden_material, do: @forbidden_material

  @spec bind(map() | keyword()) :: {:ok, binding()} | {:error, term()}
  def bind(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <- require_refs(attrs, @required_refs),
         :ok <- validate_provider_family(attrs),
         {:ok, status} <- enum_value(attrs, :provider_account_status, @provider_account_statuses),
         {:ok, lifecycle} <- enum_value(attrs, :lifecycle, @lifecycles, :installed),
         :ok <- validate_distinct_identity_refs(attrs),
         :ok <- validate_ref_families(attrs, @required_refs ++ @optional_refs) do
      {:ok,
       %Binding{
         tenant_ref: value!(attrs, :tenant_ref),
         policy_revision_ref: value!(attrs, :policy_revision_ref),
         provider_ref: value!(attrs, :provider_ref),
         provider_family: value!(attrs, :provider_family),
         provider_account_ref: value!(attrs, :provider_account_ref),
         provider_account_status: status,
         connector_instance_ref: value!(attrs, :connector_instance_ref),
         connector_binding_ref: value!(attrs, :connector_binding_ref),
         credential_handle_ref: value!(attrs, :credential_handle_ref),
         credential_lease_ref: optional_value(attrs, :credential_lease_ref),
         target_ref: value!(attrs, :target_ref),
         attach_grant_ref: value!(attrs, :attach_grant_ref),
         operation_policy_ref: value!(attrs, :operation_policy_ref),
         evidence_ref: value!(attrs, :evidence_ref),
         redaction_ref: value!(attrs, :redaction_ref),
         lifecycle: lifecycle,
         persistence_posture: PersistencePosture.from_attrs(:connector_binding_refs, attrs),
         metadata: safe_metadata(field_value(attrs, :metadata))
       }}
    end
  end

  @spec transition(binding(), atom() | String.t()) :: {:ok, binding()} | {:error, term()}
  def transition(%Binding{} = binding, lifecycle) do
    case enum_atom(lifecycle, @lifecycles) do
      {:ok, value} -> {:ok, %{binding | lifecycle: value}}
      :error -> {:error, {:invalid_binding_lifecycle, lifecycle}}
    end
  end

  @spec identity_key(binding()) :: map()
  def identity_key(%Binding{} = binding) do
    %{
      tenant_ref: binding.tenant_ref,
      policy_revision_ref: binding.policy_revision_ref,
      provider_ref: binding.provider_ref,
      provider_account_ref: binding.provider_account_ref,
      connector_instance_ref: binding.connector_instance_ref,
      credential_handle_ref: binding.credential_handle_ref,
      target_ref: binding.target_ref,
      operation_policy_ref: binding.operation_policy_ref
    }
  end

  @spec same_identity_scope?(binding(), binding()) :: boolean()
  def same_identity_scope?(%Binding{} = left, %Binding{} = right) do
    identity_key(left) == identity_key(right)
  end

  @spec redacted_evidence(binding()) :: map()
  def redacted_evidence(%Binding{} = binding) do
    %{
      binding_schema: binding.binding_schema,
      tenant_ref: binding.tenant_ref,
      provider_ref: binding.provider_ref,
      provider_family: binding.provider_family,
      provider_account_ref: binding.provider_account_ref,
      provider_account_status: binding.provider_account_status,
      connector_instance_ref: binding.connector_instance_ref,
      connector_binding_ref: binding.connector_binding_ref,
      credential_handle_ref: binding.credential_handle_ref,
      credential_lease_ref: binding.credential_lease_ref,
      target_ref: binding.target_ref,
      attach_grant_ref: binding.attach_grant_ref,
      operation_policy_ref: binding.operation_policy_ref,
      policy_revision_ref: binding.policy_revision_ref,
      evidence_ref: binding.evidence_ref,
      redaction_ref: binding.redaction_ref,
      lifecycle: binding.lifecycle,
      persistence_posture: binding.persistence_posture,
      raw_material_present?: false
    }
  end

  @spec authorize_lease(binding(), map() | keyword()) :: :ok | {:error, term()}
  def authorize_lease(%Binding{} = binding, attrs) when is_map(attrs) or is_list(attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <- require_refs(attrs, lease_scope_fields()),
         :ok <- validate_ref_families(attrs, lease_scope_fields()) do
      mismatches =
        lease_scope_fields()
        |> Enum.reject(fn field ->
          Map.fetch!(Map.from_struct(binding), field) == field_value(attrs, field)
        end)

      case mismatches do
        [] -> :ok
        fields -> {:error, {:lease_scope_mismatch, fields}}
      end
    end
  end

  defp normalize(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize()

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(
      @required_refs ++
        @optional_refs ++ @forbidden_material ++ [:lifecycle, :persistence_posture, :metadata],
      key,
      fn
        candidate -> Atom.to_string(candidate) == key
      end
    )
  end

  defp reject_material(attrs) do
    direct_hits = Enum.filter(@forbidden_material, &Map.has_key?(attrs, &1))

    metadata_hits =
      attrs
      |> field_value(:metadata)
      |> metadata_forbidden_hits()

    case Enum.uniq(direct_hits ++ metadata_hits) do
      [] -> :ok
      fields -> {:error, {:raw_material_rejected, fields}}
    end
  end

  defp metadata_forbidden_hits(metadata) when is_map(metadata) do
    Enum.filter(@forbidden_material, &Map.has_key?(metadata, &1))
  end

  defp metadata_forbidden_hits(_metadata), do: []

  defp require_refs(attrs, fields) do
    case Enum.reject(fields, &present?(field_value(attrs, &1))) do
      [] -> :ok
      missing -> {:error, {:missing_required_refs, missing}}
    end
  end

  defp validate_provider_family(attrs) do
    value = field_value(attrs, :provider_family)

    if value in @provider_families do
      :ok
    else
      {:error, {:unsupported_provider_family, value}}
    end
  end

  defp enum_value(attrs, field, allowed) do
    case enum_atom(field_value(attrs, field), allowed) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_enum_value, field, field_value(attrs, field), allowed}}
    end
  end

  defp enum_value(attrs, field, allowed, default) do
    case field_value(attrs, field) do
      nil -> {:ok, default}
      _value -> enum_value(attrs, field, allowed)
    end
  end

  defp enum_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp enum_atom(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp enum_atom(_value, _allowed), do: :error

  defp validate_ref_families(attrs, fields) do
    bad =
      fields
      |> Enum.filter(fn field ->
        case Map.fetch(@ref_prefixes, field) do
          {:ok, prefix} ->
            value = field_value(attrs, field)
            present?(value) and not String.starts_with?(value, prefix)

          :error ->
            false
        end
      end)

    case bad do
      [] -> :ok
      fields -> {:error, {:ref_family_mismatch, fields}}
    end
  end

  defp validate_distinct_identity_refs(attrs) do
    comparisons = [
      {:connector_instance_ref, :provider_account_ref},
      {:connector_instance_ref, :credential_handle_ref},
      {:connector_instance_ref, :connector_binding_ref},
      {:provider_account_ref, :credential_handle_ref},
      {:target_ref, :provider_account_ref},
      {:attach_grant_ref, :target_ref}
    ]

    conflicts =
      Enum.filter(comparisons, fn {left, right} ->
        field_value(attrs, left) == field_value(attrs, right)
      end)

    case conflicts do
      [] -> :ok
      pairs -> {:error, {:ref_conflation_rejected, pairs}}
    end
  end

  defp value!(attrs, field) do
    case field_value(attrs, field) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> value
      value -> raise ArgumentError, "#{field} must be present, got: #{inspect(value)}"
    end
  end

  defp optional_value(attrs, field) do
    case field_value(attrs, field) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp field_value(attrs, field),
    do: Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

  defp safe_metadata(metadata) when is_map(metadata), do: metadata
  defp safe_metadata(_metadata), do: %{}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp lease_scope_fields do
    [
      :tenant_ref,
      :policy_revision_ref,
      :provider_account_ref,
      :connector_instance_ref,
      :connector_binding_ref,
      :credential_handle_ref,
      :credential_lease_ref,
      :target_ref,
      :attach_grant_ref,
      :operation_policy_ref
    ]
  end
end

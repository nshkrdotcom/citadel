defmodule Citadel.ProviderAuthFabric do
  @moduledoc """
  Contract-level provider auth fabric.
  """

  alias Citadel.NativeAuthAssertion

  @provider_families [
    "amp",
    "claude",
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

  @operation_classes ["cli", "http", "graphql", "realtime", "inference"]

  @authority_required_refs [
    :authority_packet_ref,
    :system_actor_ref,
    :system_authorization_ref,
    :provider_family,
    :provider_account_ref,
    :connector_instance_ref,
    :credential_handle_ref,
    :credential_lease_ref,
    :operation_policy_ref,
    :target_ref,
    :attach_grant_ref,
    :policy_revision_ref,
    :redaction_ref
  ]

  @forbidden_material [
    :api_key,
    :auth_json,
    :default_client,
    :env,
    :home_path,
    :native_login,
    :private_key,
    :provider_payload,
    :raw_secret,
    :raw_token,
    :singleton_client,
    :token_file
  ]

  @ref_prefixes %{
    system_actor_ref: "system-actor://",
    system_authorization_ref: "system-authority://",
    provider_account_ref: "provider-account://",
    connector_instance_ref: "connector-instance://",
    credential_handle_ref: "credential-handle://",
    credential_lease_ref: "credential-lease://",
    operation_policy_ref: "operation-policy://",
    target_ref: "target://",
    attach_grant_ref: "attach-grant://",
    authority_packet_ref: "authority-packet://",
    policy_revision_ref: "policy-revision://",
    redaction_ref: "redaction://",
    native_auth_assertion_ref: "native-auth-assertion://",
    tenant_ref: "tenant://",
    subject_ref: "subject://",
    target_grant_revision: "target-grant-revision://",
    fence_token: "fence://",
    revocation_ref: "revocation://",
    cleanup_ref: "cleanup://"
  }

  defmodule Registration do
    @moduledoc false
    @enforce_keys [
      :registration_ref,
      :system_actor_ref,
      :system_authorization_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :operation_policy_ref,
      :target_ref,
      :redaction_ref
    ]
    defstruct @enforce_keys ++ [native_auth_assertion_ref: nil, metadata: %{}]
  end

  defmodule CredentialHandle do
    @moduledoc false
    @enforce_keys [
      :credential_handle_ref,
      :registration_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :operation_policy_ref,
      :redaction_ref
    ]
    defstruct @enforce_keys ++ [status: :active, metadata: %{}]
  end

  defmodule CredentialLease do
    @moduledoc false
    @enforce_keys [
      :credential_lease_ref,
      :credential_handle_ref,
      :tenant_ref,
      :subject_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :operation_class,
      :target_ref,
      :attach_grant_ref,
      :operation_policy_ref,
      :authority_packet_ref,
      :policy_revision_ref,
      :target_grant_revision,
      :rotation_epoch,
      :fence_token,
      :expires_at
    ]
    defstruct @enforce_keys ++ [renewed_from_lease_ref: nil, status: :issued, metadata: %{}]
  end

  @spec provider_families() :: [String.t()]
  def provider_families, do: @provider_families

  @spec authority_required_refs() :: [atom()]
  def authority_required_refs, do: @authority_required_refs

  @spec register_provider_account(map() | keyword()) :: {:ok, Registration.t()} | {:error, term()}
  def register_provider_account(attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <- require_refs(attrs, registration_required_refs()),
         :ok <- validate_provider_family(attrs),
         :ok <- validate_ref_families(attrs, registration_required_refs()),
         :ok <- validate_native_assertion(attrs) do
      {:ok,
       %Registration{
         registration_ref: value!(attrs, :registration_ref),
         system_actor_ref: value!(attrs, :system_actor_ref),
         system_authorization_ref: value!(attrs, :system_authorization_ref),
         provider_family: value!(attrs, :provider_family),
         provider_account_ref: value!(attrs, :provider_account_ref),
         connector_instance_ref: value!(attrs, :connector_instance_ref),
         operation_policy_ref: value!(attrs, :operation_policy_ref),
         target_ref: value!(attrs, :target_ref),
         redaction_ref: value!(attrs, :redaction_ref),
         native_auth_assertion_ref: field_value(attrs, :native_auth_assertion_ref),
         metadata: safe_metadata(field_value(attrs, :metadata))
       }}
    end
  end

  @spec issue_credential_handle(Registration.t(), map() | keyword()) ::
          {:ok, CredentialHandle.t()} | {:error, term()}
  def issue_credential_handle(%Registration{} = registration, attrs) do
    attrs = normalize(attrs)

    merged =
      attrs
      |> Map.put_new(:provider_family, registration.provider_family)
      |> Map.put_new(:provider_account_ref, registration.provider_account_ref)
      |> Map.put_new(:connector_instance_ref, registration.connector_instance_ref)
      |> Map.put_new(:operation_policy_ref, registration.operation_policy_ref)
      |> Map.put_new(:redaction_ref, registration.redaction_ref)

    with :ok <- reject_material(merged),
         :ok <- require_refs(merged, credential_handle_required_refs()),
         :ok <- validate_ref_families(merged, credential_handle_required_refs()) do
      {:ok,
       %CredentialHandle{
         credential_handle_ref: value!(merged, :credential_handle_ref),
         registration_ref: registration.registration_ref,
         provider_family: value!(merged, :provider_family),
         provider_account_ref: value!(merged, :provider_account_ref),
         connector_instance_ref: value!(merged, :connector_instance_ref),
         operation_policy_ref: value!(merged, :operation_policy_ref),
         redaction_ref: value!(merged, :redaction_ref),
         metadata: safe_metadata(field_value(merged, :metadata))
       }}
    end
  end

  @spec issue_lease(CredentialHandle.t(), map() | keyword()) ::
          {:ok, CredentialLease.t()} | {:error, term()}
  def issue_lease(%CredentialHandle{} = handle, attrs) do
    attrs = normalize(attrs)

    merged =
      attrs
      |> Map.put_new(:credential_handle_ref, handle.credential_handle_ref)
      |> Map.put_new(:provider_family, handle.provider_family)
      |> Map.put_new(:provider_account_ref, handle.provider_account_ref)
      |> Map.put_new(:connector_instance_ref, handle.connector_instance_ref)
      |> Map.put_new(:operation_policy_ref, handle.operation_policy_ref)

    with :ok <- reject_material(merged),
         :ok <- require_refs(merged, credential_lease_required_refs()),
         :ok <- validate_provider_family(merged),
         :ok <- validate_operation_class(merged),
         :ok <- validate_ref_families(merged, credential_lease_required_refs()) do
      {:ok, build_lease(merged, :issued)}
    end
  end

  @spec redeem_lease(CredentialLease.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def redeem_lease(%CredentialLease{} = lease, attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <- require_refs(attrs, redemption_required_refs()),
         :ok <- ensure_lease_redeemable(lease, attrs),
         :ok <- compare_scope(lease, attrs, :tenant_ref, :tenant_mismatch),
         :ok <- compare_scope(lease, attrs, :subject_ref, :subject_mismatch),
         :ok <- compare_scope(lease, attrs, :provider_family, :provider_family_mismatch),
         :ok <- compare_scope(lease, attrs, :provider_account_ref, :provider_account_mismatch),
         :ok <- compare_scope(lease, attrs, :connector_instance_ref, :connector_mismatch),
         :ok <- compare_scope(lease, attrs, :credential_handle_ref, :credential_handle_mismatch),
         :ok <- compare_scope(lease, attrs, :operation_class, :operation_class_mismatch),
         :ok <- compare_scope(lease, attrs, :target_ref, :target_mismatch),
         :ok <- compare_scope(lease, attrs, :attach_grant_ref, :attach_grant_mismatch),
         :ok <-
           compare_scope(lease, attrs, :operation_policy_ref, :operation_policy_mismatch),
         :ok <- compare_scope(lease, attrs, :policy_revision_ref, :stale_policy_revision),
         :ok <- compare_scope(lease, attrs, :target_grant_revision, :stale_target_grant),
         :ok <- compare_scope(lease, attrs, :rotation_epoch, :stale_rotation_epoch),
         :ok <- compare_scope(lease, attrs, :fence_token, :fence_token_mismatch) do
      {:ok,
       %{
         event: "provider_auth.lease.redeemed",
         credential_lease_ref: lease.credential_lease_ref,
         credential_handle_ref: lease.credential_handle_ref,
         tenant_ref: lease.tenant_ref,
         subject_ref: lease.subject_ref,
         provider_family: lease.provider_family,
         provider_account_ref: lease.provider_account_ref,
         connector_instance_ref: lease.connector_instance_ref,
         operation_class: lease.operation_class,
         target_ref: lease.target_ref,
         attach_grant_ref: lease.attach_grant_ref,
         operation_policy_ref: lease.operation_policy_ref,
         policy_revision_ref: lease.policy_revision_ref,
         target_grant_revision: lease.target_grant_revision,
         rotation_epoch: lease.rotation_epoch,
         fence_token: lease.fence_token,
         redacted: true
       }}
    end
  end

  @spec renew_lease(CredentialLease.t(), map() | keyword()) ::
          {:ok, CredentialLease.t()} | {:error, term()}
  def renew_lease(%CredentialLease{} = lease, attrs) do
    attrs = normalize(attrs)

    merged =
      lease
      |> Map.from_struct()
      |> Map.merge(attrs)
      |> Map.put_new(:renewed_from_lease_ref, lease.credential_lease_ref)
      |> Map.put(:status, :renewed)

    with :ok <- reject_material(merged),
         :ok <- require_refs(merged, credential_lease_required_refs()),
         :ok <- validate_provider_family(merged),
         :ok <- validate_operation_class(merged),
         :ok <- validate_ref_families(merged, credential_lease_required_refs()) do
      {:ok, build_lease(merged, :renewed, lease.credential_lease_ref)}
    end
  end

  @spec revoke_lease(CredentialLease.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def revoke_lease(%CredentialLease{} = lease, attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <-
           require_refs(attrs, [
             :authority_packet_ref,
             :system_authorization_ref,
             :revocation_ref,
             :revoked_at
           ]),
         :ok <-
           validate_ref_families(attrs, [
             :authority_packet_ref,
             :system_authorization_ref,
             :revocation_ref
           ]) do
      {:ok,
       %{
         event: "provider_auth.lease.revoked",
         credential_lease_ref: lease.credential_lease_ref,
         credential_handle_ref: lease.credential_handle_ref,
         provider_account_ref: lease.provider_account_ref,
         authority_packet_ref: value!(attrs, :authority_packet_ref),
         system_authorization_ref: value!(attrs, :system_authorization_ref),
         revocation_ref: value!(attrs, :revocation_ref),
         revoked_at: value!(attrs, :revoked_at),
         status: :revoked,
         redacted: true
       }}
    end
  end

  @spec cleanup_lease(CredentialLease.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def cleanup_lease(%CredentialLease{} = lease, attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <- require_refs(attrs, [:cleanup_ref, :cleaned_at]),
         :ok <- validate_ref_families(attrs, [:cleanup_ref]) do
      {:ok,
       %{
         event: "provider_auth.lease.cleaned",
         credential_lease_ref: lease.credential_lease_ref,
         credential_handle_ref: lease.credential_handle_ref,
         provider_account_ref: lease.provider_account_ref,
         cleanup_ref: value!(attrs, :cleanup_ref),
         cleaned_at: value!(attrs, :cleaned_at),
         status: :cleaned,
         redacted: true
       }}
    end
  end

  @spec audit_lease_event(String.t(), CredentialLease.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def audit_lease_event(event_name, %CredentialLease{} = lease, attrs \\ [])
      when is_binary(event_name) and event_name != "" do
    attrs = normalize(attrs)

    with :ok <- reject_material(Map.drop(attrs, [:metadata])) do
      {:ok,
       %{
         event: event_name,
         credential_lease_ref: lease.credential_lease_ref,
         credential_handle_ref: lease.credential_handle_ref,
         provider_account_ref: lease.provider_account_ref,
         target_ref: lease.target_ref,
         operation_class: lease.operation_class,
         redaction_ref: field_value(attrs, :redaction_ref),
         metadata: safe_event_metadata(field_value(attrs, :metadata)),
         redacted: true
       }
       |> drop_empty_values()}
    end
  end

  @spec fence_event(CredentialLease.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def fence_event(%CredentialLease{} = lease, attrs \\ []) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs) do
      {:ok,
       %{
         event: "provider_auth.lease.fenced",
         credential_lease_ref: lease.credential_lease_ref,
         credential_handle_ref: lease.credential_handle_ref,
         tenant_ref: lease.tenant_ref,
         provider_family: lease.provider_family,
         provider_account_ref: lease.provider_account_ref,
         target_ref: lease.target_ref,
         attach_grant_ref: lease.attach_grant_ref,
         operation_policy_ref: lease.operation_policy_ref,
         policy_revision_ref: lease.policy_revision_ref,
         target_grant_revision: lease.target_grant_revision,
         rotation_epoch: lease.rotation_epoch,
         fence_token: lease.fence_token,
         checked_at: field_value(attrs, :checked_at),
         redacted: true
       }
       |> drop_empty_values()}
    end
  end

  @spec authorize_provider_effect(map() | keyword()) :: :ok | {:error, term()}
  def authorize_provider_effect(attrs) do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <- require_refs(attrs, @authority_required_refs),
         :ok <- validate_provider_family(attrs),
         :ok <- validate_ref_families(attrs, @authority_required_refs) do
      :ok
    end
  end

  @spec revoke(CredentialHandle.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def revoke(%CredentialHandle{} = handle, attrs) do
    attrs = normalize(attrs)

    with :ok <- require_refs(attrs, [:authority_packet_ref, :system_authorization_ref]) do
      {:ok,
       %{
         event: "provider_auth.revoked",
         credential_handle_ref: handle.credential_handle_ref,
         provider_account_ref: handle.provider_account_ref,
         authority_packet_ref: value!(attrs, :authority_packet_ref),
         system_authorization_ref: value!(attrs, :system_authorization_ref),
         status: :revoked
       }}
    end
  end

  @spec audit_event(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def audit_event(event_name, attrs) when is_binary(event_name) and event_name != "" do
    attrs = normalize(attrs)

    with :ok <- reject_material(attrs),
         :ok <-
           require_refs(attrs, [:authority_packet_ref, :system_authorization_ref, :redaction_ref]) do
      {:ok,
       %{
         event: event_name,
         authority_packet_ref: value!(attrs, :authority_packet_ref),
         system_authorization_ref: value!(attrs, :system_authorization_ref),
         redaction_ref: value!(attrs, :redaction_ref),
         metadata: safe_metadata(field_value(attrs, :metadata))
       }}
    end
  end

  @spec redact(term(), [String.t()]) :: term()
  def redact(value, protected_values) do
    protected_values =
      protected_values
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    do_redact(value, protected_values)
  end

  defp registration_required_refs do
    [
      :registration_ref,
      :system_actor_ref,
      :system_authorization_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :operation_policy_ref,
      :target_ref,
      :redaction_ref
    ]
  end

  defp credential_handle_required_refs do
    [
      :credential_handle_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :operation_policy_ref,
      :redaction_ref
    ]
  end

  defp credential_lease_required_refs do
    [
      :credential_lease_ref,
      :credential_handle_ref,
      :tenant_ref,
      :subject_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :operation_class,
      :target_ref,
      :attach_grant_ref,
      :operation_policy_ref,
      :authority_packet_ref,
      :policy_revision_ref,
      :target_grant_revision,
      :rotation_epoch,
      :fence_token,
      :expires_at
    ]
  end

  defp redemption_required_refs do
    [
      :tenant_ref,
      :subject_ref,
      :provider_family,
      :provider_account_ref,
      :connector_instance_ref,
      :credential_handle_ref,
      :operation_class,
      :target_ref,
      :attach_grant_ref,
      :operation_policy_ref,
      :policy_revision_ref,
      :target_grant_revision,
      :rotation_epoch,
      :fence_token,
      :now
    ]
  end

  defp validate_provider_family(attrs) do
    if field_value(attrs, :provider_family) in @provider_families do
      :ok
    else
      {:error, {:unsupported_provider_family, field_value(attrs, :provider_family)}}
    end
  end

  defp validate_operation_class(attrs) do
    if field_value(attrs, :operation_class) in @operation_classes do
      :ok
    else
      {:error, {:unsupported_operation_class, field_value(attrs, :operation_class)}}
    end
  end

  defp build_lease(attrs, status, renewed_from_lease_ref \\ nil) do
    %CredentialLease{
      credential_lease_ref: value!(attrs, :credential_lease_ref),
      credential_handle_ref: value!(attrs, :credential_handle_ref),
      tenant_ref: value!(attrs, :tenant_ref),
      subject_ref: value!(attrs, :subject_ref),
      provider_family: value!(attrs, :provider_family),
      provider_account_ref: value!(attrs, :provider_account_ref),
      connector_instance_ref: value!(attrs, :connector_instance_ref),
      operation_class: value!(attrs, :operation_class),
      target_ref: value!(attrs, :target_ref),
      attach_grant_ref: value!(attrs, :attach_grant_ref),
      operation_policy_ref: value!(attrs, :operation_policy_ref),
      authority_packet_ref: value!(attrs, :authority_packet_ref),
      policy_revision_ref: value!(attrs, :policy_revision_ref),
      target_grant_revision: value!(attrs, :target_grant_revision),
      rotation_epoch: value!(attrs, :rotation_epoch),
      fence_token: value!(attrs, :fence_token),
      expires_at: value!(attrs, :expires_at),
      renewed_from_lease_ref:
        renewed_from_lease_ref || field_value(attrs, :renewed_from_lease_ref),
      status: status,
      metadata: safe_metadata(field_value(attrs, :metadata))
    }
  end

  defp ensure_lease_redeemable(%CredentialLease{status: :revoked}, _attrs),
    do: {:error, :revoked_lease}

  defp ensure_lease_redeemable(%CredentialLease{status: :rotated}, _attrs),
    do: {:error, :rotated_lease}

  defp ensure_lease_redeemable(%CredentialLease{} = lease, attrs) do
    now = field_value(attrs, :now)

    if match?(%DateTime{}, now) and DateTime.compare(lease.expires_at, now) != :gt do
      {:error, :expired_lease}
    else
      :ok
    end
  end

  defp compare_scope(%CredentialLease{} = lease, attrs, field, reason) do
    if Map.fetch!(Map.from_struct(lease), field) == field_value(attrs, field) do
      :ok
    else
      {:error, reason}
    end
  end

  defp validate_native_assertion(attrs) do
    case field_value(attrs, :native_auth_assertion) do
      nil ->
        :ok

      %NativeAuthAssertion{} ->
        :ok

      other ->
        {:error, {:invalid_native_auth_assertion, other}}
    end
  end

  defp reject_material(attrs) do
    hits =
      @forbidden_material
      |> Enum.filter(fn field -> present?(field_value(attrs, field)) end)

    case hits do
      [] -> :ok
      fields -> {:error, {:raw_material_rejected, fields}}
    end
  end

  defp require_refs(attrs, fields) do
    missing = Enum.reject(fields, fn field -> present?(field_value(attrs, field)) end)

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_authority_refs, fields}}
    end
  end

  defp validate_ref_families(attrs, fields) do
    bad =
      fields
      |> Enum.filter(fn field ->
        case Map.fetch(@ref_prefixes, field) do
          {:ok, prefix} -> not starts_with?(field_value(attrs, field), prefix)
          :error -> false
        end
      end)

    case bad do
      [] -> :ok
      fields -> {:error, {:ref_family_mismatch, fields}}
    end
  end

  defp starts_with?(value, prefix) when is_binary(value), do: String.starts_with?(value, prefix)
  defp starts_with?(_value, _prefix), do: false

  defp normalize(attrs) when is_map(attrs), do: attrs
  defp normalize(attrs) when is_list(attrs), do: Map.new(attrs)

  defp value!(attrs, field) do
    case field_value(attrs, field) do
      value when is_binary(value) and value != "" ->
        value

      value
      when field in [:expires_at, :rotation_epoch, :revoked_at, :cleaned_at] and not is_nil(value) ->
        value

      value ->
        raise ArgumentError, "#{field} must be present, got: #{inspect(value)}"
    end
  end

  defp field_value(attrs, field) do
    Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
  end

  defp safe_metadata(metadata) when is_map(metadata), do: metadata
  defp safe_metadata(_metadata), do: %{}

  defp safe_event_metadata(metadata) when is_map(metadata) do
    Map.drop(metadata, @forbidden_material ++ Enum.map(@forbidden_material, &Atom.to_string/1))
  end

  defp safe_event_metadata(_metadata), do: %{}

  defp drop_empty_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(_value), do: true

  defp do_redact(value, protected_values) when is_binary(value) do
    Enum.reduce(protected_values, value, fn protected_value, acc ->
      String.replace(acc, protected_value, "[REDACTED]")
    end)
  end

  defp do_redact(value, protected_values) when is_list(value) do
    Enum.map(value, &do_redact(&1, protected_values))
  end

  defp do_redact(value, protected_values) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> do_redact(protected_values)
    |> List.to_tuple()
  end

  defp do_redact(value, protected_values) when is_map(value) do
    Map.new(value, fn {key, map_value} ->
      {do_redact(key, protected_values), do_redact(map_value, protected_values)}
    end)
  end

  defp do_redact(value, _protected_values), do: value
end

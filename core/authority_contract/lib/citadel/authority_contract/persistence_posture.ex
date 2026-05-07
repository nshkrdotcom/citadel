defmodule Citadel.AuthorityContract.PersistencePosture do
  @moduledoc """
  Ref-only persistence posture for Citadel authority surfaces.

  Persistence posture records where evidence may be retained. It never
  authorizes provider effects, credential leases, or target attach.
  """

  alias GroundPlane.PersistencePolicy
  alias GroundPlane.PersistencePolicy.StoreCapability

  @citadel_components [
    :authority_decision,
    :authority_packet,
    :provider_auth_fabric_refs,
    :native_auth_assertion_refs,
    :connector_binding_refs,
    :audit_evidence_hash_chain
  ]

  @component_data_classes %{
    authority_decision: [:authority_decision],
    authority_packet: [:authority_packet],
    provider_auth_fabric_refs: [:provider_auth_fabric_refs],
    native_auth_assertion_refs: [:native_auth_assertion_refs],
    connector_binding_refs: [:connector_binding_refs],
    audit_evidence_hash_chain: [:audit_evidence_hash_chain]
  }

  @memory_retention_ref "retention://process-lifetime"

  @type component :: atom()
  @type posture :: %{
          required(:component) => component(),
          required(:persistence_profile_ref) => String.t(),
          required(:persistence_tier_ref) => String.t(),
          required(:capture_level_ref) => String.t(),
          required(:store_set_ref) => String.t(),
          required(:store_partition_ref) => String.t() | nil,
          required(:retention_policy_ref) => String.t(),
          required(:debug_tap_ref) => String.t() | nil,
          required(:persistence_receipt_ref) => String.t(),
          required(:store_ref) => String.t(),
          required(:durable?) => boolean(),
          required(:restart_durability_claim) => atom()
        }

  @spec components() :: [component()]
  def components, do: @citadel_components

  @spec memory(component()) :: posture()
  def memory(component), do: resolve(component, profile: :mickey_mouse)

  @spec resolve(component(), keyword() | map()) :: posture()
  def resolve(component, attrs \\ []) when component in @citadel_components do
    attrs
    |> PersistencePolicy.resolve!()
    |> posture(component)
  end

  @spec preflight(component(), keyword() | map(), [StoreCapability.t()]) :: :ok | {:error, term()}
  def preflight(component, attrs, capabilities) when component in @citadel_components do
    profile = PersistencePolicy.resolve!(attrs)

    PersistencePolicy.preflight(profile, capabilities, fn capability ->
      if component in capability.data_classes or :all in capability.data_classes do
        :ok
      else
        {:error, {:missing_component_capability, component}}
      end
    end)
  end

  @spec memory_capability(component()) :: StoreCapability.t()
  def memory_capability(component) when component in @citadel_components do
    capability!(
      store_ref: component,
      tier: :memory_ephemeral,
      data_classes: data_classes(component),
      adapter: :memory,
      restart_safe?: false
    )
  end

  @spec durable_capability(component(), atom()) :: StoreCapability.t()
  def durable_capability(component, tier \\ :postgres_shared)
      when component in @citadel_components do
    capability!(
      store_ref: component,
      tier: tier,
      data_classes: data_classes(component),
      adapter: tier,
      restart_safe?: tier in [:local_restart_safe, :postgres_shared, :temporal_durable]
    )
  end

  @spec string_keys(posture()) :: map()
  def string_keys(posture) when is_map(posture) do
    Map.new(posture, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @spec from_attrs(component(), map() | keyword()) :: posture()
  def from_attrs(component, attrs) when component in @citadel_components do
    attrs = normalize_attrs(attrs)

    case value(attrs, :persistence_posture) do
      posture when is_map(posture) -> normalize_posture(component, posture)
      _missing -> resolve(component, attrs)
    end
  end

  @spec durable?(map()) :: boolean()
  def durable?(posture) when is_map(posture) do
    value(posture, :durable?) == true
  end

  defp posture(%PersistencePolicy.Profile{} = profile, component) do
    store_set = profile.store_set
    tier = profile.default_tier

    %{
      component: component,
      persistence_profile_ref: ref("persistence-profile", profile.id),
      persistence_tier_ref: ref("persistence-tier", tier),
      capture_level_ref: ref("capture-level", profile.capture_level),
      store_set_ref: ref("store-set", store_set.id),
      store_partition_ref: partition_ref(profile),
      retention_policy_ref: retention_ref(profile),
      debug_tap_ref: debug_tap_ref(profile),
      persistence_receipt_ref: receipt_ref(component, profile.id),
      store_ref: store_ref(store_set),
      durable?: profile.durable?,
      restart_durability_claim: restart_claim(profile)
    }
  end

  defp normalize_posture(component, posture) do
    %{
      component: component,
      persistence_profile_ref:
        string_or_default(
          posture,
          :persistence_profile_ref,
          ref("persistence-profile", :mickey_mouse)
        ),
      persistence_tier_ref:
        string_or_default(
          posture,
          :persistence_tier_ref,
          ref("persistence-tier", :memory_ephemeral)
        ),
      capture_level_ref:
        string_or_default(posture, :capture_level_ref, ref("capture-level", :off)),
      store_set_ref:
        string_or_default(posture, :store_set_ref, ref("store-set", :mickey_mouse_memory)),
      store_partition_ref: optional_string(posture, :store_partition_ref),
      retention_policy_ref:
        string_or_default(posture, :retention_policy_ref, @memory_retention_ref),
      debug_tap_ref: optional_string(posture, :debug_tap_ref),
      persistence_receipt_ref:
        string_or_default(
          posture,
          :persistence_receipt_ref,
          receipt_ref(component, :mickey_mouse)
        ),
      store_ref: string_or_default(posture, :store_ref, "store://memory_ephemeral"),
      durable?: value(posture, :durable?) == true,
      restart_durability_claim: value(posture, :restart_durability_claim) || :none
    }
  end

  defp capability!(attrs) do
    case StoreCapability.new(attrs) do
      {:ok, capability} -> capability
      {:error, reason} -> raise ArgumentError, message: inspect(reason)
    end
  end

  defp data_classes(component), do: Map.fetch!(@component_data_classes, component)

  defp ref(prefix, atom) when is_atom(atom), do: "#{prefix}://#{Atom.to_string(atom)}"

  defp receipt_ref(component, profile_id),
    do: "persistence-receipt://citadel/#{Atom.to_string(component)}/#{Atom.to_string(profile_id)}"

  defp store_ref(%{default_tier: tier}), do: "store://#{Atom.to_string(tier)}"

  defp partition_ref(%PersistencePolicy.Profile{durable?: true, default_tier: tier}),
    do: "store-partition://#{Atom.to_string(tier)}/default"

  defp partition_ref(%PersistencePolicy.Profile{}), do: nil

  defp retention_ref(%PersistencePolicy.Profile{metadata: %{restart_claim: :none}}),
    do: @memory_retention_ref

  defp retention_ref(%PersistencePolicy.Profile{default_tier: tier}),
    do: "retention://#{Atom.to_string(tier)}"

  defp debug_tap_ref(%PersistencePolicy.Profile{debug_tap: PersistencePolicy.DebugTap.Noop}),
    do: nil

  defp debug_tap_ref(%PersistencePolicy.Profile{debug_tap: module}),
    do: "debug-tap://#{inspect(module)}"

  defp restart_claim(%PersistencePolicy.Profile{metadata: metadata}) do
    Map.get(metadata, :restart_claim, :none)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs

  defp string_or_default(attrs, key, default) do
    case value(attrs, key) do
      current when is_binary(current) and current != "" -> current
      _other -> default
    end
  end

  defp optional_string(attrs, key) do
    case value(attrs, key) do
      current when is_binary(current) and current != "" -> current
      _other -> nil
    end
  end

  defp value(attrs, field) when is_atom(field),
    do: Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
end

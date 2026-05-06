defmodule Citadel.ObservabilityContract.CardinalityBoundsTest do
  use ExUnit.Case, async: true

  alias Citadel.ObservabilityContract
  alias Citadel.ObservabilityContract.CardinalityBounds

  @surfaces [
    :metric,
    :trace_span,
    :trace_event,
    :trace_export,
    :audit_fact,
    :audit_export,
    :incident_export
  ]

  @required_profile_fields [
    :observability_surface,
    :owner_repo,
    :owner_package,
    :event_name,
    :metric_label_allowlist,
    :metric_label_blocklist,
    :max_label_keys,
    :max_distinct_label_values_per_window,
    :label_window_ms,
    :trace_attribute_allowlist,
    :trace_attribute_blocklist,
    :max_attributes_per_span,
    :max_events_per_span,
    :max_attribute_key_bytes,
    :max_attribute_value_bytes,
    :max_collection_items,
    :max_map_depth,
    :sample_policy,
    :sample_rate_or_budget,
    :audit_amplification_guard_ref,
    :audit_event_admission_key,
    :audit_event_window_ms,
    :max_audit_events_per_key_per_window,
    :audit_repeat_aggregation_ref,
    :audit_overflow_counter_ref,
    :redaction_policy_ref,
    :hash_or_tokenize_fields,
    :spillover_artifact_policy,
    :overflow_safe_action,
    :release_manifest_ref
  ]

  test "facade exposes cardinality bounds ownership" do
    assert ObservabilityContract.cardinality_bounds_module() == CardinalityBounds
    assert :observability_cardinality_bounds_v1 in ObservabilityContract.manifest().owns
    assert ObservabilityContract.cardinality_bounds_surfaces() == @surfaces
    assert ObservabilityContract.cardinality_bounds_profile_fields() == @required_profile_fields
  end

  test "default profiles cover required observability surfaces and bounds fields" do
    profiles = ObservabilityContract.cardinality_bounds_profiles()

    assert profiles |> Map.keys() |> Enum.sort() == Enum.sort(@surfaces)

    for surface <- @surfaces do
      profile = Map.fetch!(profiles, surface)
      dumped = CardinalityBounds.dump(profile)

      assert profile.contract_name == "Platform.ObservabilityCardinalityBounds.v1"
      assert profile.contract_version == "1.0.0"
      assert profile.observability_surface == surface
      assert profile.release_manifest_ref == "phase5-v7-milestone5"

      for field <- @required_profile_fields do
        assert Map.fetch!(dumped, field)
      end

      assert profile.max_label_keys > 0
      assert profile.max_distinct_label_values_per_window > 0
      assert profile.label_window_ms > 0
      assert profile.max_attributes_per_span > 0
      assert profile.max_events_per_span > 0
      assert profile.max_attribute_key_bytes > 0
      assert profile.max_attribute_value_bytes > 0
      assert profile.max_collection_items > 0
      assert profile.max_map_depth > 0
      assert profile.audit_event_window_ms > 0
      assert profile.max_audit_events_per_key_per_window > 0
      assert profile.sample_policy in CardinalityBounds.sample_policies()
      assert profile.overflow_safe_action in CardinalityBounds.overflow_safe_actions()
      assert :ok = CardinalityBounds.validate_profile(profile)
    end
  end

  test "metric labels are allowlisted and high-cardinality ids are blocked" do
    assert :ok =
             CardinalityBounds.validate_metric_labels([
               :event_name,
               :owner_package,
               :operation_family,
               :outcome,
               :safe_action
             ])

    assert {:error, {:blocked_metric_labels, [:trace_id, :tenant_id, :payload_hash]}} =
             CardinalityBounds.validate_metric_labels([:trace_id, :tenant_id, :payload_hash])

    assert {:error, {:unknown_metric_labels, [:custom_payload_field]}} =
             CardinalityBounds.validate_metric_labels([:custom_payload_field])
  end

  test "default profiles keep label and trace allowlists separate from blocklists" do
    for profile <- Map.values(CardinalityBounds.profiles()) do
      metric_allowlist = MapSet.new(profile.metric_label_allowlist)
      metric_blocklist = MapSet.new(profile.metric_label_blocklist)
      trace_allowlist = MapSet.new(profile.trace_attribute_allowlist)
      trace_blocklist = MapSet.new(profile.trace_attribute_blocklist)

      assert MapSet.disjoint?(metric_allowlist, metric_blocklist)
      assert MapSet.disjoint?(trace_allowlist, trace_blocklist)

      assert MapSet.subset?(
               MapSet.new(CardinalityBounds.high_cardinality_metric_label_blocklist()),
               metric_blocklist
             )
    end
  end

  test "profiles fail closed on missing bounds or unsafe label and sampling policy" do
    base = CardinalityBounds.profile!(:metric) |> CardinalityBounds.dump()

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.delete(:max_attribute_value_bytes)
             |> CardinalityBounds.new()

    assert String.contains?(message, "missing required field")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:metric_label_allowlist, [:event_name, :trace_id])
             |> CardinalityBounds.new()

    assert String.contains?(message, "metric_label_allowlist overlaps with its blocklist")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.delete(:sample_policy)
             |> CardinalityBounds.new()

    assert String.contains?(message, "missing required field")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:sample_policy, :unbounded_success)
             |> CardinalityBounds.new()

    assert String.contains?(message, "sample_policy")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.delete(:overflow_safe_action)
             |> CardinalityBounds.new()

    assert String.contains?(message, "missing required field")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:overflow_safe_action, :append_unbounded)
             |> CardinalityBounds.new()

    assert String.contains?(message, "overflow_safe_action")
  end

  test "audit and incident surfaces declare amplification guards" do
    for surface <- [:audit_fact, :audit_export, :incident_export] do
      profile = CardinalityBounds.profile!(surface)

      assert profile.audit_amplification_guard_ref == "citadel.audit_amplification_guard.v1"

      assert profile.audit_event_admission_key == [
               :tenant_or_partition,
               :owner_package,
               :source_boundary,
               :event_name,
               :error_class,
               :safe_action,
               :canonical_idempotency_key_or_payload_hash
             ]

      assert profile.audit_repeat_aggregation_ref == "citadel.audit_repeat_aggregation.v1"
      assert profile.audit_overflow_counter_ref == "citadel.audit_overflow.count"
      assert profile.max_audit_events_per_key_per_window == 1
    end
  end
end

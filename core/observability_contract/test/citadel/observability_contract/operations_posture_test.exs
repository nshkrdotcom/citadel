defmodule Citadel.ObservabilityContract.OperationsPostureTest do
  use ExUnit.Case, async: true

  alias Citadel.ObservabilityContract
  alias Citadel.ObservabilityContract.OperationsPosture

  @touched_seams [
    :signal_ingress_lineage,
    :trace_publisher_output,
    :aitrace_file_export,
    :audit_fact_append,
    :execution_lineage_store,
    :integration_bridge_lower_read
  ]

  @required_profile_fields [
    :observability_owner,
    :owner_repo,
    :owner_package,
    :surface,
    :event_or_log_name,
    :metric_ref,
    :trace_ref,
    :log_ref,
    :log_field_allowlist,
    :log_field_blocklist,
    :alert_ref,
    :incident_runbook_ref,
    :slo_or_error_budget_ref,
    :slo_or_error_budget_scope,
    :severity_mapping,
    :alert_condition_coverage,
    :paging_or_triage_route,
    :redaction_policy_ref,
    :retention_ref,
    :sampling_policy_ref,
    :dropped_or_suppressed_count_ref,
    :not_applicable_reason,
    :release_manifest_ref
  ]

  test "facade exposes operations posture ownership" do
    assert ObservabilityContract.operations_posture_module() == OperationsPosture
    assert :observability_operations_posture_v1 in ObservabilityContract.manifest().owns
    assert ObservabilityContract.operations_posture_touched_seams() == @touched_seams
    assert ObservabilityContract.operations_posture_profile_fields() == @required_profile_fields
  end

  test "default profiles cover touched observable seams and required posture fields" do
    profiles = ObservabilityContract.operations_posture_profiles()

    assert profiles |> Map.keys() |> Enum.sort() == Enum.sort(@touched_seams)

    for seam <- @touched_seams do
      profile = Map.fetch!(profiles, seam)
      dumped = OperationsPosture.dump(profile)

      assert profile.contract_name == "Platform.ObservabilityOperationsPosture.v1"
      assert profile.contract_version == "1.0.0"
      assert profile.touched_seam == seam
      assert profile.release_manifest_ref == "phase5-v7-milestone5"

      for field <- @required_profile_fields do
        assert Map.has_key?(dumped, field)
      end

      assert String.contains?(profile.metric_ref, ".")
      assert String.contains?(profile.trace_ref, ".")
      assert String.contains?(profile.log_ref, ".")
      assert profile.log_field_allowlist == OperationsPosture.safe_log_field_allowlist()
      assert profile.log_field_blocklist == OperationsPosture.raw_log_field_blocklist()
      assert String.contains?(profile.alert_ref, ".")

      assert String.contains?(
               profile.incident_runbook_ref,
               "runbooks/observability_operations_posture.md"
             )

      assert String.contains?(profile.slo_or_error_budget_ref, ".")
      assert profile.slo_or_error_budget_scope.ref == profile.slo_or_error_budget_ref
      assert String.contains?(profile.paging_or_triage_route, "-")
      assert profile.redaction_policy_ref == "citadel.redaction.refs_only.v1"
      assert profile.retention_ref == "phase5.observability_evidence.retention.v1"
      assert profile.sampling_policy_ref == "success=100/min;debug=drop;protected=always"
      assert String.contains?(profile.dropped_or_suppressed_count_ref, ".")
      assert profile.not_applicable_reason == nil
      assert OperationsPosture.alert_route_complete?(profile)
      assert OperationsPosture.alert_condition_coverage_complete?(profile)
      assert OperationsPosture.slo_or_error_budget_scope_complete?(profile)
      assert :ok = OperationsPosture.validate_profile(profile)
    end
  end

  test "log fields allow redacted refs and reject raw payload data" do
    assert :ok =
             OperationsPosture.validate_log_fields([
               :event_name,
               :owner_package,
               :safe_action,
               :trace_id,
               :causation_id,
               :canonical_idempotency_key,
               :tenant_ref,
               :release_manifest_ref,
               :payload_hash,
               :suppressed_count
             ])

    assert {:error, {:blocked_log_fields, [:raw_prompt, :tenant_secret, :stdout]}} =
             OperationsPosture.validate_log_fields([:raw_prompt, :tenant_secret, :stdout])

    assert {:error, {:unknown_log_fields, [:custom_payload_map]}} =
             OperationsPosture.validate_log_fields([:custom_payload_map])
  end

  test "critical profiles declare severity mapping and operator route evidence" do
    for profile <- Map.values(OperationsPosture.profiles()) do
      assert Enum.all?(profile.severity_mapping, fn {family, severity} ->
               family in OperationsPosture.critical_condition_families() and
                 severity in OperationsPosture.severity_levels()
             end)

      assert Enum.any?(profile.severity_mapping, fn {_family, severity} ->
               severity in [:p0, :p1, :p2]
             end)

      assert is_binary(profile.alert_ref)
      assert is_binary(profile.incident_runbook_ref)
      assert is_binary(profile.slo_or_error_budget_ref)
      assert OperationsPosture.slo_or_error_budget_scope_complete?(profile)
      assert is_binary(profile.paging_or_triage_route)
      assert is_binary(profile.dropped_or_suppressed_count_ref)
      assert OperationsPosture.missing_operating_dimensions(profile) == []
      assert OperationsPosture.not_applicable_evidence_complete?(profile)
      assert OperationsPosture.alert_condition_coverage_complete?(profile)
    end
  end

  test "slo and error-budget refs are scoped to preserved hardening behavior" do
    for profile <- Map.values(OperationsPosture.profiles()) do
      scope = profile.slo_or_error_budget_scope

      assert scope |> Map.keys() |> Enum.sort() ==
               OperationsPosture.slo_or_error_budget_scope_fields() |> Enum.sort()

      assert scope.ref == profile.slo_or_error_budget_ref

      assert scope.hardening_behavior in OperationsPosture.slo_or_error_budget_hardening_behaviors()

      assert is_binary(scope.source_evidence_ref)
      assert is_binary(scope.owner)
      assert is_binary(scope.safe_action)
      ref = String.downcase(scope.ref)
      refute String.contains?(ref, "product.slo")
      refute String.contains?(ref, "site_availability")
      refute String.contains?(ref, "uptime")
      assert OperationsPosture.slo_or_error_budget_scope_complete?(profile)
    end
  end

  test "alert condition coverage routes p0 p1 families or records source not-applicable evidence" do
    for profile <- Map.values(OperationsPosture.profiles()) do
      assert profile.alert_condition_coverage |> Map.keys() |> Enum.sort() ==
               OperationsPosture.alert_required_condition_families() |> Enum.sort()

      for family <- OperationsPosture.alert_required_condition_families() do
        coverage = Map.fetch!(profile.alert_condition_coverage, family)

        if Map.has_key?(profile.severity_mapping, family) do
          assert coverage.posture == :alert_or_triage
          assert coverage.severity in [:p0, :p1]
          assert is_binary(coverage.incident_runbook_ref)
          assert is_binary(coverage.owner)
          assert is_binary(coverage.source_evidence_ref)
          assert is_binary(coverage.safe_action)
          assert is_binary(coverage.alert_ref) or is_binary(coverage.triage_route)
        else
          assert coverage.posture == :not_applicable
          assert is_binary(coverage.not_applicable_reason)
          assert is_binary(coverage.source_evidence_ref)
          assert is_binary(coverage.owner)
          assert is_binary(coverage.safe_action)
        end
      end
    end
  end

  test "Mezzanine lineage seams have complete operations posture ledger evidence" do
    for seam <- [:execution_lineage_store, :integration_bridge_lower_read] do
      profile = OperationsPosture.profile!(seam)

      assert profile.owner_repo == "mezzanine"
      assert String.contains?(profile.log_ref, "redacted")
      assert String.contains?(profile.alert_ref, "mezzanine.alert")

      assert String.contains?(
               profile.incident_runbook_ref,
               "runbooks/observability_operations_posture.md#"
             )

      assert String.contains?(profile.slo_or_error_budget_ref, "mezzanine.error_budget")
      assert String.contains?(profile.paging_or_triage_route, "mezzanine-")
      assert profile.redaction_policy_ref == "citadel.redaction.refs_only.v1"
      assert profile.retention_ref == "phase5.observability_evidence.retention.v1"
      assert profile.sampling_policy_ref == "success=100/min;debug=drop;protected=always"
      assert String.contains?(profile.dropped_or_suppressed_count_ref, "count")
      assert profile.severity_mapping.tenant_authority_bypass == :p0
      assert profile.severity_mapping.fail_closed_security == :p1
      assert profile.alert_condition_coverage.tenant_authority_bypass.posture == :alert_or_triage
      assert profile.alert_condition_coverage.fail_closed_security.posture == :alert_or_triage
      assert OperationsPosture.alert_route_complete?(profile)
      assert OperationsPosture.alert_condition_coverage_complete?(profile)
      assert OperationsPosture.slo_or_error_budget_scope_complete?(profile)
    end
  end

  test "profiles fail closed on missing required operating evidence" do
    base = OperationsPosture.profile!(:audit_fact_append) |> OperationsPosture.dump()

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.delete(:log_ref)
             |> OperationsPosture.new()

    assert String.contains?(message, "source-backed not-applicable evidence")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:alert_ref, "")
             |> OperationsPosture.new()

    assert String.contains?(message, "non-empty strings")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.delete(:dropped_or_suppressed_count_ref)
             |> OperationsPosture.new()

    assert String.contains?(message, "missing required field")
  end

  test "profiles fail closed when log blocklists omit prohibited raw fields" do
    base = OperationsPosture.profile!(:signal_ingress_lineage) |> OperationsPosture.dump()

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.update!(:log_field_blocklist, &List.delete(&1, :raw_prompt))
             |> OperationsPosture.new()

    assert String.contains?(message, "must include raw log fields")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.update!(:log_field_allowlist, &[:raw_prompt | &1])
             |> OperationsPosture.new()

    assert String.contains?(message, "overlaps with its blocklist")
  end

  test "profiles fail closed when alert condition coverage is incomplete" do
    base = OperationsPosture.profile!(:audit_fact_append) |> OperationsPosture.dump()

    assert {:error, %ArgumentError{message: message}} =
             base
             |> update_in([:alert_condition_coverage], &Map.delete(&1, :observability_overflow))
             |> OperationsPosture.new()

    assert String.contains?(message, "missing condition families")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> update_in([:alert_condition_coverage, :fail_closed_security], fn coverage ->
               coverage
               |> Map.put(:alert_ref, nil)
               |> Map.put(:triage_route, nil)
             end)
             |> OperationsPosture.new()

    assert String.contains?(message, "P0/P1 critical condition families require")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> update_in([:alert_condition_coverage, :queue_mailbox_overflow], fn coverage ->
               Map.delete(coverage, :source_evidence_ref)
             end)
             |> OperationsPosture.new()

    assert String.contains?(message, "source_evidence_ref")
  end

  test "profiles fail closed when slo or error-budget scope is broad or incomplete" do
    base = OperationsPosture.profile!(:signal_ingress_lineage) |> OperationsPosture.dump()

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.delete(:slo_or_error_budget_scope)
             |> OperationsPosture.new()

    assert String.contains?(message, "missing required field")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> update_in([:slo_or_error_budget_scope], fn scope ->
               Map.put(scope, :hardening_behavior, :product_availability)
             end)
             |> OperationsPosture.new()

    assert String.contains?(message, "slo_or_error_budget_hardening_behavior")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> put_in([:slo_or_error_budget_scope, :ref], "product.slo.site_availability")
             |> OperationsPosture.new()

    assert String.contains?(message, "must match slo_or_error_budget_ref")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:slo_or_error_budget_ref, "product.slo.site_availability")
             |> put_in([:slo_or_error_budget_scope, :ref], "product.slo.site_availability")
             |> OperationsPosture.new()

    assert String.contains?(message, "must not be a broad product SLO claim")
  end

  test "source-backed not-applicable evidence can close a missing operating dimension" do
    attrs =
      :aitrace_file_export
      |> OperationsPosture.profile!()
      |> OperationsPosture.dump()
      |> Map.put(:slo_or_error_budget_ref, nil)
      |> Map.put(:not_applicable_reason, %{
        slo_or_error_budget_ref: %{
          reason_ref: "source:no-dedicated-product-slo-for-local-file-export",
          source_evidence_ref: "AITrace/lib/aitrace/exporter/file.ex:receipt_authoritative?",
          owner: "aitrace-runtime",
          safe_action: "use-bounded-export-failure-visibility-runbook"
        }
      })

    assert {:ok, profile} = OperationsPosture.new(attrs)
    assert OperationsPosture.missing_operating_dimensions(profile) == [:slo_or_error_budget_ref]
    assert OperationsPosture.not_applicable_evidence_complete?(profile)
    assert profile.slo_or_error_budget_scope == nil
    assert OperationsPosture.slo_or_error_budget_scope_complete?(profile)
    assert OperationsPosture.alert_route_complete?(profile)
  end

  test "metrics-only or traces-only posture cannot close with not-applicable evidence" do
    not_applicable_reason =
      Map.new(OperationsPosture.not_applicable_dimensions(), fn dimension ->
        {dimension,
         %{
           reason_ref: "source:not-applicable",
           source_evidence_ref: "source/#{dimension}",
           owner: "citadel-runtime",
           safe_action: "block-closeout"
         }}
      end)

    attrs =
      :signal_ingress_lineage
      |> OperationsPosture.profile!()
      |> OperationsPosture.dump()
      |> Map.put(:log_ref, nil)
      |> Map.put(:alert_ref, nil)
      |> Map.put(:incident_runbook_ref, nil)
      |> Map.put(:slo_or_error_budget_ref, nil)
      |> Map.put(:not_applicable_reason, not_applicable_reason)

    assert {:error, %ArgumentError{message: message}} = OperationsPosture.new(attrs)
    assert String.contains?(message, "critical observable seams require")
  end

  test "missing not-applicable source evidence fails closed" do
    attrs =
      :trace_publisher_output
      |> OperationsPosture.profile!()
      |> OperationsPosture.dump()
      |> Map.put(:alert_ref, nil)
      |> Map.put(:not_applicable_reason, %{
        alert_ref: %{
          reason_ref: "source:no-alert-needed",
          owner: "citadel-runtime",
          safe_action: "block-closeout"
        }
      })

    assert {:error, %ArgumentError{message: message}} = OperationsPosture.new(attrs)
    assert String.contains?(message, "source_evidence_ref")
  end

  test "profiles fail closed on unsupported severity posture" do
    base = OperationsPosture.profile!(:trace_publisher_output) |> OperationsPosture.dump()

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:severity_mapping, %{observability_overflow: :critical})
             |> OperationsPosture.new()

    assert String.contains?(message, "severity_mapping_severity")

    assert {:error, %ArgumentError{message: message}} =
             base
             |> Map.put(:severity_mapping, %{custom_failure: :p1})
             |> OperationsPosture.new()

    assert String.contains?(message, "severity_mapping_family")
  end
end

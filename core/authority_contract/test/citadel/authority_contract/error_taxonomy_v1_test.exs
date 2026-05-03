defmodule Citadel.AuthorityContract.ErrorTaxonomy.V1Test do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract
  alias Citadel.AuthorityContract.ErrorTaxonomy.V1

  test "normalizes platform error taxonomy entries for public and operator-visible failures" do
    taxonomy =
      sample_attrs()
      |> Map.merge(%{
        error_class: "tenant_scope_error",
        retry_posture: "never",
        redaction_class: "operator_summary"
      })
      |> V1.new!()

    assert AuthorityContract.error_taxonomy_module() == V1
    assert taxonomy.contract_name == "Platform.ErrorTaxonomy.v1"
    assert taxonomy.owner_repo == "citadel"
    assert taxonomy.error_class == :tenant_scope_error
    assert taxonomy.retry_posture == :never
    assert taxonomy.redaction_class == :operator_summary
    assert taxonomy.operator_safe_action == "stop_and_reauthorize"
    assert taxonomy.safe_action_code == "stop_and_reauthorize"
  end

  test "fails closed on missing actor, unknown error class, and unsafe retry posture" do
    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.delete(:system_actor_ref)
      |> V1.new!()
    end

    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.put(:error_class, "invented")
      |> V1.new!()
    end

    assert_raise ArgumentError, fn ->
      sample_attrs()
      |> Map.put(:retry_posture, "retry_forever")
      |> V1.new!()
    end
  end

  defp sample_attrs do
    %{
      contract_name: "Platform.ErrorTaxonomy.v1",
      contract_version: "1.0.0",
      error_taxonomy_id: "error-taxonomy:tenant-scope-denied",
      tenant_ref: "tenant-1",
      installation_ref: "installation-1",
      workspace_ref: "workspace-1",
      project_ref: "project-1",
      environment_ref: "prod",
      system_actor_ref: "system:error-taxonomy",
      resource_ref: "resource:lower-read:attempt",
      authority_packet_ref: "authpkt-tenant-scope",
      permission_decision_ref: "decision-tenant-scope-denied",
      idempotency_key: "error-taxonomy:tenant-scope-denied:1",
      trace_id: "trace:m16:084",
      correlation_id: "corr:m16:084",
      release_manifest_ref: "phase4-v6-milestone16",
      owner_repo: "citadel",
      producer_ref: "Citadel.AuthorityContract.ErrorTaxonomy.V1",
      consumer_ref: "AppKit.Core.ErrorTaxonomyProjection",
      error_code: "tenant_scope_denied",
      error_class: :tenant_scope_error,
      retry_posture: :never,
      operator_safe_action: "stop_and_reauthorize",
      safe_action_code: "stop_and_reauthorize",
      redaction_class: :operator_summary,
      runbook_path: "runbooks/formal_error_taxonomy_coverage.md",
      message: "Lower read request crossed tenant scope.",
      details: %{"scope" => "tenant_ref+installation_ref"},
      redaction: %{"public_fields" => ["error_code"], "operator_fields" => ["message"]}
    }
  end
end

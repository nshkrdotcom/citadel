defmodule Citadel.JidoIntegrationBridgeTest do
  use ExUnit.Case, async: false

  alias Citadel.ActionOutboxEntry
  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.BackoffPolicy
  alias Citadel.BoundaryIntent
  alias Citadel.ExecutionGovernanceCompiler
  alias Citadel.InvocationBridge.ExecutionIntentAdapter
  alias Citadel.InvocationRequest.V2, as: InvocationRequestV2
  alias Citadel.JidoIntegrationBridge
  alias Citadel.JidoIntegrationBridge.BrainInvocationAdapter
  alias Citadel.JidoIntegrationBridge.InvocationDownstream
  alias Citadel.JidoIntegrationBridge.LineageCodec
  alias Citadel.LocalAction
  alias Citadel.StalenessRequirements
  alias Citadel.TopologyIntent
  alias Jido.Integration.V2.ReviewProjection
  alias Jido.Integration.V2.SubmissionAcceptance

  defmodule TestTransport do
    @behaviour Citadel.JidoIntegrationBridge.Transport

    @impl true
    def submit_brain_invocation(invocation) do
      send(Process.get(:ji_bridge_test_pid), {:brain_invocation, invocation})

      {:accepted,
       Jido.Integration.V2.SubmissionAcceptance.new!(%{
         submission_key: invocation.submission_key,
         submission_receipt_ref:
           "submission/#{invocation.submission_identity.invocation_request_id}",
         status: :accepted,
         accepted_at: ~U[2026-04-11 09:00:00Z],
         ledger_version: 2
       })}
    end
  end

  defmodule DuplicateTransport do
    @behaviour Citadel.JidoIntegrationBridge.Transport

    @impl true
    def submit_brain_invocation(invocation) do
      send(Process.get(:ji_bridge_test_pid), {:brain_invocation, invocation, :duplicate})

      {:accepted,
       Jido.Integration.V2.SubmissionAcceptance.new!(%{
         submission_key: invocation.submission_key,
         submission_receipt_ref:
           "submission/#{invocation.submission_identity.invocation_request_id}",
         status: :duplicate,
         accepted_at: ~U[2026-04-11 09:01:00Z],
         ledger_version: 3
       })}
    end
  end

  defmodule RejectedTransport do
    @behaviour Citadel.JidoIntegrationBridge.Transport

    @impl true
    def submit_brain_invocation(invocation) do
      send(Process.get(:ji_bridge_test_pid), {:brain_invocation, invocation, :rejected})

      {:rejected,
       Jido.Integration.V2.SubmissionRejection.new!(%{
         submission_key: invocation.submission_key,
         rejection_family: :scope_unresolvable,
         reason_code: "workspace_ref_unresolved",
         retry_class: :after_redecision,
         redecision_required: true,
         details: %{"logical_workspace_ref" => "workspace://tenant-bridge-1/root"},
         rejected_at: ~U[2026-04-11 09:02:00Z]
       })}
    end
  end

  defmodule AmbientTransport do
    @behaviour Citadel.JidoIntegrationBridge.Transport

    @impl true
    def submit_brain_invocation(invocation) do
      send(Process.get(:ji_bridge_test_pid), {:brain_invocation, invocation, :ambient})
      {:error, :ambient_transport_used}
    end
  end

  setup do
    Process.put(:ji_bridge_test_pid, self())
    :ok
  end

  test "projects execution intent envelopes into durable brain invocations" do
    envelope = envelope_fixture("entry-project")
    invocation = BrainInvocationAdapter.project!(envelope)

    assert invocation.submission_identity.invocation_request_id == "invoke-bridge-1"
    assert invocation.submission_identity.selected_step_id == "step-bridge-1"
    assert invocation.runtime_class == :session
    assert invocation.gateway_request["sandbox"]["level"] == "strict"
    assert invocation.runtime_request["execution_family"] == "process"
    assert invocation.boundary_request["session_mode"] == "attached"
    assert invocation.execution_intent["command"] == "echo"
    assert invocation.execution_intent["args"] == ["hello"]

    citadel_extensions = invocation.extensions["citadel"]

    assert citadel_extensions["authority_persistence_posture"]["persistence_profile_ref"] ==
             "persistence-profile://mickey_mouse"

    assert citadel_extensions["execution_governance_persistence_posture"][
             "persistence_profile_ref"
           ] ==
             "persistence-profile://mickey_mouse"
  end

  test "coerces shared lineage packets through the local choke point" do
    projection =
      ReviewProjection.new!(%{
        schema_version: "review_projection.v1",
        projection: "accepted",
        packet_ref: "jido://v2/review_packet/run/run-1",
        subject: %{
          kind: :run,
          id: "run-1",
          metadata: %{}
        },
        evidence_refs: [],
        governance_refs: [],
        metadata: %{},
        extensions: %{}
      })

    coerced = projection |> ReviewProjection.dump() |> LineageCodec.review_projection!()

    assert coerced == ReviewProjection.new!(ReviewProjection.dump(projection))
  end

  test "delegates to the configured transport through the invocation downstream" do
    envelope = envelope_fixture("entry-submit")

    assert {:accepted, %SubmissionAcceptance{} = acceptance} =
             InvocationDownstream.submit_execution_intent(envelope,
               transport_module: TestTransport
             )

    assert acceptance.submission_receipt_ref == "submission/invoke-bridge-1"

    assert_receive {:brain_invocation, invocation}
    assert invocation.submission_key == acceptance.submission_key
  end

  test "preserves duplicate acceptances from the transport without collapsing them into errors" do
    envelope = envelope_fixture("entry-duplicate")

    assert {:accepted, %SubmissionAcceptance{} = acceptance} =
             InvocationDownstream.submit_execution_intent(envelope,
               transport_module: DuplicateTransport
             )

    assert acceptance.status == :duplicate
    assert acceptance.submission_receipt_ref == "submission/invoke-bridge-1"

    assert_receive {:brain_invocation, invocation, :duplicate}
    assert invocation.submission_key == acceptance.submission_key
  end

  test "propagates typed submission rejections from the transport" do
    envelope = envelope_fixture("entry-rejected")

    assert {:rejected, rejection} =
             InvocationDownstream.submit_execution_intent(envelope,
               transport_module: RejectedTransport
             )

    assert rejection.retry_class == :after_redecision
    assert rejection.reason_code == "workspace_ref_unresolved"

    assert_receive {:brain_invocation, _invocation, :rejected}
  end

  test "rejects ambient application transport for governed execution intent envelopes" do
    previous_transport = Application.get_env(:citadel_jido_integration_bridge, :transport_module)
    :ok = JidoIntegrationBridge.put_transport_module(AmbientTransport)

    on_exit(fn ->
      if is_nil(previous_transport) do
        Application.delete_env(:citadel_jido_integration_bridge, :transport_module)
      else
        Application.put_env(
          :citadel_jido_integration_bridge,
          :transport_module,
          previous_transport
        )
      end
    end)

    envelope = envelope_fixture("entry-ambient")

    assert JidoIntegrationBridge.transport_module(envelope, []) ==
             Citadel.JidoIntegrationBridge.NoopTransport

    assert {:error, :transport_not_configured} =
             InvocationDownstream.submit_execution_intent(envelope)

    refute_received {:brain_invocation, _invocation, :ambient}
  end

  test "projects substrate lineage without host-ingress continuity payloads" do
    envelope =
      envelope_fixture(
        "entry-lineage",
        session_id: "substrate-lineage/session-1",
        request_id: "req-lineage-1",
        invocation_request_id: "invoke-lineage-1"
      )

    invocation = BrainInvocationAdapter.project!(envelope)

    assert invocation.session_id == "substrate-lineage/session-1"
    assert invocation.submission_identity.session_id == "substrate-lineage/session-1"
    assert invocation.submission_identity.request_id == "req-lineage-1"
    assert invocation.submission_identity.invocation_request_id == "invoke-lineage-1"
    assert invocation.extensions["citadel"]["selected_step_id"] == "step-bridge-1"
    refute Map.has_key?(invocation.extensions["citadel"], "host_request_id")
    refute Map.has_key?(invocation.extensions["citadel"], "session_continuity")
    refute Map.has_key?(invocation.extensions["citadel"], "persisted_session_blob")
  end

  defp envelope_fixture(entry_id, request_overrides \\ []) do
    request = invocation_request_fixture(request_overrides)
    entry = outbox_entry(entry_id)
    ExecutionIntentAdapter.project!(request, entry)
  end

  defp invocation_request_fixture(overrides) do
    base_request = %{
      schema_version: 2,
      invocation_request_id: "invoke-bridge-1",
      request_id: "req-bridge-1",
      session_id: "sess-bridge-1",
      tenant_id: "tenant-bridge-1",
      trace_id: "trace-bridge-1",
      actor_id: "actor-bridge-1",
      target_id: "target-bridge-1",
      target_kind: "cli",
      selected_step_id: "step-bridge-1",
      allowed_operations: ["shell.exec"],
      authority_packet:
        AuthorityDecisionV1.new!(%{
          contract_version: "v1",
          decision_id: "dec-bridge-1",
          tenant_id: "tenant-bridge-1",
          request_id: "req-bridge-1",
          policy_version: "policy-bridge-1",
          boundary_class: "hazmat",
          trust_profile: "trusted_operator",
          approval_profile: "manual",
          egress_profile: "restricted",
          workspace_profile: "workspace_attached",
          resource_profile: "balanced",
          decision_hash: String.duplicate("a", 64),
          extensions: %{}
        }),
      boundary_intent:
        BoundaryIntent.new!(%{
          boundary_class: "hazmat",
          trust_profile: "trusted_operator",
          workspace_profile: "workspace_attached",
          resource_profile: "balanced",
          requested_attach_mode: "reuse_existing",
          requested_ttl_ms: 60_000,
          extensions: %{}
        }),
      topology_intent:
        TopologyIntent.new!(%{
          topology_intent_id: "top-bridge-1",
          session_mode: "attached",
          routing_hints: %{
            "execution_intent_family" => "process",
            "execution_intent" => %{
              "contract_version" => "v1",
              "command" => "echo",
              "args" => ["hello"],
              "working_directory" => "/workspace/project",
              "environment" => %{},
              "stdin" => nil,
              "extensions" => %{}
            },
            "downstream_scope" => "process:workspace"
          },
          coordination_mode: "single_target",
          topology_epoch: 3,
          extensions: %{}
        }),
      execution_governance:
        ExecutionGovernanceCompiler.compile!(
          authority_packet_fixture(),
          boundary_intent_fixture(),
          topology_intent_fixture(),
          execution_governance_id: "execgov-bridge-1",
          sandbox_level: "strict",
          sandbox_egress: "restricted",
          sandbox_approvals: "manual",
          acceptable_attestation: ["local-erlexec-weak"],
          allowed_tools: ["bash", "git"],
          file_scope_ref: "workspace://tenant-bridge-1/root",
          file_scope_hint: "/srv/workspaces/tenant-bridge-1",
          logical_workspace_ref: "workspace://tenant-bridge-1/root",
          workspace_mutability: "read_write",
          execution_family: "process",
          placement_intent: "host_local",
          target_kind: "cli",
          allowed_operations: ["shell.exec"],
          effect_classes: ["filesystem", "process"]
        ),
      extensions: %{
        "citadel" => %{
          "execution_intent_family" => "process",
          "execution_intent" => %{
            "contract_version" => "v1",
            "command" => "echo",
            "args" => ["hello"],
            "working_directory" => "/workspace/project",
            "environment" => %{},
            "stdin" => nil,
            "extensions" => %{}
          }
        }
      }
    }

    base_request
    |> Map.merge(Map.new(overrides))
    |> InvocationRequestV2.new!()
  end

  defp authority_packet_fixture do
    AuthorityDecisionV1.new!(%{
      contract_version: "v1",
      decision_id: "dec-bridge-1",
      tenant_id: "tenant-bridge-1",
      request_id: "req-bridge-1",
      policy_version: "policy-bridge-1",
      boundary_class: "hazmat",
      trust_profile: "trusted_operator",
      approval_profile: "manual",
      egress_profile: "restricted",
      workspace_profile: "workspace_attached",
      resource_profile: "balanced",
      decision_hash: String.duplicate("a", 64),
      extensions: %{}
    })
  end

  defp boundary_intent_fixture do
    BoundaryIntent.new!(%{
      boundary_class: "hazmat",
      trust_profile: "trusted_operator",
      workspace_profile: "workspace_attached",
      resource_profile: "balanced",
      requested_attach_mode: "reuse_existing",
      requested_ttl_ms: 60_000,
      extensions: %{}
    })
  end

  defp topology_intent_fixture do
    TopologyIntent.new!(%{
      topology_intent_id: "top-bridge-1",
      session_mode: "attached",
      routing_hints: %{
        "execution_intent_family" => "process",
        "execution_intent" => %{
          "contract_version" => "v1",
          "command" => "echo",
          "args" => ["hello"],
          "working_directory" => "/workspace/project",
          "environment" => %{},
          "stdin" => nil,
          "extensions" => %{}
        },
        "downstream_scope" => "process:workspace"
      },
      coordination_mode: "single_target",
      topology_epoch: 3,
      extensions: %{}
    })
  end

  defp outbox_entry(entry_id) do
    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: entry_id,
      causal_group_id: "group-bridge-1",
      action:
        LocalAction.new!(%{
          action_kind: "submit_invocation",
          payload: %{"request_id" => "req-bridge-1"},
          extensions: %{}
        }),
      inserted_at: ~U[2026-04-11 09:00:00Z],
      replay_status: :pending,
      attempt_count: 0,
      max_attempts: 3,
      backoff_policy:
        BackoffPolicy.new!(%{
          strategy: :fixed,
          base_delay_ms: 10,
          max_delay_ms: 10,
          linear_step_ms: nil,
          multiplier: nil,
          jitter_mode: :none,
          jitter_window_ms: 0,
          extensions: %{}
        }),
      next_attempt_at: nil,
      last_error_code: nil,
      dead_letter_reason: nil,
      ordering_mode: :strict,
      staleness_mode: :requires_check,
      staleness_requirements:
        StalenessRequirements.new!(%{
          snapshot_seq: 1,
          policy_epoch: 1,
          topology_epoch: nil,
          scope_catalog_epoch: nil,
          service_admission_epoch: nil,
          project_binding_epoch: nil,
          boundary_epoch: nil,
          required_binding_id: nil,
          required_boundary_ref: nil,
          extensions: %{}
        }),
      extensions: %{}
    })
  end
end

defmodule Citadel.InvocationBridgeTest do
  use ExUnit.Case, async: true

  alias Citadel.ActionOutboxEntry
  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.BackoffPolicy
  alias Citadel.BoundaryIntent
  alias Citadel.BridgeCircuitPolicy
  alias Citadel.ExecutionGovernanceCompiler
  alias Citadel.InvocationBridge
  alias Citadel.InvocationBridge.ExecutionIntentAdapter
  alias Citadel.InvocationRequest, as: InvocationRequestV1
  alias Citadel.InvocationRequest.V2, as: InvocationRequestV2
  alias Citadel.LocalAction
  alias Citadel.StalenessRequirements
  alias Citadel.TopologyIntent
  alias Jido.Integration.V2.SubmissionAcceptance
  alias Jido.Integration.V2.SubmissionRejection

  defmodule Downstream do
    def submit_execution_intent(envelope) do
      send(Process.get(:invocation_bridge_test_pid), {:submitted, envelope})

      {:accepted,
       Jido.Integration.V2.SubmissionAcceptance.new!(%{
         submission_key:
           Citadel.InvocationBridgeTest.submission_key_for!("bridge/#{envelope.entry_id}"),
         submission_receipt_ref: "receipt:#{envelope.entry_id}",
         status: :accepted,
         accepted_at: ~U[2026-04-11 06:00:00Z],
         ledger_version: 1
       })}
    end
  end

  defmodule FailingDownstream do
    def submit_execution_intent(_envelope), do: {:error, :timeout}
  end

  defmodule CountingFailingDownstream do
    def submit_execution_intent(envelope) do
      send(Process.get(:invocation_bridge_test_pid), {:submit_attempt, envelope.entry_id})
      {:error, :timeout}
    end
  end

  defmodule LegacyReceiptDownstream do
    def submit_execution_intent(_envelope), do: {:ok, "receipt:legacy"}
  end

  defmodule RejectedDownstream do
    def submit_execution_intent(envelope) do
      {:rejected,
       Jido.Integration.V2.SubmissionRejection.new!(%{
         submission_key:
           Citadel.InvocationBridgeTest.submission_key_for!("bridge/#{envelope.entry_id}"),
         rejection_family: :scope_unresolvable,
         reason_code: "workspace_ref_unresolved",
         retry_class: :after_redecision,
         redecision_required: true,
         details: %{"logical_workspace_ref" => "workspace://project/main"},
         rejected_at: ~U[2026-04-11 06:05:00Z]
       })}
    end
  end

  defmodule DuplicateDownstream do
    def submit_execution_intent(envelope) do
      {:accepted,
       Jido.Integration.V2.SubmissionAcceptance.new!(%{
         submission_key:
           Citadel.InvocationBridgeTest.submission_key_for!("bridge/#{envelope.entry_id}"),
         submission_receipt_ref: "receipt:#{envelope.entry_id}",
         status: :duplicate,
         accepted_at: ~U[2026-04-11 06:06:00Z],
         ledger_version: 2
       })}
    end
  end

  setup do
    Process.put(:invocation_bridge_test_pid, self())
    :ok
  end

  test "projects the explicit lower execution handoff and returns typed lower-gateway acceptance" do
    bridge = InvocationBridge.new!(downstream: Downstream)
    request = invocation_request()
    entry = outbox_entry("entry-1")

    assert {:accepted, %SubmissionAcceptance{} = acceptance, bridge_after_submit} =
             InvocationBridge.submit(bridge, request, entry)

    assert acceptance.submission_receipt_ref == "receipt:entry-1"
    assert_receive {:submitted, envelope}
    assert envelope.entry_id == "entry-1"
    assert envelope.causal_group_id == entry.causal_group_id
    assert envelope.invocation_schema_version == 2
    assert envelope.execution_intent_family == "http"
    assert envelope.authority_packet == request.authority_packet
    assert envelope.execution_governance == request.execution_governance
    assert envelope.extensions["selected_step_id"] == "step-1"
    assert bridge_after_submit.state_ref == bridge.state_ref
  end

  test "rejects unsupported invocation schema versions at bridge entry" do
    bridge = InvocationBridge.new!(downstream: Downstream)

    request = %{invocation_request() | schema_version: 3}

    assert {:error, :unsupported_schema_version, ^bridge} =
             InvocationBridge.submit(bridge, request, outbox_entry("entry-2"))

    refute_receive {:submitted, _envelope}
  end

  test "defaults to v2-only invocation request schema versions" do
    bridge = InvocationBridge.new!(downstream: Downstream)

    assert InvocationBridge.supported_invocation_request_schema_versions() == [
             InvocationRequestV2.schema_version()
           ]

    assert bridge.supported_invocation_request_schema_versions == [
             InvocationRequestV2.schema_version()
           ]
  end

  test "does not accept legacy invocation request structs at bridge entry" do
    bridge = InvocationBridge.new!(downstream: Downstream)

    assert_raise FunctionClauseError, fn ->
      apply(InvocationBridge, :submit, [
        bridge,
        legacy_invocation_request(),
        outbox_entry("entry-v1")
      ])
    end

    refute_receive {:submitted, _envelope}
  end

  test "adapter carries invocation schema version and refuses legacy projections" do
    request = invocation_request()
    envelope = ExecutionIntentAdapter.project!(request, outbox_entry("entry-adapter"))

    assert envelope.invocation_schema_version == InvocationRequestV2.schema_version()
    assert envelope.invocation_request_id == request.invocation_request_id

    assert_raise FunctionClauseError, fn ->
      apply(ExecutionIntentAdapter, :project!, [
        legacy_invocation_request(),
        outbox_entry("entry-adapter-v1")
      ])
    end
  end

  test "does not deduplicate locally by entry_id when the same request is retried" do
    state_name = unique_name(:invocation_bridge_state)
    request = invocation_request()
    entry = outbox_entry("entry-shared")

    bridge =
      InvocationBridge.new!(
        downstream: Downstream,
        state_name: state_name
      )

    assert {:accepted, %SubmissionAcceptance{} = first_acceptance, _bridge} =
             InvocationBridge.submit(bridge, request, entry)

    assert first_acceptance.submission_receipt_ref == "receipt:entry-shared"
    assert_receive {:submitted, _first_envelope}

    fresh_bridge =
      InvocationBridge.new!(
        downstream: Downstream,
        state_name: state_name
      )

    assert {:accepted, %SubmissionAcceptance{} = second_acceptance, _fresh_bridge} =
             InvocationBridge.submit(fresh_bridge, request, entry)

    assert second_acceptance.submission_receipt_ref == "receipt:entry-shared"
    assert_receive {:submitted, _second_envelope}
  end

  test "rejects explicit invocation schema transition windows without a migration policy" do
    assert_raise ArgumentError, fn ->
      InvocationBridge.new!(
        downstream: Downstream,
        supported_invocation_request_schema_versions: [2, 3]
      )
    end

    bridge =
      InvocationBridge.new!(
        downstream: Downstream,
        supported_invocation_request_schema_versions: [InvocationRequestV2.schema_version()]
      )

    request = %{invocation_request() | schema_version: 3}

    assert {:error, :unsupported_schema_version, ^bridge} =
             InvocationBridge.submit(bridge, request, outbox_entry("entry-transition"))

    refute_receive {:submitted, _envelope}
  end

  test "surfaces typed lower-gateway rejections without collapsing them into transport errors" do
    bridge = InvocationBridge.new!(downstream: RejectedDownstream)

    assert {:rejected, %SubmissionRejection{} = rejection, _bridge} =
             InvocationBridge.submit(bridge, invocation_request(), outbox_entry("entry-rejected"))

    assert rejection.retry_class == :after_redecision
    assert rejection.reason_code == "workspace_ref_unresolved"
  end

  test "preserves duplicate acceptances so replay-safe submission stays synchronous and typed" do
    bridge = InvocationBridge.new!(downstream: DuplicateDownstream)

    assert {:accepted, %SubmissionAcceptance{} = acceptance, _bridge} =
             InvocationBridge.submit(
               bridge,
               invocation_request(),
               outbox_entry("entry-duplicate")
             )

    assert acceptance.status == :duplicate
    assert acceptance.submission_receipt_ref == "receipt:entry-duplicate"
  end

  test "does not retry inline when the downstream transport errors" do
    bridge = InvocationBridge.new!(downstream: CountingFailingDownstream)

    assert {:error, :timeout, _bridge} =
             InvocationBridge.submit(bridge, invocation_request(), outbox_entry("entry-timeout"))

    assert_receive {:submit_attempt, "entry-timeout"}
    refute_receive {:submit_attempt, _}
  end

  test "rejects legacy receipt-only success tuples so retry ownership stays upstream" do
    bridge = InvocationBridge.new!(downstream: LegacyReceiptDownstream)

    assert {:error, :legacy_ok_result, _bridge} =
             InvocationBridge.submit(bridge, invocation_request(), outbox_entry("entry-legacy"))
  end

  test "fast-fails once the downstream circuit is open" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    bridge =
      InvocationBridge.new!(
        downstream: FailingDownstream,
        circuit_policy:
          BridgeCircuitPolicy.new!(%{
            failure_threshold: 2,
            window_ms: 100,
            cooldown_ms: 50,
            half_open_max_inflight: 1,
            scope_key_mode: "downstream_scope",
            extensions: %{}
          }),
        now_ms_fun: fn -> Agent.get(clock, & &1) end
      )

    assert {:error, :timeout, bridge} =
             InvocationBridge.submit(bridge, invocation_request(), outbox_entry("entry-3"))

    assert {:error, :timeout, bridge} =
             InvocationBridge.submit(bridge, invocation_request(), outbox_entry("entry-4"))

    assert {:error, :circuit_open, _bridge} =
             InvocationBridge.submit(bridge, invocation_request(), outbox_entry("entry-5"))
  end

  test "recreates bridge state by name after the underlying state process dies" do
    bridge =
      InvocationBridge.new!(
        downstream: Downstream,
        state_name: unique_name(:invocation_bridge_state_restart)
      )

    state_server =
      bridge
      |> Map.fetch!(:state_ref)
      |> Citadel.BridgeState.server()

    Process.exit(state_server, :kill)
    wait_until(fn -> not Process.alive?(state_server) end)

    assert {:accepted, %SubmissionAcceptance{}, _bridge} =
             InvocationBridge.submit(
               bridge,
               invocation_request(),
               outbox_entry("entry-restarted")
             )

    assert_receive {:submitted, envelope}
    assert envelope.entry_id == "entry-restarted"
  end

  defp invocation_request do
    InvocationRequestV2.new!(%{
      schema_version: 2,
      invocation_request_id: "invoke-1",
      request_id: "req-1",
      session_id: "sess-1",
      tenant_id: "tenant-123",
      trace_id: "trace-1",
      actor_id: "actor-1",
      target_id: "target-1",
      target_kind: "http",
      selected_step_id: "step-1",
      allowed_operations: ["fetch"],
      authority_packet:
        AuthorityDecisionV1.new!(%{
          contract_version: "v1",
          decision_id: "dec-1",
          tenant_id: "tenant-123",
          request_id: "req-1",
          policy_version: "policy-1",
          boundary_class: "workspace_session",
          trust_profile: "trusted_operator",
          approval_profile: "approval_optional",
          egress_profile: "restricted",
          workspace_profile: "project_workspace",
          resource_profile: "standard",
          decision_hash: "c941cfcdae563437fb6f200c3b7abecdc70c5a23273d81301c86e2364ead04e9",
          extensions: %{}
        }),
      boundary_intent:
        BoundaryIntent.new!(%{
          boundary_class: "workspace_session",
          trust_profile: "trusted_operator",
          workspace_profile: "project_workspace",
          resource_profile: "standard",
          requested_attach_mode: "fresh_or_reuse",
          requested_ttl_ms: 30_000,
          extensions: %{}
        }),
      topology_intent:
        TopologyIntent.new!(%{
          topology_intent_id: "top-1",
          session_mode: "attached",
          routing_hints: %{
            "execution_intent_family" => "http",
            "execution_intent" => %{
              "contract_version" => "v1",
              "method" => "POST",
              "url" => "https://example.test/invoke",
              "headers" => %{"content-type" => "application/json"},
              "body" => %{"request" => "payload"},
              "extensions" => %{}
            },
            "downstream_scope" => "http:example.test"
          },
          coordination_mode: "single_target",
          topology_epoch: 1,
          extensions: %{}
        }),
      execution_governance:
        ExecutionGovernanceCompiler.compile!(
          authority_packet(),
          boundary_intent(),
          topology_intent(),
          execution_governance_id: "execgov-invocation-bridge-1",
          sandbox_level: "standard",
          sandbox_egress: "restricted",
          sandbox_approvals: "auto",
          acceptable_attestation: ["local-erlexec-weak"],
          allowed_tools: ["fetch_http"],
          file_scope_ref: "workspace://project/main",
          logical_workspace_ref: "workspace://project/main",
          workspace_mutability: "read_write",
          execution_family: "http",
          placement_intent: "host_local",
          target_kind: "http",
          allowed_operations: ["fetch"],
          effect_classes: ["network_http"]
        ),
      extensions: %{
        "citadel" => %{
          "execution_intent_family" => "http",
          "execution_intent" => %{
            "contract_version" => "v1",
            "method" => "POST",
            "url" => "https://example.test/invoke",
            "headers" => %{"content-type" => "application/json"},
            "body" => %{"request" => "payload"},
            "extensions" => %{}
          }
        }
      }
    })
  end

  defp legacy_invocation_request do
    request = invocation_request()

    InvocationRequestV1.new!(%{
      schema_version: InvocationRequestV1.schema_version(),
      invocation_request_id: request.invocation_request_id,
      request_id: request.request_id,
      session_id: request.session_id,
      tenant_id: request.tenant_id,
      trace_id: request.trace_id,
      actor_id: request.actor_id,
      target_id: request.target_id,
      target_kind: request.target_kind,
      selected_step_id: request.selected_step_id,
      allowed_operations: request.allowed_operations,
      authority_packet: request.authority_packet,
      boundary_intent: request.boundary_intent,
      topology_intent: request.topology_intent,
      extensions: request.extensions
    })
  end

  defp authority_packet do
    AuthorityDecisionV1.new!(%{
      contract_version: "v1",
      decision_id: "dec-1",
      tenant_id: "tenant-123",
      request_id: "req-1",
      policy_version: "policy-1",
      boundary_class: "workspace_session",
      trust_profile: "trusted_operator",
      approval_profile: "approval_optional",
      egress_profile: "restricted",
      workspace_profile: "project_workspace",
      resource_profile: "standard",
      decision_hash: "c941cfcdae563437fb6f200c3b7abecdc70c5a23273d81301c86e2364ead04e9",
      extensions: %{}
    })
  end

  defp boundary_intent do
    BoundaryIntent.new!(%{
      boundary_class: "workspace_session",
      trust_profile: "trusted_operator",
      workspace_profile: "project_workspace",
      resource_profile: "standard",
      requested_attach_mode: "fresh_or_reuse",
      requested_ttl_ms: 30_000,
      extensions: %{}
    })
  end

  defp topology_intent do
    TopologyIntent.new!(%{
      topology_intent_id: "top-1",
      session_mode: "attached",
      routing_hints: %{
        "execution_intent_family" => "http",
        "execution_intent" => %{
          "contract_version" => "v1",
          "method" => "POST",
          "url" => "https://example.test/invoke",
          "headers" => %{"content-type" => "application/json"},
          "body" => %{"request" => "payload"},
          "extensions" => %{}
        },
        "downstream_scope" => "http:example.test"
      },
      coordination_mode: "single_target",
      topology_epoch: 1,
      extensions: %{}
    })
  end

  defp outbox_entry(entry_id) do
    ActionOutboxEntry.new!(%{
      schema_version: 1,
      entry_id: entry_id,
      causal_group_id: "group-1",
      action:
        LocalAction.new!(%{
          action_kind: "submit_invocation",
          payload: %{"request_id" => "req-1"},
          extensions: %{}
        }),
      inserted_at: ~U[2026-04-10 10:00:00Z],
      replay_status: :pending,
      durable_receipt_ref: nil,
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

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end

  def submission_key_for!(seed) when is_binary(seed) do
    "sha256:" <> (:crypto.hash(:sha256, seed) |> Base.encode16(case: :lower))
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      do_wait_until(fun, attempts)
    end
  end

  defp do_wait_until(fun, attempts) when attempts > 0 do
    Process.sleep(10)
    wait_until(fun, attempts - 1)
  end
end

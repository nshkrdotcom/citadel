defmodule Citadel.HostIngressTest do
  use ExUnit.Case, async: false

  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.ExecutionGovernance.V1, as: ExecutionGovernanceV1
  alias Citadel.HostIngress
  alias Citadel.HostIngress.Accepted
  alias Citadel.HostIngress.InvocationCompiler
  alias Citadel.HostIngress.InvocationPayload
  alias Citadel.HostIngress.RunRequest
  alias Citadel.IntentEnvelope
  alias Citadel.Kernel.KernelSnapshot
  alias Citadel.Kernel.SessionDirectory
  alias Citadel.Kernel.SessionServer
  alias Citadel.Kernel.ServiceCatalog
  alias Citadel.Kernel.BoundaryLeaseTracker
  alias Citadel.Kernel.SignalIngress
  alias Citadel.TopologyIntent
  alias Citadel.BoundaryIntent
  alias Citadel.InvocationRequest.V2, as: InvocationRequestV2
  alias Jido.Integration.V2.SubmissionAcceptance

  defmodule TestSignalSource do
    @behaviour Citadel.Ports.SignalSource

    @impl true
    def normalize_signal(observation), do: {:ok, observation}
  end

  setup do
    kernel_snapshot_name = unique_name(:kernel_snapshot)
    session_directory_name = unique_name(:session_directory)
    service_catalog_name = unique_name(:service_catalog)
    boundary_tracker_name = unique_name(:boundary_tracker)
    signal_ingress_name = unique_name(:signal_ingress)
    invocation_supervisor_name = unique_name(:invocation_supervisor)
    projection_supervisor_name = unique_name(:projection_supervisor)
    local_supervisor_name = unique_name(:local_supervisor)

    start_supervised!(
      {KernelSnapshot, name: kernel_snapshot_name, policy_version: "policy-v1", policy_epoch: 7}
    )

    start_supervised!(
      {SessionDirectory, name: session_directory_name, kernel_snapshot: kernel_snapshot_name}
    )

    start_supervised!(
      {ServiceCatalog, name: service_catalog_name, kernel_snapshot: kernel_snapshot_name}
    )

    start_supervised!(
      {BoundaryLeaseTracker, name: boundary_tracker_name, kernel_snapshot: kernel_snapshot_name}
    )

    start_supervised!({Task.Supervisor, name: invocation_supervisor_name, max_children: 4})
    start_supervised!({Task.Supervisor, name: projection_supervisor_name, max_children: 4})
    start_supervised!({Task.Supervisor, name: local_supervisor_name, max_children: 4})

    start_supervised!(
      {SignalIngress,
       name: signal_ingress_name,
       session_directory: session_directory_name,
       signal_source: TestSignalSource}
    )

    {:ok,
     kernel_snapshot: kernel_snapshot_name,
     session_directory: session_directory_name,
     service_catalog: service_catalog_name,
     boundary_tracker: boundary_tracker_name,
     signal_ingress: signal_ingress_name,
     invocation_supervisor: invocation_supervisor_name,
     projection_supervisor: projection_supervisor_name,
     local_supervisor: local_supervisor_name}
  end

  test "pure compiler projects structured ingress into invocation work" do
    assert {:ok, compiled} =
             InvocationCompiler.compile(valid_envelope(), request_context("req-compiler"), [
               policy_pack()
             ])

    assert compiled.outbox_entry.action.action_kind == InvocationPayload.action_kind()

    request = InvocationPayload.decode!(compiled.outbox_entry.action.payload)
    assert %InvocationRequestV2{} = request
    assert request.request_id == "req-compiler"
    assert request.selected_step_id == "step/req-compiler/compile.workspace"
    assert request.allowed_operations == ["shell.exec"]
    assert %AuthorityDecisionV1{} = request.authority_packet
    assert %BoundaryIntent{} = request.boundary_intent
    assert %TopologyIntent{} = request.topology_intent
    assert %ExecutionGovernanceV1{} = request.execution_governance
    assert request.extensions["citadel"]["execution_intent"]["command"] == "echo"
  end

  test "public host ingress enqueues durable invocation work through a live session owner", env do
    session_id = "sess-live-host-ingress"
    test_pid = self()

    {:ok, session_server} =
      SessionServer.start_link(
        name: unique_name(:session_server),
        session_id: session_id,
        session_directory: env.session_directory,
        kernel_snapshot: env.kernel_snapshot,
        boundary_lease_tracker: env.boundary_tracker,
        service_catalog: env.service_catalog,
        signal_ingress: env.signal_ingress,
        invocation_supervisor: env.invocation_supervisor,
        projection_supervisor: env.projection_supervisor,
        local_supervisor: env.local_supervisor,
        invocation_handler: fn payload, attempt_entry ->
          request = InvocationPayload.decode!(payload)
          send(test_pid, {:invocation_request, request, attempt_entry})

          {:accepted,
           SubmissionAcceptance.new!(%{
             submission_key: "sha256:#{String.duplicate("a", 64)}",
             submission_receipt_ref: "submission/#{request.request_id}",
             status: :accepted,
             accepted_at: ~U[2026-04-12 08:00:00Z],
             ledger_version: 1
           })}
        end
      )

    ingress =
      HostIngress.new!(
        session_directory: env.session_directory,
        policy_packs: [policy_pack()],
        lookup_session: fn ^session_id -> {:ok, session_server} end
      )

    assert {:accepted, %Accepted{} = accepted} =
             HostIngress.submit_envelope(
               ingress,
               valid_envelope(),
               request_context("req-live", session_id)
             )

    assert accepted.lifecycle_event == :live_owner
    assert accepted.entry_id == "submit/req-live"

    assert_receive {:invocation_request, request, attempt_entry}
    assert request.request_id == "req-live"
    assert attempt_entry.entry_id == "submit/req-live"

    wait_until(fn ->
      case SessionDirectory.resolve_outbox_entry(env.session_directory, attempt_entry.entry_id) do
        {:ok, %{entry: entry}} ->
          entry.replay_status == :submission_accepted and
            entry.submission_receipt_ref == "submission/req-live"

        _other ->
          false
      end
    end)
  end

  test "public host ingress returns synchronous rejection for unplannable structured ingress",
       env do
    ingress =
      HostIngress.new!(
        session_directory: env.session_directory,
        policy_packs: [policy_pack()]
      )

    assert {:rejected, rejection} =
             HostIngress.submit_envelope(
               ingress,
               unplannable_envelope(),
               request_context("req-rejected", "sess-rejected")
             )

    assert rejection.reason_code == "boundary_reuse_requires_attached_session"

    assert {:ok, persisted_blob} =
             SessionDirectory.fetch_persisted_blob(env.session_directory, "sess-rejected")

    assert persisted_blob.envelope.last_rejection.reason_code ==
             "boundary_reuse_requires_attached_session"
  end

  test "higher-order run requests lower through the same structured ingress compiler" do
    assert {:ok, compiled} =
             HostIngress.compile_run_request(
               higher_order_run_request(),
               request_context("req-higher-order"),
               [policy_pack()]
             )

    request = InvocationPayload.decode!(compiled.outbox_entry.action.payload)

    assert %RunRequest{} =
             higher_order_run_request()
             |> RunRequest.new!()

    assert request.request_id == "req-higher-order"
    assert request.selected_step_id == "step/req-higher-order/compile.workspace"
    assert request.allowed_operations == ["shell.exec"]
    assert request.authority_packet.boundary_class == "workspace_session"
    assert request.topology_intent.session_mode == "attached"
    assert request.extensions["citadel"]["execution_intent"]["command"] == "echo"

    assert request.extensions["citadel"]["execution_envelope"]["submission_dedupe_key"] ==
             "tenant-cb:work-1:compile.workspace:1"
  end

  test "accepted results reject existing atoms outside the host ingress vocabulary" do
    attrs = %{
      request_id: "req-bounded-accepted",
      trace_id: "trace-bounded-accepted",
      ingress_path: "ok",
      lifecycle_event: "live_owner"
    }

    assert_raise ArgumentError,
                 ~r/host ingress acceptance :ingress_path string value must be one of/,
                 fn -> Accepted.new!(attrs) end

    attrs = %{
      request_id: "req-bounded-lifecycle",
      trace_id: "trace-bounded-lifecycle",
      ingress_path: "direct_intent_envelope",
      lifecycle_event: "ok"
    }

    assert_raise ArgumentError,
                 ~r/host ingress acceptance :lifecycle_event string value must be one of/,
                 fn -> Accepted.new!(attrs) end
  end

  test "run request enum strings stay inside bounded vocabularies" do
    request =
      higher_order_run_request()
      |> put_in([:scope, :preference], "preferred")
      |> put_in([:constraints, :boundary_requirement], "fresh_only")
      |> put_in([:target, :session_mode_preference], "detached")
      |> put_in([:target, :coordination_mode_preference], "local_only")
      |> RunRequest.new!()

    assert request.scope.preference == :preferred
    assert request.constraints.boundary_requirement == :fresh_only
    assert request.target.session_mode_preference == :detached
    assert request.target.coordination_mode_preference == :local_only

    assert_raise ArgumentError,
                 ~r/run request target.session_mode_preference must be one of/,
                 fn ->
                   higher_order_run_request()
                   |> put_in([:target, :session_mode_preference], "ok")
                   |> RunRequest.new!()
                 end
  end

  test "public host ingress persists higher-order run requests through the durable path", env do
    session_id = "sess-live-run-request"
    test_pid = self()

    {:ok, session_server} =
      SessionServer.start_link(
        name: unique_name(:session_server_run_request),
        session_id: session_id,
        session_directory: env.session_directory,
        kernel_snapshot: env.kernel_snapshot,
        boundary_lease_tracker: env.boundary_tracker,
        service_catalog: env.service_catalog,
        signal_ingress: env.signal_ingress,
        invocation_supervisor: env.invocation_supervisor,
        projection_supervisor: env.projection_supervisor,
        local_supervisor: env.local_supervisor,
        invocation_handler: fn payload, attempt_entry ->
          request = InvocationPayload.decode!(payload)
          send(test_pid, {:run_request_invocation, request, attempt_entry})

          {:accepted,
           SubmissionAcceptance.new!(%{
             submission_key: "sha256:#{String.duplicate("b", 64)}",
             submission_receipt_ref: "submission/#{request.request_id}",
             status: :accepted,
             accepted_at: ~U[2026-04-13 01:00:00Z],
             ledger_version: 1
           })}
        end
      )

    ingress =
      HostIngress.new!(
        session_directory: env.session_directory,
        policy_packs: [policy_pack()],
        lookup_session: fn ^session_id -> {:ok, session_server} end
      )

    assert {:accepted, %Accepted{} = accepted} =
             HostIngress.submit_run_request(
               ingress,
               higher_order_run_request(),
               request_context("req-run-request", session_id)
             )

    assert accepted.entry_id == "submit/req-run-request"
    assert accepted.lifecycle_event == :live_owner

    assert_receive {:run_request_invocation, request, attempt_entry}
    assert request.request_id == "req-run-request"
    assert request.extensions["citadel"]["execution_intent_family"] == "process"
    assert attempt_entry.entry_id == "submit/req-run-request"
  end

  defp valid_envelope do
    IntentEnvelope.new!(%{
      intent_envelope_id: "intent/compile-workspace",
      scope_selectors: [
        %{
          scope_kind: "workspace",
          scope_id: "workspace/main",
          workspace_root: "/workspace/main",
          environment: "dev",
          preference: :required,
          extensions: %{}
        }
      ],
      desired_outcome: %{
        outcome_kind: :invoke_capability,
        requested_capabilities: ["compile.workspace"],
        result_kind: "workspace_patch",
        subject_selectors: ["primary"],
        extensions: %{}
      },
      constraints: %{
        boundary_requirement: :fresh_or_reuse,
        allowed_boundary_classes: ["workspace_session"],
        allowed_service_ids: ["svc.compiler"],
        forbidden_service_ids: [],
        max_steps: 1,
        review_required: false,
        extensions: %{}
      },
      risk_hints: [
        %{
          risk_code: "writes_workspace",
          severity: :medium,
          requires_governance: false,
          extensions: %{}
        }
      ],
      success_criteria: [
        %{
          criterion_kind: :completion,
          metric: "workspace_patch_applied",
          target: %{"status" => "accepted"},
          required: true,
          extensions: %{}
        }
      ],
      target_hints: [
        %{
          target_kind: "workspace",
          preferred_target_id: "workspace/main",
          preferred_service_id: "svc.compiler",
          preferred_boundary_class: "workspace_session",
          session_mode_preference: :attached,
          coordination_mode_preference: :single_target,
          routing_tags: ["primary"],
          extensions: %{}
        }
      ],
      plan_hints: %{
        candidate_steps: [
          %{
            step_kind: "capability",
            capability_id: "compile.workspace",
            allowed_operations: ["shell.exec"],
            extensions: %{
              "citadel" => %{
                "execution_intent_family" => "process",
                "execution_intent" => %{
                  "contract_version" => "v1",
                  "command" => "echo",
                  "args" => ["compile"],
                  "working_directory" => "/workspace/main",
                  "environment" => %{},
                  "stdin" => nil,
                  "extensions" => %{}
                },
                "allowed_tools" => ["bash", "git"],
                "effect_classes" => ["filesystem", "process"],
                "workspace_mutability" => "read_write",
                "placement_intent" => "host_local",
                "downstream_scope" => "process:workspace"
              }
            }
          }
        ],
        preferred_targets: [],
        preferred_topology: nil,
        budget_hints: nil,
        extensions: %{}
      },
      resolution_provenance: %{
        source_kind: "test",
        resolver_kind: nil,
        resolver_version: nil,
        prompt_version: nil,
        policy_version: nil,
        confidence: 1.0,
        ambiguity_flags: [],
        raw_input_refs: [],
        raw_input_hashes: [],
        extensions: %{}
      },
      extensions: %{"citadel" => %{}}
    })
  end

  defp unplannable_envelope do
    valid_envelope()
    |> IntentEnvelope.dump()
    |> put_in([:constraints, :boundary_requirement], :reuse_existing)
    |> put_in([:target_hints, Access.at(0), :session_mode_preference], :detached)
    |> IntentEnvelope.new!()
  end

  defp request_context(request_id, session_id \\ "sess-compiler") do
    %{
      request_id: request_id,
      session_id: session_id,
      tenant_id: "tenant-1",
      actor_id: "actor-1",
      trace_id: "trace/#{request_id}",
      trace_origin: :host,
      host_request_id: "host/#{request_id}",
      environment: "dev",
      policy_epoch: 7,
      metadata_keys: ["source"]
    }
  end

  defp policy_pack do
    %{
      pack_id: "default",
      policy_version: "policy-v1",
      policy_epoch: 7,
      priority: 0,
      selector: %{
        tenant_ids: [],
        scope_kinds: [],
        environments: [],
        default?: true,
        extensions: %{}
      },
      profiles: %{
        trust_profile: "baseline",
        approval_profile: "standard",
        egress_profile: "restricted",
        workspace_profile: "workspace",
        resource_profile: "standard",
        boundary_class: "workspace_session",
        extensions: %{}
      },
      rejection_policy: %{
        denial_audit_reason_codes: ["policy_denied", "approval_missing"],
        derived_state_reason_codes: ["planning_failed"],
        runtime_change_reason_codes: ["scope_unavailable", "service_hidden", "boundary_stale"],
        governance_change_reason_codes: ["approval_missing"],
        extensions: %{}
      },
      extensions: %{}
    }
  end

  defp higher_order_run_request do
    %{
      run_request_id: "run-request/compile.workspace",
      capability_id: "compile.workspace",
      objective: "Compile the current workspace capability request",
      result_kind: "workspace_patch",
      scope: %{
        scope_kind: "workspace",
        scope_id: "workspace/main",
        workspace_root: "/workspace/main",
        environment: "dev",
        preference: :required
      },
      target: %{
        target_kind: "workspace",
        target_id: "workspace/main",
        service_id: "svc.compiler",
        boundary_class: "workspace_session",
        session_mode_preference: :attached,
        coordination_mode_preference: :single_target,
        routing_tags: ["primary"]
      },
      constraints: %{
        boundary_requirement: :fresh_or_reuse,
        max_steps: 1,
        review_required: false
      },
      execution: %{
        execution_intent_family: "process",
        execution_intent: %{
          "contract_version" => "v1",
          "command" => "echo",
          "args" => ["compile"],
          "working_directory" => "/workspace/main",
          "environment" => %{},
          "stdin" => nil,
          "extensions" => %{}
        },
        allowed_operations: ["shell.exec"],
        allowed_tools: ["bash", "git"],
        effect_classes: ["filesystem", "process"],
        workspace_mutability: "read_write",
        placement_intent: "host_local",
        downstream_scope: "process:workspace"
      },
      risk_hints: [
        %{
          risk_code: "writes_workspace",
          severity: :medium,
          requires_governance: false,
          extensions: %{}
        }
      ],
      success_criteria: [
        %{
          criterion_kind: :completion,
          metric: "workspace_patch_applied",
          target: %{"status" => "accepted"},
          required: true,
          extensions: %{}
        }
      ],
      resolution_provenance: %{
        source_kind: "mezzanine",
        confidence: 1.0,
        ambiguity_flags: [],
        raw_input_refs: [],
        raw_input_hashes: [],
        extensions: %{}
      },
      extensions: %{
        "submission_dedupe_key" => "tenant-cb:work-1:compile.workspace:1",
        "mezzanine" => %{
          "work_object_id" => "work-1",
          "run_id" => "run-1"
        }
      }
    }
  end

  defp unique_name(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition did not become true in time")
  end
end

defmodule Citadel.GovernanceSubstrateIngressTest do
  use ExUnit.Case, async: true

  alias Citadel.ActionOutboxEntry
  alias Citadel.AuthorityContract.AuthorityDecision.V1, as: AuthorityDecisionV1
  alias Citadel.ExecutionGovernance.V1, as: ExecutionGovernanceV1
  alias Citadel.Governance.AccessGraphAuthorityCache
  alias Citadel.Governance.SubstrateIngress
  alias Citadel.InvocationRequest
  alias Citadel.InvocationRequest.V2, as: InvocationRequestV2
  alias Citadel.PolicyPacks

  @invocation_fixture_dir Path.expand("../fixtures/invocation_request", __DIR__)

  test "compiles an accepted substrate packet without host session continuity" do
    assert {:ok, compiled} =
             SubstrateIngress.compile(valid_packet("req-substrate"), [policy_pack()])

    assert %AuthorityDecisionV1{} = compiled.authority_packet
    assert compiled.decision_hash == compiled.authority_packet.decision_hash
    assert %InvocationRequestV2{} = compiled.lower_intent.invocation_request
    assert %ActionOutboxEntry{} = compiled.lower_intent.outbox_entry

    assert %ExecutionGovernanceV1{} =
             compiled.lower_intent.invocation_request.execution_governance

    request = compiled.lower_intent.invocation_request

    assert request.schema_version == InvocationRequestV2.schema_version()
    assert request.request_id == "execution-1"
    assert request.session_id == "substrate/execution-1"
    assert request.trace_id == "trace-substrate"

    assert request.extensions["citadel"]["ingress_provenance"]["ingress_kind"] ==
             "substrate_origin"

    refute get_in(request.extensions, ["citadel", "ingress_provenance", "host_request_id"])

    assert compiled.lower_intent.outbox_entry.action.action_kind ==
             "citadel.substrate_invocation_request.v2"

    assert compiled.lower_intent.outbox_entry.action.payload["contract"] ==
             "citadel.invocation_request.v2"

    assert compiled.lower_intent.outbox_entry.action.payload["invocation_request"][
             "schema_version"
           ] == InvocationRequestV2.schema_version()

    assert compiled.audit_attrs == %{
             decision_hash: compiled.decision_hash,
             execution_id: "execution-1",
             fact_kind: :substrate_governance_accepted,
             installation_id: "installation-1",
             subject_id: "subject-1",
             tenant_id: "tenant-1",
             trace_id: "trace-substrate"
           }
  end

  test "compiles coding-ops policy into execution governance" do
    assert {:ok, compiled} =
             SubstrateIngress.compile(valid_packet("req-coding-ops"), [
               PolicyPacks.coding_ops_standard_pack!()
             ])

    governance = compiled.lower_intent.invocation_request.execution_governance

    assert governance.sandbox["level"] == "strict"
    assert governance.sandbox["egress"] == "restricted"
    assert governance.sandbox["approvals"] == "manual"
    assert governance.sandbox["allowed_tools"] == ["bash", "git"]
    assert governance.workspace["mutability"] == "read_write"
    assert governance.placement["placement_intent"] == "remote_workspace"
    assert governance.operations["allowed_operations"] == ["shell.exec"]
    assert governance.operations["effect_classes"] == ["filesystem", "process"]

    citadel_extensions = compiled.authority_packet.extensions["citadel"]

    assert citadel_extensions["prompt_version_policy"]["allowed_prompt_refs"] == [
             "prompt://coding-ops/standard/system"
           ]

    assert citadel_extensions["guardrail_chain_policy"]["guard_chain_ref"] ==
             "guard-chain://coding-ops/standard/default"

    request_extensions = compiled.lower_intent.invocation_request.extensions["citadel"]

    assert request_extensions["prompt_version_policy"]["guard_evidence_required"] == true
    assert request_extensions["guardrail_chain_policy"]["fail_closed"] == true
  end

  test "rejects coding-ops sandbox downgrades before lower submission" do
    packet = put_step_extension(valid_packet("req-sandbox-downgrade"), "sandbox_level", "none")

    assert {:error, rejection} =
             SubstrateIngress.compile(packet, [PolicyPacks.coding_ops_standard_pack!()])

    assert rejection.class == :policy_error
    assert rejection.operator_message == "sandbox_downgrade"
    assert rejection.audit_attrs.fact_kind == :substrate_governance_rejected
  end

  test "rejects coding-ops egress and approval downgrades" do
    egress_packet =
      put_step_extension(valid_packet("req-egress-downgrade"), "sandbox_egress", "open")

    assert {:error, egress_rejection} =
             SubstrateIngress.compile(egress_packet, [PolicyPacks.coding_ops_standard_pack!()])

    assert egress_rejection.operator_message == "egress_downgrade"

    approval_packet =
      put_step_extension(valid_packet("req-approval-downgrade"), "sandbox_approvals", "auto")

    assert {:error, approval_rejection} =
             SubstrateIngress.compile(approval_packet, [PolicyPacks.coding_ops_standard_pack!()])

    assert approval_rejection.operator_message == "approval_downgrade"
  end

  test "rejects coding-ops tools, operations, and placements outside policy" do
    tool_packet =
      valid_packet("req-tool-denied")
      |> put_step_extension("allowed_tools", ["bash", "curl"])

    assert {:error, tool_rejection} =
             SubstrateIngress.compile(tool_packet, [PolicyPacks.coding_ops_standard_pack!()])

    assert tool_rejection.operator_message == "tool_not_allowed"

    operation_packet =
      valid_packet("req-operation-denied")
      |> put_in(
        [:intent_envelope, :plan_hints, :candidate_steps, Access.at(0), :allowed_operations],
        ["shell.root"]
      )

    assert {:error, operation_rejection} =
             SubstrateIngress.compile(operation_packet, [PolicyPacks.coding_ops_standard_pack!()])

    assert operation_rejection.operator_message == "operation_not_allowed"

    placement_packet =
      put_step_extension(
        valid_packet("req-placement-denied"),
        "placement_intent",
        "ephemeral_session"
      )

    assert {:error, placement_rejection} =
             SubstrateIngress.compile(placement_packet, [PolicyPacks.coding_ops_standard_pack!()])

    assert placement_rejection.operator_message == "unsupported_placement_intent"
  end

  test "compiles authority from an access graph view" do
    reader = fn query ->
      send(self(), {:authority_graph_query, query})

      {:ok,
       %{
         snapshot_epoch: 7,
         access_agents: MapSet.new(["scheduler"]),
         access_resources: MapSet.new(["workspace/main"]),
         access_scopes: MapSet.new(["workspace/main"]),
         scope_resources: MapSet.new(["workspace/main"]),
         policy_refs: MapSet.new(["policy-v1"]),
         graph_admissible?: true,
         source_node_ref: "node://ji_1@127.0.0.1/node-a",
         commit_lsn: "16/B374D848",
         commit_hlc: %{"w" => 1_776_947_200_000_000_000, "l" => 0, "n" => "node-a"}
       }}
    end

    assert {:ok, compiled} =
             SubstrateIngress.compile(valid_packet("req-substrate"), [policy_pack()],
               access_graph_reader: reader
             )

    assert_receive {:authority_graph_query,
                    %{
                      tenant_ref: "tenant-1",
                      user_ref: "subject-1",
                      agent_ref: "scheduler",
                      resource_ref: "workspace/main",
                      requested_epoch: 7,
                      policy_refs: ["policy-v1"]
                    }}

    assert get_in(compiled.authority_packet.extensions, ["citadel", "access_graph"]) == %{
             "snapshot_epoch" => 7,
             "source_node_ref" => "node://ji_1@127.0.0.1/node-a",
             "commit_lsn" => "16/B374D848",
             "commit_hlc" => %{"w" => 1_776_947_200_000_000_000, "l" => 0, "n" => "node-a"},
             "policy_refs" => ["policy-v1"]
           }
  end

  test "rejects stale authority graph cache after a cross-node revocation" do
    reader = fn _query ->
      {:error,
       {:stale_epoch,
        %{
          requested_epoch: 6,
          current_epoch: 7,
          source_node_ref: "node://ji_2@127.0.0.1/node-b"
        }}}
    end

    assert {:error, rejection} =
             SubstrateIngress.compile(valid_packet("req-substrate"), [policy_pack()],
               access_graph_reader: reader
             )

    assert rejection.class == :auth_error
    assert rejection.terminal?
    assert rejection.operator_message == "stale_authority_epoch"
    assert rejection.audit_attrs.rejection_reason == "stale_authority_epoch"
    assert rejection.audit_attrs.current_epoch == 7
  end

  test "authority cache reconciles from access graph invalidation topics" do
    cache =
      AccessGraphAuthorityCache.new!(%{
        tenant_ref: "tenant-1",
        snapshot_epoch: 6,
        source_node_ref: "node://ji_1@127.0.0.1/node-a"
      })

    message = %{
      invalidation_id: "graph-invalidation://tenant-1/7",
      tenant_ref: "tenant-1",
      topic: AccessGraphAuthorityCache.graph_topic!("tenant-1", 7),
      source_node_ref: "node://ji_2@127.0.0.1/node-b",
      commit_lsn: "16/B374D848",
      commit_hlc: %{"w" => 1_776_947_200_000_000_001, "l" => 0, "n" => "node-b"},
      published_at: ~U[2026-04-24 12:00:00Z],
      metadata: %{"new_epoch" => 7}
    }

    assert {:stale, updated_cache} = AccessGraphAuthorityCache.reconcile(cache, message)
    assert updated_cache.stale?
    assert updated_cache.current_epoch == 7
    assert updated_cache.source_node_ref == "node://ji_2@127.0.0.1/node-b"
  end

  test "rejects legacy invocation request shaped input before action outbox" do
    legacy_request =
      "structured_request.json"
      |> read_invocation_fixture!()
      |> InvocationRequest.new!()
      |> InvocationRequest.dump()

    assert {:error, rejection} =
             SubstrateIngress.compile(legacy_request, [policy_pack()])

    assert rejection.class == :validation_error
    assert rejection.terminal?
    assert rejection.audit_attrs.fact_kind == :substrate_governance_validation_failed
    refute Map.has_key?(rejection, :lower_intent)
  end

  test "classifies unplannable substrate packets with non-terminal retry metadata" do
    packet =
      "req-rejected"
      |> valid_packet()
      |> put_in([:intent_envelope, :constraints, :boundary_requirement], :reuse_existing)
      |> put_in(
        [:intent_envelope, :target_hints, Access.at(0), :session_mode_preference],
        :detached
      )

    assert {:error, rejection} = SubstrateIngress.compile(packet, [policy_pack()])

    assert rejection.class == :policy_error
    assert rejection.terminal? == false
    assert rejection.operator_message == "boundary_reuse_requires_attached_session"
    assert rejection.audit_attrs.fact_kind == :substrate_governance_rejected
    assert rejection.audit_attrs.retryability == :after_input_change
    assert rejection.audit_attrs.publication_requirement == :host_only

    assert rejection.rejection_classification == %{
             rejection_id: "rejection/execution-1/boundary_reuse_requires_attached_session",
             stage: :planning,
             reason_code: "boundary_reuse_requires_attached_session",
             summary: "boundary_reuse_requires_attached_session",
             retryability: :after_input_change,
             publication_requirement: :host_only,
             extensions: %{
               "execution_id" => "execution-1",
               "trace_id" => "trace-substrate",
               "ingress_kind" => "substrate_origin"
             }
           }
  end

  test "maps plannable-packet assembly failures to readable operator messages" do
    packet =
      valid_packet("req-missing-intent")
      |> pop_in([
        :intent_envelope,
        :plan_hints,
        :candidate_steps,
        Access.at(0),
        :extensions,
        "citadel",
        "execution_intent"
      ])
      |> elem(1)

    assert {:error, rejection} = SubstrateIngress.compile(packet, [policy_pack()])

    assert rejection.operator_message == "candidate step is missing execution intent details"
    assert rejection.terminal? == false
    assert rejection.rejection_classification.retryability == :after_input_change
  end

  defp valid_packet(request_id) do
    %{
      tenant_id: "tenant-1",
      installation_id: "installation-1",
      installation_revision: 7,
      actor_ref: "scheduler",
      subject_id: "subject-1",
      execution_id: "execution-1",
      decision_id: "decision-1",
      request_trace_id: "request-trace",
      substrate_trace_id: "trace-substrate",
      idempotency_key: "tenant-1:subject-1:compile.workspace:7",
      capability_refs: ["compile.workspace"],
      policy_refs: ["policy-v1"],
      run_intent: %{"intent_id" => request_id, "capability" => "compile.workspace"},
      placement_constraints: %{"placement_ref" => "workspace_runtime"},
      risk_hints: ["writes_workspace"],
      metadata: %{"source" => "test"},
      intent_envelope: valid_intent_envelope(request_id)
    }
  end

  defp put_step_extension(packet, key, value) do
    put_in(
      packet,
      [
        :intent_envelope,
        :plan_hints,
        :candidate_steps,
        Access.at(0),
        :extensions,
        "citadel",
        key
      ],
      value
    )
  end

  defp valid_intent_envelope(request_id) do
    %{
      intent_envelope_id: "intent/#{request_id}",
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
                "placement_intent" => "remote_workspace",
                "downstream_scope" => "process:workspace",
                "execution_envelope" => %{
                  "submission_dedupe_key" => "tenant-1:subject-1:compile.workspace:7"
                }
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

  defp read_invocation_fixture!(name) do
    @invocation_fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end

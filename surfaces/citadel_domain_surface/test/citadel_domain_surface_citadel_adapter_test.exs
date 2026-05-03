defmodule Citadel.DomainSurface.CitadelAdapterTest do
  use ExUnit.Case, async: true

  alias Citadel.BoundarySessionDescriptor.V1, as: BoundarySessionDescriptorV1
  alias Citadel.DomainSurface.Adapters.CitadelAdapter
  alias Citadel.DomainSurface.Adapters.CitadelAdapter.Accepted
  alias Citadel.DomainSurface.Error
  alias Citadel.DomainSurface.Examples.ProvingGround.Commands

  @rejection_fixtures_path Path.expand("fixtures/citadel_rejections.json", __DIR__)
  @rejection_fixtures @rejection_fixtures_path |> File.read!() |> Jason.decode!()
  @fixture_atoms %{
    "after_governance_change" => :after_governance_change,
    "after_input_change" => :after_input_change,
    "after_runtime_change" => :after_runtime_change,
    "authority_compilation" => :authority_compilation,
    "derived_state_attachment" => :derived_state_attachment,
    "host_only" => :host_only,
    "ingress_normalization" => :ingress_normalization,
    "planning" => :planning,
    "planning_rejected" => :planning_rejected,
    "policy_rejected" => :policy_rejected,
    "projection" => :projection,
    "projection_rejected" => :projection_rejected,
    "request_rejected" => :request_rejected,
    "review_projection" => :review_projection,
    "scope_rejected" => :scope_rejected,
    "scope_resolution" => :scope_resolution,
    "service_admission" => :service_admission,
    "service_rejected" => :service_rejected,
    "terminal" => :terminal
  }

  defmodule RequestSubmissionStub do
    @behaviour Citadel.DomainSurface.Adapters.CitadelAdapter.RequestSubmission

    @impl true
    def submit_envelope(envelope, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(
        agent,
        &Map.put(&1, :last_submission, %{
          envelope: envelope,
          request_context: request_context,
          opts: opts
        })
      )

      Agent.get(agent, &Map.fetch!(&1, :submission_result))
    end
  end

  defmodule QuerySurfaceStub do
    @behaviour Citadel.DomainSurface.Adapters.CitadelAdapter.QuerySurface

    @impl true
    def fetch_runtime_observation(query, opts) do
      agent = Keyword.fetch!(opts, :agent)
      Agent.update(agent, &Map.put(&1, :last_runtime_observation_query, query))
      Agent.get(agent, &Map.fetch!(&1, :runtime_observation_result))
    end

    @impl true
    def fetch_boundary_session(query, opts) do
      agent = Keyword.fetch!(opts, :agent)
      Agent.update(agent, &Map.put(&1, :last_boundary_session_query, query))
      Agent.get(agent, &Map.fetch!(&1, :boundary_session_result))
    end
  end

  defmodule MaintenanceSurfaceStub do
    @behaviour Citadel.DomainSurface.Adapters.CitadelAdapter.MaintenanceSurface

    @impl true
    def inspect_dead_letter(entry_id, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        Map.put(state, :last_inspection, %{
          entry_id: entry_id,
          request_context: request_context
        })
      end)

      Agent.get(agent, &Map.fetch!(&1, :inspection_result))
    end

    @impl true
    def clear_dead_letter(entry_id, override_reason, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        Map.put(state, :last_clear, %{
          entry_id: entry_id,
          override_reason: override_reason,
          request_context: request_context
        })
      end)

      Agent.get(agent, &Map.fetch!(&1, :clear_result))
    end

    @impl true
    def retry_dead_letter(entry_id, override_reason, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        Map.put(state, :last_retry, %{
          entry_id: entry_id,
          override_reason: override_reason,
          request_context: request_context,
          retry_opts: Keyword.get(opts, :retry_opts, [])
        })
      end)

      Agent.get(agent, &Map.fetch!(&1, :retry_result))
    end

    @impl true
    def replace_dead_letter(entry_id, replacement_entry, override_reason, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        Map.put(state, :last_replace, %{
          entry_id: entry_id,
          replacement_entry: replacement_entry,
          override_reason: override_reason,
          request_context: request_context
        })
      end)

      Agent.get(agent, &Map.fetch!(&1, :replace_result))
    end

    @impl true
    def recover_dead_letters(selector, operation, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        Map.put(state, :last_recovery, %{
          selector: selector,
          operation: operation,
          request_context: request_context
        })
      end)

      Agent.get(agent, &Map.fetch!(&1, :maintenance_result))
    end
  end

  defmodule MintingIdPort do
    def new_id(:trace), do: {:ok, "trace/minted-1"}
  end

  test "preserves host trace lineage and maps command idempotency into Citadel request identity" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result:
            {:accepted,
             %{
               ingress_path: :direct_intent_envelope,
               lifecycle_event: :attached,
               continuity_revision: 3
             }},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :not_configured},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 0}
        }
      end)

    assert {:ok, %Accepted{} = accepted} =
             Citadel.DomainSurface.submit(
               Commands.CompileWorkspace,
               %{workspace_id: "workspace/main"},
               idempotency_key: "cmd-42",
               metadata: %{source: "ui"},
               context: %{
                 trace_id: "trace/host-42",
                 request_id: "host-req-42",
                 session_id: "sess-42",
                 tenant_id: "tenant-42",
                 actor_id: "actor-42",
                 environment: "dev"
               },
               kernel_runtime: {CitadelAdapter, runtime_opts(agent)}
             )

    assert accepted.request_id == "cmd-42"
    assert accepted.trace_id == "trace/host-42"
    assert accepted.session_id == "sess-42"
    assert accepted.lifecycle_event == :attached
    assert accepted.continuity_revision == 3

    submission = Agent.get(agent, & &1.last_submission)

    assert submission.request_context.request_id == "cmd-42"
    assert submission.request_context.idempotency_key == "cmd-42"
    assert submission.request_context.host_request_id == "host-req-42"
    assert submission.request_context.trace_id == "trace/host-42"
    assert submission.request_context.trace_origin == :host
    assert submission.request_context.metadata_keys == ["source"]

    assert submission.envelope.intent_envelope_id == "intent/compile_workspace/cmd-42"
    assert submission.envelope.extensions["citadel_domain_surface"]["idempotency_key"] == "cmd-42"
    assert submission.envelope.extensions["citadel_domain_surface"]["trace_origin"] == "host"

    assert submission.envelope.extensions["citadel_domain_surface"]["host_request_id"] ==
             "host-req-42"

    assert submission.envelope.plan_hints.candidate_steps |> hd() |> Map.get(:capability_id) ==
             "compile.workspace"

    assert submission.envelope.plan_hints.candidate_steps
           |> hd()
           |> Map.get(:extensions)
           |> get_in(["citadel", "execution_intent", "args"]) == ["compile", "workspace/main"]

    assert submission.envelope.plan_hints.candidate_steps
           |> hd()
           |> Map.get(:extensions)
           |> get_in(["citadel", "execution_envelope", "submission_dedupe_key"]) == "cmd-42"

    assert submission.envelope.target_hints |> hd() |> Map.get(:preferred_target_id) ==
             "workspace/main"
  end

  test "accepted results reject existing atoms outside the Citadel adapter vocabulary" do
    attrs = %{
      request_id: "cmd-bounded-accepted",
      trace_id: "trace-bounded-accepted",
      ingress_path: "ok",
      lifecycle_event: "attached"
    }

    assert_raise ArgumentError,
                 ~r/citadel acceptance :ingress_path string value must be one of/,
                 fn -> Accepted.new!(attrs) end

    attrs = %{
      request_id: "cmd-bounded-lifecycle",
      trace_id: "trace-bounded-lifecycle",
      ingress_path: "direct_intent_envelope",
      lifecycle_event: "ok"
    }

    assert_raise ArgumentError,
                 ~r/citadel acceptance :lifecycle_event string value must be one of/,
                 fn -> Accepted.new!(attrs) end
  end

  test "mints a trace_id before command submission when the host omits one" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result:
            {:accepted,
             %{
               ingress_path: :direct_intent_envelope,
               lifecycle_event: :attached,
               continuity_revision: 1
             }},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :not_configured},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 0}
        }
      end)

    assert {:ok, %Accepted{} = accepted} =
             Citadel.DomainSurface.submit(
               Citadel.DomainSurface.Examples.ProvingGround.Commands.CompileWorkspace,
               %{workspace_id: "workspace/main"},
               idempotency_key: "cmd-mint-trace",
               context: %{
                 session_id: "sess-1",
                 tenant_id: "tenant-1",
                 actor_id: "actor-1"
               },
               kernel_runtime: {CitadelAdapter, runtime_opts(agent, id_port: MintingIdPort)}
             )

    submission = Agent.get(agent, & &1.last_submission)

    assert submission.request_context.trace_id == "trace/minted-1"
    assert submission.request_context.trace_origin == :domain_minted

    assert submission.envelope.extensions["citadel_domain_surface"]["trace_origin"] ==
             "domain_minted"

    assert accepted.trace_id == "trace/minted-1"
  end

  test "maps workspace status queries into the Citadel boundary-session read surface" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result: {:error, :unused},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :unused},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 0}
        }
      end)

    assert {:ok, %BoundarySessionDescriptorV1{} = descriptor} =
             Citadel.DomainSurface.ask(
               Citadel.DomainSurface.Examples.ProvingGround.Queries.WorkspaceStatus,
               %{workspace_id: "workspace/main"},
               context: %{tenant_id: "tenant-query-1"},
               kernel_runtime: {CitadelAdapter, runtime_opts(agent)}
             )

    assert descriptor.target_id == "workspace/main"
    assert descriptor.status == "attached"

    boundary_session_query = Agent.get(agent, & &1.last_boundary_session_query)

    assert boundary_session_query.downstream_scope == "workspace_status"
    assert boundary_session_query.target_id == "workspace/main"
    assert boundary_session_query.tenant_id == "tenant-query-1"
    assert boundary_session_query.trace_id == "trace/minted-1"
    refute Map.has_key?(Agent.get(agent, & &1), :last_runtime_observation_query)
  end

  test "routes inspect_dead_letter through the explicit maintenance surface" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result: {:error, :unused},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :unused},
          inspection_result:
            {:ok,
             %{
               entry_id: "entry-dead-1",
               session_id: "session-dead-1",
               entry: %{dead_letter_reason: "projection_backend_down"},
               session: %{continuity_revision: 7}
             }},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 0}
        }
      end)

    assert {:ok, result} =
             Citadel.DomainSurface.maintain(
               Citadel.DomainSurface.Examples.ProvingGround.AdminCommands.InspectDeadLetter,
               %{entry_id: "entry-dead-1"},
               idempotency_key: "admin-inspect-1",
               context: %{trace_id: "trace/admin-inspect-1"},
               kernel_runtime:
                 {CitadelAdapter,
                  runtime_opts(agent,
                    maintenance_surface: MaintenanceSurfaceStub,
                    maintenance_surface_opts: [agent: agent]
                  )}
             )

    assert result.operation == :inspect_dead_letter
    assert result.entry_id == "entry-dead-1"
    assert result.session_id == "session-dead-1"
    assert result.request_id == "admin-inspect-1"
    assert result.trace_id == "trace/admin-inspect-1"
    assert result.auditable? == true
    assert result.entry.dead_letter_reason == "projection_backend_down"
    assert result.session.continuity_revision == 7

    inspection = Agent.get(agent, & &1.last_inspection)
    assert inspection.entry_id == "entry-dead-1"
    assert inspection.request_context.request_id == "admin-inspect-1"
    assert inspection.request_context.trace_id == "trace/admin-inspect-1"
  end

  test "routes retry_dead_letter through the explicit maintenance surface" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result: {:error, :unused},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :unused},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok,
             %{
               entry_id: "entry-dead-2",
               session: %{session_id: "session-dead-2", continuity_revision: 8}
             }},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 0}
        }
      end)

    assert {:ok, result} =
             Citadel.DomainSurface.maintain(
               Citadel.DomainSurface.Examples.ProvingGround.AdminCommands.RetryDeadLetter,
               %{
                 entry_id: "entry-dead-2",
                 override_reason: "operator retry",
                 retry_opts: [next_attempt_at: ~U[2026-04-10 20:00:00Z]]
               },
               idempotency_key: "admin-retry-1",
               context: %{trace_id: "trace/admin-retry-1"},
               kernel_runtime:
                 {CitadelAdapter,
                  runtime_opts(agent,
                    maintenance_surface: MaintenanceSurfaceStub,
                    maintenance_surface_opts: [agent: agent]
                  )}
             )

    assert result.operation == :retry_dead_letter
    assert result.entry_id == "entry-dead-2"
    assert result.request_id == "admin-retry-1"
    assert result.trace_id == "trace/admin-retry-1"
    assert result.session.session_id == "session-dead-2"

    retry = Agent.get(agent, & &1.last_retry)
    assert retry.entry_id == "entry-dead-2"
    assert retry.override_reason == "operator retry"
    assert retry.retry_opts == [next_attempt_at: ~U[2026-04-10 20:00:00Z]]
    assert retry.request_context.request_id == "admin-retry-1"
  end

  test "routes clear_dead_letter through the explicit maintenance surface" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result: {:error, :unused},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :unused},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok,
             %{
               entry_id: "entry-dead-3",
               session: %{session_id: "session-dead-3", continuity_revision: 9}
             }},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 2}
        }
      end)

    assert {:ok, result} =
             Citadel.DomainSurface.maintain(
               Citadel.DomainSurface.Examples.ProvingGround.AdminCommands.ClearDeadLetter,
               %{entry_id: "entry-dead-3", override_reason: "operator clear"},
               idempotency_key: "admin-clear-1",
               context: %{trace_id: "trace/admin-clear-1"},
               kernel_runtime:
                 {CitadelAdapter,
                  runtime_opts(agent,
                    maintenance_surface: MaintenanceSurfaceStub,
                    maintenance_surface_opts: [agent: agent]
                  )}
             )

    assert result.operation == :clear_dead_letter
    assert result.entry_id == "entry-dead-3"
    assert result.request_id == "admin-clear-1"
    assert result.trace_id == "trace/admin-clear-1"
    assert result.session.session_id == "session-dead-3"

    clear = Agent.get(agent, & &1.last_clear)
    assert clear.entry_id == "entry-dead-3"
    assert clear.override_reason == "operator clear"
    assert clear.request_context.request_id == "admin-clear-1"
  end

  test "routes recover_dead_letters through the explicit maintenance surface" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result: {:error, :unused},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :unused},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result:
            {:ok,
             %{
               affected_count: 2,
               recovery_operation:
                 {:retry_with_override, "citadel_domain_surface_requested_recovery"},
               selector: [dead_letter_reason: "projection_backend_down"]
             }}
        }
      end)

    assert {:ok, result} =
             Citadel.DomainSurface.maintain(
               Citadel.DomainSurface.Examples.ProvingGround.AdminCommands.RecoverDeadLetters,
               %{selector: [dead_letter_reason: "projection_backend_down"]},
               idempotency_key: "admin-recover-1",
               context: %{trace_id: "trace/admin-1"},
               kernel_runtime:
                 {CitadelAdapter,
                  runtime_opts(agent,
                    maintenance_surface: MaintenanceSurfaceStub,
                    maintenance_surface_opts: [agent: agent]
                  )}
             )

    assert result.operation == :recover_dead_letters
    assert result.affected_count == 2

    assert result.recovery_operation ==
             {:retry_with_override, "citadel_domain_surface_requested_recovery"}

    assert result.request_id == "admin-recover-1"
    assert result.trace_id == "trace/admin-1"

    recovery = Agent.get(agent, & &1.last_recovery)
    assert recovery.selector == [dead_letter_reason: "projection_backend_down"]

    assert recovery.operation ==
             {:retry_with_override, "citadel_domain_surface_requested_recovery"}

    assert recovery.request_context.request_id == "admin-recover-1"
    assert recovery.request_context.trace_id == "trace/admin-1"
  end

  test "translates request-surface DecisionRejection values into Domain errors at the seam" do
    fixture = Enum.find(@rejection_fixtures, &(&1["stage"] == "planning"))

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          submission_result: {:rejected, fixture_to_rejection(fixture)},
          boundary_session_result: {:ok, boundary_session_descriptor_map()},
          runtime_observation_result: {:error, :unused},
          inspection_result: {:ok, %{entry_id: "entry-unused", session_id: "session-unused"}},
          clear_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          retry_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          replace_result:
            {:ok, %{entry_id: "entry-unused", session: %{session_id: "session-unused"}}},
          maintenance_result: {:ok, 0}
        }
      end)

    assert {:error, %Error{} = error} =
             Citadel.DomainSurface.submit(
               Citadel.DomainSurface.Examples.ProvingGround.Commands.CompileWorkspace,
               %{workspace_id: "workspace/main"},
               idempotency_key: "cmd-rejected-1",
               context: %{
                 trace_id: "trace/rejected-1",
                 session_id: "sess-rejected-1",
                 tenant_id: "tenant-rejected-1",
                 actor_id: "actor-rejected-1"
               },
               kernel_runtime: {CitadelAdapter, runtime_opts(agent)}
             )

    assert error.category == :rejected
    assert error.code == :planning_rejected
    assert error.trace_id == "trace/rejected-1"
    assert error.details.reason_code == "boundary_reuse_requires_attached_session"
  end

  test "keeps rejection translation fixture-backed across every Citadel rejection stage" do
    Enum.each(@rejection_fixtures, fn fixture ->
      error =
        fixture
        |> fixture_to_rejection()
        |> Error.from_rejection(trace_id: "trace/fixture")

      assert error.category == :rejected
      assert error.code == fixture_atom!(fixture["expected_code"])
      assert error.retryability == fixture_atom!(fixture["retryability"])
      assert error.publication == fixture_atom!(fixture["publication_requirement"])
      assert error.source.stage == fixture_atom!(fixture["stage"])
    end)
  end

  defp runtime_opts(agent, overrides \\ []) do
    [
      id_port: MintingIdPort,
      request_submission: RequestSubmissionStub,
      request_submission_opts: [agent: agent],
      query_surface: QuerySurfaceStub,
      query_surface_opts: [agent: agent],
      maintenance_surface: MaintenanceSurfaceStub,
      maintenance_surface_opts: [agent: agent],
      context_defaults: %{
        tenant_id: "tenant-default",
        actor_id: "actor-default",
        session_id: "session-default",
        environment: "dev"
      }
    ]
    |> Keyword.merge(overrides)
  end

  defp boundary_session_descriptor_map do
    %{
      contract_version: BoundarySessionDescriptorV1.contract_version(),
      boundary_session_id: "boundary-session-1",
      boundary_ref: "boundary/workspace/main",
      session_id: "session-default",
      tenant_id: "tenant-query-1",
      target_id: "workspace/main",
      boundary_class: "workspace_session",
      status: "attached",
      attach_mode: "fresh_or_reuse",
      extensions: %{}
    }
  end

  defp fixture_to_rejection(fixture) do
    %{
      rejection_id: fixture["rejection_id"],
      stage: fixture_atom!(fixture["stage"]),
      reason_code: fixture["reason_code"],
      summary: fixture["summary"],
      retryability: fixture_atom!(fixture["retryability"]),
      publication_requirement: fixture_atom!(fixture["publication_requirement"]),
      extensions: %{"fixture" => true}
    }
  end

  defp fixture_atom!(value) do
    Map.fetch!(@fixture_atoms, value)
  end
end

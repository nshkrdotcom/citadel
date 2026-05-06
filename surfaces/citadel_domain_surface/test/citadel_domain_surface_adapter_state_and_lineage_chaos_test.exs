defmodule Citadel.DomainSurface.AdapterStateAndLineageChaosTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData

  alias Citadel.BoundarySessionDescriptor.V1, as: BoundarySessionDescriptorV1
  alias Citadel.DomainSurface.Adapters.CitadelAdapter
  alias Citadel.DomainSurface.Adapters.CitadelAdapter.Accepted
  alias Citadel.DomainSurface.Error
  alias Citadel.DomainSurface.Examples.{ArticlePublishing, ProvingGround}

  @max_runs 25

  defmodule RequestSubmissionStub do
    @behaviour Citadel.DomainSurface.Adapters.CitadelAdapter.RequestSubmission

    @impl true
    def submit_envelope(envelope, request_context, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn state ->
        submission = %{envelope: envelope, request_context: request_context}
        state = update_in(state.submissions, &[submission | &1])

        case state.submission_reply do
          {:rejected, rejection} ->
            {{:rejected, rejection}, state}

          :accepted ->
            {accepted, state} = accept_submission(state, envelope, request_context)
            {{:accepted, accepted}, state}
        end
      end)
    end

    defp accept_submission(state, envelope, request_context) do
      case Map.fetch(state.accepted_by_idempotency, request_context.idempotency_key) do
        {:ok, accepted} ->
          {mark_deduplicated(accepted), state}

        :error ->
          accepted = build_accepted_payload(state, envelope, request_context)

          {accepted,
           put_in(state.accepted_by_idempotency[request_context.idempotency_key], accepted)}
      end
    end

    defp build_accepted_payload(%{submission_mode: :legacy_v0} = state, envelope, request_context) do
      %{
        "schema_version" => 0,
        "request_identity" => request_context.request_id,
        "root_trace_id" => request_context.trace_id,
        "session" => %{"id" => request_context.session_id},
        "ingress" => %{"path" => "direct_intent_envelope"},
        "lifecycle" => %{"event" => "attached"},
        "continuity" => %{"revision" => map_size(state.accepted_by_idempotency) + 1},
        "metadata" => %{"adapter" => "legacy_v0", deduplicated?: false},
        "lineage" => %{
          "command_name" =>
            get_in(envelope.extensions, ["citadel_domain_surface", "request_name"]),
          "route_name" => get_in(envelope.extensions, ["citadel_domain_surface", "route_name"]),
          "subject_identity" => envelope.target_hints |> hd() |> Map.get(:preferred_target_id),
          "idempotency_key" => request_context.idempotency_key,
          "trace_id" => request_context.trace_id
        }
      }
    end

    defp build_accepted_payload(state, _envelope, _request_context) do
      %{
        ingress_path: :direct_intent_envelope,
        lifecycle_event: :attached,
        continuity_revision: map_size(state.accepted_by_idempotency) + 1,
        metadata: %{deduplicated?: false}
      }
    end

    defp mark_deduplicated(%{} = accepted) do
      update_in(accepted[:metadata], fn metadata ->
        metadata
        |> Kernel.||(%{})
        |> Map.new()
        |> Map.put(:deduplicated?, true)
      end)
    end
  end

  defmodule QuerySurfaceStub do
    @behaviour Citadel.DomainSurface.Adapters.CitadelAdapter.QuerySurface

    @impl true
    def fetch_boundary_session(query, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn state ->
        state = update_in(state.boundary_queries, &[query | &1])
        response = build_boundary_session_payload(state.boundary_session_mode, query)
        {{:ok, response}, state}
      end)
    end

    @impl true
    def fetch_runtime_observation(_query, _opts), do: {:error, :unsupported}

    defp build_boundary_session_payload(:legacy_v0, query) do
      %{
        "contract_version" => "v0",
        "boundary_id" => "boundary-session/#{query.target_id}",
        "boundary_handle" => "boundary/#{query.target_id}",
        "session_ref" => "session-query-legacy",
        "tenant_ref" => query.tenant_id,
        "subject_id" => query.target_id,
        "boundary_type" => "publication_session",
        "status" => "attached",
        "boundary_mode" => "fresh_or_reuse",
        "extensions" => %{"adapter" => "legacy_v0"}
      }
    end

    defp build_boundary_session_payload(_mode, query) do
      %{
        contract_version: BoundarySessionDescriptorV1.contract_version(),
        boundary_session_id: "boundary-session/#{query.target_id}",
        boundary_ref: "boundary/#{query.target_id}",
        session_id: "session-query-current",
        tenant_id: query.tenant_id,
        target_id: query.target_id,
        boundary_class: "publication_session",
        status: "attached",
        attach_mode: "fresh_or_reuse",
        extensions: %{}
      }
    end
  end

  defmodule FixedIdPort do
    def new_id(:trace), do: {:ok, "trace/chaos-fixed"}
  end

  defmodule UniqueIdPort do
    def new_id(:trace) do
      {:ok, "trace/chaos/#{System.unique_integer([:positive, :monotonic])}"}
    end
  end

  property "legacy accepted payloads preserve lineage through adapter migration" do
    check all(
            article_id <- non_blank_string(),
            idempotency_key <- non_blank_string(),
            trace_id <- exact_trace_id(),
            host_request_id <- prefixed_string("host"),
            max_runs: @max_runs
          ) do
      {:ok, agent} = start_runtime_agent(%{submission_mode: :legacy_v0})

      assert {:ok, %Accepted{} = accepted} =
               ArticlePublishing.publish_article(
                 %{article_id: article_id},
                 idempotency_key: idempotency_key,
                 context: %{
                   trace_id: trace_id,
                   request_id: host_request_id,
                   session_id: "session-legacy",
                   tenant_id: "tenant-legacy",
                   actor_id: "actor-legacy"
                 },
                 kernel_runtime: {CitadelAdapter, runtime_opts(agent)}
               )

      assert accepted.request_id == idempotency_key
      assert accepted.trace_id == trace_id
      assert accepted.session_id == "session-legacy"
      assert accepted.continuity_revision == 1
      assert accepted.metadata.legacy_schema_version == 0
      assert accepted.metadata.lineage.request_name == "publish_article"
      assert accepted.metadata.lineage.route_name == "publish_article"
      assert accepted.metadata.lineage.subject_identity == article_id
      assert accepted.metadata.lineage.idempotency_key == idempotency_key
      assert accepted.metadata.lineage.trace_id == trace_id

      [submission] = observed_submissions(agent)
      assert submission.request_context.request_id == idempotency_key
      assert submission.request_context.trace_id == trace_id
      assert submission.request_context.host_request_id == host_request_id
    end
  end

  property "legacy boundary-session descriptors preserve subject identity through adapter migration" do
    check all(
            article_id <- non_blank_string(),
            tenant_id <- prefixed_string("tenant"),
            trace_id <- exact_trace_id(),
            max_runs: @max_runs
          ) do
      {:ok, agent} = start_runtime_agent(%{boundary_session_mode: :legacy_v0})

      assert {:ok, %BoundarySessionDescriptorV1{} = descriptor} =
               ArticlePublishing.publication_status(
                 %{article_id: article_id},
                 context: %{trace_id: trace_id, tenant_id: tenant_id},
                 kernel_runtime: {CitadelAdapter, runtime_opts(agent)}
               )

      assert descriptor.contract_version == "v1"
      assert descriptor.target_id == article_id
      assert descriptor.tenant_id == tenant_id
      assert descriptor.boundary_class == "publication_session"
      assert descriptor.attach_mode == "fresh_or_reuse"
      assert descriptor.extensions["legacy_contract_version"] == "v0"

      [query] = observed_boundary_queries(agent)
      assert query.target_id == article_id
      assert query.trace_id == trace_id
    end
  end

  test "concurrent duplicate submissions preserve a single semantic request identity under contention" do
    {:ok, agent} = start_runtime_agent()

    article_id = "article-contention-1"
    idempotency_key = "pub-contention-1"
    trace_id = "trace/contention-1"
    host_request_ids = Enum.map(1..12, &"host/contention-#{&1}")

    results =
      host_request_ids
      |> Task.async_stream(
        fn host_request_id ->
          ArticlePublishing.publish_article(
            %{article_id: article_id},
            idempotency_key: idempotency_key,
            context: %{
              trace_id: trace_id,
              request_id: host_request_id,
              session_id: "session-contention",
              tenant_id: "tenant-contention",
              actor_id: "actor-contention"
            },
            kernel_runtime: {CitadelAdapter, runtime_opts(agent)}
          )
        end,
        max_concurrency: 12,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn
        {:ok, {:ok, result}} -> result
        other -> flunk("unexpected concurrent submission result: #{inspect(other)}")
      end)

    assert Enum.all?(results, &(&1.request_id == idempotency_key))
    assert Enum.all?(results, &(&1.trace_id == trace_id))
    assert Enum.uniq(Enum.map(results, & &1.continuity_revision)) == [1]
    assert Enum.count(results, &(&1.metadata.deduplicated? == false)) == 1
    assert Enum.count(results, &(&1.metadata.deduplicated? == true)) == 11

    submissions = observed_submissions(agent)

    assert length(submissions) == 12
    assert Enum.all?(submissions, &(&1.request_context.request_id == idempotency_key))
    assert Enum.all?(submissions, &(&1.request_context.trace_id == trace_id))

    assert submissions
           |> Enum.map(& &1.request_context.host_request_id)
           |> Enum.sort() == Enum.sort(host_request_ids)

    assert Enum.all?(submissions, fn submission ->
             get_in(submission.envelope.extensions, ["citadel_domain_surface", "request_name"]) ==
               "publish_article"
           end)

    assert Enum.all?(submissions, fn submission ->
             submission.envelope.target_hints |> hd() |> Map.get(:preferred_target_id) ==
               article_id
           end)
  end

  test "host-supplied trace_id is preserved exactly across adapter restarts" do
    trace_id = " trace/restart exact "
    article_id = "article-restart-1"
    idempotency_key = "pub-restart-1"

    {:ok, first_agent} = start_runtime_agent()
    {:ok, second_agent} = start_runtime_agent()

    assert {:ok, first} =
             ArticlePublishing.publish_article(
               %{article_id: article_id},
               idempotency_key: idempotency_key,
               context: %{
                 trace_id: trace_id,
                 request_id: "host-restart-a",
                 session_id: "session-restart",
                 tenant_id: "tenant-restart",
                 actor_id: "actor-restart"
               },
               kernel_runtime: {CitadelAdapter, runtime_opts(first_agent)}
             )

    assert {:ok, second} =
             ArticlePublishing.publish_article(
               %{article_id: article_id},
               idempotency_key: idempotency_key,
               context: %{
                 trace_id: trace_id,
                 request_id: "host-restart-b",
                 session_id: "session-restart",
                 tenant_id: "tenant-restart",
                 actor_id: "actor-restart"
               },
               kernel_runtime: {CitadelAdapter, runtime_opts(second_agent)}
             )

    [first_submission] = observed_submissions(first_agent)
    [second_submission] = observed_submissions(second_agent)

    assert first.request_id == idempotency_key
    assert second.request_id == idempotency_key
    assert first.trace_id == trace_id
    assert second.trace_id == trace_id
    assert first_submission.request_context.trace_id == trace_id
    assert second_submission.request_context.trace_id == trace_id
    assert first_submission.request_context.request_id == idempotency_key
    assert second_submission.request_context.request_id == idempotency_key

    assert get_in(first_submission.envelope.extensions, ["citadel_domain_surface", "request_name"]) ==
             "publish_article"

    assert get_in(second_submission.envelope.extensions, [
             "citadel_domain_surface",
             "request_name"
           ]) ==
             "publish_article"

    assert first_submission.envelope.target_hints |> hd() |> Map.get(:preferred_target_id) ==
             article_id

    assert second_submission.envelope.target_hints |> hd() |> Map.get(:preferred_target_id) ==
             article_id
  end

  test "Domain-minted trace_id is not restart-stable without host persistence or durable backing" do
    article_id = "article-minted-1"
    idempotency_key = "pub-minted-1"

    {:ok, first_agent} = start_runtime_agent()
    {:ok, second_agent} = start_runtime_agent()

    assert {:ok, first} =
             ArticlePublishing.publish_article(
               %{article_id: article_id},
               idempotency_key: idempotency_key,
               context: %{request_id: "host-minted-a"},
               kernel_runtime: {CitadelAdapter, runtime_opts(first_agent, id_port: UniqueIdPort)}
             )

    assert {:ok, second} =
             ArticlePublishing.publish_article(
               %{article_id: article_id},
               idempotency_key: idempotency_key,
               context: %{request_id: "host-minted-b"},
               kernel_runtime: {CitadelAdapter, runtime_opts(second_agent, id_port: UniqueIdPort)}
             )

    [first_submission] = observed_submissions(first_agent)
    [second_submission] = observed_submissions(second_agent)

    assert first.request_id == idempotency_key
    assert second.request_id == idempotency_key
    assert first_submission.request_context.trace_origin == :domain_minted
    assert second_submission.request_context.trace_origin == :domain_minted
    refute first.trace_id == second.trace_id
    refute first_submission.request_context.trace_id == second_submission.request_context.trace_id

    assert get_in(first_submission.envelope.extensions, ["citadel_domain_surface", "request_name"]) ==
             "publish_article"

    assert get_in(second_submission.envelope.extensions, [
             "citadel_domain_surface",
             "request_name"
           ]) ==
             "publish_article"
  end

  test "stateful long-running orchestration is rejected explicitly when durable backing is absent" do
    assert {:error, %Error{} = error} =
             ProvingGround.rebuild_read_model(
               %{workspace_id: "workspace-chaos"},
               idempotency_key: "rebuild-chaos-1"
             )

    assert error.category == :unsupported
    assert error.code == :unsupported_stateful_orchestration
    assert String.contains?(error.message, "durable backing")
  end

  defp start_runtime_agent(overrides \\ %{}) do
    Agent.start_link(fn -> Map.merge(base_runtime_state(), overrides) end)
  end

  defp observed_submissions(agent) do
    agent
    |> Agent.get(& &1.submissions)
    |> Enum.reverse()
  end

  defp observed_boundary_queries(agent) do
    agent
    |> Agent.get(& &1.boundary_queries)
    |> Enum.reverse()
  end

  defp runtime_opts(agent, overrides \\ []) do
    [
      id_port: FixedIdPort,
      request_submission: RequestSubmissionStub,
      request_submission_opts: [agent: agent],
      query_surface: QuerySurfaceStub,
      query_surface_opts: [agent: agent],
      context_defaults: %{
        tenant_id: "tenant-default",
        actor_id: "actor-default",
        session_id: "session-default",
        environment: "test"
      }
    ]
    |> Keyword.merge(overrides)
  end

  defp base_runtime_state do
    %{
      submissions: [],
      boundary_queries: [],
      submission_reply: :accepted,
      submission_mode: :current,
      boundary_session_mode: :current,
      accepted_by_idempotency: %{}
    }
  end

  defp non_blank_string do
    string(:alphanumeric, min_length: 1)
  end

  defp prefixed_string(prefix) do
    map(non_blank_string(), &"#{prefix}/#{&1}")
  end

  defp exact_trace_id do
    one_of([
      prefixed_string("trace"),
      map(non_blank_string(), &" trace/#{&1} ")
    ])
  end
end

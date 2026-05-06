defmodule Citadel.DomainSurface.Wave15Test do
  use ExUnit.Case, async: true

  alias Citadel.DomainSurface, as: Domain
  alias Citadel.DomainSurface.Examples.ProvingGround
  alias Citadel.DomainSurface.Examples.ProvingGround.{AdminCommands, Commands, Queries}

  defmodule Context do
    defstruct [:trace_id, :actor]
  end

  defmodule FakeKernelRuntime do
    @behaviour Citadel.DomainSurface.Ports.KernelRuntime

    @impl true
    def dispatch_command(request) do
      {:ok,
       %{
         handled: request.name,
         request_type: request.__struct__,
         idempotency_key: Map.get(request, :idempotency_key),
         trace_id: Map.get(request, :trace_id)
       }}
    end

    @impl true
    def run_query(query) do
      {:ok,
       %{
         handled: query.name,
         request_type: query.__struct__,
         trace_id: query.trace_id
       }}
    end
  end

  defmodule FakeExternalIntegration do
    @behaviour Citadel.DomainSurface.Ports.ExternalIntegration

    @impl true
    def dispatch_command(request) do
      {:ok,
       %{
         handled: request.name,
         request_type: request.__struct__,
         lower_seam: :external_integration,
         idempotency_key: Map.get(request, :idempotency_key),
         trace_id: Map.get(request, :trace_id)
       }}
    end

    @impl true
    def run_query(query) do
      {:ok,
       %{
         handled: query.name,
         request_type: query.__struct__,
         lower_seam: :external_integration,
         trace_id: query.trace_id
       }}
    end
  end

  test "pins the packet runtime baseline" do
    assert Citadel.DomainSurface.runtime_baseline() == %{elixir: "~> 1.19", otp: 28}
    assert Mix.Project.config()[:elixir] == "~> 1.19"

    tool_versions = File.read!(Path.expand("../.tool-versions", __DIR__))

    assert String.contains?(tool_versions, "erlang 28.3")
    assert String.contains?(tool_versions, "elixir 1.19.5-otp-28")
  end

  test "materializes the proving-ground module layout" do
    expected_modules =
      Citadel.DomainSurface.baseline_layout()
      |> Keyword.values()

    assert Enum.all?(expected_modules, &Code.ensure_loaded?/1)
  end

  test "keeps the direct baseline dependency set lean" do
    deps = Mix.Project.config()[:deps]

    assert dep_opts(deps, :citadel_governance)[:path] == "../../core/citadel_governance"
    assert dep_opts(deps, :citadel_kernel)[:path] == "../../core/citadel_kernel"

    assert dep_opts(deps, :citadel_host_ingress_bridge)[:path] ==
             "../../bridges/host_ingress_bridge"

    assert dep_opts(deps, :citadel_query_bridge)[:path] == "../../bridges/query_bridge"

    assert Enum.any?(deps, fn
             {:jason, "~> 1.4"} -> true
             {:jason, "~> 1.4", _opts} -> true
             _other -> false
           end)

    refute dep_opts(deps, :citadel)
    refute dep_opts(deps, :jido_integration)
    refute dep_opts(deps, :jido_integration_contracts)
  end

  test "keeps the bounded admin surface explicit" do
    assert :inspect_dead_letter in Domain.Admin.supported_commands()
    assert :recover_dead_letters in Domain.Admin.supported_commands()
    assert :clear_dead_letter in Domain.Admin.supported_commands()
    assert :retry_dead_letter in Domain.Admin.supported_commands()
  end

  test "builds semantic commands with required idempotency and neutral context" do
    context = %Context{trace_id: "trace/cmd-1", actor: "host-user"}

    assert {:ok, command} =
             ProvingGround.compile_workspace(
               %{workspace_id: "workspace/main"},
               idempotency_key: "cmd-1",
               metadata: %{source: "ui"},
               context: context
             )

    assert command.name == :compile_workspace
    assert command.idempotency_key == "cmd-1"
    assert command.trace_id == "trace/cmd-1"
    assert command.route.name == :compile_workspace
    assert command.context == context
    assert command.metadata == %{source: "ui"}
  end

  test "requires idempotency_key for commands at the public boundary" do
    assert {:error, error} =
             ProvingGround.compile_workspace(%{
               workspace_id: "workspace/main"
             })

    assert error.category == :validation
    assert error.code == :missing_idempotency_key
  end

  test "builds semantic queries without idempotency and preserves trace context" do
    assert {:ok, query} =
             ProvingGround.workspace_status(
               %{workspace_id: "workspace/main"},
               context: %{trace_id: "trace/query-1"}
             )

    assert query.name == :workspace_status
    assert query.trace_id == "trace/query-1"
    assert query.route.name == :workspace_status
  end

  test "rejects unsupported hidden saga behavior when durable backing is absent" do
    assert {:error, error} =
             ProvingGround.rebuild_read_model(
               %{workspace_id: "workspace/main"},
               idempotency_key: "cmd-2"
             )

    assert error.category == :unsupported
    assert error.code == :unsupported_stateful_orchestration
  end

  test "evaluates policies before dispatch" do
    assert {:error, error} =
             Domain.submit(
               Commands.CompileWorkspace,
               %{},
               idempotency_key: "cmd-3",
               kernel_runtime: FakeKernelRuntime
             )

    assert error.category == :validation
    assert error.code == :invalid_request
    assert error.details[:field] == :workspace_id
  end

  test "routes commands through the semantic host-facing API" do
    assert {:ok, result} =
             Domain.submit(
               Commands.CompileWorkspace,
               %{workspace_id: "workspace/main"},
               idempotency_key: "cmd-4",
               context: %{trace_id: "trace/cmd-4"},
               kernel_runtime: FakeKernelRuntime
             )

    assert result.handled == :compile_workspace
    assert result.request_type == Citadel.DomainSurface.Command
    assert result.idempotency_key == "cmd-4"
    assert result.trace_id == "trace/cmd-4"
  end

  test "keeps the optional external integration seam explicit and absent by default" do
    assert {:error, error} =
             Domain.submit(
               Commands.RecordOperatorEvidence,
               %{evidence_id: "evidence-1"},
               idempotency_key: "cmd-ext-1"
             )

    assert error.category == :configuration
    assert error.code == :not_configured
    assert error.details[:component] == :external_integration
  end

  test "routes external integration work only when the optional adapter is configured" do
    assert {:ok, result} =
             Domain.submit(
               Commands.RecordOperatorEvidence,
               %{evidence_id: "evidence-2"},
               idempotency_key: "cmd-ext-2",
               context: %{trace_id: "trace/ext-2"},
               external_integration: FakeExternalIntegration
             )

    assert result.handled == :record_operator_evidence
    assert result.request_type == Citadel.DomainSurface.Command
    assert result.lower_seam == :external_integration
    assert result.idempotency_key == "cmd-ext-2"
    assert result.trace_id == "trace/ext-2"
  end

  test "routes queries through the semantic host-facing API" do
    assert {:ok, result} =
             Domain.ask(
               Queries.WorkspaceStatus,
               %{workspace_id: "workspace/main"},
               context: %{trace_id: "trace/query-2"},
               kernel_runtime: FakeKernelRuntime
             )

    assert result.handled == :workspace_status
    assert result.request_type == Citadel.DomainSurface.Query
    assert result.trace_id == "trace/query-2"
  end

  test "routes admin commands through an explicit maintenance surface" do
    assert {:ok, result} =
             Domain.maintain(
               AdminCommands.RecoverDeadLetters,
               %{selector: [dead_letter_reason: "projection_backend_down"]},
               idempotency_key: "admin-1",
               context: %{trace_id: "trace/admin-1"},
               kernel_runtime: FakeKernelRuntime
             )

    assert result.handled == :recover_dead_letters
    assert result.request_type == Citadel.DomainSurface.Admin
    assert result.idempotency_key == "admin-1"
  end

  test "freezes the Domain error vocabulary and Citadel rejection translation matrix" do
    assert Domain.Error.vocabulary() == %{
             configuration: [:not_configured],
             validation: [
               :missing_idempotency_key,
               :invalid_context,
               :invalid_definition,
               :invalid_metadata,
               :invalid_request,
               :invalid_trace_id,
               :route_not_found
             ],
             unsupported: [:unsupported_stateful_orchestration],
             rejected: [
               :request_rejected,
               :scope_rejected,
               :service_rejected,
               :planning_rejected,
               :policy_rejected,
               :projection_rejected
             ]
           }

    assert Enum.sort(Map.keys(Domain.Error.rejection_translation_matrix())) == [
             :authority_compilation,
             :ingress_normalization,
             :planning,
             :projection,
             :scope_resolution,
             :service_admission
           ]
  end

  test "translates Citadel DecisionRejection values into Domain errors" do
    rejection =
      Citadel.DecisionRejection.new!(%{
        rejection_id: "rejection/1",
        stage: :planning,
        reason_code: "boundary_reuse_requires_attached_session",
        summary: "boundary reuse requires an attached session",
        retryability: :after_input_change,
        publication_requirement: :host_only,
        extensions: %{"request_id" => "req-1"}
      })

    error = Domain.Error.from_rejection(rejection, trace_id: "trace/rejection-1")

    assert error.category == :rejected
    assert error.code == :planning_rejected
    assert error.message == "boundary reuse requires an attached session"
    assert error.trace_id == "trace/rejection-1"
    assert error.retryability == :after_input_change
    assert error.publication == :host_only

    assert error.source == %{
             system: :citadel,
             rejection_id: "rejection/1",
             stage: :planning,
             reason_code: "boundary_reuse_requires_attached_session"
           }

    assert error.details.reason_code == "boundary_reuse_requires_attached_session"
    assert error.details.classification_message == "request rejected during planning"
  end

  defp dep_opts(deps, app) do
    Enum.find_value(deps, fn
      {^app, opts} when is_list(opts) -> opts
      {^app, _requirement, opts} when is_list(opts) -> opts
      _ -> nil
    end)
  end
end

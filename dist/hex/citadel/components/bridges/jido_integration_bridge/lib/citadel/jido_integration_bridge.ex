defmodule Citadel.JidoIntegrationBridge do
  @moduledoc """
  Citadel-owned transport seam for brain-to-lower-gateway durable submission.
  """

  alias Jido.Integration.V2.BrainInvocation
  alias Jido.Integration.V2.SubmissionAcceptance
  alias Jido.Integration.V2.SubmissionRejection

  @transport_env_key :transport_module

  defmodule Transport do
    @moduledoc false

    alias Jido.Integration.V2.BrainInvocation
    alias Jido.Integration.V2.SubmissionAcceptance
    alias Jido.Integration.V2.SubmissionRejection

    @callback submit_brain_invocation(BrainInvocation.t()) ::
                {:accepted, SubmissionAcceptance.t()}
                | {:rejected, SubmissionRejection.t()}
                | {:error, atom()}
  end

  defmodule NoopTransport do
    @moduledoc false

    @behaviour Transport

    @impl true
    def submit_brain_invocation(%BrainInvocation{}), do: {:error, :transport_not_configured}
  end

  @manifest %{
    package: :citadel_jido_integration_bridge,
    layer: :bridge,
    status: :durable_submission_contract_frozen,
    owns: [:brain_invocation_projection, :shared_lineage_coercion, :transport_configuration],
    internal_dependencies: [
      :citadel_governance,
      :citadel_authority_contract,
      :citadel_execution_governance_contract,
      :citadel_invocation_bridge
    ],
    external_dependencies: [:jido_integration_contracts]
  }

  @spec manifest() :: map()
  def manifest, do: @manifest

  @spec transport_module() :: module()
  def transport_module do
    Application.get_env(
      :citadel_jido_integration_bridge,
      @transport_env_key,
      __MODULE__.NoopTransport
    )
  end

  @spec transport_module(term(), keyword()) :: module()
  def transport_module(context, opts) when is_list(opts) do
    case Keyword.fetch(opts, :transport_module) do
      {:ok, module} when is_atom(module) -> module
      :error -> default_transport_module(context)
    end
  end

  @spec put_transport_module(module()) :: :ok
  def put_transport_module(module) when is_atom(module) do
    Application.put_env(:citadel_jido_integration_bridge, @transport_env_key, module)
  end

  defp default_transport_module(nil), do: transport_module()
  defp default_transport_module(_governed_context), do: __MODULE__.NoopTransport
end

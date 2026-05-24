defmodule Citadel.ContextAuthority do
  @moduledoc """
  Public facade for Citadel-owned Context ABI authority contracts.
  """

  alias Citadel.ContextAuthority.{
    AuthorityRequest,
    Authorizer,
    Grant,
    PolicyAuthorizer,
    RuntimeDeps
  }

  @manifest %{
    package: :citadel_context_authority_contract,
    layer: :core,
    status: :nshkr_fugu_phase_4_context_authority,
    owns: [
      :context_access_grants,
      :model_class_allowlist_verdicts,
      :route_policy_authorization,
      :payload_mode_authorization,
      :redaction_requirements,
      :promotion_authority_checks,
      :rollback_authority_checks,
      :tenant_context_authority
    ],
    internal_dependencies: [:citadel_contract_core, :citadel_authority_contract],
    external_dependencies: [:outer_brain_context_abi]
  }

  @spec manifest() :: map()
  def manifest, do: @manifest

  @spec authority_request_module() :: module()
  def authority_request_module, do: AuthorityRequest

  @spec authorizer_module() :: module()
  def authorizer_module, do: Authorizer

  @spec default_authorizer_module() :: module()
  def default_authorizer_module, do: PolicyAuthorizer

  @spec grant_module() :: module()
  def grant_module, do: Grant

  @spec runtime_deps_module() :: module()
  def runtime_deps_module, do: RuntimeDeps

  @spec authorize(
          OuterBrain.ContextABI.ContextPacket.t(),
          AuthorityRequest.t() | map(),
          keyword()
        ) ::
          {:ok, Grant.t()} | {:error, OuterBrain.ContextABI.Failure.t()}
  def authorize(context_packet, authority_request, opts \\ []) do
    authorizer = Keyword.get(opts, :authorizer, PolicyAuthorizer)
    authorizer.authorize(context_packet, authority_request, Keyword.delete(opts, :authorizer))
  end
end

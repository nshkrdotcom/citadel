defmodule Citadel.ContextAuthority.Authorizer do
  @moduledoc """
  Behaviour for authorizing an OuterBrain Context ABI packet.

  Implementations return a ref-only Citadel context grant or an owner-local
  `OuterBrain.ContextABI.Failure`.
  """

  alias Citadel.ContextAuthority.Grant
  alias OuterBrain.ContextABI.{ContextPacket, Failure}

  @type authority_request :: %{
          required(:tenant_ref) => String.t(),
          required(:actor_ref) => String.t(),
          required(:context_packet_ref) => String.t(),
          required(:model_class_allowlist) => [String.t()],
          required(:route_policy_ref) => String.t(),
          required(:trace_ref) => String.t()
        }

  @callback authorize(ContextPacket.t(), authority_request() | struct(), keyword()) ::
              {:ok, Grant.t()} | {:error, Failure.t()}
end

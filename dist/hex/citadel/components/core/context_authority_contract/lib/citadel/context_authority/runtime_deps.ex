defmodule Citadel.ContextAuthority.RuntimeDeps do
  @moduledoc """
  Explicit runtime dependencies for Citadel context authority evaluation.

  Standalone startup may build defaults, but governed calls receive this shape
  or an equivalent explicit backend option. Runtime environment variables are
  not transaction authority.
  """

  defstruct authorizer: Citadel.ContextAuthority.PolicyAuthorizer,
            policy_store: nil,
            clock: nil

  @type t :: %__MODULE__{
          authorizer: module() | nil,
          policy_store: term(),
          clock: module() | nil
        }
end

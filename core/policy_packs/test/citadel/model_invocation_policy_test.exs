defmodule Citadel.PolicyPacks.ModelInvocationPolicyTest do
  use ExUnit.Case, async: true

  alias Citadel.PolicyPacks.ModelInvocationPolicy

  @issued_at ~U[2026-07-20 12:00:00Z]

  test "release artifact is content addressed and permits only the named Gemini turn" do
    policy = ModelInvocationPolicy.synapse_gemini_turn!()

    assert policy.source_digest ==
             ModelInvocationPolicy.source_digest(ModelInvocationPolicy.source(policy))

    assert :permitted =
             ModelInvocationPolicy.evaluate(policy, %{
               provider_family: "gemini",
               model_ref: "gemini-2.5-flash",
               operation_class: "generate_content",
               issued_at: @issued_at,
               expires_at: DateTime.add(@issued_at, 60, :second)
             })

    for {field, value, reason} <- [
          {:provider_family, "openai", :provider_not_allowed},
          {:model_ref, "gemini-2.5-pro", :model_not_allowed},
          {:operation_class, "list_models", :operation_not_allowed},
          {:expires_at, DateTime.add(@issued_at, 121, :second), :grant_ttl_not_allowed}
        ] do
      input = %{
        provider_family: "gemini",
        model_ref: "gemini-2.5-flash",
        operation_class: "generate_content",
        issued_at: @issued_at,
        expires_at: DateTime.add(@issued_at, 60, :second)
      }

      assert {:denied, ^reason} =
               ModelInvocationPolicy.evaluate(policy, Map.put(input, field, value))
    end
  end

  test "artifact reconstruction rejects changed source under a pinned digest" do
    policy = ModelInvocationPolicy.synapse_gemini_turn!()

    assert_raise ArgumentError, ~r/source digest mismatch/, fn ->
      policy
      |> ModelInvocationPolicy.dump()
      |> Map.put(:allowed_models, ["gemini-2.5-pro"])
      |> ModelInvocationPolicy.new!()
    end
  end
end

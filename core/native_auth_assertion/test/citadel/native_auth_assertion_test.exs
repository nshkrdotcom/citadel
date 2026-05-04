defmodule Citadel.NativeAuthAssertionTest do
  use ExUnit.Case, async: true

  alias Citadel.NativeAuthAssertion

  test "builds a ref-only native auth assertion" do
    assert {:ok, assertion} = NativeAuthAssertion.new(valid_attrs())

    assert assertion.provider_family == "codex"
    assert assertion.assertion_ref == "native-auth-assertion://codex/root-a"

    assert NativeAuthAssertion.summary(assertion).provider_account_ref ==
             "provider-account://tenant/codex/a"
  end

  test "rejects raw native auth material" do
    assert {:error, error} =
             valid_attrs()
             |> Map.put(:raw_token, "sk-live-token")
             |> NativeAuthAssertion.new()

    assert Exception.message(error) == "native auth assertion rejects secret fields: raw_token"
    refute Exception.message(error) =~ "sk-live-token"
  end

  test "rejects provider payload and local private paths in metadata" do
    assert {:error, error} =
             valid_attrs()
             |> Map.put(:metadata, %{token_path: "/private/auth.json", provider_payload: %{}})
             |> NativeAuthAssertion.new()

    assert Exception.message(error) ==
             "native auth assertion rejects secret fields: provider_payload, token_path"
  end

  test "bounds provider families" do
    assert {:error, error} =
             valid_attrs()
             |> Map.put(:provider_family, "unknown")
             |> NativeAuthAssertion.new()

    assert Exception.message(error) == ~s(unsupported native auth provider family: "unknown")
  end

  defp valid_attrs do
    %{
      assertion_ref: "native-auth-assertion://codex/root-a",
      provider_family: "codex",
      provider_account_ref: "provider-account://tenant/codex/a",
      native_subject_ref: "native-subject://codex/root-a",
      target_ref: "target://sandbox/a",
      issued_by_ref: "system-authority://citadel/issuer",
      evidence_ref: "evidence://native-auth/root-a",
      metadata: %{login_state: "asserted"}
    }
  end
end

defmodule Citadel.AuthorityContract.AuthorityDecision.V1Test do
  use ExUnit.Case, async: true

  alias Citadel.AuthorityContract
  alias Citadel.AuthorityContract.AuthorityDecision.V1
  alias Citadel.ContractCore.CanonicalJson

  @fixture_dir Path.expand("../../fixtures/authority_decision_v1", __DIR__)

  test "matches the frozen minimal authority packet fixture" do
    fixture = read_fixture!("minimal.json")
    packet = V1.new!(fixture)

    assert AuthorityContract.authority_decision_module() == V1
    assert AuthorityContract.extensions_namespaces() == ["citadel"]

    assert V1.schema() == [
             contract_version: {:literal, "v1"},
             decision_id: :string,
             tenant_id: :string,
             request_id: :string,
             policy_version: :string,
             boundary_class: :string,
             trust_profile: :string,
             approval_profile: :string,
             egress_profile: :string,
             workspace_profile: :string,
             resource_profile: :string,
             decision_hash: :sha256_lower_hex,
             extensions: {:map, :citadel_namespaced_json}
           ]

    assert CanonicalJson.normalize!(V1.dump(packet)) == fixture
  end

  test "preserves citadel-only extensions through the frozen fixture" do
    fixture = read_fixture!("with_citadel_extensions.json")
    packet = V1.new!(fixture)

    assert packet.extensions["citadel"]["objective_id"] == "obj-7"
    assert packet.extensions["citadel"]["budget_policy"]["max_tokens"] == 8192
    assert CanonicalJson.normalize!(V1.dump(packet)) == fixture
  end

  test "exposes Phase 7 for_action_ref binding through the citadel extension" do
    packet =
      "minimal.json"
      |> read_fixture!()
      |> Map.put("extensions", %{
        "citadel" => %{"for_action_ref" => "action://agent-loop/turn-1"}
      })
      |> V1.new!()

    assert V1.action_bound?(packet)
    assert V1.for_action_ref(packet) == "action://agent-loop/turn-1"
    assert V1.require_for_action_ref!(packet) == "action://agent-loop/turn-1"

    unbound = read_fixture!("minimal.json") |> V1.new!()
    refute V1.action_bound?(unbound)

    assert_raise ArgumentError, fn ->
      V1.require_for_action_ref!(unbound)
    end
  end

  test "rejects unknown extension namespaces" do
    fixture = read_fixture!("minimal.json")
    attrs = put_in(fixture, ["extensions", "other"], %{})

    assert_raise ArgumentError, fn ->
      V1.new!(attrs)
    end
  end

  defp read_fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end

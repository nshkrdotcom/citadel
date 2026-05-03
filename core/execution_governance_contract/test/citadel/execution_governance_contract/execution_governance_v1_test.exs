defmodule Citadel.ExecutionGovernanceContract.ExecutionGovernance.V1Test do
  use ExUnit.Case, async: true

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.ExecutionGovernance.V1
  alias Citadel.ExecutionGovernanceContract

  @fixture_dir Path.expand("../../fixtures/execution_governance_v1", __DIR__)

  test "matches the frozen minimal execution governance packet fixture" do
    fixture = read_fixture!("minimal.json")
    packet = V1.new!(fixture)

    assert ExecutionGovernanceContract.manifest().status == :wave_10_data_layer_frozen
    assert ExecutionGovernanceContract.packet_name() == "ExecutionGovernance.v1"
    assert ExecutionGovernanceContract.contract_version() == "v1"
    assert ExecutionGovernanceContract.extensions_namespaces() == ["citadel"]

    assert V1.schema() == [
             contract_version: {:literal, "v1"},
             execution_governance_id: :string,
             authority_ref: {:map, :json},
             sandbox: {:map, :json},
             boundary: {:map, :json},
             topology: {:map, :json},
             workspace: {:map, :json},
             resources: {:map, :json},
             placement: {:map, :json},
             operations: {:map, :json},
             extensions: {:map, :citadel_namespaced_json}
           ]

    assert packet.sandbox["acceptable_attestation"] == ["local-erlexec-weak"]
    assert CanonicalJson.normalize!(V1.dump(packet)) == fixture
  end

  test "preserves citadel-only extensions and optional fields" do
    fixture = read_fixture!("with_citadel_extensions.json")
    packet = V1.new!(fixture)

    assert packet.extensions["citadel"]["selection_source"] == "policy_pack/runtime"

    assert packet.sandbox["acceptable_attestation"] == [
             "spiffe://prod/microvm-strict@v1",
             "local-erlexec-weak"
           ]

    assert packet.resources["wall_clock_budget_ms"] == 90_000
    assert packet.placement["node_affinity"] == "cell-a"
    assert CanonicalJson.normalize!(V1.dump(packet)) == fixture
  end

  test "rejects unknown extension namespaces" do
    fixture = read_fixture!("minimal.json")
    attrs = put_in(fixture, ["extensions", "other"], %{})

    assert_raise ArgumentError, fn ->
      V1.new!(attrs)
    end
  end

  test "rejects empty allowed operations" do
    fixture = put_in(read_fixture!("minimal.json"), ["operations", "allowed_operations"], [])

    assert_raise ArgumentError, fn ->
      V1.new!(fixture)
    end
  end

  defp read_fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end

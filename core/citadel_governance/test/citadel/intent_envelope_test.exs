defmodule Citadel.IntentEnvelopeTest do
  use ExUnit.Case, async: true

  alias Citadel.ContractCore.CanonicalJson
  alias Citadel.IntentEnvelope
  alias Citadel.IntentMappingConstraints
  alias Citadel.TopologyIntent

  @fixture_dir Path.expand("../fixtures/intent_envelope", __DIR__)

  test "freezes the valid intent envelope subschemas and mappings" do
    fixture = read_fixture!("valid.json")
    envelope = IntentEnvelope.new!(fixture)

    assert CanonicalJson.normalize!(IntentEnvelope.dump(envelope)) == fixture
    assert IntentMappingConstraints.planning_status(envelope) == :plannable

    assert IntentMappingConstraints.boundary_mapping(envelope) == %{
             requested_attach_mode: "fresh_or_reuse",
             preferred_boundary_class: "workspace_session",
             allowed_boundary_classes: ["workspace_session"]
           }

    assert IntentMappingConstraints.topology_mapping(envelope) == %{
             session_mode: :attached,
             coordination_mode: :single_target,
             routing_hints: %{
               preferred_target_ids: ["target-shell-1"],
               preferred_service_ids: ["svc-terminal"],
               routing_tags: ["repo_local"]
             }
           }
  end

  test "accepts structurally valid but deliberately unplannable ingress fixtures" do
    fixture = read_fixture!("unplannable.json")
    envelope = IntentEnvelope.new!(fixture)

    assert CanonicalJson.normalize!(IntentEnvelope.dump(envelope)) == fixture

    assert IntentMappingConstraints.planning_status(envelope) ==
             {:unplannable, "boundary_reuse_requires_attached_session"}
  end

  test "builds a typed topology intent with a deterministic generated id" do
    envelope = read_fixture!("valid.json") |> IntentEnvelope.new!()

    topology_intent =
      IntentMappingConstraints.topology_intent(
        envelope,
        topology_epoch: 7,
        extensions: %{"planner" => "wave-7"}
      )

    assert %TopologyIntent{} = topology_intent
    assert topology_intent.topology_epoch == 7
    assert topology_intent.session_mode == "attached"
    assert topology_intent.coordination_mode == "single_target"
    assert topology_intent.extensions == %{"planner" => "wave-7"}
    assert String.starts_with?(topology_intent.topology_intent_id, "topology/")

    assert topology_intent ==
             IntentMappingConstraints.topology_intent(
               envelope,
               topology_epoch: 7,
               extensions: %{"planner" => "wave-7"}
             )
  end

  test "rejects raw intent strings at the kernel boundary" do
    fixture = read_fixture!("valid.json") |> Map.put("intent", "open the repo")

    assert_raise ArgumentError, fn ->
      IntentEnvelope.new!(fixture)
    end
  end

  test "freezes carrier-shape versus value-mapping criteria" do
    assert IntentMappingConstraints.carrier_shape_change_criteria() == [
             :field_inventory,
             :requiredness,
             :field_type,
             :field_ownership,
             :public_field_meaning
           ]

    assert IntentMappingConstraints.value_mapping_change_examples() == [
             :selector_vocabularies,
             :defaults,
             :allowed_values,
             :population_rules
           ]
  end

  defp read_fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end

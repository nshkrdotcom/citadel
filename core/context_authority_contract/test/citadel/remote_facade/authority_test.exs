defmodule Citadel.RemoteFacade.AuthorityTest do
  use ExUnit.Case, async: true

  alias Citadel.RemoteFacade.Authority
  alias OuterBrain.ContextABI.ContextPacket

  test "declares owner-defined authority group" do
    assert Authority.owner_group() == {Authority, :authority}
  end

  test "authorizes context packet maps through Citadel context authority" do
    assert {:ok, grant} =
             Authority.authorize(%{
               "context_packet" => packet_attrs(),
               "authority_request" => authority_attrs(packet_attrs())
             })

    assert grant["tenant_ref"] == "tenant://one"
    assert grant["route_policy_ref"] == "route-policy://one"
    assert grant["trace_ref"] == "trace://one"
    assert grant["authority_ref"]
  end

  test "rejects missing context packet" do
    assert {:error, %{"code" => "invalid_envelope", "missing_field" => "context_packet"}} =
             Authority.authorize(%{"authority_request" => authority_attrs(packet_attrs())})
  end

  test "returns safe authority failure map" do
    assert {:error, %{"code" => "authority_denied", "reason_code" => reason_code}} =
             Authority.authorize(%{
               "context_packet" => packet_attrs(),
               "authority_request" => %{
                 authority_attrs(packet_attrs())
                 | "payload_mode" => "raw_payload"
               }
             })

    assert String.starts_with?(reason_code, "citadel.")
  end

  defp packet_attrs do
    %{
      "tenant_ref" => "tenant://one",
      "user_request_ref" => "user-request://one",
      "system_instruction_ref" => "system-instruction://one",
      "memory_refs" => ["memory://promoted/one"],
      "budget_ref" => "budget://one",
      "model_class_allowlist" => ["model-class://small"],
      "route_policy_ref" => "route-policy://one",
      "trace_ref" => "trace://one"
    }
  end

  defp authority_attrs(packet_attrs) do
    {:ok, packet} = ContextPacket.new(packet_attrs)

    %{
      "tenant_ref" => "tenant://one",
      "actor_ref" => "actor://one",
      "context_packet_ref" => packet.context_packet_ref,
      "model_class_allowlist" => ["model-class://small"],
      "route_policy_ref" => "route-policy://one",
      "trace_ref" => "trace://one",
      "payload_mode" => "refs_only",
      "redaction_class" => "tenant_sensitive"
    }
  end
end

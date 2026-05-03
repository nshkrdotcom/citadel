defmodule Citadel.ContractCore.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias Citadel.ContractCore
  alias Citadel.ContractCore.CanonicalJson

  test "tracks the packet-pinned JCS dependency boundary" do
    assert CanonicalJson.encoder_module() == Jcs
    assert ContractCore.manifest().external_dependencies == [:jcs]
    assert ContractCore.manifest().status == :wave_2_seam_frozen
  end

  test "normalizes packet values into JSON-safe string-keyed objects" do
    datetime = DateTime.from_naive!(~N[2026-04-10 08:30:00.123456], "Etc/UTC")

    normalized =
      CanonicalJson.normalize!(%{
        "a" => true,
        :b => 2,
        :time => datetime,
        :nested => [mode: :manual, flags: [nil, false]]
      })

    assert normalized == %{
             "a" => true,
             "b" => 2,
             "nested" => %{"flags" => [nil, false], "mode" => "manual"},
             "time" => "2026-04-10T08:30:00.123456Z"
           }

    assert CanonicalJson.encode!(%{b: 2, a: 1}) == "{\"a\":1,\"b\":2}"
  end

  test "rejects duplicate post-normalization object keys" do
    assert_raise ArgumentError, fn ->
      CanonicalJson.normalize!(%{:foo => 1, "foo" => 2})
    end

    assert_raise ArgumentError, fn ->
      CanonicalJson.normalize!(foo: 1, foo: 2)
    end
  end

  test "rejects oversized inline input before JCS encoding" do
    assert_raise ArgumentError, fn ->
      CanonicalJson.encode_inline!(
        %{"payload" => String.duplicate("x", 256)},
        max_bytes: 128,
        label: "Packet hash input"
      )
    end
  end

  test "rejects unsupported non-json values and generic structs" do
    assert_raise ArgumentError, fn ->
      CanonicalJson.normalize!({:tuple, 1})
    end

    assert_raise ArgumentError, fn ->
      CanonicalJson.normalize!(self())
    end

    assert_raise ArgumentError, fn ->
      CanonicalJson.normalize!(%URI{scheme: "https", host: "example.com"})
    end
  end
end

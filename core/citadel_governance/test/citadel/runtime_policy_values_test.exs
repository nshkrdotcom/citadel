defmodule Citadel.RuntimePolicyValuesTest do
  use ExUnit.Case, async: true

  alias Citadel.BoundaryResumePolicy
  alias Citadel.SessionActivationPolicy
  alias Citadel.SignalIngressRebuildPolicy

  test "signal ingress rebuild policy defaults to the packet MVP posture" do
    policy = SignalIngressRebuildPolicy.new!(%{})

    assert policy.max_sessions_per_batch == 64
    assert policy.batch_interval_ms == 250
    assert policy.high_priority_ready_slo_ms == 5_000

    assert Enum.take(policy.priority_order, 3) == [
             "explicit_resume",
             "live_request",
             "pending_replay_safe"
           ]
  end

  test "signal ingress rebuild policy rejects looser than packet MVP limits" do
    assert_raise ArgumentError, fn ->
      SignalIngressRebuildPolicy.new!(%{batch_interval_ms: 251})
    end

    assert_raise ArgumentError, fn ->
      SignalIngressRebuildPolicy.new!(%{high_priority_ready_slo_ms: 5_001})
    end
  end

  test "boundary resume policy defaults coalesced ttl to the retry interval" do
    policy = BoundaryResumePolicy.new!(%{})

    assert policy.max_wait_ms == 30_000
    assert policy.retry_interval_ms == 1_000
    assert policy.coalesced_request_ttl_ms == 1_000
  end

  test "boundary resume policy rejects unbounded waits" do
    assert_raise ArgumentError, fn ->
      BoundaryResumePolicy.new!(%{max_wait_ms: 30_001})
    end

    assert_raise ArgumentError, fn ->
      BoundaryResumePolicy.new!(%{retry_interval_ms: 1_001})
    end
  end

  test "session activation policy keeps blocked and replay-safe sessions ahead of idle work" do
    policy = SessionActivationPolicy.new!(%{})

    assert Enum.take(policy.priority_order, 4) == [
             "blocked",
             "pending_replay_safe",
             "explicit_resume",
             "committed_signal_lag"
           ]

    assert List.last(policy.priority_order) == "idle"
  end

  test "session activation policy rejects idle before recovery classes" do
    assert_raise ArgumentError, fn ->
      SessionActivationPolicy.new!(%{
        priority_order: [
          "blocked",
          "idle",
          "pending_replay_safe",
          "explicit_resume",
          "committed_signal_lag"
        ]
      })
    end
  end
end

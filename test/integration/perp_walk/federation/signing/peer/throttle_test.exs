defmodule PerpWalk.Federation.Signing.Peer.ThrottleIntegrationTest do
  @moduledoc "Integration tests for the per-peer signing throttle window."

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.Signing.Peer.Throttle

  # Anchor `now_ms` at a fixed point so tests are independent of
  # wall-clock time.
  @now 1_700_000_000_000
  @one_xmr 1_000_000_000_000

  setup do
    Throttle.reset()
    :ok
  end

  describe "reserve/2" do
    test "accepts amounts that fit under the default cap" do
      assert :ok = Throttle.reserve(50 * @one_xmr, @now)
      assert :ok = Throttle.reserve(50 * @one_xmr, @now + 100)
    end

    test "rejects an amount that would push the running total over the cap" do
      # Default cap is 200 XMR. Two 90-XMR reservations are 180; a
      # third would land at 270 — over cap.
      assert :ok = Throttle.reserve(90 * @one_xmr, @now)
      assert :ok = Throttle.reserve(90 * @one_xmr, @now + 100)
      assert {:reject, "peer_throttle:" <> _} = Throttle.reserve(90 * @one_xmr, @now + 200)
    end

    test "rejected reservation is not recorded against the window" do
      # Fill the window to exactly the cap.
      assert :ok = Throttle.reserve(200 * @one_xmr, @now)
      # Next call is rejected.
      assert {:reject, _} = Throttle.reserve(@one_xmr, @now + 100)
      # The rejected reservation should not consume any further
      # headroom — once an entry ages out, headroom returns by exactly
      # the original cap.
      cap = 200 * @one_xmr
      assert %{current_total: ^cap} = Throttle.status(@now + 100)
    end

    test "old entries are pruned outside the window" do
      cap = 200 * @one_xmr
      assert :ok = Throttle.reserve(cap, @now)

      # 6 hours + 1ms later, the original entry should be pruned.
      later = @now + 6 * 3_600 * 1_000 + 1
      assert :ok = Throttle.reserve(cap, later)
      assert %{current_total: ^cap} = Throttle.status(later)
    end

    test "entries within the window count even when many small" do
      Enum.each(1..20, fn i ->
        assert :ok = Throttle.reserve(10 * @one_xmr, @now + i)
      end)

      # Cumulative 200 XMR — exactly at cap. Next call must reject.
      assert {:reject, _} = Throttle.reserve(@one_xmr, @now + 21)
    end
  end

  describe "status/1" do
    test "reports zero on a fresh window" do
      assert %{current_total: 0, cap: cap, window_seconds: window} = Throttle.status(@now)
      assert cap == 200 * @one_xmr
      assert window == 6 * 3_600
    end

    test "reflects pruned entries on read" do
      hundred_xmr = 100 * @one_xmr
      assert :ok = Throttle.reserve(hundred_xmr, @now)
      assert %{current_total: ^hundred_xmr} = Throttle.status(@now + 1)

      # Past the window — the original entry is pruned.
      later = @now + 6 * 3_600 * 1_000 + 1
      assert %{current_total: 0} = Throttle.status(later)
    end
  end

  describe "config overrides" do
    setup do
      original = Application.get_env(:perpwalk, :peer_throttle)

      on_exit(fn ->
        if original do
          Application.put_env(:perpwalk, :peer_throttle, original)
        else
          Application.delete_env(:perpwalk, :peer_throttle)
        end

        # The Throttle GenServer captured the old config at init; restart
        # so subsequent suites get default values back.
        restart_throttle()
      end)

      :ok
    end

    test "honours :max_total_piconeros and :window_seconds overrides" do
      Application.put_env(:perpwalk, :peer_throttle,
        max_total_piconeros: 5 * @one_xmr,
        window_seconds: 60
      )

      restart_throttle()

      assert :ok = Throttle.reserve(3 * @one_xmr, @now)
      assert {:reject, _} = Throttle.reserve(3 * @one_xmr, @now + 100)
    end
  end

  # The Throttle reads its config at init/1 — to exercise overrides
  # the supervised process must be restarted after the config change.
  defp restart_throttle do
    pid = Process.whereis(Throttle)

    if pid do
      ref = Process.monitor(pid)
      :ok = Supervisor.terminate_child(PerpWalk.Federation.Supervisor, Throttle)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end

      {:ok, _} = Supervisor.restart_child(PerpWalk.Federation.Supervisor, Throttle)
    end

    :ok
  end
end

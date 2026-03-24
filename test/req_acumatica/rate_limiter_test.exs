defmodule ReqAcumatica.RateLimiterTest do
  use ExUnit.Case

  alias ReqAcumatica.RateLimiter

  describe "acquire/1" do
    test "allows requests up to rate limit" do
      {:ok, pid} = RateLimiter.start_link(name: :test_rl_basic, rate: 3, window: 60_000)

      assert :ok = RateLimiter.acquire(:test_rl_basic)
      assert :ok = RateLimiter.acquire(:test_rl_basic)
      assert :ok = RateLimiter.acquire(:test_rl_basic)

      # 4th request should block — test with a short timeout
      task =
        Task.async(fn ->
          try do
            RateLimiter.acquire(:test_rl_basic, 200)
          catch
            :exit, _ -> :timeout
          end
        end)

      assert Task.await(task) == :timeout

      GenServer.stop(pid)
    end

    test "refills tokens after window" do
      {:ok, pid} = RateLimiter.start_link(name: :test_rl_refill, rate: 2, window: 100)

      assert :ok = RateLimiter.acquire(:test_rl_refill)
      assert :ok = RateLimiter.acquire(:test_rl_refill)

      # Wait for refill
      Process.sleep(150)

      assert :ok = RateLimiter.acquire(:test_rl_refill)

      GenServer.stop(pid)
    end
  end

  describe "stats/1" do
    test "returns current state" do
      {:ok, pid} = RateLimiter.start_link(name: :test_rl_stats, rate: 10, window: 60_000)

      assert %{available_tokens: 10, max_tokens: 10, queued_waiters: 0} =
               RateLimiter.stats(:test_rl_stats)

      RateLimiter.acquire(:test_rl_stats)

      assert %{available_tokens: 9} = RateLimiter.stats(:test_rl_stats)

      GenServer.stop(pid)
    end
  end
end

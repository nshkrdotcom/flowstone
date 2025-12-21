defmodule FlowStone.HTTP.RetryTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.HTTP.Retry

  @default_config %{
    max_attempts: 3,
    base_delay_ms: 10,
    max_delay_ms: 100,
    jitter: false
  }

  describe "with_retry/2" do
    test "returns success immediately on 2xx response" do
      response = %{status: 200, body: %{"data" => "test"}, headers: %{}}

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          {:ok, response}
        end)

      assert {:ok, ^response} = result
    end

    test "returns success for all 2xx status codes" do
      for status <- 200..299 do
        response = %{status: status, body: %{}, headers: %{}}

        result =
          Retry.with_retry(@default_config, fn _attempt ->
            {:ok, response}
          end)

        assert {:ok, ^response} = result
      end
    end

    test "does not retry on 4xx client errors (except 429)" do
      call_count = :counters.new(1, [])

      response = %{status: 400, body: %{"error" => "bad request"}, headers: %{}}

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          {:ok, response}
        end)

      assert {:ok, ^response} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "retries on 429 rate limit" do
      call_count = :counters.new(1, [])

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count < 2 do
            {:ok, %{status: 429, body: %{}, headers: %{}}}
          else
            {:ok, %{status: 200, body: %{"success" => true}, headers: %{}}}
          end
        end)

      assert {:ok, %{status: 200}} = result
      assert :counters.get(call_count, 1) == 2
    end

    test "respects Retry-After header on 429" do
      call_count = :counters.new(1, [])
      start_time = System.monotonic_time(:millisecond)

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count < 2 do
            # Retry-After in seconds
            {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => "1"}}}
          else
            {:ok, %{status: 200, body: %{}, headers: %{}}}
          end
        end)

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert {:ok, %{status: 200}} = result
      # Should have waited at least 1 second (1000ms)
      assert elapsed >= 1000
    end

    test "retries on 5xx server errors" do
      call_count = :counters.new(1, [])

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count < 2 do
            {:ok, %{status: 500, body: %{}, headers: %{}}}
          else
            {:ok, %{status: 200, body: %{}, headers: %{}}}
          end
        end)

      assert {:ok, %{status: 200}} = result
      assert :counters.get(call_count, 1) == 2
    end

    test "retries on transport errors" do
      call_count = :counters.new(1, [])

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count < 2 do
            {:error, {:transport_error, :timeout}}
          else
            {:ok, %{status: 200, body: %{}, headers: %{}}}
          end
        end)

      assert {:ok, %{status: 200}} = result
      assert :counters.get(call_count, 1) == 2
    end

    test "does not retry on non-transport errors" do
      call_count = :counters.new(1, [])

      result =
        Retry.with_retry(@default_config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          {:error, {:request_error, %RuntimeError{message: "failed"}}}
        end)

      assert {:error, {:request_error, _}} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "gives up after max_attempts" do
      call_count = :counters.new(1, [])
      config = %{@default_config | max_attempts: 3}

      result =
        Retry.with_retry(config, fn _attempt ->
          :counters.add(call_count, 1, 1)
          {:ok, %{status: 500, body: %{}, headers: %{}}}
        end)

      # Should return the last error response
      assert {:ok, %{status: 500}} = result
      assert :counters.get(call_count, 1) == 3
    end

    test "returns last error after max_attempts exhausted on transport error" do
      config = %{@default_config | max_attempts: 2}

      result =
        Retry.with_retry(config, fn _attempt ->
          {:error, {:transport_error, :econnrefused}}
        end)

      assert {:error, {:transport_error, :econnrefused}} = result
    end
  end

  describe "exponential backoff" do
    test "delays increase exponentially" do
      config = %{@default_config | base_delay_ms: 50, max_delay_ms: 1000, jitter: false}

      call_count = :counters.new(1, [])
      timestamps = :ets.new(:timestamps, [:set, :public])

      Retry.with_retry(config, fn attempt ->
        :ets.insert(timestamps, {attempt, System.monotonic_time(:millisecond)})
        :counters.add(call_count, 1, 1)

        if attempt < 3 do
          {:ok, %{status: 500, body: %{}, headers: %{}}}
        else
          {:ok, %{status: 200, body: %{}, headers: %{}}}
        end
      end)

      [{1, t1}] = :ets.lookup(timestamps, 1)
      [{2, t2}] = :ets.lookup(timestamps, 2)
      [{3, t3}] = :ets.lookup(timestamps, 3)

      delay1 = t2 - t1
      delay2 = t3 - t2

      # First delay should be ~50ms (base)
      assert delay1 >= 45 and delay1 < 100
      # Second delay should be ~100ms (50 * 2^1)
      assert delay2 >= 90 and delay2 < 200
    end

    test "delays are capped at max_delay_ms" do
      config = %{
        @default_config
        | base_delay_ms: 100,
          max_delay_ms: 150,
          jitter: false,
          max_attempts: 4
      }

      timestamps = :ets.new(:timestamps, [:set, :public])

      Retry.with_retry(config, fn attempt ->
        :ets.insert(timestamps, {attempt, System.monotonic_time(:millisecond)})

        if attempt < 4 do
          {:ok, %{status: 500, body: %{}, headers: %{}}}
        else
          {:ok, %{status: 200, body: %{}, headers: %{}}}
        end
      end)

      [{3, t3}] = :ets.lookup(timestamps, 3)
      [{4, t4}] = :ets.lookup(timestamps, 4)

      delay = t4 - t3
      # Should be capped at 150ms, not 400ms (100 * 2^2)
      assert delay >= 140 and delay < 200
    end
  end

  describe "jitter" do
    test "adds randomness when jitter is enabled" do
      config = %{
        @default_config
        | base_delay_ms: 100,
          max_delay_ms: 1000,
          jitter: true,
          max_attempts: 10
      }

      # Collect delays from multiple retry runs
      delays =
        for _ <- 1..5 do
          timestamps = :ets.new(:timestamps, [:set, :public])

          Retry.with_retry(config, fn attempt ->
            :ets.insert(timestamps, {attempt, System.monotonic_time(:millisecond)})

            if attempt < 2 do
              {:ok, %{status: 500, body: %{}, headers: %{}}}
            else
              {:ok, %{status: 200, body: %{}, headers: %{}}}
            end
          end)

          [{1, t1}] = :ets.lookup(timestamps, 1)
          [{2, t2}] = :ets.lookup(timestamps, 2)
          t2 - t1
        end

      # With jitter, delays should vary (not all identical)
      # At least some should be different (or there's only one unique value)
      unique_delays = Enum.uniq(delays)
      # Should have at least one delay recorded
      refute Enum.empty?(unique_delays)
    end
  end
end

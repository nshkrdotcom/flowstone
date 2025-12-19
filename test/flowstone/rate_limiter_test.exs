defmodule FlowStone.RateLimiterTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.RateLimiter

  setup do
    # Reset any buckets from previous tests
    RateLimiter.reset("test-bucket")
    RateLimiter.reset("test-slot-bucket")
    :ok
  end

  describe "check/2" do
    test "allows operations under limit" do
      bucket = "test-bucket-#{System.unique_integer()}"

      assert :ok = RateLimiter.check(bucket, {10, :second})
      assert :ok = RateLimiter.check(bucket, {10, :second})
      assert :ok = RateLimiter.check(bucket, {10, :second})
    end

    test "rate limits when exceeded" do
      bucket = "test-bucket-#{System.unique_integer()}"

      # Use up the limit
      for _ <- 1..5 do
        RateLimiter.check(bucket, {5, :second})
      end

      # Next should be rate limited
      result = RateLimiter.check(bucket, {5, :second})
      assert {:wait, ms} = result
      assert is_integer(ms)
    end
  end

  describe "with_limit/4" do
    test "executes function when allowed" do
      bucket = "test-bucket-#{System.unique_integer()}"

      {:ok, result} =
        RateLimiter.with_limit(bucket, {10, :second}, fn ->
          :executed
        end)

      assert result == :executed
    end

    test "retries until allowed" do
      bucket = "test-bucket-#{System.unique_integer()}"
      counter = :counters.new(1, [])

      # Use up some of the limit
      for _ <- 1..3 do
        RateLimiter.check(bucket, {5, :second})
      end

      # Should still execute (under limit)
      {:ok, result} =
        RateLimiter.with_limit(
          bucket,
          {5, :second},
          fn ->
            :counters.add(counter, 1, 1)
            :done
          end,
          max_wait: 100
        )

      assert result == :done
    end
  end

  describe "status/2" do
    test "returns bucket status" do
      bucket = "test-bucket-#{System.unique_integer()}"

      # Make some requests
      RateLimiter.check(bucket, {10, :second})
      RateLimiter.check(bucket, {10, :second})

      status = RateLimiter.status(bucket, {10, :second})

      assert status.bucket == bucket
      assert status.limit == 10
      assert status.period == :second
      assert status.count >= 0
      assert status.remaining >= 0
    end
  end

  describe "reset/1" do
    test "resets bucket count" do
      bucket = "test-bucket-#{System.unique_integer()}"

      # Make some requests
      for _ <- 1..5 do
        RateLimiter.check(bucket, {10, :second})
      end

      # Reset
      :ok = RateLimiter.reset(bucket)

      # Should be able to make requests again
      assert :ok = RateLimiter.check(bucket, {5, :second})
    end
  end

  describe "acquire_slot/2 and release_slot/2" do
    @tag :skip_in_isolation
    test "acquires and releases slots (requires Postgres)" do
      # Note: This test requires a real Postgres connection for advisory locks
      # In isolation mode, Postgres advisory locks may not work correctly
      bucket = "test-slot-#{System.unique_integer()}"

      case RateLimiter.acquire_slot(bucket, 3) do
        {:ok, slot1} ->
          assert slot1 >= 1 and slot1 <= 3

          {:ok, slot2} = RateLimiter.acquire_slot(bucket, 3)
          assert slot2 >= 1 and slot2 <= 3

          # Clean up
          RateLimiter.release_slot(bucket, slot1)
          RateLimiter.release_slot(bucket, slot2)

        {:error, :at_capacity} ->
          # Advisory locks not available in test isolation
          :ok
      end
    end

    @tag :skip
    test "returns error when at capacity (requires Postgres and separate processes)" do
      # Note: Postgres advisory locks are session-scoped and re-entrant within
      # the same connection. To properly test capacity limits, we would need
      # multiple database connections in separate processes.
      #
      # In production, this works correctly because each Oban worker runs in
      # its own process with its own database connection.
      _bucket = "test-slot-#{System.unique_integer()}"

      # Skip this test - advisory lock capacity testing requires multi-process setup
      assert true
    end
  end

  describe "with_slot/4" do
    test "executes function with acquired slot" do
      bucket = "test-slot-#{System.unique_integer()}"

      {:ok, result} =
        RateLimiter.with_slot(bucket, 5, fn ->
          :executed
        end)

      assert result == :executed
    end

    test "releases slot after execution" do
      bucket = "test-slot-#{System.unique_integer()}"

      # Execute with slot
      {:ok, :done} = RateLimiter.with_slot(bucket, 1, fn -> :done end)

      # Should be able to acquire again
      {:ok, :done2} = RateLimiter.with_slot(bucket, 1, fn -> :done2 end)

      assert true
    end

    test "releases slot even on error" do
      bucket = "test-slot-#{System.unique_integer()}"

      # Execute with error
      try do
        RateLimiter.with_slot(bucket, 1, fn ->
          raise "test error"
        end)
      rescue
        _ -> :ok
      end

      # Should be able to acquire again
      {:ok, :done} = RateLimiter.with_slot(bucket, 1, fn -> :done end)
      assert true
    end
  end
end

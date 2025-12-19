defmodule FlowStone.RateLimiter do
  @moduledoc """
  Global rate limiting for FlowStone operations.

  Provides distributed rate limiting using Postgres advisory locks
  and the Hammer library. Supports:

  - Per-asset rate limits
  - Per-domain rate limits (for scraping)
  - Per-scatter-barrier rate limits
  - Global rate limits

  ## Usage

      # Check rate limit before operation
      case FlowStone.RateLimiter.check("scraper:example.com", {10, :second}) do
        :ok -> proceed_with_operation()
        {:wait, ms} -> {:snooze, div(ms, 1000) + 1}
      end

      # With automatic retry
      FlowStone.RateLimiter.with_limit("api:openai", {60, :minute}, fn ->
        call_openai_api()
      end)
  """

  alias FlowStone.Repo

  @type bucket :: String.t()
  @type limit :: pos_integer()
  @type period :: :second | :minute | :hour
  @type rate :: {limit(), period()}

  @doc """
  Check if an operation is allowed under the rate limit.

  Returns `:ok` if allowed, or `{:wait, milliseconds}` if rate limited.

  ## Examples

      iex> FlowStone.RateLimiter.check("my-bucket", {10, :second})
      :ok

      iex> FlowStone.RateLimiter.check("exceeded-bucket", {10, :second})
      {:wait, 850}
  """
  @spec check(bucket(), rate()) :: :ok | {:wait, pos_integer()}
  def check(bucket, {limit, period}) do
    scale = period_to_ms(period)

    case Hammer.check_rate(bucket, scale, limit) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:wait, estimate_wait_time(scale, limit)}
    end
  end

  @doc """
  Execute a function with rate limiting.

  Blocks until the rate limit allows execution, then runs the function.
  Returns `{:ok, result}` or `{:error, :rate_limit_timeout}` if max_wait exceeded.

  ## Options

  - `:max_wait` - Maximum time to wait in milliseconds (default: 60_000)
  - `:retry_interval` - Time between retries in milliseconds (default: 100)

  ## Examples

      FlowStone.RateLimiter.with_limit("api:openai", {60, :minute}, fn ->
        OpenAI.complete(prompt)
      end)
  """
  @spec with_limit(bucket(), rate(), (-> term()), keyword()) ::
          {:ok, term()} | {:error, :rate_limit_timeout}
  def with_limit(bucket, rate, fun, opts \\ []) do
    max_wait = Keyword.get(opts, :max_wait, 60_000)
    retry_interval = Keyword.get(opts, :retry_interval, 100)
    deadline = System.monotonic_time(:millisecond) + max_wait

    do_with_limit(bucket, rate, fun, deadline, retry_interval)
  end

  defp do_with_limit(bucket, rate, fun, deadline, retry_interval) do
    case check(bucket, rate) do
      :ok ->
        {:ok, fun.()}

      {:wait, _ms} ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(retry_interval)
          do_with_limit(bucket, rate, fun, deadline, retry_interval)
        else
          {:error, :rate_limit_timeout}
        end
    end
  end

  @doc """
  Acquire a global semaphore slot using Postgres advisory locks.

  Returns `{:ok, slot}` if acquired, `{:error, :at_capacity}` if full.

  ## Examples

      case FlowStone.RateLimiter.acquire_slot("scatter:abc123", 50) do
        {:ok, slot} ->
          try do
            do_work()
          after
            FlowStone.RateLimiter.release_slot("scatter:abc123", slot)
          end

        {:error, :at_capacity} ->
          {:snooze, 5}
      end
  """
  @spec acquire_slot(bucket(), pos_integer()) :: {:ok, pos_integer()} | {:error, :at_capacity}
  def acquire_slot(bucket, max_slots) do
    lock_key = bucket_to_lock_key(bucket)

    # Try each slot from 1 to max_slots
    Enum.find_value(1..max_slots, {:error, :at_capacity}, fn slot ->
      case try_advisory_lock(lock_key, slot) do
        true -> {:ok, slot}
        false -> nil
      end
    end)
  end

  @doc """
  Release a semaphore slot.
  """
  @spec release_slot(bucket(), pos_integer()) :: :ok
  def release_slot(bucket, slot) do
    lock_key = bucket_to_lock_key(bucket)
    release_advisory_lock(lock_key, slot)
    :ok
  end

  @doc """
  Execute a function with semaphore-based concurrency limiting.

  ## Examples

      FlowStone.RateLimiter.with_slot("scatter:abc123", 50, fn ->
        expensive_operation()
      end)
  """
  @spec with_slot(bucket(), pos_integer(), (-> term()), keyword()) ::
          {:ok, term()} | {:error, :at_capacity | :slot_timeout}
  def with_slot(bucket, max_slots, fun, opts \\ []) do
    max_wait = Keyword.get(opts, :max_wait, 30_000)
    retry_interval = Keyword.get(opts, :retry_interval, 100)
    deadline = System.monotonic_time(:millisecond) + max_wait

    do_with_slot(bucket, max_slots, fun, deadline, retry_interval)
  end

  defp do_with_slot(bucket, max_slots, fun, deadline, retry_interval) do
    case acquire_slot(bucket, max_slots) do
      {:ok, slot} ->
        try do
          {:ok, fun.()}
        after
          release_slot(bucket, slot)
        end

      {:error, :at_capacity} ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(retry_interval)
          do_with_slot(bucket, max_slots, fun, deadline, retry_interval)
        else
          {:error, :slot_timeout}
        end
    end
  end

  @doc """
  Get current usage for a bucket.

  Returns a map with count and remaining capacity.
  """
  @spec status(bucket(), rate()) :: map()
  def status(bucket, {limit, period}) do
    scale = period_to_ms(period)

    case Hammer.inspect_bucket(bucket, scale, limit) do
      {:ok, {count, _count_remaining, _ms_to_next, _created, _updated}} ->
        %{
          bucket: bucket,
          count: count,
          limit: limit,
          period: period,
          remaining: max(0, limit - count),
          utilization: count / limit * 100
        }

      {:error, _} ->
        %{
          bucket: bucket,
          count: 0,
          limit: limit,
          period: period,
          remaining: limit,
          utilization: 0
        }
    end
  end

  @doc """
  Reset a rate limit bucket.
  """
  @spec reset(bucket()) :: :ok
  def reset(bucket) do
    Hammer.delete_buckets(bucket)
    :ok
  end

  # Private helpers

  defp period_to_ms(:second), do: 1_000
  defp period_to_ms(:minute), do: 60_000
  defp period_to_ms(:hour), do: 3_600_000

  defp estimate_wait_time(scale, limit) do
    # Estimate wait time as scale / limit (average time between allowed requests)
    div(scale, limit)
  end

  defp bucket_to_lock_key(bucket) do
    # Convert bucket string to a consistent integer for advisory locks
    :erlang.phash2(bucket)
  end

  defp try_advisory_lock(lock_key, slot) do
    case Repo.query("SELECT pg_try_advisory_lock($1, $2)", [lock_key, slot]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  rescue
    # Handle case where Repo is not available
    _ -> false
  end

  defp release_advisory_lock(lock_key, slot) do
    Repo.query("SELECT pg_advisory_unlock($1, $2)", [lock_key, slot])
  rescue
    _ -> :ok
  end
end

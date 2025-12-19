# Rate Limiter Example - Distributed Rate Limiting
#
# This example demonstrates FlowStone's rate limiting capabilities for
# controlling throughput across distributed workers.

Logger.configure(level: :info)

alias FlowStone.RateLimiter

IO.puts("=" |> String.duplicate(60))
IO.puts("FlowStone Rate Limiter Example")
IO.puts("=" |> String.duplicate(60))

# Example 1: Simple rate limit checking
IO.puts("\n--- Example 1: Rate Limit Checking ---")

bucket = "api:openai"
limit = {5, :second}

IO.puts("Checking rate limit for bucket '#{bucket}' with limit 5/second")

for i <- 1..7 do
  case RateLimiter.check(bucket, limit) do
    :ok ->
      IO.puts("  Request #{i}: ALLOWED")

    {:wait, ms} ->
      IO.puts("  Request #{i}: RATE LIMITED (wait #{ms}ms)")
  end
end

# Reset for next example
RateLimiter.reset(bucket)

# Example 2: Rate limit status
IO.puts("\n--- Example 2: Rate Limit Status ---")

bucket = "scraper:example.com"
limit = {10, :second}

# Make some requests
for _ <- 1..4 do
  RateLimiter.check(bucket, limit)
end

status = RateLimiter.status(bucket, limit)

IO.puts("Status for bucket '#{bucket}':")
IO.puts("  Count: #{status.count}/#{status.limit}")
IO.puts("  Remaining: #{status.remaining}")
IO.puts("  Utilization: #{Float.round(status.utilization, 1)}%")

RateLimiter.reset(bucket)

# Example 3: Execute with rate limiting
IO.puts("\n--- Example 3: Execute with Rate Limiting ---")

bucket = "api:slow"
limit = {2, :second}

IO.puts("Executing 4 operations with limit of 2/second...")

for i <- 1..4 do
  start = System.monotonic_time(:millisecond)

  {:ok, result} =
    RateLimiter.with_limit(bucket, limit, fn ->
      Process.sleep(50)
      "result_#{i}"
    end)

  elapsed = System.monotonic_time(:millisecond) - start
  IO.puts("  Operation #{i}: #{result} (took #{elapsed}ms)")
end

RateLimiter.reset(bucket)

# Example 4: Semaphore-based concurrency limiting
IO.puts("\n--- Example 4: Semaphore-based Concurrency ---")

bucket = "expensive:operation"
max_slots = 3

IO.puts("Running 5 operations with max 3 concurrent...")

tasks =
  for i <- 1..5 do
    Task.async(fn ->
      start = System.monotonic_time(:millisecond)

      result =
        RateLimiter.with_slot(bucket, max_slots, fn ->
          Process.sleep(200)
          "task_#{i}_done"
        end)

      elapsed = System.monotonic_time(:millisecond) - start
      {i, result, elapsed}
    end)
  end

results = Task.await_many(tasks, 5000)

for {i, result, elapsed} <- results do
  case result do
    {:ok, value} -> IO.puts("  Task #{i}: #{value} (#{elapsed}ms)")
    {:error, reason} -> IO.puts("  Task #{i}: ERROR #{reason} (#{elapsed}ms)")
  end
end

# Example 5: Domain-specific rate limiting (for scrapers)
IO.puts("\n--- Example 5: Per-Domain Rate Limiting ---")

domains = ["example.com", "test.org", "sample.net"]

for domain <- domains do
  bucket = "scraper:#{domain}"
  limit = {3, :second}

  IO.puts("\nDomain: #{domain}")

  for i <- 1..4 do
    case RateLimiter.check(bucket, limit) do
      :ok -> IO.puts("  Request #{i}: OK")
      {:wait, _} -> IO.puts("  Request #{i}: WAIT")
    end
  end

  RateLimiter.reset(bucket)
end

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Rate Limiter Example Complete!")
IO.puts(String.duplicate("=", 60))

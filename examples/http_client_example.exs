# HTTP Client Example
#
# This example demonstrates using FlowStone.HTTP.Client as a resource
# for REST API integrations in pipelines.
#
# Run with: mix run examples/http_client_example.exs

# ============================================================================
# Setup
# ============================================================================

Application.ensure_all_started(:flowstone)

alias FlowStone.HTTP.Client

IO.puts("=" |> String.duplicate(60))
IO.puts("FlowStone HTTP Client Example")
IO.puts("=" |> String.duplicate(60))

# ============================================================================
# 1. Basic Client Setup
# ============================================================================

IO.puts("\n1. Basic Client Setup")
IO.puts("-" |> String.duplicate(40))

{:ok, client} =
  Client.setup(%{
    base_url: "https://jsonplaceholder.typicode.com",
    timeout: 30_000,
    headers: %{
      "X-Custom-Header" => "FlowStone-Example"
    }
  })

IO.puts("✓ Client created with base_url: #{client.base_url}")
IO.puts("✓ Timeout: #{client.timeout}ms")
IO.puts("✓ Headers: #{inspect(client.headers)}")

# ============================================================================
# 2. Client Configuration Options
# ============================================================================

IO.puts("\n2. Full Configuration Example")
IO.puts("-" |> String.duplicate(40))

{:ok, configured_client} =
  Client.setup(%{
    base_url: "https://api.example.com",
    timeout: 60_000,
    headers: %{
      "Authorization" => "Bearer token123",
      "X-Client-ID" => "flowstone-pipeline"
    },
    retry: %{
      max_attempts: 5,
      base_delay_ms: 500,
      max_delay_ms: 30_000,
      jitter: true
    },
    req_options: [
      pool_timeout: 5_000
    ]
  })

IO.puts("✓ Configured client:")
IO.puts("  - Base URL: #{configured_client.base_url}")
IO.puts("  - Timeout: #{configured_client.timeout}ms")
IO.puts("  - Max retry attempts: #{configured_client.retry_config.max_attempts}")
IO.puts("  - Base delay: #{configured_client.retry_config.base_delay_ms}ms")
IO.puts("  - Jitter: #{configured_client.retry_config.jitter}")

# ============================================================================
# 3. Making HTTP Requests (Live API)
# ============================================================================

IO.puts("\n3. Making HTTP Requests")
IO.puts("-" |> String.duplicate(40))

# GET request to JSONPlaceholder (free fake API for testing)
IO.puts("\nGET /posts/1:")

case Client.get(client, "/posts/1") do
  {:ok, %{status: 200, body: body}} ->
    IO.puts("✓ Status: 200 OK")
    IO.puts("✓ Title: #{body["title"] |> String.slice(0, 50)}...")

  {:ok, %{status: status}} ->
    IO.puts("✗ Unexpected status: #{status}")

  {:error, reason} ->
    IO.puts("✗ Error: #{inspect(reason)}")
end

# GET list
IO.puts("\nGET /users (first 3):")

case Client.get(client, "/users") do
  {:ok, %{status: 200, body: users}} when is_list(users) ->
    IO.puts("✓ Status: 200 OK")

    users
    |> Enum.take(3)
    |> Enum.each(fn user ->
      IO.puts("  - #{user["name"]} (#{user["email"]})")
    end)

  {:ok, %{status: status}} ->
    IO.puts("✗ Unexpected status: #{status}")

  {:error, reason} ->
    IO.puts("✗ Error: #{inspect(reason)}")
end

# POST request
IO.puts("\nPOST /posts:")

new_post = %{
  title: "FlowStone Test Post",
  body: "This is a test post from FlowStone HTTP Client",
  userId: 1
}

case Client.post(client, "/posts", new_post) do
  {:ok, %{status: 201, body: created}} ->
    IO.puts("✓ Status: 201 Created")
    IO.puts("✓ Created post ID: #{created["id"]}")

  {:ok, %{status: status, body: body}} ->
    IO.puts("✗ Unexpected status: #{status}")
    IO.puts("  Body: #{inspect(body)}")

  {:error, reason} ->
    IO.puts("✗ Error: #{inspect(reason)}")
end

# ============================================================================
# 4. Idempotency Key Example
# ============================================================================

IO.puts("\n4. Idempotency Key for Safe Retries")
IO.puts("-" |> String.duplicate(40))

idempotency_key = "order-#{:erlang.unique_integer([:positive])}"
IO.puts("Using idempotency key: #{idempotency_key}")

case Client.post(client, "/posts", %{title: "Idempotent Post", body: "Safe to retry", userId: 1},
       idempotency_key: idempotency_key
     ) do
  {:ok, %{status: 201}} ->
    IO.puts("✓ Request succeeded with idempotency key")
    IO.puts("  (Server can use this key to deduplicate retries)")

  {:error, reason} ->
    IO.puts("✗ Error: #{inspect(reason)}")
end

# ============================================================================
# 5. Request Options
# ============================================================================

IO.puts("\n5. Request Options")
IO.puts("-" |> String.duplicate(40))

# Custom timeout per request
IO.puts("\nCustom timeout (5 seconds):")

case Client.get(client, "/posts/1", timeout: 5_000) do
  {:ok, %{status: 200}} -> IO.puts("✓ Request completed within 5s timeout")
  {:error, {:transport_error, :timeout}} -> IO.puts("✗ Request timed out")
  {:error, reason} -> IO.puts("✗ Error: #{inspect(reason)}")
end

# Disable retry
IO.puts("\nDisabled retry:")

case Client.get(client, "/posts/1", retry: false) do
  {:ok, %{status: 200}} -> IO.puts("✓ Request succeeded (no retries)")
  {:error, reason} -> IO.puts("✗ Error (no retry attempted): #{inspect(reason)}")
end

# Additional headers per request
IO.puts("\nExtra headers per request:")

case Client.get(client, "/posts/1", headers: %{"X-Request-ID" => "abc123"}) do
  {:ok, %{status: 200}} -> IO.puts("✓ Request with extra headers succeeded")
  {:error, reason} -> IO.puts("✗ Error: #{inspect(reason)}")
end

# ============================================================================
# 6. Pipeline Integration Pattern
# ============================================================================

IO.puts("\n6. Pipeline Integration Pattern")
IO.puts("-" |> String.duplicate(40))

defmodule APIIntegrationPipeline do
  use FlowStone.Pipeline

  asset :fetch_user do
    execute fn _ctx, _deps ->
      # In a real pipeline, client would come from ctx.resources[:api]
      # For this example, we create it inline
      {:ok, client} =
        FlowStone.HTTP.Client.setup(%{
          base_url: "https://jsonplaceholder.typicode.com"
        })

      # Using user_id 1 for this example
      user_id = 1

      case FlowStone.HTTP.Client.get(client, "/users/#{user_id}") do
        {:ok, %{status: 200, body: user}} ->
          {:ok, user}

        {:ok, %{status: 404}} ->
          {:error, :user_not_found}

        {:error, reason} ->
          {:error, {:api_error, reason}}
      end
    end
  end

  asset :fetch_user_posts do
    depends_on([:fetch_user])

    execute fn _ctx, %{fetch_user: user} ->
      {:ok, client} =
        FlowStone.HTTP.Client.setup(%{
          base_url: "https://jsonplaceholder.typicode.com"
        })

      case FlowStone.HTTP.Client.get(client, "/posts?userId=#{user["id"]}") do
        {:ok, %{status: 200, body: posts}} ->
          {:ok, %{user: user, posts: posts}}

        {:error, reason} ->
          {:error, {:api_error, reason}}
      end
    end
  end

  asset :summary do
    depends_on([:fetch_user_posts])

    execute fn _ctx, %{fetch_user_posts: %{user: user, posts: posts}} ->
      {:ok,
       %{
         user_name: user["name"],
         email: user["email"],
         post_count: length(posts),
         latest_post: posts |> List.first() |> Map.get("title", "No posts")
       }}
    end
  end
end

IO.puts("\nRunning API integration pipeline:")

case FlowStone.run(APIIntegrationPipeline, :summary) do
  {:ok, summary} ->
    IO.puts("✓ Pipeline completed successfully!")
    IO.puts("  User: #{summary.user_name}")
    IO.puts("  Email: #{summary.email}")
    IO.puts("  Post count: #{summary.post_count}")
    IO.puts("  Latest post: #{summary.latest_post |> String.slice(0, 40)}...")

  {:error, reason} ->
    IO.puts("✗ Pipeline failed: #{inspect(reason)}")
end

# ============================================================================
# 7. Resource Lifecycle
# ============================================================================

IO.puts("\n7. Resource Lifecycle")
IO.puts("-" |> String.duplicate(40))

{:ok, lifecycle_client} = Client.setup(%{base_url: "https://api.example.com"})
IO.puts("✓ Client setup complete")

# Teardown (cleanup)
:ok = Client.teardown(lifecycle_client)
IO.puts("✓ Client teardown complete")

# ============================================================================
# Summary
# ============================================================================

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("HTTP Client Example Complete!")
IO.puts(String.duplicate("=", 60))

IO.puts("""

Key Features Demonstrated:
  1. Client setup with configuration options
  2. GET, POST requests with JSON handling
  3. Idempotency keys for safe retries
  4. Per-request options (timeout, retry, headers)
  5. Pipeline integration pattern
  6. Resource lifecycle (setup/teardown)

The HTTP client automatically handles:
  - Retry with exponential backoff on 5xx errors
  - Rate limit handling (429 with Retry-After)
  - Transport error retries (timeouts, connection issues)
  - Telemetry events for monitoring
""")

# HTTP Adapter Design

## Overview

The HTTP adapter provides a standardized way for FlowStone assets to make HTTP requests to external services. It follows FlowStone's Resource pattern for configuration and lifecycle management.

## Design Goals

1. **Pluggable** - Swappable via configuration
2. **Observable** - Full telemetry integration
3. **Resilient** - Retry with exponential backoff
4. **Simple** - Minimal API surface

## Module Structure

```
lib/flowstone/http/
├── client.ex           # Main resource module
├── retry.ex            # Retry logic
└── telemetry.ex        # Telemetry helpers
```

## FlowStone.HTTP.Client

### Module Definition

```elixir
defmodule FlowStone.HTTP.Client do
  @moduledoc """
  HTTP client resource for FlowStone pipelines.

  Provides HTTP operations with built-in retry, timeout handling,
  and telemetry integration.

  ## Usage

  Register as a resource:

      FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
        base_url: "https://api.example.com",
        timeout: 30_000,
        headers: %{"Authorization" => "Bearer \#{token}"}
      )

  Use in assets:

      asset :fetch_data do
        requires [:api]

        execute fn ctx, _deps ->
          client = ctx.resources[:api]
          FlowStone.HTTP.Client.get(client, "/users/\#{ctx.partition.user_id}")
        end
      end

  """

  @behaviour FlowStone.Resource

  defstruct [
    :base_url,
    :headers,
    :timeout,
    :retry_config,
    :req_options
  ]

  @type t :: %__MODULE__{
    base_url: String.t(),
    headers: map(),
    timeout: pos_integer(),
    retry_config: retry_config(),
    req_options: keyword()
  }

  @type retry_config :: %{
    max_attempts: pos_integer(),
    base_delay_ms: pos_integer(),
    max_delay_ms: pos_integer(),
    jitter: boolean()
  }

  @type response :: %{
    status: integer(),
    body: term(),
    headers: map()
  }

  @default_timeout 30_000
  @default_retry %{
    max_attempts: 3,
    base_delay_ms: 1000,
    max_delay_ms: 30_000,
    jitter: true
  }

  # ============================================================================
  # Resource Callbacks
  # ============================================================================

  @impl FlowStone.Resource
  def setup(config) do
    unless config[:base_url] do
      raise ArgumentError, "FlowStone.HTTP.Client requires :base_url in config"
    end

    client = %__MODULE__{
      base_url: normalize_base_url(config[:base_url]),
      headers: Map.merge(default_headers(), config[:headers] || %{}),
      timeout: config[:timeout] || @default_timeout,
      retry_config: Map.merge(@default_retry, config[:retry] || %{}),
      req_options: config[:req_options] || []
    }

    {:ok, client}
  end

  @impl FlowStone.Resource
  def teardown(_client), do: :ok

  @impl FlowStone.Resource
  def health_check(client) do
    # Try to hit /health endpoint with short timeout
    opts = [timeout: 5_000, retry: false]

    case get(client, "/health", opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :healthy

      {:ok, %{status: status}} ->
        {:unhealthy, {:http_status, status}}

      {:error, reason} ->
        {:unhealthy, reason}
    end
  end

  # ============================================================================
  # HTTP Operations
  # ============================================================================

  @doc """
  Perform HTTP GET request.

  ## Options

    * `:timeout` - Request timeout in milliseconds
    * `:retry` - Whether to retry on failure (default: true)
    * `:headers` - Additional headers to merge

  ## Examples

      FlowStone.HTTP.Client.get(client, "/users")
      FlowStone.HTTP.Client.get(client, "/users/123", timeout: 5_000)

  """
  @spec get(t(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def get(client, path, opts \\ []) do
    request(client, :get, path, nil, opts)
  end

  @doc """
  Perform HTTP POST request with JSON body.

  ## Examples

      FlowStone.HTTP.Client.post(client, "/users", %{name: "Alice"})
      FlowStone.HTTP.Client.post(client, "/users", %{name: "Alice"},
        idempotency_key: "create-alice-123"
      )

  """
  @spec post(t(), String.t(), map(), keyword()) :: {:ok, response()} | {:error, term()}
  def post(client, path, body, opts \\ []) do
    request(client, :post, path, body, opts)
  end

  @doc """
  Perform HTTP PUT request with JSON body.
  """
  @spec put(t(), String.t(), map(), keyword()) :: {:ok, response()} | {:error, term()}
  def put(client, path, body, opts \\ []) do
    request(client, :put, path, body, opts)
  end

  @doc """
  Perform HTTP PATCH request with JSON body.
  """
  @spec patch(t(), String.t(), map(), keyword()) :: {:ok, response()} | {:error, term()}
  def patch(client, path, body, opts \\ []) do
    request(client, :patch, path, body, opts)
  end

  @doc """
  Perform HTTP DELETE request.
  """
  @spec delete(t(), String.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def delete(client, path, opts \\ []) do
    request(client, :delete, path, nil, opts)
  end

  # ============================================================================
  # Internal Implementation
  # ============================================================================

  defp request(client, method, path, body, opts) do
    url = client.base_url <> path
    timeout = Keyword.get(opts, :timeout, client.timeout)
    should_retry = Keyword.get(opts, :retry, true)

    headers = client.headers
    |> Map.merge(Keyword.get(opts, :headers, %{}))
    |> maybe_add_idempotency_key(Keyword.get(opts, :idempotency_key))

    metadata = %{
      method: method,
      url: url,
      path: path,
      base_url: client.base_url
    }

    start_time = System.monotonic_time()
    emit_start(metadata)

    result = if should_retry do
      FlowStone.HTTP.Retry.with_retry(client.retry_config, fn attempt ->
        do_request(method, url, body, headers, timeout, client.req_options, attempt)
      end)
    else
      do_request(method, url, body, headers, timeout, client.req_options, 1)
    end

    duration = System.monotonic_time() - start_time
    emit_stop_or_error(result, duration, metadata)

    result
  end

  defp do_request(method, url, body, headers, timeout, req_options, _attempt) do
    req_opts = [
      method: method,
      url: url,
      headers: Enum.into(headers, []),
      receive_timeout: timeout
    ] ++ req_options

    req_opts = if body do
      Keyword.put(req_opts, :json, body)
    else
      req_opts
    end

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok, %{
          status: status,
          body: resp_body,
          headers: normalize_headers(resp_headers)
        }}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, exception} ->
        {:error, {:request_error, exception}}
    end
  end

  defp maybe_add_idempotency_key(headers, nil), do: headers
  defp maybe_add_idempotency_key(headers, key) do
    Map.put(headers, "X-Idempotency-Key", key)
  end

  defp normalize_base_url(url) do
    String.trim_trailing(url, "/")
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)
  end
  defp normalize_headers(headers), do: headers

  defp default_headers do
    %{
      "content-type" => "application/json",
      "accept" => "application/json",
      "user-agent" => "FlowStone/#{FlowStone.version()}"
    }
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  defp emit_start(metadata) do
    :telemetry.execute(
      [:flowstone, :http, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp emit_stop_or_error({:ok, response}, duration, metadata) do
    :telemetry.execute(
      [:flowstone, :http, :request, :stop],
      %{duration: duration, status: response.status},
      metadata
    )
  end

  defp emit_stop_or_error({:error, reason}, duration, metadata) do
    :telemetry.execute(
      [:flowstone, :http, :request, :error],
      %{duration: duration, error: reason},
      metadata
    )
  end
end
```

## FlowStone.HTTP.Retry

```elixir
defmodule FlowStone.HTTP.Retry do
  @moduledoc """
  Retry logic for HTTP requests with exponential backoff.
  """

  @doc """
  Execute function with retry on transient failures.
  """
  def with_retry(config, fun) do
    do_retry(config, fun, 1, nil)
  end

  defp do_retry(config, _fun, attempt, last_error) when attempt > config.max_attempts do
    case last_error do
      nil -> {:error, :max_retries_exceeded}
      error -> error
    end
  end

  defp do_retry(config, fun, attempt, _last_error) do
    case fun.(attempt) do
      # Success - return immediately
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      # Rate limited - use Retry-After header if present
      {:ok, %{status: 429} = response} ->
        delay = get_retry_after(response) || calculate_delay(config, attempt)
        Process.sleep(delay)
        do_retry(config, fun, attempt + 1, {:ok, response})

      # Server error - retry with backoff
      {:ok, %{status: status} = response} when status >= 500 ->
        delay = calculate_delay(config, attempt)
        Process.sleep(delay)
        do_retry(config, fun, attempt + 1, {:ok, response})

      # Client error (4xx except 429) - don't retry
      {:ok, response} ->
        {:ok, response}

      # Transport error - retry with backoff
      {:error, {:transport_error, _} = error} ->
        delay = calculate_delay(config, attempt)
        Process.sleep(delay)
        do_retry(config, fun, attempt + 1, {:error, error})

      # Other errors - don't retry
      {:error, _} = error ->
        error
    end
  end

  defp calculate_delay(config, attempt) do
    # Exponential backoff: base * 2^(attempt-1)
    base = config.base_delay_ms * :math.pow(2, attempt - 1)
    capped = min(trunc(base), config.max_delay_ms)

    if config.jitter do
      # Add random jitter up to 50% of delay
      jitter = :rand.uniform(div(capped, 2))
      capped + jitter
    else
      capped
    end
  end

  defp get_retry_after(%{headers: headers}) do
    case Map.get(headers, "retry-after") do
      nil -> nil
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> nil
        end
      value when is_integer(value) ->
        value * 1000
    end
  end
end
```

## Configuration Examples

### Basic Configuration

```elixir
FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com"
)
```

### Full Configuration

```elixir
FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com",
  timeout: 60_000,
  headers: %{
    "Authorization" => "Bearer #{System.get_env("API_TOKEN")}",
    "X-Client-ID" => "flowstone-pipeline"
  },
  retry: %{
    max_attempts: 5,
    base_delay_ms: 500,
    max_delay_ms: 60_000,
    jitter: true
  },
  req_options: [
    # Pass-through options to Req
    pool_timeout: 5_000,
    connect_options: [
      timeout: 10_000
    ]
  ]
)
```

### Multiple Clients

```elixir
# Primary API
FlowStone.Resources.register(:primary_api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com",
  timeout: 30_000
)

# Third-Party Service
FlowStone.Resources.register(:payments_api, FlowStone.HTTP.Client,
  base_url: "https://api.stripe.com/v1",
  timeout: 30_000,
  headers: %{
    "Authorization" => "Bearer #{System.get_env("STRIPE_API_KEY")}"
  }
)

# Use in asset
asset :create_order do
  requires [:primary_api, :payments_api]

  execute fn ctx, deps ->
    data = FlowStone.HTTP.Client.get(ctx.resources[:primary_api], "/cart")
    # ... process cart and create payment
  end
end
```

## Usage Patterns

### Basic GET Request

```elixir
asset :fetch_user do
  requires [:api]

  execute fn ctx, _deps ->
    user_id = ctx.partition.user_id

    case FlowStone.HTTP.Client.get(ctx.resources[:api], "/users/#{user_id}") do
      {:ok, %{status: 200, body: user}} ->
        {:ok, user}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### POST with Idempotency Key

```elixir
asset :create_resource do
  requires [:api]

  execute fn ctx, deps ->
    # Idempotency key ensures retries don't create duplicates
    idempotency_key = "#{ctx.execution_id}-#{ctx.scatter_key}"

    payload = %{
      name: deps[:prepare_data].name,
      data: deps[:prepare_data].data
    }

    case FlowStone.HTTP.Client.post(ctx.resources[:api], "/resources", payload,
      idempotency_key: idempotency_key
    ) do
      {:ok, %{status: 201, body: resource}} ->
        {:ok, resource}

      {:ok, %{status: 409, body: existing}} ->
        # Already exists (idempotent replay)
        {:ok, existing}

      {:ok, %{status: status, body: body}} ->
        {:error, {:create_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### Scatter Pattern with HTTP

```elixir
asset :process_items do
  requires [:api]

  scatter fn ctx, deps ->
    deps[:load_items]
  end

  execute fn ctx, deps ->
    item = ctx.scatter_key

    case FlowStone.HTTP.Client.post(ctx.resources[:api], "/process",
      %{item_id: item.id, data: item.data}
    ) do
      {:ok, %{status: 200, body: result}} ->
        {:ok, {item.id, result}}

      {:error, reason} ->
        {:error, {item.id, reason}}
    end
  end

  gather fn results ->
    {successes, failures} = Enum.split_with(results, fn
      {:ok, _} -> true
      {:error, _} -> false
    end)

    if length(failures) > length(successes) * 0.5 do
      {:error, {:too_many_failures, failures}}
    else
      {:ok, Enum.into(successes, %{}, fn {:ok, {id, result}} -> {id, result} end)}
    end
  end
end
```

## Testing

### Mocking HTTP Responses

```elixir
defmodule MyPipelineTest do
  use ExUnit.Case

  import Mox

  setup :verify_on_exit!

  test "asset handles API response" do
    # Setup mock
    Mox.stub(FlowStone.HTTP.MockClient, :get, fn _client, "/users/123", _opts ->
      {:ok, %{status: 200, body: %{"id" => "123", "name" => "Test User"}}}
    end)

    # Execute pipeline with mock
    result = FlowStone.materialize(MyPipeline,
      partition: %{user_id: "123"},
      resources: %{api: FlowStone.HTTP.MockClient}
    )

    assert {:ok, %{fetch_user: %{"id" => "123"}}} = result
  end

  test "asset handles API error" do
    Mox.stub(FlowStone.HTTP.MockClient, :get, fn _client, _path, _opts ->
      {:ok, %{status: 500, body: %{"error" => "Internal error"}}}
    end)

    result = FlowStone.materialize(MyPipeline,
      partition: %{user_id: "123"},
      resources: %{api: FlowStone.HTTP.MockClient}
    )

    assert {:error, {:api_error, 500, _}} = result
  end
end
```

## Telemetry Events

The HTTP adapter emits the following telemetry events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:flowstone, :http, :request, :start]` | `system_time` | `method`, `url`, `path`, `base_url` |
| `[:flowstone, :http, :request, :stop]` | `duration`, `status` | `method`, `url`, `path`, `base_url` |
| `[:flowstone, :http, :request, :error]` | `duration`, `error` | `method`, `url`, `path`, `base_url` |

### Example Handler

```elixir
:telemetry.attach(
  "http-logger",
  [:flowstone, :http, :request, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("HTTP #{metadata.method} #{metadata.path}",
      status: measurements.status,
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
    )
  end,
  nil
)
```

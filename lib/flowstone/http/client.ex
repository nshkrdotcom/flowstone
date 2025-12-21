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

  ## Configuration Options

  - `:base_url` - (required) Base URL for all requests
  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:headers` - Map of default headers to include in all requests
  - `:retry` - Retry configuration map:
    - `:max_attempts` - Maximum retry attempts (default: 3)
    - `:base_delay_ms` - Initial delay between retries (default: 1000)
    - `:max_delay_ms` - Maximum delay between retries (default: 30_000)
    - `:jitter` - Add random jitter to delays (default: true)
  - `:req_options` - Additional options passed to Req
  """

  @behaviour FlowStone.Resource

  alias FlowStone.HTTP.Retry

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

    retry_config =
      @default_retry
      |> Map.merge(config[:retry] || %{})

    client = %__MODULE__{
      base_url: normalize_base_url(config[:base_url]),
      headers: Map.merge(default_headers(), config[:headers] || %{}),
      timeout: config[:timeout] || @default_timeout,
      retry_config: retry_config,
      req_options: config[:req_options] || []
    }

    {:ok, client}
  end

  @impl FlowStone.Resource
  def teardown(_client), do: :ok

  @impl FlowStone.Resource
  def health_check(client) do
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

    headers =
      client.headers
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

    result =
      if should_retry do
        Retry.with_retry(client.retry_config, fn attempt ->
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
    req_opts =
      [
        method: method,
        url: url,
        headers: Enum.into(headers, []),
        receive_timeout: timeout
      ] ++ req_options

    req_opts =
      if body do
        Keyword.put(req_opts, :json, body)
      else
        req_opts
      end

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok,
         %{
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

  # Req returns headers as %{String.t() => [String.t()]}
  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn
      {k, [v | _]} -> {String.downcase(to_string(k)), v}
      {k, v} when is_binary(v) -> {String.downcase(to_string(k)), v}
      {k, v} -> {String.downcase(to_string(k)), to_string(v)}
    end)
  end

  defp default_headers do
    version = Application.spec(:flowstone, :vsn) |> to_string()

    %{
      "content-type" => "application/json",
      "accept" => "application/json",
      "user-agent" => "FlowStone/#{version}"
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

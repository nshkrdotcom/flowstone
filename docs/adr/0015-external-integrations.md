# ADR-0015: External System Integration Patterns

## Status
Accepted

## Context

Production orchestration integrates with:
- LLM/AI services (OpenAI, Anthropic, local models)
- Data transformation tools (dbt, Spark)
- Python ML pipelines (scikit-learn, PyTorch)
- Notification systems (Slack, email)
- External APIs and databases

We need patterns that:
- Keep integrations testable and mockable
- Handle failures gracefully
- Support rate limiting and backpressure
- Maintain observability

## Decision

### 1. Integration as I/O Managers

External data sources are modeled as I/O managers:

```elixir
defmodule FlowStone.IO.REST do
  @behaviour FlowStone.IO.Manager

  def load(asset, partition, config) do
    url = config.url_fn.(partition)
    headers = config[:headers] || []

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, decode(body, config)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def store(asset, data, partition, config) do
    url = config.url_fn.(partition)
    headers = config[:headers] || []
    body = encode(data, config)

    case Req.post(url, headers: headers, body: body) do
      {:ok, %{status: status}} when status in [200, 201, 204] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Usage
asset :external_data do
  io_manager FlowStone.IO.REST
  config %{
    url_fn: fn partition -> "https://api.example.com/data/#{partition}" end,
    headers: [{"Authorization", "Bearer #{System.get_env("API_TOKEN")}"}],
    format: :json
  }

  execute fn context, _deps ->
    # Data is loaded automatically via I/O manager
    {:ok, context.data}
  end
end
```

### 2. LLM Integration Pattern

```elixir
defmodule FlowStone.Integrations.LLM do
  @doc "Call an LLM with retry and rate limiting"
  def call(provider, prompt, opts \\ []) do
    config = get_provider_config(provider)
    max_retries = Keyword.get(opts, :max_retries, 3)
    timeout = Keyword.get(opts, :timeout, :timer.minutes(2))

    do_call(config, prompt, max_retries, timeout)
  end

  defp do_call(_config, _prompt, 0, _timeout) do
    {:error, :max_retries_exceeded}
  end

  defp do_call(config, prompt, retries, timeout) do
    # Rate limiting via Hammer
    case Hammer.check_rate("llm:#{config.provider}", 60_000, config.rpm_limit) do
      {:allow, _count} ->
        make_request(config, prompt, timeout)

      {:deny, _limit} ->
        # Backoff and retry
        Process.sleep(1000)
        do_call(config, prompt, retries - 1, timeout)
    end
  end

  defp make_request(%{provider: :anthropic} = config, prompt, timeout) do
    body = %{
      model: config.model,
      max_tokens: config[:max_tokens] || 4096,
      messages: [%{role: "user", content: prompt}]
    }

    headers = [
      {"x-api-key", config.api_key},
      {"anthropic-version", "2024-01-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(config.endpoint, json: body, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text}]}}} ->
        {:ok, text}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp make_request(%{provider: :openai} = config, prompt, timeout) do
    # Similar implementation for OpenAI
  end

  defp get_provider_config(provider) do
    Application.get_env(:flowstone, :llm_providers)[provider]
  end
end

# Usage in asset
asset :llm_analysis do
  depends_on [:source_data]
  requires [:llm_client]

  execute fn context, %{source_data: data} ->
    prompt = build_prompt(data)

    case FlowStone.Integrations.LLM.call(:anthropic, prompt) do
      {:ok, response} ->
        {:ok, parse_response(response)}

      {:error, reason} ->
        {:error, FlowStone.Error.io_error(:llm_call, :llm_analysis, context.partition, reason)}
    end
  end
end
```

### 3. Python/ML Integration via Erlport

```elixir
defmodule FlowStone.Integrations.Python do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    python_path = Keyword.get(opts, :python_path, "python3")
    {:ok, pid} = :python.start([{:python_path, python_path}])
    {:ok, %{python: pid}}
  end

  def call(module, function, args) do
    GenServer.call(__MODULE__, {:call, module, function, args}, :timer.minutes(10))
  end

  def handle_call({:call, module, function, args}, _from, %{python: pid} = state) do
    result = :python.call(pid, module, function, args)
    {:reply, {:ok, result}, state}
  rescue
    error ->
      {:reply, {:error, error}, state}
  end
end

# Python script at priv/python/ml_models.py
# def predict(features):
#     import sklearn
#     model = load_model()
#     return model.predict(features).tolist()

# Usage in asset
asset :ml_predictions do
  depends_on [:features]

  execute fn _context, %{features: features} ->
    case FlowStone.Integrations.Python.call(:ml_models, :predict, [features]) do
      {:ok, predictions} ->
        {:ok, predictions}

      {:error, reason} ->
        {:error, FlowStone.Error.execution_error(:ml_predictions, _context.partition, reason, [])}
    end
  end
end
```

### 4. dbt Integration

```elixir
defmodule FlowStone.Integrations.DBT do
  @doc "Run a dbt model and return its result"
  def run_model(model_name, opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, ".")
    target = Keyword.get(opts, :target, "dev")
    profiles_dir = Keyword.get(opts, :profiles_dir)

    args = [
      "run",
      "--select", model_name,
      "--target", target
    ]

    args = if profiles_dir, do: args ++ ["--profiles-dir", profiles_dir], else: args

    case System.cmd("dbt", args, cd: project_dir, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_dbt_output(output)}

      {output, exit_code} ->
        {:error, {:dbt_failed, exit_code, output}}
    end
  end

  @doc "Run dbt tests for a model"
  def test_model(model_name, opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, ".")

    case System.cmd("dbt", ["test", "--select", model_name], cd: project_dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, {:tests_failed, output}}
    end
  end

  defp parse_dbt_output(output) do
    # Extract timing and row counts from dbt output
    %{
      raw_output: output,
      models_run: count_models(output),
      errors: extract_errors(output)
    }
  end
end

# Usage as asset
asset :dbt_analytics do
  depends_on [:raw_data]

  execute fn context, _deps ->
    with {:ok, result} <- FlowStone.Integrations.DBT.run_model("analytics_daily",
           target: "prod",
           project_dir: "/app/dbt"
         ),
         {:ok, _} <- FlowStone.Integrations.DBT.test_model("analytics_daily") do
      {:ok, result}
    else
      {:error, reason} ->
        {:error, FlowStone.Error.execution_error(:dbt_analytics, context.partition, reason, [])}
    end
  end
end
```

### 5. Notification Integration

```elixir
defmodule FlowStone.Integrations.Notifications do
  @doc "Send notification via configured channels"
  def notify(event, payload, opts \\ []) do
    channels = Keyword.get(opts, :channels, [:slack, :email])

    results =
      Enum.map(channels, fn channel ->
        {channel, send_to_channel(channel, event, payload)}
      end)

    errors = Enum.filter(results, fn {_, result} -> match?({:error, _}, result) end)

    case errors do
      [] -> :ok
      _ -> {:error, {:partial_failure, errors}}
    end
  end

  defp send_to_channel(:slack, event, payload) do
    config = Application.get_env(:flowstone, :notifications)[:slack]
    webhook_url = config[:webhook_url]

    message = format_slack_message(event, payload)

    case Req.post(webhook_url, json: message) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:slack_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_to_channel(:email, event, payload) do
    config = Application.get_env(:flowstone, :notifications)[:email]

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(payload[:recipients] || config[:default_recipients])
      |> Swoosh.Email.from(config[:from])
      |> Swoosh.Email.subject(format_subject(event, payload))
      |> Swoosh.Email.html_body(format_email_body(event, payload))

    case Swoosh.Mailer.deliver(email, config[:mailer]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_slack_message(:checkpoint_pending, payload) do
    %{
      blocks: [
        %{
          type: "section",
          text: %{
            type: "mrkdwn",
            text: "*Approval Required*\n#{payload[:message]}"
          }
        },
        %{
          type: "actions",
          elements: [
            %{type: "button", text: %{type: "plain_text", text: "View"}, url: payload[:url]}
          ]
        }
      ]
    }
  end

  defp format_slack_message(:materialization_failed, payload) do
    %{
      blocks: [
        %{
          type: "section",
          text: %{
            type: "mrkdwn",
            text: ":x: *Materialization Failed*\nAsset: `#{payload[:asset]}`\nPartition: `#{payload[:partition]}`\nError: #{payload[:error]}"
          }
        }
      ]
    }
  end
end

# Integration with checkpoint events
defmodule FlowStone.Checkpoint.Notifier do
  def on_checkpoint_created(checkpoint) do
    FlowStone.Integrations.Notifications.notify(:checkpoint_pending, %{
      message: checkpoint.message,
      checkpoint: checkpoint.checkpoint_name,
      url: "#{base_url()}/flowstone/checkpoints/#{checkpoint.id}"
    })
  end

  def on_checkpoint_timeout(checkpoint) do
    FlowStone.Integrations.Notifications.notify(:checkpoint_timeout, %{
      checkpoint: checkpoint.checkpoint_name,
      timeout_at: checkpoint.timeout_at
    }, channels: [:slack, :email])
  end
end
```

### 6. Database Integration

```elixir
defmodule FlowStone.IO.ExternalDB do
  @behaviour FlowStone.IO.Manager
  use DBConnection

  def load(asset, partition, config) do
    pool = get_or_start_pool(config)
    query = config[:load_query].(partition)

    case DBConnection.execute(pool, query, []) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, to_maps(rows, columns)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def store(asset, data, partition, config) do
    pool = get_or_start_pool(config)

    Enum.each(data, fn row ->
      query = config[:insert_query]
      params = config[:params_fn].(row, partition)
      DBConnection.execute(pool, query, params)
    end)

    :ok
  end

  defp get_or_start_pool(config) do
    name = config[:pool_name] || :default_external_pool

    case Process.whereis(name) do
      nil ->
        {:ok, pool} = DBConnection.start_link(
          config[:adapter],
          config[:connection_opts] ++ [name: name]
        )
        pool

      pid ->
        pid
    end
  end

  defp to_maps(rows, columns) do
    Enum.map(rows, fn row ->
      Enum.zip(columns, row) |> Map.new()
    end)
  end
end

# Usage
asset :external_users do
  io_manager FlowStone.IO.ExternalDB
  config %{
    adapter: Postgrex,
    connection_opts: [
      hostname: System.get_env("EXTERNAL_DB_HOST"),
      database: "users",
      username: System.get_env("EXTERNAL_DB_USER"),
      password: System.get_env("EXTERNAL_DB_PASS")
    ],
    load_query: fn partition ->
      {"SELECT * FROM users WHERE date = $1", [partition]}
    end
  }

  execute fn context, _deps ->
    {:ok, context.data}
  end
end
```

### 7. Retry and Circuit Breaker

```elixir
defmodule FlowStone.Integrations.Resilience do
  @doc "Execute with retry and exponential backoff"
  def with_retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay = Keyword.get(opts, :base_delay, 1000)

    do_retry(fun, 1, max_attempts, base_delay)
  end

  defp do_retry(fun, attempt, max_attempts, _base_delay) when attempt > max_attempts do
    {:error, :max_attempts_exceeded}
  end

  defp do_retry(fun, attempt, max_attempts, base_delay) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, :rate_limited} ->
        delay = base_delay * :math.pow(2, attempt - 1) |> trunc()
        Process.sleep(delay)
        do_retry(fun, attempt + 1, max_attempts, base_delay)

      {:error, :timeout} ->
        delay = base_delay * :math.pow(2, attempt - 1) |> trunc()
        Process.sleep(delay)
        do_retry(fun, attempt + 1, max_attempts, base_delay)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Execute with circuit breaker"
  def with_circuit_breaker(name, fun, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 5)
    timeout = Keyword.get(opts, :timeout, :timer.seconds(30))

    case check_circuit(name, threshold, timeout) do
      :closed ->
        case fun.() do
          {:ok, result} ->
            record_success(name)
            {:ok, result}

          {:error, reason} ->
            record_failure(name)
            {:error, reason}
        end

      :open ->
        {:error, :circuit_open}
    end
  end

  defp check_circuit(name, threshold, timeout) do
    case :ets.lookup(:circuit_breakers, name) do
      [{^name, failures, opened_at}] when failures >= threshold ->
        if DateTime.diff(DateTime.utc_now(), opened_at, :millisecond) > timeout do
          :ets.delete(:circuit_breakers, name)
          :closed
        else
          :open
        end

      _ ->
        :closed
    end
  end

  defp record_success(name) do
    :ets.delete(:circuit_breakers, name)
  end

  defp record_failure(name) do
    case :ets.lookup(:circuit_breakers, name) do
      [{^name, failures, opened_at}] ->
        :ets.insert(:circuit_breakers, {name, failures + 1, opened_at})

      [] ->
        :ets.insert(:circuit_breakers, {name, 1, DateTime.utc_now()})
    end
  end
end
```

## Consequences

### Positive

1. **Consistent Patterns**: All integrations follow similar patterns.
2. **Testable**: Integrations are mockable via behaviours.
3. **Resilient**: Built-in retry and circuit breaker support.
4. **Observable**: Telemetry events for all external calls.
5. **Configurable**: Environment-specific configuration.

### Negative

1. **Abstraction Cost**: Each integration needs a wrapper.
2. **Maintenance**: Must update wrappers when APIs change.
3. **Latency**: Additional layer adds small overhead.

## References

- Req HTTP Client: https://hexdocs.pm/req
- Erlport: https://erlport.org/
- Hammer Rate Limiter: https://hexdocs.pm/hammer
- Circuit Breaker Pattern: https://martinfowler.com/bliki/CircuitBreaker.html

# Implementation Prompt: ADR-0015 External System Integration Patterns

## Objective

Implement integration patterns for external systems (LLMs, Python/ML, dbt, APIs, notifications) with resilience, testability, and observability using TDD with Supertester.

## Required Reading

1. **ADR-0015**: `docs/adr/0015-external-integrations.md`
2. **ADR-0004**: `docs/adr/0004-io-manager-abstraction.md` (I/O manager dependency)
3. **ADR-0013**: `docs/adr/0013-testing-strategies.md` (testing patterns)
4. **Req HTTP Client**: https://hexdocs.pm/req
5. **Hammer Rate Limiter**: https://hexdocs.pm/hammer
6. **Circuit Breaker Pattern**: https://martinfowler.com/bliki/CircuitBreaker.html
7. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

Production orchestration integrates with:
- LLM/AI services (OpenAI, Anthropic, local models)
- Data transformation tools (dbt, Spark)
- Python ML pipelines (scikit-learn, PyTorch)
- Notification systems (Slack, email)
- External APIs and databases

Integration requirements:
- Testable and mockable via behaviours
- Handle failures gracefully with retries
- Support rate limiting and backpressure
- Maintain observability via telemetry
- Circuit breakers for failing services

## Implementation Tasks

### 1. REST I/O Manager

```elixir
# lib/flowstone/io/rest.ex
defmodule FlowStone.IO.REST do
  @behaviour FlowStone.IO.Manager

  def load(asset, partition, config)
  def store(asset, data, partition, config)

  defp decode(body, config)
  defp encode(data, config)
end
```

### 2. LLM Integration

```elixir
# lib/flowstone/integrations/llm.ex
defmodule FlowStone.Integrations.LLM do
  @doc "Call an LLM with retry and rate limiting"
  def call(provider, prompt, opts \\ [])

  defp do_call(config, prompt, retries, timeout)
  defp make_request(%{provider: :anthropic}, prompt, timeout)
  defp make_request(%{provider: :openai}, prompt, timeout)
  defp get_provider_config(provider)
end
```

### 3. Python/ML Integration

```elixir
# lib/flowstone/integrations/python.ex
defmodule FlowStone.Integrations.Python do
  use GenServer

  def start_link(opts)
  def init(opts)
  def call(module, function, args)

  def handle_call({:call, module, function, args}, _from, state)
end
```

### 4. dbt Integration

```elixir
# lib/flowstone/integrations/dbt.ex
defmodule FlowStone.Integrations.DBT do
  @doc "Run a dbt model and return its result"
  def run_model(model_name, opts \\ [])

  @doc "Run dbt tests for a model"
  def test_model(model_name, opts \\ [])

  defp parse_dbt_output(output)
  defp count_models(output)
  defp extract_errors(output)
end
```

### 5. Notifications

```elixir
# lib/flowstone/integrations/notifications.ex
defmodule FlowStone.Integrations.Notifications do
  @doc "Send notification via configured channels"
  def notify(event, payload, opts \\ [])

  defp send_to_channel(:slack, event, payload)
  defp send_to_channel(:email, event, payload)
  defp format_slack_message(event, payload)
  defp format_email_body(event, payload)
end
```

### 6. External Database I/O Manager

```elixir
# lib/flowstone/io/external_db.ex
defmodule FlowStone.IO.ExternalDB do
  @behaviour FlowStone.IO.Manager
  use DBConnection

  def load(asset, partition, config)
  def store(asset, data, partition, config)

  defp get_or_start_pool(config)
  defp to_maps(rows, columns)
end
```

### 7. Resilience Helpers

```elixir
# lib/flowstone/integrations/resilience.ex
defmodule FlowStone.Integrations.Resilience do
  @doc "Execute with retry and exponential backoff"
  def with_retry(fun, opts \\ [])

  @doc "Execute with circuit breaker"
  def with_circuit_breaker(name, fun, opts \\ [])

  defp do_retry(fun, attempt, max_attempts, base_delay)
  defp check_circuit(name, threshold, timeout)
  defp record_success(name)
  defp record_failure(name)
end
```

## Test Design with Supertester

### REST I/O Manager Tests

```elixir
defmodule FlowStone.IO.RESTTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.IO.REST

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "load/3" do
    test "loads data from REST API", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data/2025-01-15", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{data: [1, 2, 3]}))
      end)

      config = %{
        url_fn: fn partition -> "http://localhost:#{bypass.port}/data/#{partition}" end,
        format: :json
      }

      {:ok, result} = REST.load(:test_asset, ~D[2025-01-15], config)

      assert result == %{"data" => [1, 2, 3]}
    end

    test "returns error on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data/missing", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      config = %{
        url_fn: fn partition -> "http://localhost:#{bypass.port}/data/#{partition}" end
      }

      assert {:error, :not_found} = REST.load(:test_asset, "missing", config)
    end

    test "handles HTTP errors", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data/error", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      config = %{
        url_fn: fn partition -> "http://localhost:#{bypass.port}/data/#{partition}" end
      }

      assert {:error, {:http_error, 500}} = REST.load(:test_asset, "error", config)
    end

    test "includes authorization headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/data/secure", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]
        Plug.Conn.resp(conn, 200, Jason.encode!(%{data: "secure"}))
      end)

      config = %{
        url_fn: fn partition -> "http://localhost:#{bypass.port}/data/#{partition}" end,
        headers: [{"Authorization", "Bearer secret"}],
        format: :json
      }

      {:ok, _result} = REST.load(:test_asset, "secure", config)
    end
  end

  describe "store/4" do
    test "stores data via POST", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/data/2025-01-15", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded == %{"value" => 42}
        Plug.Conn.resp(conn, 201, "")
      end)

      config = %{
        url_fn: fn partition -> "http://localhost:#{bypass.port}/data/#{partition}" end,
        format: :json
      }

      assert :ok = REST.store(:test_asset, %{value: 42}, ~D[2025-01-15], config)
    end
  end
end
```

### LLM Integration Tests with Mox

```elixir
defmodule FlowStone.Integrations.LLMTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Integrations.LLM

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "call/3" do
    test "calls Anthropic API successfully", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "claude-3-sonnet-20240229"
        assert decoded["messages"] == [%{"role" => "user", "content" => "Test prompt"}]

        response = %{
          "content" => [%{"text" => "Test response"}]
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      # Configure test provider
      config = %{
        provider: :anthropic,
        model: "claude-3-sonnet-20240229",
        api_key: "test-key",
        endpoint: "http://localhost:#{bypass.port}/v1/messages",
        rpm_limit: 100
      }

      Application.put_env(:flowstone, :llm_providers, %{anthropic: config})

      {:ok, response} = LLM.call(:anthropic, "Test prompt")

      assert response == "Test response"
    end

    test "handles rate limiting with retry", %{bypass: bypass} do
      # First attempt: rate limited
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        Plug.Conn.resp(conn, 429, "Rate limit exceeded")
      end)

      # Second attempt: success
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        response = %{"content" => [%{"text" => "Success after retry"}]}
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      config = %{
        provider: :anthropic,
        model: "claude-3-sonnet-20240229",
        api_key: "test-key",
        endpoint: "http://localhost:#{bypass.port}/v1/messages",
        rpm_limit: 100
      }

      Application.put_env(:flowstone, :llm_providers, %{anthropic: config})

      {:ok, response} = LLM.call(:anthropic, "Test prompt", max_retries: 3)

      assert response == "Success after retry"
    end

    test "handles timeout errors", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        Process.sleep(5000)  # Longer than timeout
        Plug.Conn.resp(conn, 200, "")
      end)

      config = %{
        provider: :anthropic,
        endpoint: "http://localhost:#{bypass.port}/v1/messages",
        api_key: "test-key",
        rpm_limit: 100
      }

      Application.put_env(:flowstone, :llm_providers, %{anthropic: config})

      assert {:error, :timeout} = LLM.call(:anthropic, "Test", timeout: 100)
    end
  end
end
```

### Python Integration Tests

```elixir
defmodule FlowStone.Integrations.PythonTest do
  use FlowStone.DataCase, async: false  # Python GenServer not async-safe

  alias FlowStone.Integrations.Python

  setup do
    {:ok, pid} = start_supervised(Python)
    {:ok, python: pid}
  end

  @tag :python
  test "calls Python function", %{python: _pid} do
    # Assumes priv/python/test_module.py exists with add function
    {:ok, result} = Python.call(:test_module, :add, [2, 3])

    assert result == 5
  end

  @tag :python
  test "handles Python exceptions", %{python: _pid} do
    # Call function that raises exception
    assert {:error, _error} = Python.call(:test_module, :raise_error, [])
  end

  @tag :python
  test "passes complex data structures", %{python: _pid} do
    data = %{key: "value", numbers: [1, 2, 3]}

    {:ok, result} = Python.call(:test_module, :process_data, [data])

    assert is_map(result)
  end
end
```

### dbt Integration Tests

```elixir
defmodule FlowStone.Integrations.DBTTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Integrations.DBT

  @tag :dbt
  test "runs dbt model successfully" do
    # Requires actual dbt project in test environment
    {:ok, result} = DBT.run_model("test_model", project_dir: "test/fixtures/dbt_project")

    assert result.models_run > 0
    assert result.errors == []
  end

  @tag :dbt
  test "detects dbt failures" do
    # Run non-existent model
    assert {:error, {:dbt_failed, _code, output}} = DBT.run_model("nonexistent_model")
    assert output =~ "could not find"
  end

  @tag :dbt
  test "runs dbt tests" do
    {:ok, output} = DBT.test_model("test_model", project_dir: "test/fixtures/dbt_project")

    assert output =~ "PASS"
  end

  test "parses dbt output" do
    output = """
    Running with dbt=1.0.0
    Found 3 models, 2 tests, 0 snapshots
    Completed successfully
    """

    result = DBT.parse_dbt_output(output)

    assert result.models_run == 3
    assert result.errors == []
  end
end
```

### Notification Integration Tests

```elixir
defmodule FlowStone.Integrations.NotificationsTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Integrations.Notifications

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "notify/3" do
    test "sends Slack notification", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/slack/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["blocks"] != nil
        Plug.Conn.resp(conn, 200, "ok")
      end)

      config = %{
        slack: %{webhook_url: "http://localhost:#{bypass.port}/slack/webhook"}
      }

      Application.put_env(:flowstone, :notifications, config)

      assert :ok = Notifications.notify(:checkpoint_pending, %{
        message: "Approval needed",
        url: "http://example.com/checkpoint/123"
      }, channels: [:slack])
    end

    test "sends email notification" do
      # Use Swoosh test adapter
      payload = %{
        recipients: ["test@example.com"],
        message: "Test notification"
      }

      assert :ok = Notifications.notify(:test_event, payload, channels: [:email])

      # Verify email was sent (requires Swoosh.TestAssertions)
      assert_email_sent(subject: "Test Event")
    end

    test "handles partial failures" do
      # Slack fails, email succeeds
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/slack/webhook", fn conn ->
        Plug.Conn.resp(conn, 500, "error")
      end)

      config = %{
        slack: %{webhook_url: "http://localhost:#{bypass.port}/slack/webhook"},
        email: %{from: "test@example.com", mailer: TestMailer}
      }

      Application.put_env(:flowstone, :notifications, config)

      result = Notifications.notify(:test_event, %{}, channels: [:slack, :email])

      assert {:error, {:partial_failure, errors}} = result
      assert length(errors) == 1
    end
  end

  describe "Slack message formatting" do
    test "formats checkpoint pending message" do
      message = Notifications.format_slack_message(:checkpoint_pending, %{
        message: "Review needed",
        url: "http://example.com/checkpoint/123"
      })

      assert message.blocks != nil
      assert length(message.blocks) == 2  # Text + Actions
    end

    test "formats materialization failed message" do
      message = Notifications.format_slack_message(:materialization_failed, %{
        asset: :test_asset,
        partition: "p1",
        error: "Something went wrong"
      })

      text_block = hd(message.blocks)
      assert text_block.text.text =~ "Materialization Failed"
      assert text_block.text.text =~ "test_asset"
    end
  end
end
```

### Resilience Tests with Supertester

```elixir
defmodule FlowStone.Integrations.ResilienceTest do
  use FlowStone.DataCase, async: true
  use Supertester.ChaosHelpers

  alias FlowStone.Integrations.Resilience

  describe "with_retry/2" do
    test "succeeds on first attempt" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, :success}
      end

      assert {:ok, :success} = Resilience.with_retry(fun)
      assert :counters.get(call_count, 1) == 1
    end

    test "retries on rate limit" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        count = :counters.add(call_count, 1, 1)

        if count < 3 do
          {:error, :rate_limited}
        else
          {:ok, :success}
        end
      end

      assert {:ok, :success} = Resilience.with_retry(fun, max_attempts: 5)
      assert :counters.get(call_count, 1) == 3
    end

    test "retries on timeout" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        count = :counters.add(call_count, 1, 1)

        if count < 2 do
          {:error, :timeout}
        else
          {:ok, :success}
        end
      end

      assert {:ok, :success} = Resilience.with_retry(fun, max_attempts: 3)
      assert :counters.get(call_count, 1) == 2
    end

    test "fails after max attempts" do
      fun = fn -> {:error, :rate_limited} end

      assert {:error, :max_attempts_exceeded} = Resilience.with_retry(fun, max_attempts: 3)
    end

    test "uses exponential backoff" do
      start_time = System.monotonic_time(:millisecond)

      fun = fn -> {:error, :rate_limited} end

      Resilience.with_retry(fun, max_attempts: 3, base_delay: 100)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should wait: 100ms + 200ms = 300ms minimum
      assert elapsed >= 300
    end
  end

  describe "with_circuit_breaker/3" do
    setup do
      # Initialize ETS table for circuit breakers
      :ets.new(:circuit_breakers, [:set, :public, :named_table])
      :ok
    end

    test "allows calls when circuit is closed" do
      fun = fn -> {:ok, :success} end

      assert {:ok, :success} = Resilience.with_circuit_breaker(:test_service, fun)
    end

    test "opens circuit after threshold failures" do
      fun = fn -> {:error, :service_down} end

      # Fail 5 times to reach threshold
      Enum.each(1..5, fn _ ->
        Resilience.with_circuit_breaker(:test_service, fun, threshold: 5)
      end)

      # Circuit should be open now
      success_fun = fn -> {:ok, :success} end

      assert {:error, :circuit_open} = Resilience.with_circuit_breaker(:test_service, success_fun, threshold: 5)
    end

    test "closes circuit after timeout" do
      fun = fn -> {:error, :service_down} end

      # Open circuit
      Enum.each(1..5, fn _ ->
        Resilience.with_circuit_breaker(:test_service, fun, threshold: 5)
      end)

      # Wait for timeout
      Process.sleep(100)

      # Circuit should close after timeout
      success_fun = fn -> {:ok, :success} end

      assert {:ok, :success} = Resilience.with_circuit_breaker(
        :test_service,
        success_fun,
        threshold: 5,
        timeout: 50
      )
    end

    test "resets failure count on success" do
      # 3 failures
      fail_fun = fn -> {:error, :fail} end
      Enum.each(1..3, fn _ ->
        Resilience.with_circuit_breaker(:test_service, fail_fun, threshold: 5)
      end)

      # 1 success resets counter
      success_fun = fn -> {:ok, :success} end
      Resilience.with_circuit_breaker(:test_service, success_fun, threshold: 5)

      # 4 more failures shouldn't open circuit (would need 5 consecutive)
      Enum.each(1..4, fn _ ->
        Resilience.with_circuit_breaker(:test_service, fail_fun, threshold: 5)
      end)

      # Circuit still closed
      assert {:ok, :success} = Resilience.with_circuit_breaker(:test_service, success_fun, threshold: 5)
    end
  end
end
```

### External Database I/O Manager Tests

```elixir
defmodule FlowStone.IO.ExternalDBTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.IO.ExternalDB

  @tag :external_db
  test "loads data from external database" do
    config = %{
      adapter: Postgrex,
      connection_opts: [
        hostname: "localhost",
        database: "test_external",
        username: "test",
        password: "test"
      ],
      load_query: fn partition ->
        {"SELECT * FROM users WHERE date = $1", [partition]}
      end
    }

    {:ok, result} = ExternalDB.load(:external_users, ~D[2025-01-15], config)

    assert is_list(result)
  end

  @tag :external_db
  test "stores data to external database" do
    config = %{
      adapter: Postgrex,
      connection_opts: [
        hostname: "localhost",
        database: "test_external",
        username: "test",
        password: "test"
      ],
      insert_query: "INSERT INTO users (name, date) VALUES ($1, $2)",
      params_fn: fn row, partition ->
        [row.name, partition]
      end
    }

    data = [%{name: "Alice"}, %{name: "Bob"}]

    assert :ok = ExternalDB.store(:external_users, data, ~D[2025-01-15], config)
  end
end
```

## Implementation Order

1. **REST I/O Manager** - HTTP-based data loading/storing
2. **LLM Integration** - API clients for OpenAI/Anthropic
3. **Resilience helpers** - Retry and circuit breaker
4. **Python integration** - Erlport GenServer
5. **dbt integration** - Shell command execution
6. **Notifications** - Slack and email
7. **External DB I/O Manager** - Database connections
8. **Integration tests** - End-to-end external system tests

## Success Criteria

- [ ] REST I/O Manager handles all HTTP status codes
- [ ] LLM integration supports retry and rate limiting
- [ ] Python integration calls ML functions successfully
- [ ] dbt integration parses output correctly
- [ ] Notifications send to Slack and email
- [ ] Circuit breaker opens after threshold failures
- [ ] Retry uses exponential backoff
- [ ] All integrations testable with Bypass/Mox
- [ ] Telemetry events emitted for all external calls

## Commands

```bash
# Run integration tests
mix test test/flowstone/integrations/

# Run REST I/O tests
mix test test/flowstone/io/rest_test.exs

# Run LLM tests
mix test test/flowstone/integrations/llm_test.exs

# Run resilience tests
mix test test/flowstone/integrations/resilience_test.exs

# Run notification tests
mix test test/flowstone/integrations/notifications_test.exs

# Run Python tests (requires Python setup)
mix test test/flowstone/integrations/python_test.exs --only python

# Run dbt tests (requires dbt project)
mix test test/flowstone/integrations/dbt_test.exs --only dbt

# Check coverage
mix coveralls.html
```

## Spawn Subagents

1. **REST I/O Manager** - HTTP-based integration
2. **LLM Integration** - OpenAI/Anthropic clients
3. **Resilience helpers** - Retry and circuit breaker
4. **Python integration** - ML pipeline support
5. **dbt integration** - Data transformation
6. **Notifications** - Slack and email alerts
7. **External DB I/O Manager** - Database connectivity

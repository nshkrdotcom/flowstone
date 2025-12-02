# Implementation Prompt: ADR-0009 Structured Error Handling

## Objective

Implement structured error handling for FlowStone with retryability, error recording, observability integration, and user-friendly messaging using TDD with Supertester.

## Required Reading

Before starting, read these documents thoroughly:

1. **ADR-0009**: `docs/adr/0009-error-handling.md` - Error handling architecture
2. **ADR-0006**: `docs/adr/0006-oban-job-execution.md` - Oban worker patterns
3. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md` - Asset fundamentals
4. **Supertester Manual**: https://hexdocs.pm/supertester - Testing framework
5. **Elixir Error Handling**: https://elixir-lang.org/getting-started/try-catch-and-rescue.html

## Context

Error handling in orchestration systems must:

1. **Distinguish retryable from fatal errors** - Transient network issues vs logic bugs
2. **Provide actionable messages** - Users know what to do next
3. **Enable debugging** - Full context for developers without exposing internals
4. **Integrate with observability** - Structured logging, metrics, telemetry

Analysis of pipeline_ex revealed anti-patterns:
- 72 generic `rescue` blocks catching everything
- Inconsistent error message formats
- No distinction between expected errors and bugs
- Silent failures masking issues

FlowStone uses structured errors with:
- Typed error variants (asset_not_found, io_error, timeout, etc.)
- Retryable flag for Oban retry decisions
- Rich context for debugging
- Factory functions for common errors
- Single exception boundary in Materializer

## Implementation Tasks

### 1. Create FlowStone.Error Exception

```elixir
# lib/flowstone/error.ex
defmodule FlowStone.Error do
  @type t :: %__MODULE__{
    type: error_type(),
    message: String.t(),
    context: map(),
    retryable: boolean(),
    original: Exception.t() | nil
  }

  @type error_type ::
    :asset_not_found |
    :dependency_failed |
    :dependency_not_ready |
    :io_error |
    :execution_error |
    :timeout |
    :validation_error |
    :resource_unavailable |
    :checkpoint_rejected

  defexception [:type, :message, :context, :retryable, :original]

  # Exception behaviour
  def message(%__MODULE__{message: msg, type: type})

  # Factory functions
  def asset_not_found(asset_name)
  def dependency_failed(asset, dep, reason)
  def dependency_not_ready(asset, missing_deps)
  def io_error(operation, asset, partition, reason)
  def execution_error(asset, partition, exception, stacktrace)
  def timeout(asset, partition, duration_ms)
  def validation_error(message, context)
  def resource_unavailable(resource_name, reason)
  def checkpoint_rejected(asset, partition, reason)
end
```

### 2. Create FlowStone.Result Utilities

```elixir
# lib/flowstone/result.ex
defmodule FlowStone.Result do
  @type t(value) :: {:ok, value} | {:error, FlowStone.Error.t()}

  def ok(value)
  def error(%FlowStone.Error{} = err)
  def map({:ok, value}, fun)
  def map({:error, _} = err, _fun)
  def flat_map({:ok, value}, fun)
  def flat_map({:error, _} = err, _fun)
  def unwrap!({:ok, value})
  def unwrap!({:error, err})
end
```

### 3. Create Controlled Exception Boundary

```elixir
# Update lib/flowstone/materializer.ex
defmodule FlowStone.Materializer do
  def execute(asset, context, deps) do
    # Single try/rescue boundary
    # Convert all exceptions to FlowStone.Error
  end

  defp normalize_result({:ok, value})
  defp normalize_result({:error, %FlowStone.Error{}} = err)
  defp normalize_result({:error, reason}) when is_binary(reason)
  defp normalize_result(other)
end
```

### 4. Create Error Recorder

```elixir
# lib/flowstone/error_recorder.ex
defmodule FlowStone.ErrorRecorder do
  require Logger

  def record(%FlowStone.Error{}, context)

  # Private helpers
  defp log_error(error, context)
  defp emit_telemetry(error, context)
  defp update_materialization_error(context, error)
end
```

### 5. Create Error Formatter

```elixir
# lib/flowstone/error/formatter.ex
defmodule FlowStone.Error.Formatter do
  def user_message(%FlowStone.Error{})
  def developer_message(%FlowStone.Error{})
end
```

### 6. Update Oban Worker with Retry Logic

```elixir
# Update lib/flowstone/workers/asset_worker.ex
defmodule FlowStone.Workers.AssetWorker do
  use Oban.Worker, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    case materialize_asset(args) do
      {:ok, _} -> :ok
      {:error, %FlowStone.Error{retryable: true} = error} when attempt < 5 ->
        {:error, error.message}
      {:error, %FlowStone.Error{retryable: false} = error} ->
        {:discard, error.message}
      {:error, %FlowStone.Error{type: :dependency_not_ready}} ->
        {:snooze, 30}
    end
  end
end
```

### 7. Create Asset Validator

```elixir
# lib/flowstone/asset/validator.ex
defmodule FlowStone.Asset.Validator do
  def validate(asset_definition) :: :ok | {:error, [error]}

  defp validate_name(errors, asset_definition)
  defp validate_dependencies(errors, asset_definition)
  defp validate_io_manager(errors, asset_definition)
  defp validate_execute_fn(errors, asset_definition)
end
```

### 8. Create Transient Error Detection

```elixir
# Add to lib/flowstone/error.ex
defmodule FlowStone.Error do
  defp is_transient_io_error?(%DBConnection.ConnectionError{}), do: true
  defp is_transient_io_error?(%Req.TransportError{}), do: true
  defp is_transient_io_error?({:timeout, _}), do: true
  defp is_transient_io_error?(_), do: false
end
```

## Test Design with Supertester

### Test File Structure

```
test/
├── flowstone/
│   ├── error_test.exs
│   ├── result_test.exs
│   ├── error_recorder_test.exs
│   ├── materializer_error_handling_test.exs
│   ├── error/
│   │   └── formatter_test.exs
│   ├── asset/
│   │   └── validator_test.exs
│   └── workers/
│       └── asset_worker_retry_test.exs
└── support/
    └── error_fixtures.ex
```

### Test Cases

#### FlowStone.Error Factory Tests

```elixir
defmodule FlowStone.ErrorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Error

  describe "asset_not_found/1" do
    test "creates non-retryable error" do
      error = Error.asset_not_found(:missing_asset)

      assert error.type == :asset_not_found
      assert error.message =~ "missing_asset"
      assert error.retryable == false
      assert error.context.asset == :missing_asset
    end
  end

  describe "dependency_failed/3" do
    test "creates non-retryable error with context" do
      error = Error.dependency_failed(:my_asset, :upstream, "computation failed")

      assert error.type == :dependency_failed
      assert error.retryable == false
      assert error.context.asset == :my_asset
      assert error.context.dependency == :upstream
      assert error.context.reason == "computation failed"
    end
  end

  describe "dependency_not_ready/2" do
    test "creates retryable error for snoozing" do
      error = Error.dependency_not_ready(:my_asset, [:dep1, :dep2])

      assert error.type == :dependency_not_ready
      assert error.retryable == true
      assert error.context.asset == :my_asset
      assert error.context.missing == [:dep1, :dep2]
    end
  end

  describe "io_error/4" do
    test "creates retryable error for transient failures" do
      db_error = %DBConnection.ConnectionError{message: "connection refused"}

      error = Error.io_error(:read, :my_asset, ~D[2025-01-15], db_error)

      assert error.type == :io_error
      assert error.retryable == true
      assert error.context.operation == :read
      assert error.context.asset == :my_asset
      assert error.context.partition == ~D[2025-01-15]
      assert error.original == db_error
    end

    test "creates non-retryable error for permanent failures" do
      error = Error.io_error(:read, :my_asset, ~D[2025-01-15], :file_not_found)

      assert error.type == :io_error
      assert error.retryable == false
    end
  end

  describe "execution_error/4" do
    test "captures exception and stacktrace" do
      exception = %RuntimeError{message: "division by zero"}
      stacktrace = [{MyModule, :my_function, 2, [file: "lib/my_module.ex", line: 42]}]

      error = Error.execution_error(:my_asset, ~D[2025-01-15], exception, stacktrace)

      assert error.type == :execution_error
      assert error.retryable == false
      assert error.context.asset == :my_asset
      assert error.context.partition == ~D[2025-01-15]
      assert error.context.stacktrace =~ "my_module.ex:42"
      assert error.original == exception
    end
  end

  describe "timeout/3" do
    test "creates retryable timeout error" do
      error = Error.timeout(:slow_asset, ~D[2025-01-15], 30_000)

      assert error.type == :timeout
      assert error.retryable == true
      assert error.message =~ "30000ms"
      assert error.context.duration_ms == 30_000
    end
  end

  describe "validation_error/2" do
    test "creates non-retryable validation error" do
      error = Error.validation_error("Invalid schema", %{field: "name", value: nil})

      assert error.type == :validation_error
      assert error.retryable == false
      assert error.message == "Invalid schema"
      assert error.context.field == "name"
    end
  end

  describe "resource_unavailable/2" do
    test "creates retryable resource error" do
      error = Error.resource_unavailable(:database, :connection_timeout)

      assert error.type == :resource_unavailable
      assert error.retryable == true
      assert error.context.resource == :database
      assert error.context.reason == :connection_timeout
    end
  end

  describe "checkpoint_rejected/3" do
    test "creates non-retryable checkpoint error" do
      error = Error.checkpoint_rejected(:my_asset, ~D[2025-01-15], "Quality check failed")

      assert error.type == :checkpoint_rejected
      assert error.retryable == false
      assert error.context.asset == :my_asset
      assert error.context.partition == ~D[2025-01-15]
      assert error.context.reason == "Quality check failed"
    end
  end

  describe "Exception.message/1" do
    test "formats error message with type prefix" do
      error = Error.asset_not_found(:test)

      message = Exception.message(error)
      assert message =~ "[asset_not_found]"
      assert message =~ "test"
    end
  end
end
```

#### FlowStone.Result Tests

```elixir
defmodule FlowStone.ResultTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.{Result, Error}

  describe "ok/1" do
    test "wraps value in ok tuple" do
      assert {:ok, 42} = Result.ok(42)
    end
  end

  describe "error/1" do
    test "wraps error in error tuple" do
      err = Error.asset_not_found(:test)
      assert {:error, ^err} = Result.error(err)
    end
  end

  describe "map/2" do
    test "transforms ok value" do
      result = {:ok, 10}

      assert {:ok, 20} = Result.map(result, fn x -> x * 2 end)
    end

    test "passes through error" do
      err = Error.asset_not_found(:test)
      result = {:error, err}

      assert {:error, ^err} = Result.map(result, fn x -> x * 2 end)
    end
  end

  describe "flat_map/2" do
    test "chains successful operations" do
      result = {:ok, 5}

      chained = Result.flat_map(result, fn x ->
        {:ok, x * 2}
      end)

      assert {:ok, 10} = chained
    end

    test "short-circuits on error" do
      err = Error.timeout(:test, ~D[2025-01-15], 1000)
      result = {:error, err}

      chained = Result.flat_map(result, fn x ->
        {:ok, x * 2}
      end)

      assert {:error, ^err} = chained
    end

    test "propagates inner error" do
      result = {:ok, 5}

      chained = Result.flat_map(result, fn _x ->
        {:error, Error.validation_error("too small", %{})}
      end)

      assert {:error, %Error{type: :validation_error}} = chained
    end
  end

  describe "unwrap!/1" do
    test "extracts ok value" do
      assert 42 = Result.unwrap!({:ok, 42})
    end

    test "raises error" do
      err = Error.asset_not_found(:test)

      assert_raise FlowStone.Error, fn ->
        Result.unwrap!({:error, err})
      end
    end
  end
end
```

#### Materializer Error Boundary Tests

```elixir
defmodule FlowStone.MaterializerErrorHandlingTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.{Materializer, Error}

  describe "execute/3 exception boundary" do
    test "returns ok result unchanged" do
      asset = %FlowStone.Asset{
        name: :success,
        execute_fn: fn _ctx, _deps -> {:ok, :result} end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:ok, :result} = Materializer.execute(asset, context, %{})
    end

    test "passes through FlowStone.Error unchanged" do
      err = Error.timeout(:test, ~D[2025-01-15], 1000)

      asset = %FlowStone.Asset{
        name: :returns_error,
        execute_fn: fn _ctx, _deps -> {:error, err} end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:error, ^err} = Materializer.execute(asset, context, %{})
    end

    test "wraps string error in execution_error" do
      asset = %FlowStone.Asset{
        name: :string_error,
        execute_fn: fn _ctx, _deps -> {:error, "something went wrong"} end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:error, %Error{type: :execution_error}} = Materializer.execute(asset, context, %{})
    end

    test "catches raised exceptions" do
      asset = %FlowStone.Asset{
        name: :raises,
        execute_fn: fn _ctx, _deps -> raise "boom!" end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:error, %Error{type: :execution_error} = error} =
        Materializer.execute(asset, context, %{})

      assert error.original.message == "boom!"
      assert error.context.stacktrace != nil
    end

    test "catches exits" do
      asset = %FlowStone.Asset{
        name: :exits,
        execute_fn: fn _ctx, _deps -> exit(:killed) end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:error, %Error{type: :execution_error} = error} =
        Materializer.execute(asset, context, %{})

      assert error.message =~ "exited"
      assert error.message =~ "killed"
    end

    test "handles unexpected return values" do
      asset = %FlowStone.Asset{
        name: :bad_return,
        execute_fn: fn _ctx, _deps -> :unexpected end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:error, %Error{type: :execution_error} = error} =
        Materializer.execute(asset, context, %{})

      assert error.message =~ "Unexpected return"
      assert error.message =~ "unexpected"
    end

    test "preserves stacktrace in execution_error" do
      asset = %FlowStone.Asset{
        name: :deep_error,
        execute_fn: fn _ctx, _deps ->
          deep_function()
        end
      }

      context = %FlowStone.Context{asset: asset, partition: ~D[2025-01-15]}

      assert {:error, %Error{type: :execution_error} = error} =
        Materializer.execute(asset, context, %{})

      assert error.context.stacktrace =~ "deep_function"
    end
  end

  defp deep_function do
    raise "error deep in the stack"
  end
end
```

#### Error Recorder Tests

```elixir
defmodule FlowStone.ErrorRecorderTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.{Error, ErrorRecorder}

  setup do
    # Attach telemetry handler
    :telemetry.attach(
      "test-error-handler",
      [:flowstone, :error],
      &handle_telemetry/4,
      self()
    )

    on_exit(fn ->
      :telemetry.detach("test-error-handler")
    end)

    :ok
  end

  describe "record/2" do
    test "logs error with structured context" do
      error = Error.timeout(:my_asset, ~D[2025-01-15], 5000)
      context = %{asset: :my_asset, partition: ~D[2025-01-15], run_id: "run-123"}

      # Capture logs
      log = capture_log(fn ->
        ErrorRecorder.record(error, context)
      end)

      assert log =~ "FlowStone error"
      assert log =~ "timeout"
      assert log =~ "my_asset"
      assert log =~ "run-123"
    end

    test "emits telemetry event" do
      error = Error.io_error(:read, :my_asset, ~D[2025-01-15], :connection_lost)
      context = %{asset: :my_asset, run_id: "run-456"}

      ErrorRecorder.record(error, context)

      assert_receive {:telemetry, [:flowstone, :error], measurements, metadata}
      assert measurements.count == 1
      assert metadata.type == :io_error
      assert metadata.asset == :my_asset
      assert metadata.retryable == true
    end

    test "updates materialization record with error" do
      error = Error.execution_error(:my_asset, ~D[2025-01-15], %RuntimeError{}, [])
      context = %{
        asset: :my_asset,
        partition: ~D[2025-01-15],
        run_id: "run-789"
      }

      ErrorRecorder.record(error, context)

      # Query materialization record
      materialization = FlowStone.Repo.get_by(FlowStone.Materialization,
        run_id: "run-789",
        asset_name: "my_asset"
      )

      assert materialization.status == :failed
      assert materialization.error_message =~ "execution failed"
      assert materialization.metadata.error_type == :execution_error
      assert materialization.metadata.retryable == false
    end

    test "handles recording errors gracefully" do
      error = Error.asset_not_found(:test)
      context = %{}  # Missing required fields

      # Should not crash
      assert :ok = ErrorRecorder.record(error, context)
    end
  end

  defp handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
```

#### Error Formatter Tests

```elixir
defmodule FlowStone.Error.FormatterTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Error
  alias FlowStone.Error.Formatter

  describe "user_message/1" do
    test "formats asset_not_found for users" do
      error = Error.asset_not_found(:missing)

      msg = Formatter.user_message(error)
      assert msg =~ "not found"
      refute msg =~ "missing"  # Don't leak internal asset names
    end

    test "formats io_error for users" do
      error = Error.io_error(:read, :asset, ~D[2025-01-15], :timeout)

      msg = Formatter.user_message(error)
      assert msg =~ "read or write"
      assert msg =~ "temporary"
      refute msg =~ ":timeout"  # No raw atoms
    end

    test "formats execution_error for users" do
      exception = %RuntimeError{message: "internal error"}
      error = Error.execution_error(:asset, ~D[2025-01-15], exception, [])

      msg = Formatter.user_message(error)
      assert msg =~ "computation failed"
      assert msg =~ "logs"
      refute msg =~ "RuntimeError"
    end

    test "formats timeout for users" do
      error = Error.timeout(:slow, ~D[2025-01-15], 60000)

      msg = Formatter.user_message(error)
      assert msg =~ "timed out"
      assert msg =~ "timeout"
      assert msg =~ "optimizing"
    end

    test "formats validation_error with message" do
      error = Error.validation_error("Schema validation failed: missing field 'name'", %{})

      msg = Formatter.user_message(error)
      assert msg =~ "validation failed"
      assert msg =~ "missing field 'name'"
    end

    test "formats checkpoint_rejected with reason" do
      error = Error.checkpoint_rejected(:asset, ~D[2025-01-15], "Quality below threshold")

      msg = Formatter.user_message(error)
      assert msg =~ "rejected"
      assert msg =~ "Quality below threshold"
    end

    test "provides generic message for unknown types" do
      error = %Error{type: :unknown_type, message: "test", context: %{}, retryable: false}

      msg = Formatter.user_message(error)
      assert msg =~ "unexpected error"
      assert msg =~ "support"
    end
  end

  describe "developer_message/1" do
    test "includes full error details" do
      exception = %ArgumentError{message: "bad argument"}
      stacktrace = [{Foo, :bar, 2, [file: "lib/foo.ex", line: 10]}]
      error = Error.execution_error(:my_asset, ~D[2025-01-15], exception, stacktrace)

      msg = Formatter.developer_message(error)

      assert msg =~ "FlowStone Error"
      assert msg =~ "execution_error"
      assert msg =~ error.message
      assert msg =~ "Retryable: false"
      assert msg =~ "Context:"
      assert msg =~ "my_asset"
      assert msg =~ "Original:"
      assert msg =~ "ArgumentError"
    end

    test "formats error without original exception" do
      error = Error.timeout(:asset, ~D[2025-01-15], 5000)

      msg = Formatter.developer_message(error)

      assert msg =~ "timeout"
      refute msg =~ "Original:"
    end

    test "pretty-prints context map" do
      error = Error.dependency_failed(:asset, :dep, %{
        details: "computation failed",
        attempts: 3,
        last_error: "division by zero"
      })

      msg = Formatter.developer_message(error)

      assert msg =~ "Context:"
      assert msg =~ "details:"
      assert msg =~ "attempts:"
      assert msg =~ "last_error:"
    end
  end
end
```

#### Oban Worker Retry Tests

```elixir
defmodule FlowStone.Workers.AssetWorkerRetryTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  use Oban.Testing, repo: FlowStone.Repo

  alias FlowStone.Workers.AssetWorker
  alias FlowStone.Error

  describe "perform/1 retry logic" do
    test "returns :ok for successful materialization" do
      setup_asset(:success, fn _ctx, _deps -> {:ok, :result} end)

      job = %Oban.Job{
        args: %{"asset" => "success", "partition" => "2025-01-15"},
        attempt: 1
      }

      assert :ok = AssetWorker.perform(job)
    end

    test "retries retryable errors" do
      setup_asset(:retryable_error, fn _ctx, _deps ->
        {:error, Error.io_error(:read, :test, ~D[2025-01-15], :timeout)}
      end)

      job = %Oban.Job{
        args: %{"asset" => "retryable_error", "partition" => "2025-01-15"},
        attempt: 1
      }

      assert {:error, message} = AssetWorker.perform(job)
      assert message =~ "I/O"
    end

    test "discards non-retryable errors immediately" do
      setup_asset(:fatal_error, fn _ctx, _deps ->
        {:error, Error.asset_not_found(:nonexistent)}
      end)

      job = %Oban.Job{
        args: %{"asset" => "fatal_error"},
        attempt: 1
      }

      assert {:discard, message} = AssetWorker.perform(job)
      assert message =~ "not found"
    end

    test "snoozes for dependency_not_ready errors" do
      setup_asset(:waiting, fn _ctx, _deps ->
        {:error, Error.dependency_not_ready(:waiting, [:upstream])}
      end)

      job = %Oban.Job{
        args: %{"asset" => "waiting"},
        attempt: 1
      }

      assert {:snooze, 30} = AssetWorker.perform(job)
    end

    test "discards retryable error on final attempt" do
      setup_asset(:retry_exhausted, fn _ctx, _deps ->
        {:error, Error.timeout(:test, ~D[2025-01-15], 5000)}
      end)

      job = %Oban.Job{
        args: %{"asset" => "retry_exhausted"},
        attempt: 5  # max_attempts reached
      }

      # Should not return {:error, _} which would trigger retry
      result = AssetWorker.perform(job)
      assert result == :ok or match?({:discard, _}, result)
    end

    test "records error on each attempt" do
      setup_asset(:recorded_error, fn _ctx, _deps ->
        {:error, Error.execution_error(:test, ~D[2025-01-15], %RuntimeError{}, [])}
      end)

      job = %Oban.Job{
        args: %{"asset" => "recorded_error", "partition" => "2025-01-15"},
        attempt: 1
      }

      AssetWorker.perform(job)

      # Verify error was recorded
      assert_receive {:error_recorded, %Error{type: :execution_error}}
    end
  end

  describe "error backoff strategy" do
    test "respects Oban exponential backoff" do
      setup_asset(:backoff_test, fn _ctx, _deps ->
        {:error, Error.timeout(:test, ~D[2025-01-15], 1000)}
      end)

      # Insert job
      job_args = %{"asset" => "backoff_test", "partition" => "2025-01-15"}
      {:ok, job} = AssetWorker.new(job_args) |> Oban.insert()

      # First attempt fails
      perform_job(AssetWorker, job)

      # Check scheduled_at for next attempt (should be in future with backoff)
      next_job = FlowStone.Repo.get(Oban.Job, job.id)
      assert DateTime.compare(next_job.scheduled_at, DateTime.utc_now()) == :gt
    end
  end

  defp setup_asset(name, execute_fn) do
    asset = %FlowStone.Asset{
      name: name,
      execute_fn: execute_fn
    }
    FlowStone.Asset.Registry.register(asset)
  end
end
```

#### Asset Validator Tests

```elixir
defmodule FlowStone.Asset.ValidatorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Asset
  alias FlowStone.Asset.Validator

  describe "validate/1" do
    test "accepts valid asset" do
      asset = %Asset{
        name: :valid,
        depends_on: [:upstream],
        io_manager: :memory,
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      assert :ok = Validator.validate(asset)
    end

    test "rejects nil name" do
      asset = %Asset{name: nil, execute_fn: fn _, _ -> {:ok, nil} end}

      assert {:error, errors} = Validator.validate(asset)
      assert {:name, msg} = List.keyfind(errors, :name, 0)
      assert msg =~ "required"
    end

    test "rejects non-atom name" do
      asset = %Asset{name: "string_name", execute_fn: fn _, _ -> {:ok, nil} end}

      assert {:error, errors} = Validator.validate(asset)
      assert {:name, msg} = List.keyfind(errors, :name, 0)
      assert msg =~ "atom"
    end

    test "rejects non-atom dependencies" do
      asset = %Asset{
        name: :test,
        depends_on: [:valid, "invalid", :another],
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      assert {:error, errors} = Validator.validate(asset)
      assert {:depends_on, msg} = List.keyfind(errors, :depends_on, 0)
      assert msg =~ "atoms"
      assert msg =~ "invalid"
    end

    test "rejects missing execute function" do
      asset = %Asset{name: :no_execute, execute_fn: nil}

      assert {:error, errors} = Validator.validate(asset)
      assert {:execute, msg} = List.keyfind(errors, :execute, 0)
      assert msg =~ "execute function"
    end

    test "rejects wrong arity execute function" do
      asset = %Asset{
        name: :wrong_arity,
        execute_fn: fn _ -> {:ok, nil} end  # arity 1, should be 2
      }

      assert {:error, errors} = Validator.validate(asset)
      assert {:execute, msg} = List.keyfind(errors, :execute, 0)
      assert msg =~ "arity 2"
    end

    test "validates io_manager is registered" do
      asset = %Asset{
        name: :bad_io,
        io_manager: :nonexistent_manager,
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      assert {:error, errors} = Validator.validate(asset)
      assert {:io_manager, msg} = List.keyfind(errors, :io_manager, 0)
      assert msg =~ "Unknown"
      assert msg =~ "nonexistent_manager"
    end

    test "allows nil io_manager (uses default)" do
      asset = %Asset{
        name: :default_io,
        io_manager: nil,
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      assert :ok = Validator.validate(asset)
    end

    test "accumulates multiple validation errors" do
      asset = %Asset{
        name: "bad_name",  # Should be atom
        depends_on: ["string_dep"],  # Should be atoms
        execute_fn: fn _ -> :ok end  # Wrong arity
      }

      assert {:error, errors} = Validator.validate(asset)
      assert length(errors) >= 3
      assert List.keyfind(errors, :name, 0)
      assert List.keyfind(errors, :depends_on, 0)
      assert List.keyfind(errors, :execute, 0)
    end
  end
end
```

#### Integration Tests

```elixir
defmodule FlowStone.ErrorHandlingIntegrationTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  use Oban.Testing, repo: FlowStone.Repo

  describe "end-to-end error handling" do
    test "transient error retries and succeeds" do
      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      asset = %FlowStone.Asset{
        name: :flaky_asset,
        execute_fn: fn _ctx, _deps ->
          count = Agent.get_and_update(call_count, fn c -> {c + 1, c + 1} end)

          if count < 3 do
            {:error, FlowStone.Error.timeout(:flaky_asset, ~D[2025-01-15], 1000)}
          else
            {:ok, :success}
          end
        end
      }

      FlowStone.Asset.Registry.register(asset)

      # Insert job
      {:ok, job} = FlowStone.Workers.AssetWorker.new(%{
        "asset" => "flaky_asset",
        "partition" => "2025-01-15"
      }) |> Oban.insert()

      # Perform multiple times
      perform_job(FlowStone.Workers.AssetWorker, job)  # Attempt 1: fails
      perform_job(FlowStone.Workers.AssetWorker, job)  # Attempt 2: fails
      perform_job(FlowStone.Workers.AssetWorker, job)  # Attempt 3: succeeds

      # Job should complete
      final_job = FlowStone.Repo.get(Oban.Job, job.id)
      assert final_job.state == :completed
    end

    test "fatal error discarded immediately" do
      asset = %FlowStone.Asset{
        name: :fatal_asset,
        execute_fn: fn _ctx, _deps ->
          raise "unrecoverable error"
        end
      }

      FlowStone.Asset.Registry.register(asset)

      {:ok, job} = FlowStone.Workers.AssetWorker.new(%{
        "asset" => "fatal_asset"
      }) |> Oban.insert()

      perform_job(FlowStone.Workers.AssetWorker, job)

      final_job = FlowStone.Repo.get(Oban.Job, job.id)
      assert final_job.state == :discarded
    end
  end
end
```

## Supertester Integration Principles

### 1. Use Isolation Modes
```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. Test Error Factories Thoroughly
```elixir
test "creates correct error structure" do
  error = Error.timeout(:asset, ~D[2025-01-15], 5000)
  assert error.type == :timeout
  assert error.retryable == true
end
```

### 3. Test Exception Boundaries
```elixir
test "catches and wraps exceptions" do
  assert {:error, %Error{}} = execute_with_boundary(fn -> raise "boom" end)
end
```

### 4. Verify Telemetry Events
```elixir
test "emits error telemetry" do
  record_error(error, context)
  assert_receive {:telemetry, [:flowstone, :error], _, _}
end
```

### 5. Test Oban Retry Logic
```elixir
test "retries on retryable error" do
  job = %Oban.Job{args: %{}, attempt: 1}
  assert {:error, _} = Worker.perform(job)  # Triggers retry
end
```

## Implementation Order

1. **FlowStone.Error struct and factory functions** - Core error types
2. **FlowStone.Result utilities** - Result monad helpers
3. **Transient error detection** - is_transient_io_error?/1
4. **Error.Formatter** - User and developer messages
5. **Materializer exception boundary** - Single try/rescue point
6. **ErrorRecorder** - Logging, telemetry, persistence
7. **Asset.Validator** - Compile-time validation
8. **AssetWorker retry logic** - Oban integration

## Success Criteria

- [ ] All tests pass with `async: true`
- [ ] 100% test coverage for Error and Result modules
- [ ] All error types have factory functions
- [ ] Single exception boundary in Materializer
- [ ] Error recording emits telemetry events
- [ ] Oban worker correctly handles retryable vs fatal errors
- [ ] User messages hide internal details
- [ ] Developer messages include full context
- [ ] Dialyzer passes with no warnings
- [ ] Credo passes with no issues
- [ ] Documentation for all error types and usage patterns

## Commands

```bash
# Run all error handling tests
mix test test/flowstone/error_test.exs test/flowstone/error_recorder_test.exs test/flowstone/materializer_error_handling_test.exs

# Run with coverage
mix coveralls.html --umbrella

# Test Oban worker retry logic
mix test test/flowstone/workers/asset_worker_retry_test.exs

# Test validator
mix test test/flowstone/asset/validator_test.exs

# Check types
mix dialyzer

# Check style
mix credo --strict
```

## Spawn Subagents

For parallel implementation, spawn subagents for:

1. **Error struct and factories** - FlowStone.Error with all error types
2. **Result utilities** - FlowStone.Result monad helpers
3. **Error Formatter** - User and developer message formatting
4. **Materializer boundary** - Exception handling in execute/3
5. **Error Recorder** - Logging, telemetry, persistence integration
6. **Asset Validator** - Compile-time validation
7. **Oban retry logic** - Worker perform/1 with retry handling
8. **Integration tests** - End-to-end error scenarios

Each subagent should follow TDD: write tests first using Supertester, then implement.

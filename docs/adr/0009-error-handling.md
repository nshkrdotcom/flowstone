# ADR-0009: Structured Error Handling

## Status
Accepted

## Context

Error handling in orchestration systems must:
1. Distinguish between retryable and fatal errors
2. Provide actionable error messages
3. Enable debugging without exposing internals to end users
4. Integrate with observability (logging, metrics, alerts)

Analysis of pipeline_ex revealed anti-patterns:
- 72 generic `rescue` blocks catching all exceptions
- Inconsistent error message formats
- No distinction between expected errors and bugs
- Silent failures masking underlying issues

## Decision

### 1. Structured Error Types

```elixir
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

  def message(%__MODULE__{message: msg, type: type}) do
    "[#{type}] #{msg}"
  end

  # Factory functions for common errors
  def asset_not_found(asset_name) do
    %__MODULE__{
      type: :asset_not_found,
      message: "Asset #{inspect(asset_name)} is not registered",
      context: %{asset: asset_name},
      retryable: false
    }
  end

  def dependency_failed(asset, dep, reason) do
    %__MODULE__{
      type: :dependency_failed,
      message: "Dependency #{inspect(dep)} failed for asset #{inspect(asset)}",
      context: %{asset: asset, dependency: dep, reason: reason},
      retryable: false
    }
  end

  def dependency_not_ready(asset, missing_deps) do
    %__MODULE__{
      type: :dependency_not_ready,
      message: "Dependencies not ready: #{inspect(missing_deps)}",
      context: %{asset: asset, missing: missing_deps},
      retryable: true  # Retry after snooze
    }
  end

  def io_error(operation, asset, partition, reason) do
    %__MODULE__{
      type: :io_error,
      message: "I/O #{operation} failed for #{inspect(asset)}/#{inspect(partition)}",
      context: %{operation: operation, asset: asset, partition: partition},
      retryable: is_transient_io_error?(reason),
      original: if(is_exception(reason), do: reason, else: nil)
    }
  end

  def execution_error(asset, partition, exception, stacktrace) do
    %__MODULE__{
      type: :execution_error,
      message: "Asset execution failed: #{Exception.message(exception)}",
      context: %{
        asset: asset,
        partition: partition,
        stacktrace: Exception.format_stacktrace(stacktrace)
      },
      retryable: false,
      original: exception
    }
  end

  def timeout(asset, partition, duration_ms) do
    %__MODULE__{
      type: :timeout,
      message: "Asset execution timed out after #{duration_ms}ms",
      context: %{asset: asset, partition: partition, duration_ms: duration_ms},
      retryable: true
    }
  end

  defp is_transient_io_error?(%DBConnection.ConnectionError{}), do: true
  defp is_transient_io_error?(%Req.TransportError{}), do: true
  defp is_transient_io_error?({:timeout, _}), do: true
  defp is_transient_io_error?(_), do: false
end
```

### 2. Result Types

```elixir
defmodule FlowStone.Result do
  @type t(value) :: {:ok, value} | {:error, FlowStone.Error.t()}

  @doc "Wrap a value in an ok tuple"
  def ok(value), do: {:ok, value}

  @doc "Wrap an error"
  def error(%FlowStone.Error{} = err), do: {:error, err}

  @doc "Map over a result"
  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _} = err, _fun), do: err

  @doc "Flat map over a result"
  def flat_map({:ok, value}, fun), do: fun.(value)
  def flat_map({:error, _} = err, _fun), do: err

  @doc "Unwrap or raise"
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, err}), do: raise err
end
```

### 3. Controlled Exception Boundaries

```elixir
defmodule FlowStone.Materializer do
  def execute(asset, context, deps) do
    execute_fn = FlowStone.Asset.execute_fn(asset)

    try do
      case execute_fn.(context, deps) do
        {:ok, result} ->
          {:ok, result}

        {:error, %FlowStone.Error{} = err} ->
          {:error, err}

        {:error, reason} when is_binary(reason) ->
          {:error, FlowStone.Error.execution_error(
            asset, context.partition,
            %RuntimeError{message: reason},
            []
          )}

        other ->
          {:error, FlowStone.Error.execution_error(
            asset, context.partition,
            %RuntimeError{message: "Unexpected return: #{inspect(other)}"},
            []
          )}
      end
    rescue
      exception ->
        {:error, FlowStone.Error.execution_error(
          asset, context.partition,
          exception,
          __STACKTRACE__
        )}
    catch
      :exit, reason ->
        {:error, FlowStone.Error.execution_error(
          asset, context.partition,
          %RuntimeError{message: "Process exited: #{inspect(reason)}"},
          []
        )}
    end
  end
end
```

### 4. Error Recording

```elixir
defmodule FlowStone.ErrorRecorder do
  require Logger

  def record(%FlowStone.Error{} = error, context) do
    # Structured logging
    Logger.error("FlowStone error",
      type: error.type,
      message: error.message,
      asset: context[:asset],
      partition: context[:partition],
      run_id: context[:run_id],
      retryable: error.retryable
    )

    # Telemetry for metrics
    :telemetry.execute(
      [:flowstone, :error],
      %{count: 1},
      %{
        type: error.type,
        asset: context[:asset],
        retryable: error.retryable
      }
    )

    # Store in materialization record
    update_materialization_error(context, error)
  end

  defp update_materialization_error(%{run_id: run_id, asset: asset, partition: partition}, error) do
    Repo.update_all(
      from(m in Materialization,
        where: m.run_id == ^run_id and m.asset_name == ^to_string(asset) and m.partition == ^to_string(partition)
      ),
      set: [
        status: :failed,
        error_message: error.message,
        metadata: %{
          error_type: error.type,
          error_context: error.context,
          retryable: error.retryable
        }
      ]
    )
  end
end
```

### 5. Retry Decision

```elixir
defmodule FlowStone.Workers.AssetWorker do
  use Oban.Worker, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    case materialize_asset(args) do
      {:ok, _} ->
        :ok

      {:error, %FlowStone.Error{retryable: true} = error} when attempt < 5 ->
        # Retryable error, let Oban retry with backoff
        FlowStone.ErrorRecorder.record(error, args)
        {:error, error.message}

      {:error, %FlowStone.Error{retryable: false} = error} ->
        # Non-retryable, fail immediately
        FlowStone.ErrorRecorder.record(error, args)
        {:discard, error.message}

      {:error, %FlowStone.Error{type: :dependency_not_ready}} ->
        # Snooze and check again
        {:snooze, 30}
    end
  end
end
```

### 6. User-Facing Error Messages

```elixir
defmodule FlowStone.Error.Formatter do
  @doc "Format error for user display (hide internals)"
  def user_message(%FlowStone.Error{type: type} = error) do
    case type do
      :asset_not_found ->
        "The requested asset was not found. Please check the asset name."

      :dependency_failed ->
        "A required upstream asset failed. Check the dependency chain."

      :io_error ->
        "Failed to read or write data. This may be a temporary issue."

      :execution_error ->
        "Asset computation failed. Check asset logs for details."

      :timeout ->
        "The operation timed out. Consider increasing the timeout or optimizing the asset."

      :validation_error ->
        "Data validation failed: #{error.message}"

      :resource_unavailable ->
        "A required resource is unavailable. Please try again later."

      :checkpoint_rejected ->
        "The checkpoint was rejected: #{error.context[:reason]}"

      _ ->
        "An unexpected error occurred. Please contact support."
    end
  end

  @doc "Format error for developer/logs (full details)"
  def developer_message(%FlowStone.Error{} = error) do
    """
    FlowStone Error [#{error.type}]
    Message: #{error.message}
    Retryable: #{error.retryable}
    Context: #{inspect(error.context, pretty: true)}
    #{if error.original, do: "Original: #{Exception.format(:error, error.original)}", else: ""}
    """
  end
end
```

### 7. Validation Errors at Definition Time

```elixir
defmodule FlowStone.Asset.Validator do
  def validate(asset_definition) do
    errors =
      []
      |> validate_name(asset_definition)
      |> validate_dependencies(asset_definition)
      |> validate_io_manager(asset_definition)
      |> validate_execute_fn(asset_definition)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_name(errors, %{name: nil}) do
    [{:name, "Asset name is required"} | errors]
  end
  defp validate_name(errors, %{name: name}) when not is_atom(name) do
    [{:name, "Asset name must be an atom, got: #{inspect(name)}"} | errors]
  end
  defp validate_name(errors, _), do: errors

  defp validate_dependencies(errors, %{depends_on: deps}) when is_list(deps) do
    invalid = Enum.reject(deps, &is_atom/1)
    case invalid do
      [] -> errors
      _ -> [{:depends_on, "Dependencies must be atoms, got: #{inspect(invalid)}"} | errors]
    end
  end
  defp validate_dependencies(errors, _), do: errors

  defp validate_io_manager(errors, %{io_manager: nil}) do
    errors  # nil means use default
  end
  defp validate_io_manager(errors, %{io_manager: manager}) do
    if FlowStone.IO.manager_registered?(manager) do
      errors
    else
      [{:io_manager, "Unknown I/O manager: #{inspect(manager)}"} | errors]
    end
  end

  defp validate_execute_fn(errors, %{execute_fn: nil}) do
    [{:execute, "Asset must have an execute function"} | errors]
  end
  defp validate_execute_fn(errors, %{execute_fn: fun}) when is_function(fun, 2) do
    errors
  end
  defp validate_execute_fn(errors, %{execute_fn: fun}) do
    [{:execute, "Execute function must be arity 2, got: #{inspect(fun)}"} | errors]
  end
end
```

## Consequences

### Positive

1. **Actionable Errors**: Users know what went wrong and if they can retry.
2. **Observability**: Structured errors integrate with logging and metrics.
3. **Retry Intelligence**: System knows which errors are transient.
4. **Debug Support**: Full context available for developers.
5. **Compile-Time Validation**: Catch config errors before runtime.

### Negative

1. **Boilerplate**: Custom error types require more code than generic rescue.
2. **Wrapping Overhead**: External exceptions need to be wrapped.
3. **Learning Curve**: Developers must use error factory functions.

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| 72 generic rescues | Single boundary with structured errors |
| Inconsistent messages | Error factory functions |
| No retry intelligence | `retryable` field on errors |
| Silent failures | Mandatory error recording |

## References

- Elixir Error Handling: https://elixir-lang.org/getting-started/try-catch-and-rescue.html
- Joe Armstrong on "Let it Crash": https://erlang.org/download/armstrong_thesis_2003.pdf

defmodule FlowStone.Error do
  @moduledoc """
  Structured error type used across FlowStone.

  This is a proper exception (defexception) so it can be raised directly.
  Each error includes:
  - `type` - categorizes the error for routing/retry decisions
  - `message` - human-readable description
  - `context` - structured data for debugging
  - `retryable` - whether the error is transient and worth retrying
  - `original` - the underlying exception if wrapping another error
  """

  @type error_type ::
          :asset_not_found
          | :dependency_failed
          | :dependency_not_ready
          | :io_error
          | :execution_error
          | :timeout
          | :validation_error
          | :resource_unavailable
          | :checkpoint_rejected
          | :waiting_approval

  @type t :: %__MODULE__{
          type: error_type() | atom(),
          message: String.t(),
          context: map(),
          retryable: boolean(),
          original: Exception.t() | nil
        }

  defexception [:type, :message, :context, :retryable, :original]

  @impl Exception
  def message(%__MODULE__{type: type, message: msg}) do
    "[FlowStone.#{type}] #{msg}"
  end

  @doc """
  Create an error for when an asset execution fails.
  """
  def execution_error(asset, partition, exception, stacktrace) do
    %__MODULE__{
      type: :execution_error,
      message: "Asset execution failed: #{Exception.message(exception)}",
      context: %{
        asset: asset,
        partition: partition,
        stacktrace: format_stacktrace(stacktrace)
      },
      retryable: false,
      original: exception
    }
  end

  @doc """
  Create an error for when dependencies are not ready.
  """
  def dependency_not_ready(asset, missing) do
    %__MODULE__{
      type: :dependency_not_ready,
      message: "Dependencies not ready: #{inspect(missing)}",
      context: %{asset: asset, missing: missing},
      retryable: true,
      original: nil
    }
  end

  @doc """
  Create an error for when a dependency has failed.
  """
  def dependency_failed(asset, dep, reason) do
    %__MODULE__{
      type: :dependency_failed,
      message: "Dependency #{inspect(dep)} failed for asset #{inspect(asset)}",
      context: %{asset: asset, dependency: dep, reason: reason},
      retryable: false,
      original: nil
    }
  end

  @doc """
  Create an error for unexpected return values from execute functions.
  """
  def unexpected_return(asset, partition, value) do
    %__MODULE__{
      type: :execution_error,
      message: "Unexpected return: #{inspect(value)}",
      context: %{asset: asset, partition: partition},
      retryable: false,
      original: nil
    }
  end

  @doc """
  Create an error for when an asset is not found.
  """
  def asset_not_found(asset_name) do
    %__MODULE__{
      type: :asset_not_found,
      message: "Asset #{inspect(asset_name)} is not registered",
      context: %{asset: asset_name},
      retryable: false,
      original: nil
    }
  end

  @doc """
  Create an error for when an asset is not found, with suggestions.
  """
  def asset_not_found_with_suggestion(pipeline, asset_name, available) do
    suggestion = suggest_similar(asset_name, available)

    message =
      if suggestion do
        "Asset #{inspect(asset_name)} not found in #{inspect(pipeline)}. Available: #{inspect(available)}. Did you mean: #{inspect(suggestion)}?"
      else
        "Asset #{inspect(asset_name)} not found in #{inspect(pipeline)}. Available: #{inspect(available)}"
      end

    %__MODULE__{
      type: :asset_not_found,
      message: message,
      context: %{
        asset: asset_name,
        pipeline: pipeline,
        available: available,
        suggestion: suggestion
      },
      retryable: false,
      original: nil
    }
  end

  defp suggest_similar(target, candidates) do
    target_str = to_string(target)

    candidates
    |> Enum.map(fn candidate ->
      candidate_str = to_string(candidate)
      {candidate, String.jaro_distance(target_str, candidate_str)}
    end)
    |> Enum.filter(fn {_, score} -> score > 0.7 end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> List.first()
    |> case do
      {candidate, _score} -> candidate
      nil -> nil
    end
  end

  @doc """
  Create an error for I/O operations.
  """
  def io_error(operation, asset, partition, reason) do
    %__MODULE__{
      type: :io_error,
      message: "I/O #{operation} failed for #{inspect(asset)}/#{inspect(partition)}",
      context: %{operation: operation, asset: asset, partition: partition},
      retryable: transient_io_error?(reason),
      original: if(is_exception(reason), do: reason, else: nil)
    }
  end

  @doc """
  Create an error for timeout situations.
  """
  def timeout(asset, partition, duration_ms) do
    %__MODULE__{
      type: :timeout,
      message: "Asset execution timed out after #{duration_ms}ms",
      context: %{asset: asset, partition: partition, duration_ms: duration_ms},
      retryable: true,
      original: nil
    }
  end

  @doc """
  Create an error for validation failures.
  """
  def validation_error(asset, reason) do
    %__MODULE__{
      type: :validation_error,
      message: "Validation failed: #{reason}",
      context: %{asset: asset, reason: reason},
      retryable: false,
      original: nil
    }
  end

  @doc """
  Create an error for when a checkpoint is rejected.
  """
  def checkpoint_rejected(checkpoint, reason) do
    %__MODULE__{
      type: :checkpoint_rejected,
      message: "Checkpoint #{inspect(checkpoint)} was rejected: #{reason}",
      context: %{checkpoint: checkpoint, reason: reason},
      retryable: false,
      original: nil
    }
  end

  # Determine if an IO error is transient (worth retrying)
  defp transient_io_error?(%DBConnection.ConnectionError{}), do: true
  defp transient_io_error?({:timeout, _}), do: true
  defp transient_io_error?(:timeout), do: true
  defp transient_io_error?(_), do: false

  # Safely format stacktrace
  defp format_stacktrace([]), do: ""

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    Exception.format_stacktrace(stacktrace)
  end

  defp format_stacktrace(_), do: ""
end

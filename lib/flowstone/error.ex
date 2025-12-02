defmodule FlowStone.Error do
  @moduledoc """
  Structured error type used across FlowStone.
  """

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          context: map(),
          retryable: boolean(),
          original: Exception.t() | nil
        }

  defstruct type: nil, message: nil, context: %{}, retryable: false, original: nil

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

  def dependency_not_ready(asset, missing) do
    %__MODULE__{
      type: :dependency_not_ready,
      message: "Dependencies not ready: #{inspect(missing)}",
      context: %{asset: asset, missing: missing},
      retryable: true,
      original: nil
    }
  end

  def unexpected_return(asset, partition, value) do
    %__MODULE__{
      type: :execution_error,
      message: "Unexpected return: #{inspect(value)}",
      context: %{asset: asset, partition: partition},
      retryable: false,
      original: nil
    }
  end
end

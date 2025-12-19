defmodule FlowStone.Scatter.Options do
  @moduledoc """
  Configuration options for scatter execution.

  Controls concurrency, rate limiting, failure handling, and other
  scatter-specific behaviors.
  """

  @type t :: %__MODULE__{
          max_concurrent: pos_integer() | :unlimited,
          rate_limit: {pos_integer(), :second | :minute} | nil,
          failure_threshold: float(),
          failure_mode: :partial | :all_or_nothing,
          retry_strategy: :individual | :batch,
          max_attempts: pos_integer(),
          queue: atom(),
          priority: 0..3,
          timeout: pos_integer() | :infinity
        }

  defstruct max_concurrent: :unlimited,
            rate_limit: nil,
            failure_threshold: 0.0,
            failure_mode: :all_or_nothing,
            retry_strategy: :individual,
            max_attempts: 3,
            queue: :flowstone_scatter,
            priority: 1,
            timeout: :timer.minutes(30)

  @doc """
  Build options from a keyword list.

  ## Examples

      iex> FlowStone.Scatter.Options.new(max_concurrent: 50, failure_threshold: 0.05)
      %FlowStone.Scatter.Options{max_concurrent: 50, failure_threshold: 0.05, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Convert options to a JSON-safe map for database storage.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = opts) do
    %{
      "max_concurrent" => serialize_concurrent(opts.max_concurrent),
      "rate_limit" => serialize_rate_limit(opts.rate_limit),
      "failure_threshold" => opts.failure_threshold,
      "failure_mode" => to_string(opts.failure_mode),
      "retry_strategy" => to_string(opts.retry_strategy),
      "max_attempts" => opts.max_attempts,
      "queue" => to_string(opts.queue),
      "priority" => opts.priority,
      "timeout" => serialize_timeout(opts.timeout)
    }
  end

  @doc """
  Restore options from a stored map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      max_concurrent: deserialize_concurrent(map["max_concurrent"]),
      rate_limit: deserialize_rate_limit(map["rate_limit"]),
      failure_threshold: map["failure_threshold"] || 0.0,
      failure_mode: safe_to_atom(map["failure_mode"], :all_or_nothing),
      retry_strategy: safe_to_atom(map["retry_strategy"], :individual),
      max_attempts: map["max_attempts"] || 3,
      queue: safe_to_atom(map["queue"], :flowstone_scatter),
      priority: map["priority"] || 1,
      timeout: deserialize_timeout(map["timeout"])
    }
  end

  defp serialize_concurrent(:unlimited), do: "unlimited"
  defp serialize_concurrent(n) when is_integer(n), do: n

  defp deserialize_concurrent("unlimited"), do: :unlimited
  defp deserialize_concurrent(n) when is_integer(n), do: n
  defp deserialize_concurrent(_), do: :unlimited

  defp serialize_rate_limit(nil), do: nil
  defp serialize_rate_limit({limit, period}), do: [limit, to_string(period)]

  defp deserialize_rate_limit(nil), do: nil
  defp deserialize_rate_limit([limit, period]), do: {limit, safe_to_atom(period, :second)}
  defp deserialize_rate_limit(_), do: nil

  defp serialize_timeout(:infinity), do: "infinity"
  defp serialize_timeout(ms) when is_integer(ms), do: ms

  defp deserialize_timeout("infinity"), do: :infinity
  defp deserialize_timeout(ms) when is_integer(ms), do: ms
  defp deserialize_timeout(_), do: :timer.minutes(30)

  defp safe_to_atom(nil, default), do: default

  defp safe_to_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end

  defp safe_to_atom(atom, _default) when is_atom(atom), do: atom
end

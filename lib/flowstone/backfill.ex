defmodule FlowStone.Backfill do
  @moduledoc """
  Helpers to generate and plan backfill partitions.
  """

  @doc """
  Build a list of partitions from options.

  Supports:
  - partitions: explicit list
  - partition_fn: function returning an enumerable of partitions
  - start_partition + end_partition for Date ranges
  """
  def generate(opts) do
    partition_fn = Keyword.get(opts, :partition_fn)

    cond do
      is_function(partition_fn, 1) ->
        apply_partition_fn(partition_fn, opts)

      Keyword.has_key?(opts, :partitions) ->
        Keyword.fetch!(opts, :partitions)

      opts[:start_partition] && opts[:end_partition] ->
        build_range(opts[:start_partition], opts[:end_partition])

      true ->
        raise ArgumentError, "backfill requires :partitions or start/end partitions"
    end
  end

  defp build_range(%Date{} = start_date, %Date{} = end_date) do
    Date.range(start_date, end_date) |> Enum.to_list()
  end

  defp build_range(start_val, end_val) do
    raise ArgumentError, "unsupported partition range #{inspect(start_val)}..#{inspect(end_val)}"
  end

  defp apply_partition_fn(fun, opts) when is_function(fun, 1) do
    fun.(opts) |> Enum.to_list()
  end
end

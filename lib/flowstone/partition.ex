defmodule FlowStone.Partition do
  @moduledoc """
  Helpers for working with partition keys.
  """

  @doc """
  Serialize a partition to a string key suitable for storage.
  """
  def serialize(%Date{} = date), do: Date.to_iso8601(date)
  def serialize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def serialize(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  def serialize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&serialize/1) |> Enum.join("|")

  def serialize(other), do: to_string(other)
end

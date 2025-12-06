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

  @doc """
  Best-effort deserialization of a partition string back to a structured type.
  """
  def deserialize(nil), do: nil

  def deserialize(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&deserialize/1) |> List.to_tuple()

  def deserialize(%Date{} = date), do: date
  def deserialize(%DateTime{} = dt), do: dt
  def deserialize(%NaiveDateTime{} = ndt), do: ndt

  def deserialize(value) when is_binary(value) do
    cond do
      String.contains?(value, "|") ->
        value
        |> String.split("|")
        |> Enum.map(&deserialize/1)
        |> List.to_tuple()

      match_datetime?(value) ->
        {:ok, dt, _} = DateTime.from_iso8601(value)
        dt

      match_naive?(value) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(value)
        ndt

      match_date?(value) ->
        {:ok, date} = Date.from_iso8601(value)
        date

      true ->
        value
    end
  end

  def deserialize(other), do: other

  defp match_datetime?(value), do: match?({:ok, _dt, _offset}, DateTime.from_iso8601(value))
  defp match_naive?(value), do: match?({:ok, _}, NaiveDateTime.from_iso8601(value))
  defp match_date?(value), do: match?({:ok, _}, Date.from_iso8601(value))
end

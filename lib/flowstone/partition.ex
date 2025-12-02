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
  def deserialize(%Date{} = date), do: date
  def deserialize(%DateTime{} = dt), do: dt
  def deserialize(%NaiveDateTime{} = ndt), do: ndt

  def deserialize(value) when is_binary(value) do
    with {:ok, dt, _} <- DateTime.from_iso8601(value) do
      dt
    else
      _ ->
        with {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
          ndt
        else
          _ ->
            with {:ok, date} <- Date.from_iso8601(value) do
              date
            else
              _ -> value
            end
        end
    end
  end

  def deserialize(other), do: other
end

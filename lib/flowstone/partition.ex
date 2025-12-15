defmodule FlowStone.Partition do
  @moduledoc """
  Helpers for working with partition keys.

  ## Serialization Format

  Partitions are serialized to strings for storage. The format uses a tagged
  encoding to distinguish between types and avoid collisions:

  - Dates: `d:2024-01-01`
  - DateTimes: `dt:2024-01-01T00:00:00Z`
  - NaiveDateTimes: `ndt:2024-01-01T00:00:00`
  - Tuples: `t:base64_encoded_json_array`
  - Strings/other: `s:value` (value is base64 encoded if it contains reserved chars)

  This ensures that a string containing special characters (like `|` or `:`)
  will correctly round-trip through serialize/deserialize.
  """

  @type partition :: term()
  @type serialized :: String.t()

  # Reserved prefix characters that indicate special handling
  @prefixes ["d:", "dt:", "ndt:", "t:", "s:"]

  @doc """
  Serialize a partition to a string key suitable for storage.
  """
  @spec serialize(partition()) :: serialized()
  def serialize(%Date{} = date), do: "d:#{Date.to_iso8601(date)}"
  def serialize(%DateTime{} = dt), do: "dt:#{DateTime.to_iso8601(dt)}"
  def serialize(%NaiveDateTime{} = ndt), do: "ndt:#{NaiveDateTime.to_iso8601(ndt)}"

  def serialize(tuple) when is_tuple(tuple) do
    elements = tuple |> Tuple.to_list() |> Enum.map(&serialize_element/1)
    encoded = elements |> Jason.encode!() |> Base.url_encode64(padding: false)
    "t:#{encoded}"
  end

  def serialize(nil), do: ""

  def serialize(value) when is_binary(value) do
    if needs_encoding?(value) do
      "s:#{Base.url_encode64(value, padding: false)}"
    else
      value
    end
  end

  def serialize(value) when is_integer(value), do: Integer.to_string(value)
  def serialize(value) when is_atom(value), do: Atom.to_string(value)
  def serialize(value), do: to_string(value)

  @doc """
  Deserialize a partition string back to a structured type.
  """
  @spec deserialize(serialized() | partition()) :: partition()
  def deserialize(nil), do: nil
  def deserialize(""), do: nil

  # Already structured types pass through
  def deserialize(%Date{} = date), do: date
  def deserialize(%DateTime{} = dt), do: dt
  def deserialize(%NaiveDateTime{} = ndt), do: ndt
  def deserialize(tuple) when is_tuple(tuple), do: tuple

  def deserialize(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "d:") ->
        {:ok, date} = value |> String.slice(2..-1//1) |> Date.from_iso8601()
        date

      String.starts_with?(value, "dt:") ->
        {:ok, dt, _} = value |> String.slice(3..-1//1) |> DateTime.from_iso8601()
        dt

      String.starts_with?(value, "ndt:") ->
        {:ok, ndt} = value |> String.slice(4..-1//1) |> NaiveDateTime.from_iso8601()
        ndt

      String.starts_with?(value, "t:") ->
        value
        |> String.slice(2..-1//1)
        |> Base.url_decode64!(padding: false)
        |> Jason.decode!()
        |> Enum.map(&deserialize_element/1)
        |> List.to_tuple()

      String.starts_with?(value, "s:") ->
        value
        |> String.slice(2..-1//1)
        |> Base.url_decode64!(padding: false)

      true ->
        # Legacy/simple values - try to parse as date/datetime for backward compatibility
        parse_legacy(value)
    end
  end

  def deserialize(other), do: other

  # Serialize individual tuple elements (preserving type info)
  defp serialize_element(%Date{} = date), do: %{"_type" => "date", "v" => Date.to_iso8601(date)}

  defp serialize_element(%DateTime{} = dt),
    do: %{"_type" => "datetime", "v" => DateTime.to_iso8601(dt)}

  defp serialize_element(%NaiveDateTime{} = ndt),
    do: %{"_type" => "naive_datetime", "v" => NaiveDateTime.to_iso8601(ndt)}

  defp serialize_element(tuple) when is_tuple(tuple) do
    %{"_type" => "tuple", "v" => tuple |> Tuple.to_list() |> Enum.map(&serialize_element/1)}
  end

  defp serialize_element(value), do: value

  # Deserialize individual tuple elements
  defp deserialize_element(%{"_type" => "date", "v" => v}) do
    {:ok, date} = Date.from_iso8601(v)
    date
  end

  defp deserialize_element(%{"_type" => "datetime", "v" => v}) do
    {:ok, dt, _} = DateTime.from_iso8601(v)
    dt
  end

  defp deserialize_element(%{"_type" => "naive_datetime", "v" => v}) do
    {:ok, ndt} = NaiveDateTime.from_iso8601(v)
    ndt
  end

  defp deserialize_element(%{"_type" => "tuple", "v" => elements}) do
    elements |> Enum.map(&deserialize_element/1) |> List.to_tuple()
  end

  defp deserialize_element(value), do: value

  # Check if a string value needs base64 encoding
  # Encode if it contains reserved characters that would cause ambiguity
  defp needs_encoding?(value) do
    String.contains?(value, ":") or
      String.contains?(value, "|") or
      Enum.any?(@prefixes, &String.starts_with?(value, &1))
  end

  # Parse legacy format values for backward compatibility
  defp parse_legacy(value) do
    cond do
      # Try DateTime first (most specific)
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, dt, _} = DateTime.from_iso8601(value)
        dt

      # Try NaiveDateTime
      match?({:ok, _}, NaiveDateTime.from_iso8601(value)) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(value)
        ndt

      # Try Date
      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        date

      # Legacy tuple format with | separator (deprecated, for backward compat only)
      String.contains?(value, "|") ->
        value
        |> String.split("|")
        |> Enum.map(&parse_legacy/1)
        |> List.to_tuple()

      true ->
        value
    end
  end
end

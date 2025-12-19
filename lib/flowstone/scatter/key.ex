defmodule FlowStone.Scatter.Key do
  @moduledoc """
  Scatter key utilities for serialization and comparison.

  Scatter keys are maps that uniquely identify each scattered instance.
  This module provides consistent serialization and hashing for storage.
  """

  @type t :: map()

  @doc """
  Serialize a scatter key for database storage.
  Keys are sorted for consistent hashing.

  ## Examples

      iex> FlowStone.Scatter.Key.serialize(%{url: "https://example.com"})
      ~s({"url":"https://example.com"})

      iex> FlowStone.Scatter.Key.serialize(%{b: 2, a: 1})
      ~s({"a":1,"b":2})
  """
  @spec serialize(t()) :: String.t()
  def serialize(key) when is_map(key) do
    key
    |> sort_keys()
    |> Jason.encode!()
  end

  @doc """
  Generate a deterministic hash for deduplication.
  Uses SHA-256 truncated to 16 characters.

  ## Examples

      iex> FlowStone.Scatter.Key.hash(%{url: "https://example.com"})
      "e3b0c44298fc1c14"
  """
  @spec hash(t()) :: String.t()
  def hash(key) do
    :crypto.hash(:sha256, serialize(key))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Deserialize a scatter key from database storage.

  ## Examples

      iex> FlowStone.Scatter.Key.deserialize(~s({"url":"https://example.com"}))
      %{"url" => "https://example.com"}
  """
  @spec deserialize(String.t()) :: t()
  def deserialize(json) when is_binary(json) do
    Jason.decode!(json)
  end

  def deserialize(map) when is_map(map), do: map

  @doc """
  Compare two scatter keys for equality.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(key1, key2) do
    serialize(key1) == serialize(key2)
  end

  @doc """
  Normalize a scatter key by converting atom keys to strings.
  """
  @spec normalize(t()) :: t()
  def normalize(key) when is_map(key) do
    key
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_value(v)}
      {k, v} -> {k, normalize_value(v)}
    end)
    |> Map.new()
  end

  defp normalize_value(v) when is_map(v), do: normalize(v)
  defp normalize_value(v) when is_list(v), do: Enum.map(v, &normalize_value/1)
  defp normalize_value(v), do: v

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {k, sort_keys(v)} end)
    |> Map.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other
end

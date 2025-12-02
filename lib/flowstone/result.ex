defmodule FlowStone.Result do
  @moduledoc """
  Convenience helpers for working with FlowStone results.
  """

  alias FlowStone.Error

  @type t(value) :: {:ok, value} | {:error, Error.t()}

  def ok(value), do: {:ok, value}
  def error(%Error{} = err), do: {:error, err}

  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _} = err, _fun), do: err

  def flat_map({:ok, value}, fun), do: fun.(value)
  def flat_map({:error, _} = err, _fun), do: err

  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Error{} = err}), do: raise(err)
end

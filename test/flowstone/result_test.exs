defmodule FlowStone.ResultTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.{Error, Result}

  test "maps and flat maps ok tuples" do
    assert {:ok, 2} = Result.map({:ok, 1}, &(&1 + 1))
    assert {:ok, 4} = Result.flat_map({:ok, 2}, fn v -> {:ok, v * 2} end)
  end

  test "propagates errors" do
    error = %Error{type: :test, message: "boom", retryable: false, context: %{}, original: nil}
    assert {:error, ^error} = Result.map({:error, error}, &(&1 + 1))
    assert {:error, ^error} = Result.flat_map({:error, error}, fn _ -> {:ok, :ok} end)
  end
end

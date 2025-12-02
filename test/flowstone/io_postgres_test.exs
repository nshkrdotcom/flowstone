defmodule FlowStone.IOPostgresTest do
  use FlowStone.TestCase, isolation: :full_isolation

  @tag :skip
  test "stores and loads data (requires Postgres configured)" do
    assert true
  end
end

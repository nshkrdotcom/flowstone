defmodule FlowStone.IOManagersTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.IO.{Parquet, Postgres, S3}

  test "postgres manager uses injected functions" do
    config = %{
      load_fun: fn partition, _config -> {:ok, {:loaded, partition}} end,
      store_fun: fn partition, data, _config ->
        send(self(), {:stored, partition, data})
        :ok
      end
    }

    assert {:ok, {:loaded, :p1}} = Postgres.load(:asset, :p1, config)
    assert :ok = Postgres.store(:asset, :data, :p1, config)
    assert_received {:stored, :p1, :data}
  end

  test "s3 manager resolves bucket and key" do
    config = %{
      bucket: fn _ -> "b" end,
      path: fn p -> "k-#{p}" end,
      get_fun: fn b, k -> {:ok, {b, k}} end,
      put_fun: fn b, k, d -> {:ok, {b, k, d}} end
    }

    assert {:ok, {"b", "k-p1"}} = S3.load(:asset, :p1, config)
    assert {:ok, {"b", "k-p1", :data}} = S3.store(:asset, :data, :p1, config)
  end

  test "parquet manager delegates to funs" do
    config = %{load_fun: fn -> {:ok, :df} end, store_fun: fn _ -> :ok end}
    assert {:ok, :df} = Parquet.load(:a, :p, config)
    assert :ok = Parquet.store(:a, :df, :p, config)
  end
end

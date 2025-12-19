defmodule FlowStone.TestHelpersTest do
  @moduledoc """
  Tests for FlowStone.Test module.
  """
  use FlowStone.Test

  defmodule TestPipeline do
    use FlowStone.Pipeline

    asset :upstream do
      execute fn _, _ -> {:ok, "real upstream data"} end
    end

    asset :downstream do
      depends_on([:upstream])
      execute fn _, %{upstream: data} -> {:ok, String.upcase(data)} end
    end

    asset :with_partition do
      execute fn ctx, _ -> {:ok, "data_for_#{ctx.partition}"} end
    end
  end

  describe "run_asset/3" do
    test "runs asset with real dependencies" do
      {:ok, result} = run_asset(TestPipeline, :upstream)
      assert result == "real upstream data"
    end

    test "runs asset with mocked dependencies" do
      {:ok, result} = run_asset(TestPipeline, :downstream, with_deps: %{upstream: "mocked"})

      assert result == "MOCKED"
    end

    test "supports partitions" do
      {:ok, result} = run_asset(TestPipeline, :with_partition, partition: :my_partition)

      assert result == "data_for_my_partition"
    end
  end

  describe "assert_asset_exists/3" do
    test "passes when asset exists" do
      {:ok, _} = run_asset(TestPipeline, :upstream)
      assert_asset_exists(TestPipeline, :upstream)
    end

    test "raises when asset does not exist" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_asset_exists(TestPipeline, :nonexistent_asset)
      end
    end
  end

  describe "refute_asset_exists/3" do
    test "passes when asset does not exist" do
      refute_asset_exists(TestPipeline, :never_run_asset)
    end

    test "raises when asset exists" do
      {:ok, _} = run_asset(TestPipeline, :upstream, partition: :refute_test)

      assert_raise ExUnit.AssertionError, fn ->
        refute_asset_exists(TestPipeline, :upstream, partition: :refute_test)
      end
    end
  end
end

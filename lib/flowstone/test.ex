defmodule FlowStone.Test do
  @moduledoc """
  Test helpers for FlowStone pipelines.

  ## Usage

      defmodule MyPipelineTest do
        use FlowStone.Test

        test "my asset works" do
          {:ok, result} = run_asset(MyPipeline, :asset)
          assert result == expected
        end

        test "with mocked dependencies" do
          {:ok, result} = run_asset(MyPipeline, :downstream,
            with_deps: %{upstream: "mocked data"}
          )
          assert result == expected
        end
      end

  ## Features

  - `run_asset/3` - Run an asset with optional mocked dependencies
  - Automatic isolated storage per test
  - Easy dependency mocking
  - Partition support for testing partitioned assets
  """

  @doc """
  Use this module in your test files for FlowStone pipeline testing.

  ## Options

  - `:async` - Run tests asynchronously (default: `false`)

  ## Example

      defmodule MyPipelineTest do
        use FlowStone.Test, async: true

        test "asset returns expected value" do
          {:ok, result} = run_asset(MyPipeline, :my_asset)
          assert result == "expected"
        end
      end
  """
  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false)

    quote do
      use ExUnit.Case, async: unquote(async)
      import FlowStone.Test

      setup do
        # Create a unique test ID for isolation
        test_id = :erlang.unique_integer([:positive])
        {:ok, test_id: test_id}
      end
    end
  end

  @doc """
  Run an asset with optional mocked dependencies.

  This function allows you to execute a specific asset while providing
  mocked values for its dependencies, enabling isolated unit testing.

  ## Options

  - `with_deps` - Map of dependency name to mocked value
  - `partition` - Partition key (default: `:default`)
  - `force` - Re-run even if cached (default: `true` for tests)

  ## Examples

      # Run with real dependencies
      {:ok, result} = run_asset(MyPipeline, :asset)

      # Run with mocked dependencies
      {:ok, result} = run_asset(MyPipeline, :downstream,
        with_deps: %{upstream: "mocked value"}
      )

      # Run for specific partition
      {:ok, result} = run_asset(MyPipeline, :daily,
        partition: ~D[2025-01-15]
      )

  ## Returns

  - `{:ok, result}` - On success
  - `{:error, reason}` - On failure
  """
  @spec run_asset(module(), atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_asset(pipeline, asset_name, opts \\ []) do
    with_deps = Keyword.get(opts, :with_deps, %{})
    partition = Keyword.get(opts, :partition, :default)

    # Ensure pipeline is registered
    :ok = FlowStone.API.ensure_pipeline_registered(pipeline)

    if map_size(with_deps) > 0 do
      run_with_mocked_deps(pipeline, asset_name, partition, with_deps, opts)
    else
      FlowStone.API.run(pipeline, asset_name, Keyword.put(opts, :partition, partition))
    end
  end

  @doc """
  Assert that an asset exists (has been run).

  ## Example

      assert_asset_exists(MyPipeline, :asset)
      assert_asset_exists(MyPipeline, :daily, partition: ~D[2025-01-15])
  """
  @spec assert_asset_exists(module(), atom(), keyword()) :: true
  def assert_asset_exists(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, :default)

    unless FlowStone.API.exists?(pipeline, asset_name, partition: partition) do
      raise ExUnit.AssertionError,
        message:
          "Expected asset #{inspect(asset_name)} to exist for partition #{inspect(partition)}"
    end

    true
  end

  @doc """
  Assert that an asset does not exist.

  ## Example

      refute_asset_exists(MyPipeline, :asset)
  """
  @spec refute_asset_exists(module(), atom(), keyword()) :: true
  def refute_asset_exists(pipeline, asset_name, opts \\ []) do
    partition = Keyword.get(opts, :partition, :default)

    if FlowStone.API.exists?(pipeline, asset_name, partition: partition) do
      raise ExUnit.AssertionError,
        message:
          "Expected asset #{inspect(asset_name)} NOT to exist for partition #{inspect(partition)}"
    end

    true
  end

  @doc """
  Clear all cached assets for a pipeline.

  Useful for resetting state between tests.
  """
  @spec clear_pipeline(module()) :: :ok
  def clear_pipeline(pipeline) do
    for asset_name <- FlowStone.API.assets(pipeline) do
      FlowStone.API.invalidate(pipeline, asset_name)
    end

    :ok
  end

  # Private functions

  defp run_with_mocked_deps(pipeline, asset_name, partition, mocked_deps, opts) do
    # Store mocked dependencies first
    io_opts = FlowStone.API.io_opts_for_pipeline(pipeline)

    for {dep_name, dep_value} <- mocked_deps do
      :ok = FlowStone.IO.store(dep_name, dep_value, partition, io_opts)
    end

    # Run the asset without running its dependencies
    FlowStone.API.run(
      pipeline,
      asset_name,
      Keyword.merge(opts, partition: partition, with_deps: false)
    )
  end
end

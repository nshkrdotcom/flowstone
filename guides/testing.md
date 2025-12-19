# FlowStone Testing Guide

This guide covers testing patterns for FlowStone pipelines.

## Test Setup

FlowStone provides a `TestCase` module for isolated testing:

```elixir
# test/my_app/pipeline_test.exs
defmodule MyApp.PipelineTest do
  use FlowStone.TestCase, isolation: :full_isolation

  # Tests run in isolation - each test gets fresh storage
end
```

### Isolation Modes

- `:full_isolation` - Each test gets a completely isolated environment
- `:shared` - Tests share state (faster but may have side effects)

## Basic Testing

### Testing Asset Execution

```elixir
defmodule MyApp.NumberPipelineTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule TestPipeline do
    use FlowStone.Pipeline

    asset :numbers do
      execute fn _, _ -> {:ok, [1, 2, 3]} end
    end

    asset :doubled do
      depends_on [:numbers]
      execute fn _, %{numbers: nums} -> {:ok, Enum.map(nums, &(&1 * 2))} end
    end
  end

  test "runs asset and returns result" do
    {:ok, result} = FlowStone.run(TestPipeline, :numbers)
    assert result == [1, 2, 3]
  end

  test "runs asset with dependencies" do
    {:ok, result} = FlowStone.run(TestPipeline, :doubled)
    assert result == [2, 4, 6]
  end
end
```

### Testing with Partitions

```elixir
test "handles partitions correctly" do
  {:ok, _} = FlowStone.run(TestPipeline, :daily, partition: ~D[2025-01-15])
  {:ok, _} = FlowStone.run(TestPipeline, :daily, partition: ~D[2025-01-16])

  assert FlowStone.exists?(TestPipeline, :daily, partition: ~D[2025-01-15])
  assert FlowStone.exists?(TestPipeline, :daily, partition: ~D[2025-01-16])
end
```

## Test Helpers

### run_asset/3 with Mocked Dependencies

Test assets in isolation by mocking their dependencies:

```elixir
test "runs asset with mocked dependencies" do
  # Mock the :numbers dependency
  {:ok, result} = run_asset(TestPipeline, :doubled, with_deps: %{numbers: [10, 20, 30]})
  assert result == [20, 40, 60]
end

test "mocks multiple dependencies" do
  {:ok, result} = run_asset(TestPipeline, :combined,
    with_deps: %{
      numbers: [1, 2, 3],
      multiplier: 10
    }
  )
  assert result == [10, 20, 30]
end
```

### Existence Assertions

```elixir
test "asset exists after running" do
  {:ok, _} = FlowStone.run(TestPipeline, :numbers)
  assert_asset_exists(TestPipeline, :numbers)
end

test "asset does not exist before running" do
  refute_asset_exists(TestPipeline, :numbers)
end

test "checks specific partition" do
  {:ok, _} = FlowStone.run(TestPipeline, :daily, partition: ~D[2025-01-15])

  assert_asset_exists(TestPipeline, :daily, partition: ~D[2025-01-15])
  refute_asset_exists(TestPipeline, :daily, partition: ~D[2025-01-16])
end
```

## Testing Error Conditions

### Testing Execute Errors

```elixir
defmodule FailingPipeline do
  use FlowStone.Pipeline

  asset :will_fail do
    execute fn _, _ -> {:error, :something_went_wrong} end
  end

  asset :will_raise do
    execute fn _, _ -> raise "Boom!" end
  end
end

test "handles error return" do
  assert {:error, _reason} = FlowStone.run(FailingPipeline, :will_fail)
end

test "handles exceptions" do
  assert {:error, %FlowStone.Error{type: :execution_error}} =
    FlowStone.run(FailingPipeline, :will_raise)
end
```

### Testing Unknown Assets

```elixir
test "returns error for unknown asset" do
  assert {:error, %FlowStone.Error{type: :asset_not_found}} =
    FlowStone.run(TestPipeline, :nonexistent)
end
```

### Testing Dependency Failures

```elixir
test "fails when dependencies not ready" do
  # Skip automatic dependency resolution
  assert {:error, %FlowStone.Error{type: :dependency_not_ready}} =
    FlowStone.run(TestPipeline, :doubled, with_deps: false)
end
```

## Testing Caching Behavior

```elixir
defmodule CounterPipeline do
  use FlowStone.Pipeline

  asset :counter do
    execute fn _, _ ->
      {:ok, System.unique_integer([:positive])}
    end
  end
end

test "caches results between runs" do
  {:ok, first} = FlowStone.run(CounterPipeline, :counter)
  {:ok, second} = FlowStone.run(CounterPipeline, :counter)
  assert first == second
end

test "force: true bypasses cache" do
  {:ok, first} = FlowStone.run(CounterPipeline, :counter)
  {:ok, forced} = FlowStone.run(CounterPipeline, :counter, force: true)
  assert forced != first
end

test "invalidate clears cache" do
  {:ok, first} = FlowStone.run(CounterPipeline, :counter)
  {:ok, 1} = FlowStone.invalidate(CounterPipeline, :counter)
  {:ok, after_invalidate} = FlowStone.run(CounterPipeline, :counter)
  assert after_invalidate != first
end
```

## Testing Backfill

```elixir
test "backfills multiple partitions" do
  {:ok, stats} = FlowStone.backfill(TestPipeline, :daily,
    partitions: [:a, :b, :c]
  )

  assert stats.succeeded == 3
  assert stats.failed == 0

  assert_asset_exists(TestPipeline, :daily, partition: :a)
  assert_asset_exists(TestPipeline, :daily, partition: :b)
  assert_asset_exists(TestPipeline, :daily, partition: :c)
end

test "skips already completed partitions" do
  {:ok, _} = FlowStone.run(TestPipeline, :daily, partition: :already_done)

  {:ok, stats} = FlowStone.backfill(TestPipeline, :daily,
    partitions: [:already_done, :new_one]
  )

  assert stats.succeeded == 1
  assert stats.skipped == 1
end
```

## Testing DAG Structure

```elixir
test "lists all assets" do
  assets = FlowStone.assets(TestPipeline)
  assert :numbers in assets
  assert :doubled in assets
end

test "returns asset info" do
  info = FlowStone.asset_info(TestPipeline, :doubled)
  assert info.name == :doubled
  assert info.depends_on == [:numbers]
end

test "generates graph" do
  graph = FlowStone.graph(TestPipeline)
  assert is_binary(graph)
  assert graph =~ "numbers"
  assert graph =~ "doubled"
end
```

## Testing with Captures

Use ExUnit's capture utilities for testing logs:

```elixir
import ExUnit.CaptureLog

test "logs errors on failure" do
  log = capture_log(fn ->
    FlowStone.run(FailingPipeline, :will_fail)
  end)

  assert log =~ "FlowStone error"
  assert log =~ "will_fail"
end
```

## Testing wrap_results Pipelines

```elixir
defmodule WrappedPipeline do
  use FlowStone.Pipeline, wrap_results: true

  asset :numbers do
    execute fn _, _ -> [1, 2, 3] end
  end
end

test "implicitly wraps results" do
  {:ok, result} = FlowStone.run(WrappedPipeline, :numbers)
  assert result == [1, 2, 3]
end
```

## Integration Testing

For integration tests with a real database:

```elixir
defmodule MyApp.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  setup do
    # Use real repo for integration tests
    Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
    :ok
  end

  test "persists to database" do
    {:ok, _} = FlowStone.run(MyPipeline, :asset, partition: ~D[2025-01-15])

    # Verify in database
    assert FlowStone.exists?(MyPipeline, :asset, partition: ~D[2025-01-15])
  end
end
```

## Best Practices

### 1. Use Full Isolation

```elixir
use FlowStone.TestCase, isolation: :full_isolation
```

This ensures tests don't interfere with each other.

### 2. Test Assets in Isolation

Use `run_asset/3` with `with_deps` to test single assets without running their dependencies:

```elixir
{:ok, result} = run_asset(Pipeline, :my_asset, with_deps: %{dep: mocked_value})
```

### 3. Test Both Success and Failure Paths

```elixir
test "handles success" do
  {:ok, result} = FlowStone.run(Pipeline, :asset)
  assert result == expected
end

test "handles failure" do
  {:error, error} = FlowStone.run(FailingPipeline, :asset)
  assert error.type == :execution_error
end
```

### 4. Test Partition Isolation

```elixir
test "partitions are isolated" do
  {:ok, _} = FlowStone.run(Pipeline, :asset, partition: :a)
  refute_asset_exists(Pipeline, :asset, partition: :b)
end
```

### 5. Use Descriptive Test Names

```elixir
test "doubled asset multiplies each number by 2"
test "sum asset returns total of all doubled values"
test "returns error when source data is invalid"
```

## Next Steps

- [Getting Started Guide](getting-started.md) - Basic usage patterns
- [Configuration Guide](configuration.md) - Configure test environments

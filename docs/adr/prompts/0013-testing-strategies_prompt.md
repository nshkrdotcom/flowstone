# Implementation Prompt: ADR-0013 Testing Strategies

## Objective

Implement comprehensive testing infrastructure using Supertester with dependency injection, Mox for external dependencies, and property-based testing to avoid pipeline_ex anti-patterns.

## Required Reading

1. **ADR-0013**: `docs/adr/0013-testing-strategies.md`
2. **Supertester Manual**: https://hexdocs.pm/supertester
3. **Mox**: https://hexdocs.pm/mox
4. **Oban Testing**: https://hexdocs.pm/oban/testing.html
5. **Ecto Sandbox**: https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html
6. **ExUnitProperties**: https://hexdocs.pm/stream_data

## Context

Orchestration systems are hard to test due to:
- External dependencies (databases, APIs, storage)
- Time-based behavior (schedules, timeouts)
- Distributed execution (job queues, workers)
- Complex state machines (checkpoints, retries)

FlowStone avoids pipeline_ex anti-patterns:
- NO global test mode flags via environment variables
- NO process dictionary for test context
- NO mock/live code path divergence
- Use dependency injection, Mox, and Supertester patterns

## Implementation Tasks

### 1. Test Case Modules

```elixir
# test/support/asset_case.ex
defmodule FlowStone.AssetCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Supertester.ExUnitFoundation, isolation: :full_isolation
      import FlowStone.AssetCase
      import Mox

      alias FlowStone.Test.Fixtures
    end
  end

  setup tags do
    # Setup for each test
  end

  def build_context(asset, opts \\ [])
  def execute_asset(asset, deps, opts \\ [])
end
```

### 2. Mox Definitions

```elixir
# test/support/mocks.ex
Mox.defmock(FlowStone.ResourceMock, for: FlowStone.Resource)
Mox.defmock(FlowStone.IO.Mock, for: FlowStone.IO.Manager)

# test/support/stubs.ex
defmodule FlowStone.Test.ResourceStub do
  @behaviour FlowStone.Resource

  def setup(_config), do: {:ok, :test_resource}
  def teardown(_resource), do: :ok
  def health_check(_resource), do: :healthy
end
```

### 3. Test Fixtures

```elixir
# test/support/fixtures.ex
defmodule FlowStone.Test.Fixtures do
  def build_context(overrides \\ %{})
  def create_materialization(attrs \\ %{})
  def create_pending_approval(attrs \\ %{})
  def create_lineage_entry(attrs \\ %{})
end
```

### 4. Data Case

```elixir
# test/support/data_case.ex
defmodule FlowStone.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Supertester.ExUnitFoundation, isolation: :full_isolation
      import FlowStone.DataCase
      alias FlowStone.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(FlowStone.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
```

### 5. Conn Case for LiveView

```elixir
# test/support/conn_case.ex
defmodule FlowStoneWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Supertester.ExUnitFoundation, isolation: :full_isolation
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import FlowStoneWeb.ConnCase

      alias FlowStoneWeb.Router.Helpers, as: Routes

      @endpoint FlowStoneWeb.Endpoint
    end
  end

  setup tags do
    # Setup database and conn
  end
end
```

## Test Design with Supertester

### Unit Testing Assets with Dependency Injection

```elixir
defmodule MyApp.Assets.DailyReportTest do
  use FlowStone.AssetCase, async: true

  describe "daily_report asset" do
    test "aggregates events correctly" do
      deps = %{
        raw_events: [
          %{type: "click", count: 10},
          %{type: "click", count: 5},
          %{type: "view", count: 100}
        ]
      }

      {:ok, result} = execute_asset(:daily_report, deps, partition: ~D[2025-01-15])

      assert result == %{
        clicks: 15,
        views: 100,
        date: ~D[2025-01-15]
      }
    end

    test "handles empty events" do
      {:ok, result} = execute_asset(:daily_report, %{raw_events: []})

      assert result == %{clicks: 0, views: 0, date: Date.utc_today()}
    end

    test "returns error for invalid data" do
      deps = %{raw_events: "not a list"}

      {:error, error} = execute_asset(:daily_report, deps)

      assert error.type == :validation_error
      assert error.message =~ "expected list"
    end
  end
end
```

### Mox for External Dependencies

```elixir
defmodule FlowStone.ExternalAPITest do
  use FlowStone.AssetCase, async: true

  setup :verify_on_exit!

  test "fetches data from external API" do
    expect(FlowStone.ResourceMock, :setup, fn _config ->
      {:ok, %{data: [1, 2, 3]}}
    end)

    {:ok, result} = execute_asset(:my_asset, %{}, resources: %{
      api_client: FlowStone.ResourceMock
    })

    assert result == [1, 2, 3]
    verify!()
  end

  test "handles API errors gracefully" do
    expect(FlowStone.ResourceMock, :setup, fn _config ->
      {:error, :connection_refused}
    end)

    {:error, error} = execute_asset(:my_asset, %{}, resources: %{
      api_client: FlowStone.ResourceMock
    })

    assert error.type == :io_error
  end

  test "retries on transient failures" do
    expect(FlowStone.ResourceMock, :setup, 3, fn _config ->
      {:error, :timeout}
    end)

    expect(FlowStone.ResourceMock, :setup, fn _config ->
      {:ok, :success}
    end)

    # Should retry and eventually succeed
    {:ok, result} = execute_asset(:my_asset, %{}, resources: %{
      api_client: FlowStone.ResourceMock
    })

    assert result == :success
  end
end
```

### Integration Tests with Sandbox

```elixir
defmodule FlowStone.IntegrationTest do
  use FlowStone.DataCase, async: false  # Shared DB connection

  @tag :integration
  test "full pipeline execution" do
    # Seed test data
    insert(:raw_event, type: "click", count: 10)
    insert(:raw_event, type: "view", count: 50)

    # Execute full pipeline
    {:ok, run} = FlowStone.materialize_all(:final_report,
      partition: ~D[2025-01-15],
      wait: true
    )

    assert run.status == :completed

    # Verify results stored
    {:ok, report} = FlowStone.IO.load(:final_report, ~D[2025-01-15])
    assert report.total_events == 2
  end

  @tag :integration
  test "checkpoint pauses workflow" do
    # Setup: Asset with checkpoint
    insert(:raw_data, flagged: true)

    # Execute - should pause at checkpoint
    {:ok, run} = FlowStone.materialize(:reviewed_data, partition: ~D[2025-01-15])

    assert run.status == :waiting_approval
    [checkpoint] = FlowStone.Checkpoint.list_pending()
    assert checkpoint.checkpoint_name == :quality_review

    # Approve checkpoint
    :ok = FlowStone.Checkpoint.approve(checkpoint.id, by: "test_user")

    # Verify workflow resumed
    {:ok, run} = FlowStone.Run.get(run.run_id)
    assert run.status == :completed
  end
end
```

### Testing with Supertester Patterns

```elixir
defmodule FlowStone.GenServerTest do
  use FlowStone.DataCase, async: true
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import Supertester.OTPHelpers
  import Supertester.Assertions

  describe "GenServer with isolation" do
    test "setup_isolated_genserver/1" do
      {:ok, server} = setup_isolated_genserver(FlowStone.AssetServer, %{
        asset: :test_asset
      })

      assert Process.alive?(server)
      assert GenServer.call(server, :get_state).asset == :test_asset
    end

    test "cast_and_sync/2 ensures message processing" do
      {:ok, server} = setup_isolated_genserver(FlowStone.AssetServer, %{})

      cast_and_sync(server, {:update_status, :running})

      state = GenServer.call(server, :get_state)
      assert state.status == :running
    end

    test "assert_genserver_state/2 validates state" do
      {:ok, server} = setup_isolated_genserver(FlowStone.AssetServer, %{
        status: :idle
      })

      assert_genserver_state(server, fn state ->
        state.status == :idle
      end)

      cast_and_sync(server, {:update_status, :running})

      assert_genserver_state(server, fn state ->
        state.status == :running
      end)
    end
  end
end
```

### Concurrent Testing with ConcurrentHarness

```elixir
defmodule FlowStone.ConcurrencyTest do
  use FlowStone.DataCase, async: true
  use Supertester.ConcurrentHarness

  describe "concurrent materialization writes" do
    test "handles concurrent writes safely" do
      scenario = define_scenario(
        threads: 10,
        iterations: 5,
        operation: fn i, iteration ->
          FlowStone.Materialization.Store.create(%{
            asset_name: "concurrent_asset_#{i}_#{iteration}",
            partition: "p1",
            run_id: Ecto.UUID.generate(),
            status: :success
          })
        end
      )

      {:ok, report} = run_scenario(scenario)

      assert report.metrics.success_count == 50  # 10 threads * 5 iterations
      assert report.metrics.error_count == 0
    end

    test "concurrent checkpoint approvals" do
      # Create 10 pending approvals
      approval_ids = Enum.map(1..10, fn i ->
        {:pending, id} = create_pending_approval(%{
          checkpoint_name: "concurrent_#{i}"
        })
        id
      end)

      scenario = define_scenario(
        threads: 10,
        operation: fn i ->
          approval_id = Enum.at(approval_ids, i - 1)
          FlowStone.Checkpoint.approve(approval_id, by: "user_#{i}")
        end
      )

      {:ok, report} = run_scenario(scenario)

      assert report.metrics.success_count == 10

      # Verify all approved
      Enum.each(approval_ids, fn id ->
        {:ok, approval} = FlowStone.Checkpoint.get_approval(id)
        assert approval.status == :approved
      end)
    end
  end
end
```

### Chaos Testing with ChaosHelpers

```elixir
defmodule FlowStone.ResilienceTest do
  use FlowStone.DataCase, async: true
  use Supertester.ChaosHelpers

  describe "resilience to failures" do
    test "survives random process crashes" do
      {:ok, supervisor} = start_supervised(FlowStone.AssetSupervisor)

      # Start chaos: randomly kill child processes
      chaos_config = %{
        kill_probability: 0.3,
        duration_ms: 5000,
        target_supervisor: supervisor
      }

      inject_chaos(:random_kills, chaos_config)

      # Verify supervisor restarts children
      :timer.sleep(6000)

      # Should still be able to execute assets
      {:ok, result} = execute_asset(:test_asset, %{})
      assert result != nil
    end

    test "handles network partitions" do
      chaos_config = %{
        partition_probability: 0.5,
        duration_ms: 3000
      }

      inject_chaos(:network_partition, chaos_config)

      # Asset execution should handle network issues
      result = execute_asset(:external_asset, %{})

      assert match?({:ok, _} or {:error, %{retryable: true}}, result)
    end
  end
end
```

### Performance Testing with PerformanceHelpers

```elixir
defmodule FlowStone.PerformanceTest do
  use FlowStone.DataCase, async: true
  use Supertester.PerformanceHelpers

  describe "performance benchmarks" do
    test "DAG execution order is O(n log n)" do
      # Generate large DAG
      assets = generate_dag(size: 100)

      execution_time = measure_execution_time(fn ->
        FlowStone.DAG.execution_order(:target, assets)
      end)

      # Assert reasonable performance
      assert execution_time < 100  # milliseconds
    end

    test "materialization throughput" do
      throughput = measure_throughput(
        duration_seconds: 10,
        operation: fn ->
          execute_asset(:fast_asset, %{})
        end
      )

      # Assert minimum throughput
      assert throughput.operations_per_second > 100
    end

    test "memory usage stays bounded" do
      initial_memory = measure_memory_usage()

      # Execute many materializations
      Enum.each(1..1000, fn i ->
        execute_asset(:test_asset, %{}, partition: "p_#{i}")
      end)

      final_memory = measure_memory_usage()
      memory_growth = final_memory - initial_memory

      # Assert memory growth is reasonable
      assert memory_growth < 50_000_000  # 50 MB
    end
  end

  defp generate_dag(size: n) do
    Enum.map(1..n, fn i ->
      deps = if i > 1, do: [:"asset_#{i - 1}"], else: []
      %FlowStone.Asset{name: :"asset_#{i}", depends_on: deps}
    end)
  end
end
```

### Property-Based Testing

```elixir
defmodule FlowStone.DAG.PropertyTest do
  use FlowStone.DataCase, async: true
  use ExUnitProperties

  property "topological sort maintains dependency ordering" do
    check all assets <- valid_dag_generator() do
      sorted = FlowStone.DAG.execution_order(:target, assets)

      for asset <- sorted do
        asset_idx = Enum.find_index(sorted, &(&1.name == asset.name))

        for dep <- asset.depends_on do
          dep_idx = Enum.find_index(sorted, &(&1.name == dep))
          assert dep_idx < asset_idx, "#{dep} should come before #{asset.name}"
        end
      end
    end
  end

  property "cycle detection never misses cycles" do
    check all assets <- dag_with_cycle_generator() do
      assert {:error, _cycle} = FlowStone.DAG.check_cycles(assets)
    end
  end

  defp valid_dag_generator do
    gen all count <- integer(2..20),
            names = Enum.map(1..count, &:"asset_#{&1}") do
      Enum.with_index(names)
      |> Enum.map(fn {name, idx} ->
        possible_deps = Enum.take(names, idx)
        deps = Enum.take_random(possible_deps, min(idx, 3))
        %FlowStone.Asset{name: name, depends_on: deps}
      end)
    end
  end

  defp dag_with_cycle_generator do
    gen all count <- integer(2..10) do
      names = Enum.map(1..count, &:"asset_#{&1}")

      # Create cycle: last asset depends on first
      assets = Enum.with_index(names)
      |> Enum.map(fn {name, idx} ->
        deps = if idx == count - 1 do
          [hd(names)]  # Cycle!
        else
          if idx > 0, do: [Enum.at(names, idx - 1)], else: []
        end
        %FlowStone.Asset{name: name, depends_on: deps}
      end)

      assets
    end
  end
end
```

### Testing Schedules and Time

```elixir
defmodule FlowStone.ScheduleTest do
  use FlowStone.DataCase, async: true

  test "cron schedule generates correct partitions" do
    schedule = %FlowStone.Schedule{
      asset: :daily_report,
      cron: "0 2 * * *",
      timezone: "America/New_York",
      partition_fn: fn -> Date.utc_today() end
    }

    assert FlowStone.Schedule.next_partition(schedule) == Date.utc_today()
  end

  test "schedule triggers materialization" do
    FlowStone.schedule(:daily_report, cron: "0 2 * * *")

    # Manually trigger the scheduled job
    {:ok, job} = Oban.insert(FlowStone.Workers.ScheduledAsset.new(%{
      asset: "daily_report"
    }))

    assert job.queue == "assets"
  end
end
```

### Oban Testing

```elixir
defmodule FlowStone.Workers.AssetWorkerTest do
  use FlowStone.DataCase, async: true
  use Oban.Testing, repo: FlowStone.Repo

  test "processes asset materialization job" do
    {:ok, job} = FlowStone.materialize(:my_asset, partition: ~D[2025-01-15])

    # Assert job was enqueued
    assert_enqueued(worker: FlowStone.Workers.AssetWorker, args: %{
      asset_name: "my_asset",
      partition: "2025-01-15"
    })

    # Process the job inline
    assert :ok = perform_job(FlowStone.Workers.AssetWorker, %{
      asset_name: "my_asset",
      partition: "2025-01-15",
      run_id: job.run_id
    })
  end

  test "retries on transient failure" do
    # Setup: Make first attempt fail
    expect(FlowStone.ResourceMock, :setup, fn _ ->
      {:error, :connection_refused}
    end)

    expect(FlowStone.ResourceMock, :setup, fn _ ->
      {:ok, :connected}
    end)

    {:error, _} = perform_job(FlowStone.Workers.AssetWorker, job_args)

    # Second attempt succeeds
    assert :ok = perform_job(FlowStone.Workers.AssetWorker, job_args)
  end
end
```

## Implementation Order

1. **Test support modules** - AssetCase, DataCase, ConnCase
2. **Mox definitions** - Mock behaviours for external systems
3. **Fixtures** - Test data builders
4. **Unit tests** - Asset execution with dependency injection
5. **Integration tests** - Full pipeline execution
6. **Concurrent tests** - ConcurrentHarness for race conditions
7. **Property tests** - DAG invariants and edge cases
8. **Performance tests** - Benchmarks and memory profiling

## Success Criteria

- [ ] All tests use dependency injection (no global flags)
- [ ] Mox used for all external dependencies
- [ ] Tests run with `async: true` where possible
- [ ] Concurrent tests validate thread safety
- [ ] Property tests validate DAG invariants
- [ ] Performance benchmarks establish baselines
- [ ] Integration tests cover end-to-end workflows
- [ ] No flaky tests (deterministic test data)

## Commands

```bash
# Run all tests
mix test

# Run with coverage
mix coveralls.html

# Run only unit tests
mix test --only unit

# Run integration tests
mix test --only integration

# Run property tests
mix test test/flowstone/dag/property_test.exs

# Run performance tests
mix test --only performance

# Run concurrent tests
mix test --only concurrent

# Run with warnings as errors
mix test --warnings-as-errors
```

## Spawn Subagents

1. **Test support modules** - AssetCase, DataCase, fixtures
2. **Mox integration** - Mock definitions and stubs
3. **Unit tests** - Asset execution tests
4. **Integration tests** - End-to-end workflows
5. **Concurrent tests** - ConcurrentHarness scenarios
6. **Property tests** - DAG invariants
7. **Performance tests** - Benchmarks and profiling

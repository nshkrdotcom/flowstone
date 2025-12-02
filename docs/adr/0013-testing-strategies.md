# ADR-0013: Testing Strategies

## Status
Accepted

## Context

Orchestration systems are notoriously hard to test due to:
- External dependencies (databases, APIs, storage)
- Time-based behavior (schedules, timeouts)
- Distributed execution (job queues, workers)
- Complex state machines (checkpoints, retries)

pipeline_ex demonstrated testing anti-patterns:
- Global test mode flags via environment variables
- Process dictionary for test context
- Mock/live code path divergence
- Incomplete mock implementations

## Decision

### 1. Test Case Modules

```elixir
defmodule FlowStone.AssetCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import FlowStone.AssetCase
      import Mox

      alias FlowStone.Test.Fixtures
    end
  end

  setup tags do
    # Start fresh I/O storage
    FlowStone.IO.Memory.clear()

    # Configure test I/O manager
    Application.put_env(:flowstone, :default_io_manager, :memory)

    # Setup Mox for resources
    Mox.stub_with(FlowStone.ResourceMock, FlowStone.Test.ResourceStub)

    # Handle async tests
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(FlowStone.Repo, shared: not tags[:async])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  @doc "Build a test context for asset execution"
  def build_context(asset, opts \\ []) do
    %FlowStone.Context{
      asset: asset,
      partition: Keyword.get(opts, :partition, Date.utc_today()),
      run_id: Keyword.get(opts, :run_id, Ecto.UUID.generate()),
      resources: Keyword.get(opts, :resources, %{}),
      started_at: DateTime.utc_now()
    }
  end

  @doc "Execute an asset with test dependencies"
  def execute_asset(asset, deps, opts \\ []) do
    context = build_context(asset, opts)
    FlowStone.Materializer.execute(asset, context, deps)
  end
end
```

### 2. Mox for External Dependencies

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

# In tests
defmodule MyAssetTest do
  use FlowStone.AssetCase, async: true

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
end
```

### 3. Dependency Injection over Global State

```elixir
# BAD: Global test mode (pipeline_ex pattern)
def get_provider do
  if System.get_env("TEST_MODE") == "mock" do
    MockProvider
  else
    LiveProvider
  end
end

# GOOD: Dependency injection
def execute(asset, context, deps) do
  # Resources are injected via context
  api_client = context.resources[:api_client]
  api_client.call(...)
end

# Test injects mock
test "uses API client" do
  mock_client = start_supervised!(MockAPIClient)
  context = build_context(:my_asset, resources: %{api_client: mock_client})

  {:ok, result} = FlowStone.Materializer.execute(:my_asset, context, %{})
  assert result == expected
end
```

### 4. Unit Testing Assets

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

### 5. Integration Testing with Sandbox

```elixir
defmodule FlowStone.IntegrationTest do
  use FlowStone.AssetCase, async: false  # Shared DB connection

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

### 6. Testing Schedules

```elixir
defmodule FlowStone.ScheduleTest do
  use FlowStone.AssetCase

  test "cron schedule generates correct partitions" do
    # Don't actually wait for cron - test partition generation
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

    # Assert job was inserted
    assert job.queue == "assets"
  end
end
```

### 7. Testing Sensors

```elixir
defmodule FlowStone.Sensors.S3FileArrivalTest do
  use FlowStone.AssetCase

  setup do
    # Mock S3 responses
    Mox.stub(ExAws.Mock, :request, fn
      %ExAws.Operation.S3{} = op when op.action == :list_objects_v2 ->
        {:ok, %{body: %{contents: []}}}
    end)

    :ok
  end

  test "triggers on new file" do
    {:ok, state} = FlowStone.Sensors.S3FileArrival.init(%{
      bucket: "test-bucket",
      prefix: "data/"
    })

    # First poll: no files
    assert {:no_trigger, state} = FlowStone.Sensors.S3FileArrival.poll(state)

    # Mock new file appears
    Mox.expect(ExAws.Mock, :request, fn _ ->
      {:ok, %{body: %{contents: [%{key: "data/2025-01-15/events.json"}]}}}
    end)

    # Second poll: new file triggers
    assert {:trigger, ~D[2025-01-15], _state} = FlowStone.Sensors.S3FileArrival.poll(state)
  end
end
```

### 8. Property-Based Testing

```elixir
defmodule FlowStone.DAG.PropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  property "topological sort always puts dependencies before dependents" do
    check all assets <- list_of(asset_generator(), min_length: 1, max_length: 20) do
      # Remove cycles for valid DAG
      assets = remove_cycles(assets)

      sorted = FlowStone.DAG.topological_sort(assets)

      for asset <- sorted do
        asset_index = Enum.find_index(sorted, &(&1.name == asset.name))

        for dep <- asset.depends_on do
          dep_index = Enum.find_index(sorted, &(&1.name == dep))
          assert dep_index < asset_index, "#{dep} should come before #{asset.name}"
        end
      end
    end
  end

  defp asset_generator do
    gen all name <- atom(:alphanumeric),
            deps <- list_of(atom(:alphanumeric), max_length: 3) do
      %FlowStone.Asset{name: name, depends_on: deps}
    end
  end
end
```

### 9. Oban Testing

```elixir
defmodule FlowStone.Workers.AssetWorkerTest do
  use FlowStone.AssetCase
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
    Mox.expect(FlowStone.ResourceMock, :setup, fn _ ->
      {:error, :connection_refused}
    end)

    Mox.expect(FlowStone.ResourceMock, :setup, fn _ ->
      {:ok, :connected}
    end)

    {:error, _} = perform_job(FlowStone.Workers.AssetWorker, job_args)

    # Second attempt succeeds
    assert :ok = perform_job(FlowStone.Workers.AssetWorker, job_args)
  end
end
```

## Consequences

### Positive

1. **Isolation**: Tests don't affect each other or production.
2. **Speed**: In-memory I/O and Mox make tests fast.
3. **Reliability**: No flaky tests from external dependencies.
4. **Coverage**: Can test edge cases and error paths.
5. **CI-Friendly**: No external services required.

### Negative

1. **Mock Maintenance**: Mocks must stay in sync with real implementations.
2. **Integration Gaps**: Mocked tests may miss real integration issues.
3. **Setup Complexity**: Test infrastructure requires initial investment.

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| TEST_MODE env var | Dependency injection |
| Process dictionary context | Explicit context passing |
| Mock/live code divergence | Mox with behaviors |
| Incomplete mocks | Stubs with full implementation |
| Global test state | Ecto Sandbox per-test |

## References

- Mox: https://hexdocs.pm/mox
- Oban Testing: https://hexdocs.pm/oban/testing.html
- Ecto Sandbox: https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html
- ExUnitProperties: https://hexdocs.pm/stream_data

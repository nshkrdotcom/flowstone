# Implementation Prompt: ADR-0007 Scheduling and Sensor Framework

## Objective

Implement time-based scheduling via Oban and event-based sensor framework for FlowStone using TDD with Supertester.

## Required Reading

Before starting, read these documents thoroughly:

1. **ADR-0007**: `docs/adr/0007-scheduling-sensors.md` - The scheduling and sensor architecture
2. **ADR-0006**: `docs/adr/0006-oban-job-execution.md` - Oban integration
3. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md` - Asset fundamentals
4. **Supertester Manual**: https://hexdocs.pm/supertester - Testing framework
5. **Oban Docs**: https://hexdocs.pm/oban - Job processing system

## Context

FlowStone needs to trigger asset materializations in two ways:

1. **Time-Based Scheduling**: Cron expressions for periodic execution (daily at 2 AM, hourly, etc.)
2. **Event-Based Sensors**: Poll external systems for changes (S3 files, database updates, webhooks)

Both mechanisms should:
- Generate dynamic partitions based on trigger context
- Integrate with the existing materialization pipeline
- Be testable without real external dependencies
- Handle failures gracefully with supervisor recovery

The sensor framework provides a behaviour for custom sensors and built-in implementations for common patterns (S3, database, webhooks).

## Implementation Tasks

### 1. Create Schedule Data Structure

```elixir
# lib/flowstone/schedule.ex
defmodule FlowStone.Schedule do
  @type t :: %__MODULE__{
    asset: atom(),
    cron: String.t(),
    timezone: String.t(),
    partition_fn: (-> term()),
    enabled: boolean(),
    metadata: map()
  }

  defstruct [
    :asset,
    :cron,
    timezone: "UTC",
    partition_fn: &Date.utc_today/0,
    enabled: true,
    metadata: %{}
  ]

  # CRUD operations
  def create(schedule)
  def delete(asset)
  def get(asset)
  def list()
  def update(asset, updates)
end
```

### 2. Create Schedule API

```elixir
# Add to lib/flowstone.ex
defmodule FlowStone do
  def schedule(asset, opts)
  def unschedule(asset)
  def list_schedules()
end
```

### 3. Create Scheduled Worker

```elixir
# lib/flowstone/workers/scheduled_asset.ex
defmodule FlowStone.Workers.ScheduledAsset do
  use Oban.Worker, queue: :assets

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset" => asset_name}})
end
```

### 4. Create Sensor Behaviour

```elixir
# lib/flowstone/sensor.ex
defmodule FlowStone.Sensor do
  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback poll(state :: term()) ::
    {:trigger, partition :: term(), new_state :: term()} |
    {:no_trigger, new_state :: term()} |
    {:error, reason :: term(), new_state :: term()}
  @callback cleanup(state :: term()) :: :ok

  @optional_callbacks [cleanup: 1]
end
```

### 5. Create Built-In Sensors

```elixir
# lib/flowstone/sensors/s3_file_arrival.ex
defmodule FlowStone.Sensors.S3FileArrival do
  @behaviour FlowStone.Sensor
end

# lib/flowstone/sensors/database_change.ex
defmodule FlowStone.Sensors.DatabaseChange do
  @behaviour FlowStone.Sensor
end

# lib/flowstone/sensors/webhook.ex
defmodule FlowStone.Sensors.Webhook do
  @behaviour FlowStone.Sensor
end
```

### 6. Create Sensor Worker

```elixir
# lib/flowstone/sensors/worker.ex
defmodule FlowStone.Sensors.Worker do
  use GenServer
  # Manages lifecycle of a single sensor (init, poll loop, trigger callback)
end
```

### 7. Create Sensor Supervisor

```elixir
# lib/flowstone/sensors/supervisor.ex
defmodule FlowStone.Sensors.Supervisor do
  use Supervisor
  # Supervises all sensor workers
end
```

### 8. Create Sensor DSL

```elixir
# Add to lib/flowstone/pipeline.ex
defmodule FlowStone.Pipeline do
  defmacro sensor(name, do: block)
  defmacro type(module)
  defmacro config(map)
  defmacro poll_interval(duration)
  defmacro on_trigger(callback_fn)
end
```

## Test Design with Supertester

### Test File Structure

```
test/
├── flowstone/
│   ├── schedule_test.exs
│   ├── workers/
│   │   └── scheduled_asset_test.exs
│   └── sensors/
│       ├── s3_file_arrival_test.exs
│       ├── database_change_test.exs
│       ├── webhook_test.exs
│       ├── worker_test.exs
│       └── supervisor_test.exs
└── support/
    └── mock_sensors.ex
```

### Test Cases

#### Schedule CRUD Tests

```elixir
defmodule FlowStone.ScheduleTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.Assertions

  describe "create/1" do
    test "creates valid schedule" do
      schedule = %FlowStone.Schedule{
        asset: :daily_report,
        cron: "0 2 * * *",
        timezone: "America/New_York",
        partition_fn: fn -> Date.utc_today() end
      }

      assert {:ok, created} = FlowStone.Schedule.create(schedule)
      assert created.asset == :daily_report
      assert created.cron == "0 2 * * *"
    end

    test "validates cron expression" do
      schedule = %FlowStone.Schedule{
        asset: :test,
        cron: "invalid cron"
      }

      assert {:error, %FlowStone.Error{type: :validation_error}} =
        FlowStone.Schedule.create(schedule)
    end

    test "rejects duplicate asset schedules" do
      schedule = %FlowStone.Schedule{asset: :dup, cron: "0 * * * *"}

      assert {:ok, _} = FlowStone.Schedule.create(schedule)
      assert {:error, %FlowStone.Error{type: :validation_error}} =
        FlowStone.Schedule.create(schedule)
    end
  end

  describe "get/1" do
    test "retrieves existing schedule" do
      schedule = %FlowStone.Schedule{asset: :lookup, cron: "0 * * * *"}
      {:ok, _} = FlowStone.Schedule.create(schedule)

      assert {:ok, found} = FlowStone.Schedule.get(:lookup)
      assert found.asset == :lookup
    end

    test "returns error for nonexistent schedule" do
      assert {:error, :not_found} = FlowStone.Schedule.get(:nonexistent)
    end
  end

  describe "delete/1" do
    test "removes existing schedule" do
      schedule = %FlowStone.Schedule{asset: :to_delete, cron: "0 * * * *"}
      {:ok, _} = FlowStone.Schedule.create(schedule)

      assert :ok = FlowStone.Schedule.delete(:to_delete)
      assert {:error, :not_found} = FlowStone.Schedule.get(:to_delete)
    end
  end
end
```

#### Scheduled Worker Tests with Oban

```elixir
defmodule FlowStone.Workers.ScheduledAssetTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  use Oban.Testing, repo: FlowStone.Repo

  alias FlowStone.Workers.ScheduledAsset

  describe "perform/1" do
    test "materializes asset with dynamic partition" do
      # Create schedule with custom partition function
      schedule = %FlowStone.Schedule{
        asset: :hourly_metrics,
        cron: "0 * * * *",
        partition_fn: fn -> DateTime.utc_now() |> DateTime.truncate(:hour) end
      }
      {:ok, _} = FlowStone.Schedule.create(schedule)

      # Execute worker
      job = %Oban.Job{args: %{"asset" => "hourly_metrics"}}
      assert :ok = ScheduledAsset.perform(job)

      # Verify materialization was triggered
      partition = DateTime.utc_now() |> DateTime.truncate(:hour)
      assert_materialization_started(:hourly_metrics, partition)
    end

    test "handles missing schedule gracefully" do
      job = %Oban.Job{args: %{"asset" => "nonexistent"}}

      assert {:error, %FlowStone.Error{type: :asset_not_found}} =
        ScheduledAsset.perform(job)
    end

    test "uses default partition function when not specified" do
      schedule = %FlowStone.Schedule{
        asset: :default_partition,
        cron: "0 0 * * *"
        # partition_fn defaults to Date.utc_today/0
      }
      {:ok, _} = FlowStone.Schedule.create(schedule)

      job = %Oban.Job{args: %{"asset" => "default_partition"}}
      assert :ok = ScheduledAsset.perform(job)

      assert_materialization_started(:default_partition, Date.utc_today())
    end
  end
end
```

#### Sensor Worker Tests with GenServer Isolation

```elixir
defmodule FlowStone.Sensors.WorkerTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers
  import Supertester.Assertions

  alias FlowStone.Sensors.Worker

  describe "sensor lifecycle" do
    test "initializes sensor with config" do
      sensor_def = %{
        name: :test_sensor,
        module: MockSensor,
        config: %{initial_value: 42},
        poll_interval: :timer.seconds(10),
        on_trigger: fn _partition -> :ok end
      }

      {:ok, worker} = setup_isolated_genserver(Worker, sensor_def)

      assert_genserver_state(worker, fn state ->
        state.sensor.name == :test_sensor and
        state.state.value == 42
      end)
    end

    test "polls sensor on interval" do
      sensor_def = %{
        name: :polling_sensor,
        module: MockSensor,
        config: %{},
        poll_interval: 50,  # 50ms for fast test
        on_trigger: fn partition -> send(self(), {:triggered, partition}) end
      }

      {:ok, worker} = setup_isolated_genserver(Worker, sensor_def)

      # Mock sensor will trigger on first poll
      MockSensor.set_next_result({:trigger, :test_partition, %{polled: true}})

      # Wait for poll to happen
      assert_receive {:triggered, :test_partition}, 200
    end

    test "handles no_trigger correctly" do
      sensor_def = %{
        name: :no_trigger_sensor,
        module: MockSensor,
        config: %{},
        poll_interval: 50,
        on_trigger: fn partition -> send(self(), {:triggered, partition}) end
      }

      {:ok, worker} = setup_isolated_genserver(Worker, sensor_def)

      MockSensor.set_next_result({:no_trigger, %{checked: true}})

      # Should not receive trigger message
      refute_receive {:triggered, _}, 200
    end

    test "handles sensor errors and continues polling" do
      sensor_def = %{
        name: :error_sensor,
        module: MockSensor,
        config: %{},
        poll_interval: 50,
        on_trigger: fn partition -> send(self(), {:triggered, partition}) end
      }

      {:ok, worker} = setup_isolated_genserver(Worker, sensor_def)

      # First poll errors
      MockSensor.set_next_result({:error, :connection_failed, %{}})

      # Wait and verify worker is still alive
      Process.sleep(100)
      assert Process.alive?(worker)

      # Second poll succeeds
      MockSensor.set_next_result({:trigger, :recovered, %{}})
      assert_receive {:triggered, :recovered}, 200
    end

    test "updates sensor state across polls" do
      sensor_def = %{
        name: :stateful_sensor,
        module: MockSensor,
        config: %{counter: 0},
        poll_interval: 50,
        on_trigger: fn _ -> :ok end
      }

      {:ok, worker} = setup_isolated_genserver(Worker, sensor_def)

      # First poll updates state
      MockSensor.set_next_result({:no_trigger, %{counter: 1}})
      Process.sleep(100)

      assert_genserver_state(worker, fn state ->
        state.state.counter == 1
      end)

      # Second poll updates state again
      MockSensor.set_next_result({:no_trigger, %{counter: 2}})
      Process.sleep(100)

      assert_genserver_state(worker, fn state ->
        state.state.counter == 2
      end)
    end
  end

  describe "concurrent polling" do
    test "handles rapid poll intervals without race conditions" do
      sensor_def = %{
        name: :rapid_sensor,
        module: MockSensor,
        config: %{count: 0},
        poll_interval: 10,  # Very fast
        on_trigger: fn _ -> :ok end
      }

      {:ok, worker} = setup_isolated_genserver(Worker, sensor_def)

      # Let it poll multiple times
      Process.sleep(100)

      # Verify worker is still healthy
      assert Process.alive?(worker)

      # State should be consistent
      assert_genserver_state(worker, fn state ->
        is_integer(state.state.count)
      end)
    end
  end
end
```

#### S3 Sensor Tests with Mocks

```elixir
defmodule FlowStone.Sensors.S3FileArrivalTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Sensors.S3FileArrival

  setup do
    # Mock ExAws for testing
    MockExAws.start_link()
    :ok
  end

  describe "init/1" do
    test "initializes with config" do
      config = %{
        bucket: "test-bucket",
        prefix: "data/",
        partition_fn: &extract_date/1
      }

      assert {:ok, state} = S3FileArrival.init(config)
      assert state.bucket == "test-bucket"
      assert state.prefix == "data/"
      assert state.last_keys == MapSet.new()
    end
  end

  describe "poll/1" do
    test "triggers on new file arrival" do
      config = %{
        bucket: "test-bucket",
        prefix: "events/",
        partition_fn: fn _key -> ~D[2025-01-15] end
      }
      {:ok, state} = S3FileArrival.init(config)

      # Mock S3 list with new file
      MockExAws.expect_list_objects("test-bucket", "events/", [
        "events/2025-01-15/data.parquet"
      ])

      assert {:trigger, partition, new_state} = S3FileArrival.poll(state)
      assert partition == ~D[2025-01-15]
      assert MapSet.size(new_state.last_keys) == 1
    end

    test "does not trigger when no new files" do
      config = %{bucket: "test-bucket", prefix: "data/"}
      {:ok, state} = S3FileArrival.init(config)

      # First poll - new file
      MockExAws.expect_list_objects("test-bucket", "data/", ["file1.txt"])
      {:trigger, _, state} = S3FileArrival.poll(state)

      # Second poll - same file
      MockExAws.expect_list_objects("test-bucket", "data/", ["file1.txt"])
      assert {:no_trigger, _} = S3FileArrival.poll(state)
    end

    test "extracts date from key path" do
      config = %{
        bucket: "data",
        prefix: "events/"
      }
      {:ok, state} = S3FileArrival.init(config)

      MockExAws.expect_list_objects("data", "events/", [
        "events/2025-01-20/batch1.parquet"
      ])

      assert {:trigger, ~D[2025-01-20], _} = S3FileArrival.poll(state)
    end

    test "handles S3 errors gracefully" do
      config = %{bucket: "test-bucket", prefix: "data/"}
      {:ok, state} = S3FileArrival.init(config)

      MockExAws.expect_list_error("test-bucket", :network_error)

      assert {:error, :network_error, new_state} = S3FileArrival.poll(state)
      assert new_state.last_keys == MapSet.new()
    end
  end
end
```

#### Database Sensor Tests

```elixir
defmodule FlowStone.Sensors.DatabaseChangeTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Sensors.DatabaseChange

  describe "init/1" do
    test "initializes with query config" do
      config = %{
        query: "SELECT MAX(updated_at) FROM events",
        repo: MockRepo,
        partition_fn: fn _ -> Date.utc_today() end
      }

      assert {:ok, state} = DatabaseChange.init(config)
      assert state.query == "SELECT MAX(updated_at) FROM events"
      assert state.last_value == nil
    end
  end

  describe "poll/1" do
    test "triggers on value change" do
      config = %{
        query: "SELECT COUNT(*) FROM events",
        repo: MockRepo
      }
      {:ok, state} = DatabaseChange.init(config)

      # First poll
      MockRepo.expect_query_result([[100]])
      assert {:trigger, partition, state} = DatabaseChange.poll(state)
      assert state.last_value == 100

      # Second poll, value changed
      MockRepo.expect_query_result([[150]])
      assert {:trigger, _, state} = DatabaseChange.poll(state)
      assert state.last_value == 150
    end

    test "does not trigger when value unchanged" do
      config = %{query: "SELECT MAX(id) FROM events", repo: MockRepo}
      {:ok, state} = DatabaseChange.init(config)

      MockRepo.expect_query_result([[42]])
      {:trigger, _, state} = DatabaseChange.poll(state)

      MockRepo.expect_query_result([[42]])
      assert {:no_trigger, _} = DatabaseChange.poll(state)
    end

    test "handles database errors" do
      config = %{query: "SELECT * FROM bad_table", repo: MockRepo}
      {:ok, state} = DatabaseChange.init(config)

      MockRepo.expect_query_error(:table_not_found)

      assert {:error, :table_not_found, _} = DatabaseChange.poll(state)
    end
  end
end
```

#### Webhook Sensor Tests

```elixir
defmodule FlowStone.Sensors.WebhookTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Sensors.Webhook

  describe "init/1" do
    test "initializes with HTTP config" do
      config = %{
        url: "https://api.example.com/status",
        headers: [{"Authorization", "Bearer token"}],
        check_fn: fn body -> body["ready"] == true end,
        partition_fn: fn body -> body["partition"] end
      }

      assert {:ok, state} = Webhook.init(config)
      assert state.url == "https://api.example.com/status"
      assert length(state.headers) == 1
    end
  end

  describe "poll/1" do
    test "triggers when check function returns true" do
      config = %{
        url: "http://test.local/webhook",
        check_fn: fn body -> body["ready"] == true end,
        partition_fn: fn body -> body["date"] end
      }
      {:ok, state} = Webhook.init(config)

      MockReq.expect_get("http://test.local/webhook", %{
        "ready" => true,
        "date" => "2025-01-15"
      })

      assert {:trigger, "2025-01-15", _} = Webhook.poll(state)
    end

    test "does not trigger when check returns false" do
      config = %{
        url: "http://test.local/webhook",
        check_fn: fn body -> body["ready"] == true end
      }
      {:ok, state} = Webhook.init(config)

      MockReq.expect_get("http://test.local/webhook", %{"ready" => false})

      assert {:no_trigger, _} = Webhook.poll(state)
    end

    test "handles HTTP errors" do
      config = %{url: "http://test.local/webhook"}
      {:ok, state} = Webhook.init(config)

      MockReq.expect_error(:timeout)

      assert {:error, :timeout, _} = Webhook.poll(state)
    end

    test "handles non-200 status codes" do
      config = %{url: "http://test.local/webhook"}
      {:ok, state} = Webhook.init(config)

      MockReq.expect_status(503)

      assert {:error, {:http_status, 503}, _} = Webhook.poll(state)
    end
  end
end
```

#### Sensor Supervisor Tests

```elixir
defmodule FlowStone.Sensors.SupervisorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.OTPHelpers
  import Supertester.Assertions

  alias FlowStone.Sensors.Supervisor

  describe "supervisor lifecycle" do
    test "starts with no sensors" do
      {:ok, sup} = Supervisor.start_link([])

      children = Supervisor.which_children(sup)
      assert children == []
    end

    test "starts multiple sensor workers" do
      sensors = [
        %{name: :sensor1, module: MockSensor, config: %{}, poll_interval: 1000, on_trigger: fn _ -> :ok end},
        %{name: :sensor2, module: MockSensor, config: %{}, poll_interval: 1000, on_trigger: fn _ -> :ok end}
      ]

      {:ok, sup} = Supervisor.start_link(sensors)

      children = Supervisor.which_children(sup)
      assert length(children) == 2
    end

    test "restarts failed sensor workers" do
      sensors = [
        %{name: :restartable, module: MockSensor, config: %{}, poll_interval: 1000, on_trigger: fn _ -> :ok end}
      ]

      {:ok, sup} = Supervisor.start_link(sensors)

      # Find worker PID
      [{_, worker_pid, _, _}] = Supervisor.which_children(sup)
      assert Process.alive?(worker_pid)

      # Kill worker
      Process.exit(worker_pid, :kill)
      Process.sleep(50)

      # Verify new worker started
      [{_, new_pid, _, _}] = Supervisor.which_children(sup)
      assert Process.alive?(new_pid)
      assert new_pid != worker_pid
    end
  end
end
```

#### Sensor DSL Tests

```elixir
defmodule FlowStone.SensorDSLTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "sensor macro" do
    test "defines sensor with all properties" do
      defmodule TestPipelineWithSensor do
        use FlowStone.Pipeline

        sensor :new_files do
          type FlowStone.Sensors.S3FileArrival
          config %{bucket: "data", prefix: "events/"}
          poll_interval :timer.seconds(30)

          on_trigger fn partition ->
            FlowStone.materialize(:raw_events, partition: partition)
          end
        end
      end

      sensors = TestPipelineWithSensor.__flowstone_sensors__()
      assert length(sensors) == 1

      sensor = hd(sensors)
      assert sensor.name == :new_files
      assert sensor.module == FlowStone.Sensors.S3FileArrival
      assert sensor.poll_interval == 30_000
    end

    test "validates sensor module implements behaviour" do
      assert_raise CompileError, fn ->
        defmodule BadSensorModule do
          use FlowStone.Pipeline

          sensor :bad do
            type NotASensor  # Doesn't implement FlowStone.Sensor
            config %{}
            poll_interval 1000
            on_trigger fn _ -> :ok end
          end
        end
      end
    end
  end
end
```

#### Concurrency Tests with ConcurrentHarness

```elixir
defmodule FlowStone.Sensors.ConcurrencyTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Supertester.ConcurrentHarness

  describe "concurrent sensor operations" do
    test "multiple sensors poll independently" do
      sensors = for i <- 1..10 do
        %{
          name: :"sensor_#{i}",
          module: MockSensor,
          config: %{id: i},
          poll_interval: 50,
          on_trigger: fn partition -> send(self(), {:trigger, i, partition}) end
        }
      end

      {:ok, sup} = FlowStone.Sensors.Supervisor.start_link(sensors)

      # Set all sensors to trigger
      for i <- 1..10 do
        MockSensor.set_result(:"sensor_#{i}", {:trigger, :"partition_#{i}", %{}})
      end

      # Collect all triggers
      triggers = for _ <- 1..10 do
        assert_receive {:trigger, i, partition}, 500
        {i, partition}
      end

      # Verify all 10 sensors triggered
      assert length(triggers) == 10
      assert Enum.all?(1..10, fn i ->
        {^i, partition} = Enum.find(triggers, fn {tid, _} -> tid == i end)
        partition == :"partition_#{i}"
      end)
    end

    test "sensor state updates are isolated" do
      scenario = ConcurrentHarness.define_scenario(%{
        name: "sensor_state_isolation",
        threads: 5,
        operations_per_thread: 10,
        setup: fn ->
          sensor = %{
            name: :concurrent_sensor,
            module: MockSensor,
            config: %{counter: 0},
            poll_interval: :infinity,  # Manual poll
            on_trigger: fn _ -> :ok end
          }
          {:ok, worker} = FlowStone.Sensors.Worker.start_link(sensor)
          {:ok, worker, %{}}
        end,
        operation: fn worker, _context, _thread_id, op_num ->
          # Simulate concurrent polls
          MockSensor.set_next_result({:no_trigger, %{counter: op_num}})
          send(worker, :poll)
          :ok
        end,
        cleanup: fn worker, _context ->
          GenServer.stop(worker)
        end
      })

      assert {:ok, report} = ConcurrentHarness.run(scenario)
      assert report.metrics.total_operations == 50
      assert report.metrics.errors == 0
    end
  end
end
```

#### Performance Tests with PerformanceHelpers

```elixir
defmodule FlowStone.Sensors.PerformanceTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.PerformanceHelpers

  describe "sensor performance" do
    test "poll completes within timeout" do
      config = %{bucket: "perf-test", prefix: "data/"}
      {:ok, state} = FlowStone.Sensors.S3FileArrival.init(config)

      MockExAws.expect_list_objects("perf-test", "data/",
        Enum.map(1..1000, fn i -> "file_#{i}.txt" end))

      assert_performance(max_duration: 100) do
        FlowStone.Sensors.S3FileArrival.poll(state)
      end
    end

    test "sensor worker handles high poll frequency" do
      sensor_def = %{
        name: :high_freq,
        module: MockSensor,
        config: %{},
        poll_interval: 1,  # 1ms
        on_trigger: fn _ -> :ok end
      }

      assert_performance(max_duration: 1000, iterations: 100) do
        {:ok, worker} = FlowStone.Sensors.Worker.start_link(sensor_def)
        Process.sleep(100)  # Let it poll rapidly
        GenServer.stop(worker)
      end
    end
  end
end
```

## Supertester Integration Principles

### 1. Use Isolation Modes
```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. Use `cast_and_sync/2` for Worker Async Operations
```elixir
:ok = cast_and_sync(worker, :poll)
```

### 3. Use `assert_genserver_state/2` for Sensor State
```elixir
assert_genserver_state(sensor_worker, fn state ->
  state.sensor.name == :my_sensor
end)
```

### 4. Use `setup_isolated_genserver/1` for Worker Lifecycle
```elixir
{:ok, worker} = setup_isolated_genserver(FlowStone.Sensors.Worker, sensor_config)
```

### 5. Use ConcurrentHarness for Multi-Sensor Tests
```elixir
scenario = ConcurrentHarness.define_scenario(...)
{:ok, report} = ConcurrentHarness.run(scenario)
```

### 6. Use PerformanceHelpers for Timing Assertions
```elixir
assert_performance(max_duration: 100) do
  sensor.poll(state)
end
```

## Implementation Order

1. **FlowStone.Schedule struct and CRUD** - Schedule data management
2. **FlowStone.schedule/2 API** - Public scheduling interface
3. **FlowStone.Workers.ScheduledAsset** - Oban worker for cron triggers
4. **FlowStone.Sensor behaviour** - Sensor callback definitions
5. **FlowStone.Sensors.Worker** - GenServer for sensor lifecycle
6. **Built-in sensors** - S3FileArrival, DatabaseChange, Webhook
7. **FlowStone.Sensors.Supervisor** - Supervisor for all sensors
8. **Sensor DSL macros** - sensor/2 and configuration macros
9. **Oban cron integration** - Wire schedules into Oban config

## Success Criteria

- [ ] All tests pass with `async: true`
- [ ] Zero `Process.sleep` calls (except for time-based integration tests)
- [ ] 100% test coverage for Schedule, Worker, and all built-in sensors
- [ ] Sensors recover from failures without data loss
- [ ] Dialyzer passes with no warnings
- [ ] Credo passes with no issues
- [ ] Documentation for all public functions and behaviours
- [ ] At least one example sensor in test/support
- [ ] Oban cron plugin successfully schedules jobs

## Commands

```bash
# Run all scheduling and sensor tests
mix test test/flowstone/schedule_test.exs test/flowstone/workers/scheduled_asset_test.exs test/flowstone/sensors/

# Run with coverage
mix coveralls.html --umbrella

# Test specific sensor
mix test test/flowstone/sensors/s3_file_arrival_test.exs

# Check concurrency tests
mix test --only concurrent

# Check performance tests
mix test --only performance

# Check types
mix dialyzer

# Check style
mix credo --strict
```

## Spawn Subagents

For parallel implementation, spawn subagents for:

1. **Schedule API + Storage** - Schedule CRUD operations and persistence
2. **Scheduled Worker** - Oban worker for cron-triggered materializations
3. **Sensor Behaviour + Worker** - Core sensor framework and GenServer
4. **Built-in Sensors** - S3FileArrival, DatabaseChange, Webhook implementations
5. **Sensor Supervisor** - Supervisor and sensor DSL
6. **Test Suite** - Comprehensive test coverage with Supertester patterns

Each subagent should follow TDD: write tests first using Supertester, then implement.

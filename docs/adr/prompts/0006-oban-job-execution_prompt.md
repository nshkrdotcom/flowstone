# Implementation Prompt: ADR-0006 Oban-Based Job Execution

## Objective

Implement reliable distributed job execution using Oban for asset materialization using TDD with Supertester.

## Required Reading

1. **ADR-0006**: `docs/adr/0006-oban-job-execution.md`
2. **Oban docs**: https://hexdocs.pm/oban
3. **Oban Testing**: https://hexdocs.pm/oban/testing.html
4. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

Oban provides:
- PostgreSQL-backed job queue
- Automatic retries with backoff
- Unique jobs to prevent duplicates
- Cron scheduling
- Telemetry integration

## Implementation Tasks

### 1. Asset Worker

```elixir
# lib/flowstone/workers/asset_worker.ex
defmodule FlowStone.Workers.AssetWorker do
  use Oban.Worker,
    queue: :assets,
    max_attempts: 3,
    priority: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: args})

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt})
end
```

### 2. Materializer

```elixir
# lib/flowstone/materializer.ex
defmodule FlowStone.Materializer do
  def execute(asset, context, deps)
  def check_dependencies_ready(asset, partition)
  def load_dependencies(asset, partition)
  def build_context(asset, partition, run_id)
  def store_result(asset, partition, result, context)
end
```

### 3. Public API

```elixir
# lib/flowstone.ex
defmodule FlowStone do
  def materialize(asset, opts \\ [])
  def materialize_all(asset, opts \\ [])
  def backfill(asset, opts \\ [])
end
```

## Test Design with Supertester

### Asset Worker Tests with Oban.Testing

```elixir
defmodule FlowStone.Workers.AssetWorkerTest do
  use FlowStone.DataCase, async: true
  use Oban.Testing, repo: FlowStone.Repo
  import Supertester.OTPHelpers
  import Supertester.Assertions

  setup do
    # Register test asset
    asset = %FlowStone.Asset{
      name: :test_asset,
      depends_on: [],
      io_manager: :memory,
      execute_fn: fn _ctx, _deps -> {:ok, %{computed: true}} end
    }
    FlowStone.Asset.Registry.register(asset)
    :ok
  end

  describe "perform/1" do
    test "materializes asset successfully" do
      job_args = %{
        "asset_name" => "test_asset",
        "partition" => "2025-01-15",
        "run_id" => Ecto.UUID.generate(),
        "force" => false
      }

      assert :ok = perform_job(FlowStone.Workers.AssetWorker, job_args)

      # Verify result was stored
      {:ok, data} = FlowStone.IO.Memory.load(:test_asset, "2025-01-15", %{})
      assert data.computed == true
    end

    test "records materialization on success" do
      run_id = Ecto.UUID.generate()
      job_args = %{
        "asset_name" => "test_asset",
        "partition" => "2025-01-15",
        "run_id" => run_id,
        "force" => false
      }

      perform_job(FlowStone.Workers.AssetWorker, job_args)

      {:ok, mat} = FlowStone.Materialization.Store.get("test_asset", "2025-01-15")
      assert mat.status == :success
      assert mat.run_id == run_id
    end

    test "snoozes when dependencies not ready" do
      # Register asset with unmet dependency
      asset = %FlowStone.Asset{
        name: :dependent_asset,
        depends_on: [:missing_dependency],
        io_manager: :memory,
        execute_fn: fn _, _ -> {:ok, nil} end
      }
      FlowStone.Asset.Registry.register(asset)

      job_args = %{
        "asset_name" => "dependent_asset",
        "partition" => "2025-01-15",
        "run_id" => Ecto.UUID.generate(),
        "force" => false
      }

      assert {:snooze, 30} = perform_job(FlowStone.Workers.AssetWorker, job_args)
    end

    test "discards on non-retryable error" do
      # Register asset that fails permanently
      asset = %FlowStone.Asset{
        name: :failing_asset,
        depends_on: [],
        io_manager: :memory,
        execute_fn: fn _, _ -> {:error, %FlowStone.Error{type: :validation_error, retryable: false}} end
      }
      FlowStone.Asset.Registry.register(asset)

      job_args = %{
        "asset_name" => "failing_asset",
        "partition" => "2025-01-15",
        "run_id" => Ecto.UUID.generate(),
        "force" => false
      }

      assert {:discard, _} = perform_job(FlowStone.Workers.AssetWorker, job_args)
    end
  end

  describe "backoff/1" do
    test "uses exponential backoff" do
      assert FlowStone.Workers.AssetWorker.backoff(%Oban.Job{attempt: 1}) == 30
      assert FlowStone.Workers.AssetWorker.backoff(%Oban.Job{attempt: 2}) == 90
      assert FlowStone.Workers.AssetWorker.backoff(%Oban.Job{attempt: 3}) == 270
    end
  end
end
```

### Materializer Tests

```elixir
defmodule FlowStone.MaterializerTest do
  use FlowStone.DataCase, async: true
  import Supertester.OTPHelpers
  import Supertester.PerformanceHelpers

  describe "execute/3" do
    test "executes asset function with context and deps" do
      asset = %FlowStone.Asset{
        name: :exec_test,
        execute_fn: fn ctx, deps ->
          {:ok, %{partition: ctx.partition, deps: deps}}
        end
      }

      context = %FlowStone.Context{
        asset: :exec_test,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }

      deps = %{upstream: :data}

      {:ok, result} = FlowStone.Materializer.execute(asset, context, deps)
      assert result.partition == ~D[2025-01-15]
      assert result.deps == %{upstream: :data}
    end

    test "catches exceptions and returns error" do
      asset = %FlowStone.Asset{
        name: :crashing_asset,
        execute_fn: fn _, _ -> raise "boom" end
      }

      context = %FlowStone.Context{asset: :crashing_asset, partition: "p1", run_id: Ecto.UUID.generate()}

      {:error, error} = FlowStone.Materializer.execute(asset, context, %{})
      assert error.type == :execution_error
      assert error.message =~ "boom"
    end
  end

  describe "load_dependencies/2" do
    test "loads all upstream assets" do
      # Store upstream data
      FlowStone.IO.Memory.store(:upstream_a, %{a: 1}, "p1", %{})
      FlowStone.IO.Memory.store(:upstream_b, %{b: 2}, "p1", %{})

      asset = %FlowStone.Asset{name: :test, depends_on: [:upstream_a, :upstream_b]}

      {:ok, deps} = FlowStone.Materializer.load_dependencies(asset, "p1")
      assert deps[:upstream_a] == %{a: 1}
      assert deps[:upstream_b] == %{b: 2}
    end

    test "returns error if dependency missing" do
      asset = %FlowStone.Asset{name: :test, depends_on: [:nonexistent]}

      {:error, error} = FlowStone.Materializer.load_dependencies(asset, "p1")
      assert error.type == :dependency_failed
    end
  end
end
```

### Public API Tests

```elixir
defmodule FlowStoneTest do
  use FlowStone.DataCase, async: true
  use Oban.Testing, repo: FlowStone.Repo

  describe "materialize/2" do
    test "enqueues asset worker job" do
      {:ok, %{run_id: run_id}} = FlowStone.materialize(:test_asset, partition: ~D[2025-01-15])

      assert_enqueued(
        worker: FlowStone.Workers.AssetWorker,
        args: %{asset_name: "test_asset", partition: "2025-01-15", run_id: run_id}
      )
    end

    test "waits for completion when wait: true" do
      {:ok, result} = FlowStone.materialize(:test_asset, partition: ~D[2025-01-15], wait: true)

      assert result.status == :completed
    end
  end

  describe "materialize_all/2" do
    test "queues assets in dependency order" do
      {:ok, %{assets: assets}} = FlowStone.materialize_all(:final_asset, partition: ~D[2025-01-15])

      # Verify all dependencies were queued
      assert :source in assets
      assert :derived in assets
      assert :final_asset in assets
    end
  end

  describe "backfill/2" do
    test "queues all partitions" do
      partitions = Date.range(~D[2025-01-01], ~D[2025-01-05]) |> Enum.to_list()

      {:ok, %{total: total}} = FlowStone.backfill(:asset, partitions: partitions)

      assert total == 5
      assert all_enqueued?(worker: FlowStone.Workers.AssetWorker)
    end
  end
end
```

### Chaos Testing for Job Execution

```elixir
defmodule FlowStone.Workers.AssetWorkerChaosTest do
  use FlowStone.DataCase, async: true
  use Oban.Testing, repo: FlowStone.Repo
  import Supertester.ChaosHelpers

  describe "resilience under failures" do
    test "survives random job failures" do
      # Enqueue 100 jobs
      for i <- 1..100 do
        %{asset_name: "asset_#{i}", partition: "p1", run_id: Ecto.UUID.generate()}
        |> FlowStone.Workers.AssetWorker.new()
        |> Oban.insert!()
      end

      # Inject chaos: randomly fail some jobs
      chaos_config = %{failure_rate: 0.3}

      report = with_chaos(chaos_config, fn ->
        Oban.drain_queue(queue: :assets)
      end)

      # Jobs should eventually succeed via retry
      successful = Repo.aggregate(
        from(j in Oban.Job, where: j.state == "completed"),
        :count
      )

      assert successful >= 70  # At least 70% succeeded
    end
  end
end
```

## Implementation Order

1. **Context struct** - Execution context
2. **Materializer** - Core execution logic
3. **AssetWorker** - Oban job
4. **Public API** - materialize/backfill
5. **Unique jobs** - Prevent duplicates

## Success Criteria

- [ ] Jobs execute assets correctly
- [ ] Dependencies loaded before execution
- [ ] Retries work with backoff
- [ ] Snooze when deps not ready
- [ ] Unique jobs prevent duplicates

## Commands

```bash
mix test test/flowstone/workers/
mix test test/flowstone/materializer_test.exs
mix coveralls.html
```

## Spawn Subagents

1. **AssetWorker** - Oban job implementation
2. **Materializer** - Execution coordination
3. **Public API** - User-facing functions
4. **Chaos tests** - Resilience verification

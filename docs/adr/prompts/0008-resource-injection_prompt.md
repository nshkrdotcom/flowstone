# Implementation Prompt: ADR-0008 Resource Injection Pattern

## Objective

Implement resource injection framework for FlowStone assets with lifecycle management, health checking, and testability using Supertester.

## Required Reading

Before starting, read these documents thoroughly:

1. **ADR-0008**: `docs/adr/0008-resource-injection.md` - Resource injection architecture
2. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md` - Asset fundamentals
3. **ADR-0009**: `docs/adr/0009-error-handling.md` - Error handling patterns
4. **Supertester Manual**: https://hexdocs.pm/supertester - Testing framework
5. **Dependency Injection in Elixir**: https://blog.appsignal.com/2022/10/25/dependency-injection-in-elixir.html

## Context

Assets need external dependencies (databases, APIs, ML models, credentials) that should be:

- **Injected, not globally accessed** - No `Application.get_env` inside asset code
- **Testable with mocks** - Easy to replace with test doubles
- **Lifecycle-managed** - Setup/teardown handled centrally
- **Health-checkable** - Periodic health monitoring for observability

The resource injection pattern provides:
1. A behaviour for defining resources with setup/teardown/health_check
2. A GenServer (FlowStone.Resources) that manages all resource lifecycles
3. Context injection where assets receive only their declared resources
4. Test support for overriding resources with mocks

This solves pipeline_ex anti-patterns like global config access and hidden dependencies.

## Implementation Tasks

### 1. Create Resource Behaviour

```elixir
# lib/flowstone/resource.ex
defmodule FlowStone.Resource do
  @callback setup(config :: map()) :: {:ok, resource :: term()} | {:error, term()}
  @callback teardown(resource :: term()) :: :ok
  @callback health_check(resource :: term()) :: :healthy | {:unhealthy, reason :: term()}

  @optional_callbacks [teardown: 1, health_check: 1]

  defmacro __using__(_opts) do
    # Provide default implementations for optional callbacks
  end
end
```

### 2. Create Resource Manager GenServer

```elixir
# lib/flowstone/resources.ex
defmodule FlowStone.Resources do
  use GenServer

  # Public API
  def start_link(opts)
  def get(name) :: {:ok, resource} | {:error, :not_found}
  def load() :: %{atom() => resource}
  def health() :: %{atom() => :healthy | {:unhealthy, term()}}

  # Test-only API
  def override(resources) :: :ok
  def reset() :: :ok

  # GenServer callbacks
  def init(_opts)
  def handle_call({:get, name}, _from, state)
  def handle_call(:load_all, _from, state)
  def handle_call(:health, _from, state)
  def handle_info(:health_check, state)
end
```

### 3. Create Context with Resources

```elixir
# Extend lib/flowstone/context.ex
defmodule FlowStone.Context do
  defstruct [
    :asset,
    :partition,
    :run_id,
    :resources,  # NEW: Map of name => resource
    :metadata,
    :started_at
  ]

  def build(asset, partition, run_id) do
    # Load only resources declared in asset.requires
    required_resources = FlowStone.Asset.requires(asset)
    all_resources = FlowStone.Resources.load()

    resources =
      required_resources
      |> Enum.map(fn name -> {name, Map.get(all_resources, name)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    %__MODULE__{
      asset: asset,
      partition: partition,
      run_id: run_id,
      resources: resources,
      started_at: DateTime.utc_now()
    }
  end
end
```

### 4. Update Asset Struct

```elixir
# Add to lib/flowstone/asset.ex
defmodule FlowStone.Asset do
  defstruct [
    # ... existing fields ...
    :requires  # NEW: List of required resource names
  ]
end
```

### 5. Create Example Resource Implementations

```elixir
# lib/flowstone/resources/database.ex
defmodule FlowStone.Resources.Database do
  use FlowStone.Resource

  def setup(config)
  def teardown(pool)
  def health_check(pool)
end

# lib/flowstone/resources/ml_client.ex
defmodule FlowStone.Resources.MLClient do
  use FlowStone.Resource

  def setup(config)
  def health_check(client)
end

# lib/flowstone/resources/api_key.ex
defmodule FlowStone.Resources.APIKey do
  use FlowStone.Resource

  def setup(config)
end
```

### 6. Add DSL Support

```elixir
# Add to lib/flowstone/pipeline.ex
defmodule FlowStone.Pipeline do
  defmacro requires(resource_names) do
    # Add resource requirements to asset definition
  end
end
```

### 7. Create Configuration Resolver

```elixir
# Add to lib/flowstone/resources.ex (private)
defp resolve_config(config) when is_map(config) do
  # Recursively resolve {:system, "ENV_VAR"} tuples
end
```

## Test Design with Supertester

### Test File Structure

```
test/
├── flowstone/
│   ├── resource_test.exs
│   ├── resources_test.exs
│   ├── context_test.exs
│   └── resources/
│       ├── database_test.exs
│       ├── ml_client_test.exs
│       └── api_key_test.exs
└── support/
    ├── mock_resources.ex
    └── test_resources.ex
```

### Test Cases

#### Resource Behaviour Tests

```elixir
defmodule FlowStone.ResourceTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "using FlowStone.Resource" do
    test "provides default teardown implementation" do
      defmodule MinimalResource do
        use FlowStone.Resource

        def setup(_config), do: {:ok, :resource}
      end

      assert :ok = MinimalResource.teardown(:resource)
    end

    test "provides default health_check implementation" do
      defmodule HealthyResource do
        use FlowStone.Resource

        def setup(_config), do: {:ok, :resource}
      end

      assert :healthy = HealthyResource.health_check(:resource)
    end

    test "allows overriding default implementations" do
      defmodule CustomResource do
        use FlowStone.Resource

        def setup(_config), do: {:ok, :custom}

        def teardown(resource) do
          send(self(), {:teardown, resource})
          :ok
        end

        def health_check(_resource), do: {:unhealthy, :always_sick}
      end

      assert :ok = CustomResource.teardown(:test)
      assert_receive {:teardown, :test}

      assert {:unhealthy, :always_sick} = CustomResource.health_check(:test)
    end
  end
end
```

#### Resources GenServer Tests

```elixir
defmodule FlowStone.ResourcesTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers
  import Supertester.Assertions

  alias FlowStone.Resources

  describe "initialization" do
    test "starts with empty resources when no config" do
      {:ok, manager} = setup_isolated_genserver(Resources, [])

      assert_genserver_state(manager, fn state ->
        state.resources == %{}
      end)
    end

    test "initializes resources from application config" do
      config = %{
        database: {MockDatabase, %{host: "localhost"}},
        api_key: {MockAPIKey, %{key: "test123"}}
      }

      {:ok, manager} = setup_isolated_genserver(Resources, config)

      assert_genserver_state(manager, fn state ->
        Map.has_key?(state.resources, :database) and
        Map.has_key?(state.resources, :api_key)
      end)
    end

    test "resolves {:system, env_var} in config" do
      System.put_env("TEST_DB_HOST", "db.example.com")
      System.put_env("TEST_API_KEY", "secret123")

      config = %{
        database: {MockDatabase, %{
          host: {:system, "TEST_DB_HOST"},
          port: 5432
        }},
        api: {MockAPIKey, %{
          key: {:system, "TEST_API_KEY"}
        }}
      }

      {:ok, manager} = setup_isolated_genserver(Resources, config)

      # Verify resolved config was passed to resource setup
      assert_receive {:mock_database_setup, resolved_config}
      assert resolved_config.host == "db.example.com"
      assert resolved_config.port == 5432

      assert_receive {:mock_api_setup, resolved_config}
      assert resolved_config.key == "secret123"
    end

    test "skips resources that fail to initialize" do
      config = %{
        working: {MockResource, %{value: :ok}},
        failing: {FailingResource, %{}}
      }

      {:ok, manager} = setup_isolated_genserver(Resources, config)

      assert_genserver_state(manager, fn state ->
        Map.has_key?(state.resources, :working) and
        not Map.has_key?(state.resources, :failing)
      end)
    end
  end

  describe "get/1" do
    test "retrieves existing resource" do
      config = %{
        test_resource: {MockResource, %{value: 42}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      assert {:ok, resource} = GenServer.call(manager, {:get, :test_resource})
      assert resource.value == 42
    end

    test "returns error for nonexistent resource" do
      {:ok, manager} = setup_isolated_genserver(Resources, %{})

      assert {:error, :not_found} = GenServer.call(manager, {:get, :nonexistent})
    end
  end

  describe "load/0" do
    test "returns all resources as map" do
      config = %{
        db: {MockDatabase, %{}},
        api: {MockAPIKey, %{}},
        ml: {MockMLClient, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      loaded = GenServer.call(manager, :load_all)

      assert is_map(loaded)
      assert Map.has_key?(loaded, :db)
      assert Map.has_key?(loaded, :api)
      assert Map.has_key?(loaded, :ml)
    end

    test "returns empty map when no resources" do
      {:ok, manager} = setup_isolated_genserver(Resources, %{})

      loaded = GenServer.call(manager, :load_all)
      assert loaded == %{}
    end
  end

  describe "health/0" do
    test "returns health status for all resources" do
      config = %{
        healthy: {HealthyResource, %{}},
        unhealthy: {UnhealthyResource, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      health = GenServer.call(manager, :health)

      assert health.healthy == :healthy
      assert {:unhealthy, _reason} = health.unhealthy
    end

    test "calls health_check on each resource" do
      config = %{
        check_me: {SpyResource, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      GenServer.call(manager, :health)

      assert_receive {:health_check_called, :check_me}
    end
  end

  describe "periodic health checks" do
    test "runs health checks on interval" do
      config = %{
        monitored: {SpyResource, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      # Should receive initial health check
      assert_receive {:health_check_called, :monitored}, 100

      # Should receive periodic health check
      assert_receive {:health_check_called, :monitored}, 35_000
    end

    test "updates healthy status in state" do
      config = %{
        flaky: {FlakyResource, %{healthy: true}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      # Initially healthy
      assert_genserver_state(manager, fn state ->
        state.resources.flaky.healthy == true
      end)

      # Make it unhealthy
      FlakyResource.set_health(:unhealthy)
      send(manager, :health_check)
      Process.sleep(50)

      # State should update
      assert_genserver_state(manager, fn state ->
        state.resources.flaky.healthy == false
      end)
    end
  end

  describe "override/1 for testing" do
    test "replaces resources with mocks" do
      config = %{
        prod_db: {RealDatabase, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      mock_resources = %{
        prod_db: %MockDatabase{},
        test_api: %MockAPI{}
      }

      :ok = GenServer.call(manager, {:override, mock_resources})

      loaded = GenServer.call(manager, :load_all)
      assert %MockDatabase{} = loaded.prod_db
      assert %MockAPI{} = loaded.test_api
    end

    test "reset/0 restores original resources" do
      config = %{
        original: {OriginalResource, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      # Override
      GenServer.call(manager, {:override, %{original: :mocked}})
      loaded = GenServer.call(manager, :load_all)
      assert loaded.original == :mocked

      # Reset
      :ok = GenServer.call(manager, :reset)
      loaded = GenServer.call(manager, :load_all)
      assert is_struct(loaded.original)
    end
  end

  describe "concurrent access" do
    test "handles concurrent get requests" do
      config = %{
        shared: {MockResource, %{value: :shared}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      scenario = Supertester.ConcurrentHarness.simple_genserver_scenario(
        Resources,
        Enum.map(1..100, fn _ -> {:call, {:get, :shared}} end),
        10,  # 10 concurrent threads
        setup: fn -> {:ok, manager, %{}} end,
        cleanup: fn _, _ -> :ok end
      )

      assert {:ok, report} = Supertester.ConcurrentHarness.run(scenario)
      assert report.metrics.total_operations == 100
      assert report.metrics.errors == 0
    end

    test "handles concurrent load_all requests" do
      config = %{
        r1: {MockResource, %{}},
        r2: {MockResource, %{}},
        r3: {MockResource, %{}}
      }
      {:ok, manager} = setup_isolated_genserver(Resources, config)

      tasks = for _ <- 1..50 do
        Task.async(fn -> GenServer.call(manager, :load_all) end)
      end

      results = Task.await_many(tasks)

      # All should return same 3 resources
      assert Enum.all?(results, fn loaded ->
        Map.keys(loaded) |> Enum.sort() == [:r1, :r2, :r3]
      end)
    end
  end
end
```

#### Context with Resources Tests

```elixir
defmodule FlowStone.ContextTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Context

  setup do
    # Setup resource manager with test resources
    config = %{
      database: {MockDatabase, %{host: "test"}},
      ml_client: {MockMLClient, %{endpoint: "http://test"}},
      api_key: {MockAPIKey, %{key: "secret"}}
    }

    {:ok, _manager} = FlowStone.Resources.start_link(config)

    :ok
  end

  describe "build/3 with resource injection" do
    test "includes only required resources" do
      asset = %FlowStone.Asset{
        name: :my_asset,
        requires: [:database, :ml_client],
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      context = Context.build(asset, ~D[2025-01-15], "run-123")

      assert Map.has_key?(context.resources, :database)
      assert Map.has_key?(context.resources, :ml_client)
      refute Map.has_key?(context.resources, :api_key)
    end

    test "excludes resources not in requires list" do
      asset = %FlowStone.Asset{
        name: :minimal_asset,
        requires: [],
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      context = Context.build(asset, ~D[2025-01-15], "run-123")

      assert context.resources == %{}
    end

    test "handles missing resources gracefully" do
      asset = %FlowStone.Asset{
        name: :needs_missing,
        requires: [:database, :nonexistent_resource],
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      context = Context.build(asset, ~D[2025-01-15], "run-123")

      # Only includes available resources
      assert Map.has_key?(context.resources, :database)
      refute Map.has_key?(context.resources, :nonexistent_resource)
    end

    test "sets all other context fields correctly" do
      asset = %FlowStone.Asset{
        name: :test_asset,
        requires: [],
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      context = Context.build(asset, ~D[2025-01-15], "run-456")

      assert context.asset == asset
      assert context.partition == ~D[2025-01-15]
      assert context.run_id == "run-456"
      assert %DateTime{} = context.started_at
    end
  end

  describe "resource usage in asset execution" do
    test "asset can access injected resources" do
      asset = %FlowStone.Asset{
        name: :db_asset,
        requires: [:database],
        execute_fn: fn context, _deps ->
          db = context.resources.database
          {:ok, MockDatabase.query(db, "SELECT 1")}
        end
      }

      context = Context.build(asset, ~D[2025-01-15], "run-123")

      assert {:ok, result} = asset.execute_fn.(context, %{})
      assert result == [%{column: 1}]
    end

    test "asset with multiple resources" do
      asset = %FlowStone.Asset{
        name: :ml_predictions,
        requires: [:database, :ml_client],
        execute_fn: fn context, _deps ->
          %{database: db, ml_client: client} = context.resources

          features = MockDatabase.query(db, "SELECT features FROM data")
          predictions = MockMLClient.predict(client, features)

          {:ok, predictions}
        end
      }

      context = Context.build(asset, ~D[2025-01-15], "run-123")

      assert {:ok, predictions} = asset.execute_fn.(context, %{})
      assert is_list(predictions)
    end
  end
end
```

#### Database Resource Implementation Tests

```elixir
defmodule FlowStone.Resources.DatabaseTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Resources.Database

  describe "setup/1" do
    test "establishes database connection pool" do
      config = %{
        database: "flowstone_test",
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        pool_size: 5
      }

      assert {:ok, pool} = Database.setup(config)
      assert is_pid(pool)
      assert Process.alive?(pool)
    end

    test "returns error for invalid credentials" do
      config = %{
        database: "nonexistent",
        username: "baduser",
        password: "wrong",
        hostname: "localhost"
      }

      assert {:error, reason} = Database.setup(config)
      assert is_binary(reason) or is_atom(reason)
    end

    test "uses default pool size when not specified" do
      config = %{
        database: "flowstone_test",
        hostname: "localhost"
      }

      {:ok, pool} = Database.setup(config)

      # Verify pool size via metadata (implementation-specific)
      assert Database.pool_size(pool) == 10  # default
    end
  end

  describe "teardown/1" do
    test "closes connection pool" do
      config = %{database: "flowstone_test", hostname: "localhost"}
      {:ok, pool} = Database.setup(config)

      assert :ok = Database.teardown(pool)
      refute Process.alive?(pool)
    end
  end

  describe "health_check/1" do
    test "returns healthy for working connection" do
      config = %{database: "flowstone_test", hostname: "localhost"}
      {:ok, pool} = Database.setup(config)

      assert :healthy = Database.health_check(pool)
    end

    test "returns unhealthy when connection lost" do
      config = %{database: "flowstone_test", hostname: "localhost"}
      {:ok, pool} = Database.setup(config)

      # Simulate connection failure
      GenServer.stop(pool)

      assert {:unhealthy, _reason} = Database.health_check(pool)
    end
  end
end
```

#### ML Client Resource Tests

```elixir
defmodule FlowStone.Resources.MLClientTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Resources.MLClient

  describe "setup/1" do
    test "creates client configuration" do
      config = %{
        endpoint: "http://ml-service:5000",
        timeout: :timer.minutes(2),
        api_key: "test-key"
      }

      assert {:ok, client} = MLClient.setup(config)
      assert client.endpoint == "http://ml-service:5000"
      assert client.timeout == 120_000
      assert client.api_key == "test-key"
    end

    test "uses default timeout when not specified" do
      config = %{endpoint: "http://ml-service:5000"}

      {:ok, client} = MLClient.setup(config)
      assert client.timeout == :timer.minutes(5)
    end
  end

  describe "health_check/1" do
    test "returns healthy when service responds 200" do
      client = %{endpoint: "http://ml-test:5000"}

      MockReq.expect_get("http://ml-test:5000/health", 200)

      assert :healthy = MLClient.health_check(client)
    end

    test "returns unhealthy for non-200 status" do
      client = %{endpoint: "http://ml-test:5000"}

      MockReq.expect_get("http://ml-test:5000/health", 503)

      assert {:unhealthy, {:status, 503}} = MLClient.health_check(client)
    end

    test "returns unhealthy on network error" do
      client = %{endpoint: "http://unreachable:5000"}

      MockReq.expect_error(:timeout)

      assert {:unhealthy, :timeout} = MLClient.health_check(client)
    end
  end
end
```

#### DSL Integration Tests

```elixir
defmodule FlowStone.ResourceDSLTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "requires macro" do
    test "declares resource dependencies" do
      defmodule PipelineWithResources do
        use FlowStone.Pipeline

        asset :ml_predictions do
          requires [:database, :ml_client]

          execute fn context, _deps ->
            %{database: db, ml_client: client} = context.resources
            {:ok, predict_with(db, client)}
          end
        end
      end

      assets = PipelineWithResources.__flowstone_assets__()
      asset = hd(assets)

      assert asset.requires == [:database, :ml_client]
    end

    test "validates required resources exist at compile time" do
      assert_raise CompileError, fn ->
        defmodule BadResourcePipeline do
          use FlowStone.Pipeline

          asset :bad do
            requires [:nonexistent_resource]
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end
  end
end
```

#### Integration Tests with Asset Execution

```elixir
defmodule FlowStone.AssetResourceIntegrationTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  setup do
    # Start resource manager with test resources
    config = %{
      database: {TestDatabase, %{name: "test_db"}},
      api_key: {TestAPIKey, %{key: "test123"}}
    }

    {:ok, _} = FlowStone.Resources.start_link(config)

    :ok
  end

  describe "asset execution with resources" do
    test "materializes asset with injected resources" do
      asset = %FlowStone.Asset{
        name: :test_asset,
        requires: [:database],
        execute_fn: fn context, _deps ->
          db = context.resources.database
          data = TestDatabase.fetch_data(db)
          {:ok, data}
        end
      }

      FlowStone.Asset.Registry.register(asset)

      assert {:ok, result} = FlowStone.materialize(:test_asset, partition: ~D[2025-01-15])
      assert is_list(result)
    end

    test "fails when required resource unavailable" do
      asset = %FlowStone.Asset{
        name: :needs_missing,
        requires: [:database, :missing_resource],
        execute_fn: fn context, _deps ->
          # Will error if missing_resource not present
          context.resources.missing_resource.call()
        end
      }

      FlowStone.Asset.Registry.register(asset)

      assert {:error, %FlowStone.Error{type: :resource_unavailable}} =
        FlowStone.materialize(:needs_missing, partition: ~D[2025-01-15])
    end
  end

  describe "resource override in tests" do
    test "uses mock resources for testing" do
      # Define asset that uses database
      asset = %FlowStone.Asset{
        name: :query_asset,
        requires: [:database],
        execute_fn: fn context, _deps ->
          db = context.resources.database
          {:ok, TestDatabase.query(db, "SELECT count(*)")}
        end
      }

      FlowStone.Asset.Registry.register(asset)

      # Override with mock
      mock_db = MockDatabase.new(query_results: [[42]])
      FlowStone.Resources.override(%{database: mock_db})

      assert {:ok, [[42]]} = FlowStone.materialize(:query_asset, partition: ~D[2025-01-15])

      # Reset
      FlowStone.Resources.reset()
    end
  end
end
```

#### Chaos Tests with ChaosHelpers

```elixir
defmodule FlowStone.Resources.ChaosTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.ChaosHelpers

  describe "resource failure scenarios" do
    test "handles resource crashes during health check" do
      config = %{
        crashy: {CrashyResource, %{}}
      }
      {:ok, manager} = FlowStone.Resources.start_link(config)

      # Inject random crashes during health checks
      with_chaos(crash_probability: 0.3) do
        for _ <- 1..10 do
          GenServer.call(manager, :health)
          Process.sleep(50)
        end
      end

      # Manager should still be alive
      assert Process.alive?(manager)
    end

    test "recovers from transient resource failures" do
      config = %{
        flaky: {FlakyResource, %{fail_rate: 0.5}}
      }
      {:ok, manager} = FlowStone.Resources.start_link(config)

      health_results = for _ <- 1..20 do
        GenServer.call(manager, :health)
      end

      # Should have mix of healthy and unhealthy
      healthy_count = Enum.count(health_results, fn h ->
        h.flaky == :healthy
      end)

      assert healthy_count > 0
      assert healthy_count < 20
    end
  end
end
```

## Supertester Integration Principles

### 1. Use Isolation Modes
```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. Use `setup_isolated_genserver/1` for Resources Manager
```elixir
{:ok, manager} = setup_isolated_genserver(FlowStone.Resources, config)
```

### 3. Use `assert_genserver_state/2` for State Verification
```elixir
assert_genserver_state(manager, fn state ->
  Map.has_key?(state.resources, :database)
end)
```

### 4. Use ConcurrentHarness for Concurrent Resource Access
```elixir
scenario = ConcurrentHarness.simple_genserver_scenario(...)
{:ok, report} = ConcurrentHarness.run(scenario)
```

### 5. Use ChaosHelpers for Failure Testing
```elixir
with_chaos(crash_probability: 0.3) do
  # Test resource resilience
end
```

## Implementation Order

1. **FlowStone.Resource behaviour** - Define callbacks and using macro
2. **FlowStone.Resources GenServer** - Resource lifecycle manager
3. **Configuration resolver** - Handle {:system, "ENV"} resolution
4. **Context.build/3 updates** - Inject resources into context
5. **Asset.requires field** - Add resource requirements to assets
6. **requires/1 DSL macro** - Pipeline DSL support
7. **Example resources** - Database, MLClient, APIKey implementations
8. **Test infrastructure** - Mock resources and test helpers

## Success Criteria

- [ ] All tests pass with `async: true`
- [ ] Zero `Process.sleep` calls (except timed health checks)
- [ ] 100% test coverage for Resources GenServer
- [ ] Resources survive GenServer crashes and restarts
- [ ] Health checks run periodically without blocking
- [ ] Mock resources easy to create and use in tests
- [ ] Dialyzer passes with no warnings
- [ ] Credo passes with no issues
- [ ] Documentation for Resource behaviour and all example resources
- [ ] At least 3 example resource implementations

## Commands

```bash
# Run all resource tests
mix test test/flowstone/resource_test.exs test/flowstone/resources_test.exs test/flowstone/resources/

# Run with coverage
mix coveralls.html --umbrella

# Test specific resource implementation
mix test test/flowstone/resources/database_test.exs

# Test integration with assets
mix test test/flowstone/asset_resource_integration_test.exs

# Check concurrency tests
mix test --only concurrent

# Check chaos tests
mix test --only chaos

# Check types
mix dialyzer

# Check style
mix credo --strict
```

## Spawn Subagents

For parallel implementation, spawn subagents for:

1. **Resource Behaviour + Using Macro** - Core behaviour definition
2. **Resources GenServer** - Lifecycle management and health checks
3. **Configuration Resolver** - Environment variable resolution
4. **Example Resources** - Database, MLClient, APIKey implementations
5. **Context Integration** - Resource injection into execution context
6. **DSL Support** - requires/1 macro and compile-time validation
7. **Test Infrastructure** - Mock resources, test helpers, integration tests

Each subagent should follow TDD: write tests first using Supertester, then implement.

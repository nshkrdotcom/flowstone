# Implementation Prompt: ADR-0001 Asset-First Orchestration

## Objective

Implement the core asset-first orchestration model for FlowStone using TDD with Supertester.

## Required Reading

Before starting, read these documents thoroughly:

1. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md` - The architecture decision
2. **Design Overview**: `docs/design/OVERVIEW.md` - High-level architecture
3. **Supertester Manual**: https://hexdocs.pm/supertester - Testing framework

## Context

FlowStone adopts an asset-first orchestration model where:
- Assets are persistent, versioned data artifacts (the primary abstraction)
- The DAG is derived from asset dependencies (not explicit step ordering)
- Materialization is the unit of execution (computing + storing for a partition)
- Lineage is first-class (every materialization records its inputs)

This ADR establishes the foundational data structures and DSL.

## Implementation Tasks

### 1. Create Core Data Structures

```elixir
# lib/flowstone/asset.ex
defmodule FlowStone.Asset do
  @type t :: %__MODULE__{
    name: atom(),
    description: String.t() | nil,
    depends_on: [atom()],
    io_manager: atom(),
    io_config: map(),
    partitioned_by: :date | :datetime | :custom | nil,
    partition_fn: (map() -> [term()]) | nil,
    execute_fn: (Context.t(), map() -> {:ok, term()} | {:error, term()}),
    requires: [atom()],
    metadata: map(),
    tags: [String.t()],
    module: module(),
    line: integer()
  }
end
```

### 2. Create the Pipeline DSL

```elixir
# lib/flowstone/pipeline.ex
defmodule FlowStone.Pipeline do
  defmacro __using__(_opts) do
    # Setup module attributes, imports, before_compile hook
  end

  defmacro asset(name, do: block) do
    # Build asset struct from DSL block
  end

  defmacro depends_on(deps)
  defmacro io_manager(manager)
  defmacro execute(fun)
  # ... other DSL macros
end
```

### 3. Create Asset Registry

```elixir
# lib/flowstone/asset/registry.ex
defmodule FlowStone.Asset.Registry do
  use GenServer
  # Store and retrieve asset definitions
  # Support compile-time and runtime registration
end
```

### 4. Create Asset Validator

```elixir
# lib/flowstone/asset/validator.ex
defmodule FlowStone.Asset.Validator do
  def validate(asset_definition) :: :ok | {:error, [error]}
  # Validate name, dependencies, io_manager, execute_fn
end
```

## Test Design with Supertester

### Test File Structure

```
test/
├── flowstone/
│   ├── asset_test.exs
│   ├── pipeline_test.exs
│   └── asset/
│       ├── registry_test.exs
│       └── validator_test.exs
└── support/
    ├── test_pipelines.ex
    └── fixtures.ex
```

### Test Cases

#### Asset Struct Tests

```elixir
defmodule FlowStone.AssetTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.Assertions

  describe "Asset struct" do
    test "creates valid asset with all fields" do
      asset = %FlowStone.Asset{
        name: :test_asset,
        depends_on: [:upstream],
        io_manager: :memory,
        execute_fn: fn _, _ -> {:ok, :result} end
      }

      assert asset.name == :test_asset
      assert asset.depends_on == [:upstream]
    end

    test "defaults are applied correctly" do
      asset = %FlowStone.Asset{name: :minimal}
      assert asset.depends_on == []
      assert asset.metadata == %{}
    end
  end
end
```

#### Pipeline DSL Tests

```elixir
defmodule FlowStone.PipelineTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "asset/2 macro" do
    test "defines asset with basic properties" do
      defmodule TestPipeline do
        use FlowStone.Pipeline

        asset :simple_asset do
          description "A test asset"
          io_manager :memory

          execute fn _ctx, _deps ->
            {:ok, :computed}
          end
        end
      end

      assets = TestPipeline.__flowstone_assets__()
      assert length(assets) == 1
      assert hd(assets).name == :simple_asset
    end

    test "compiles dependencies correctly" do
      defmodule DepPipeline do
        use FlowStone.Pipeline

        asset :source do
          execute fn _, _ -> {:ok, :source_data} end
        end

        asset :derived do
          depends_on [:source]
          execute fn _, %{source: data} -> {:ok, {:derived, data}} end
        end
      end

      assets = DepPipeline.__flowstone_assets__()
      derived = Enum.find(assets, &(&1.name == :derived))
      assert derived.depends_on == [:source]
    end

    test "raises compile error for invalid dependencies" do
      assert_raise CompileError, fn ->
        defmodule BadDeps do
          use FlowStone.Pipeline

          asset :bad do
            depends_on ["string_not_atom"]
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end
  end
end
```

#### Registry Tests with Supertester OTP Helpers

```elixir
defmodule FlowStone.Asset.RegistryTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers
  import Supertester.Assertions

  describe "Registry GenServer" do
    test "starts and registers assets" do
      {:ok, registry} = setup_isolated_genserver(FlowStone.Asset.Registry)

      asset = %FlowStone.Asset{name: :test, execute_fn: fn _, _ -> {:ok, nil} end}

      :ok = cast_and_sync(registry, {:register, asset})

      assert_genserver_state(registry, fn state ->
        Map.has_key?(state.assets, :test)
      end)
    end

    test "retrieves registered asset" do
      {:ok, registry} = setup_isolated_genserver(FlowStone.Asset.Registry)

      asset = %FlowStone.Asset{name: :lookup_test, execute_fn: fn _, _ -> {:ok, nil} end}
      :ok = cast_and_sync(registry, {:register, asset})

      result = GenServer.call(registry, {:get, :lookup_test})
      assert {:ok, ^asset} = result
    end

    test "returns error for unknown asset" do
      {:ok, registry} = setup_isolated_genserver(FlowStone.Asset.Registry)

      result = GenServer.call(registry, {:get, :nonexistent})
      assert {:error, :not_found} = result
    end

    test "lists all registered assets" do
      {:ok, registry} = setup_isolated_genserver(FlowStone.Asset.Registry)

      assets = for i <- 1..5 do
        %FlowStone.Asset{name: :"asset_#{i}", execute_fn: fn _, _ -> {:ok, nil} end}
      end

      for asset <- assets do
        :ok = cast_and_sync(registry, {:register, asset})
      end

      all = GenServer.call(registry, :list_all)
      assert length(all) == 5
    end
  end

  describe "concurrent access" do
    test "handles concurrent registrations safely" do
      {:ok, registry} = setup_isolated_genserver(FlowStone.Asset.Registry)

      scenario = Supertester.ConcurrentHarness.simple_genserver_scenario(
        FlowStone.Asset.Registry,
        Enum.map(1..10, fn i ->
          {:cast, {:register, %FlowStone.Asset{name: :"concurrent_#{i}", execute_fn: fn _, _ -> {:ok, nil} end}}}
        end),
        5,  # 5 concurrent threads
        setup: fn -> {:ok, registry, %{}} end,
        cleanup: fn _, _ -> :ok end
      )

      assert {:ok, report} = Supertester.ConcurrentHarness.run(scenario)
      assert report.metrics.total_operations == 10
    end
  end
end
```

#### Validator Tests

```elixir
defmodule FlowStone.Asset.ValidatorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Asset.Validator

  describe "validate/1" do
    test "accepts valid asset" do
      asset = %FlowStone.Asset{
        name: :valid,
        depends_on: [:other],
        io_manager: :memory,
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      assert :ok = Validator.validate(asset)
    end

    test "rejects nil name" do
      asset = %FlowStone.Asset{name: nil}
      assert {:error, errors} = Validator.validate(asset)
      assert {:name, _} in errors
    end

    test "rejects non-atom dependencies" do
      asset = %FlowStone.Asset{
        name: :test,
        depends_on: ["string"],
        execute_fn: fn _, _ -> {:ok, nil} end
      }

      assert {:error, errors} = Validator.validate(asset)
      assert {:depends_on, _} in errors
    end

    test "rejects missing execute function" do
      asset = %FlowStone.Asset{name: :no_exec}
      assert {:error, errors} = Validator.validate(asset)
      assert {:execute, _} in errors
    end

    test "rejects wrong arity execute function" do
      asset = %FlowStone.Asset{
        name: :wrong_arity,
        execute_fn: fn _ -> {:ok, nil} end  # arity 1, should be 2
      }

      assert {:error, errors} = Validator.validate(asset)
      assert {:execute, _} in errors
    end
  end
end
```

## Supertester Integration Principles

### 1. Use Isolation Modes

```elixir
# Full isolation for all tests
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. Use `cast_and_sync/2` for Async Operations

```elixir
# Instead of Process.sleep after a cast:
:ok = cast_and_sync(pid, {:register, asset})
```

### 3. Use `assert_genserver_state/2` for State Assertions

```elixir
# Instead of GenServer.call to fetch state:
assert_genserver_state(pid, fn state -> condition(state) end)
```

### 4. Use `setup_isolated_genserver/1` for Process Lifecycle

```elixir
# Automatic cleanup, no name conflicts:
{:ok, pid} = setup_isolated_genserver(MyGenServer)
```

### 5. Use ConcurrentHarness for Concurrency Tests

```elixir
scenario = Supertester.ConcurrentHarness.simple_genserver_scenario(...)
{:ok, report} = Supertester.ConcurrentHarness.run(scenario)
```

## Implementation Order

1. **FlowStone.Asset struct** - Define the core data structure
2. **FlowStone.Asset.Validator** - Validate asset definitions
3. **FlowStone.Asset.Registry** - GenServer for storing assets
4. **FlowStone.Pipeline macros** - DSL for defining assets
5. **Compile-time validation** - Hook into `@before_compile`

## Success Criteria

- [ ] All tests pass with `async: true`
- [ ] Zero `Process.sleep` calls
- [ ] 100% test coverage for new modules
- [ ] Dialyzer passes with no warnings
- [ ] Credo passes with no issues
- [ ] Documentation for all public functions

## Commands

```bash
# Run tests
mix test test/flowstone/asset_test.exs test/flowstone/pipeline_test.exs

# Run with coverage
mix coveralls.html

# Check types
mix dialyzer

# Check style
mix credo --strict
```

## Spawn Subagents

For parallel implementation, spawn subagents for:

1. **Asset struct + Validator** - Core data structures
2. **Registry GenServer** - Process management
3. **Pipeline DSL** - Macro implementation
4. **Test suite** - Comprehensive test coverage

Each subagent should follow TDD: write tests first, then implement.

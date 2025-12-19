# FlowStone v0.5.0 UX Redesign Implementation Prompt

**For: Autonomous Agent**
**Date:** 2025-12-18
**Target Version:** 0.5.0
**Success Criteria:** All tests pass, zero warnings, zero dialyzer errors

---

## MISSION

Implement the FlowStone v0.5.0 UX redesign as specified in the design documents. This involves creating a new simplified API layer, configuration system, DSL improvements, and comprehensive documentation while maintaining full backward compatibility with the existing API.

---

## PHASE 0: CONTEXT GATHERING

### Required Reading (In Order)

You MUST read and understand these files before writing any code:

#### Design Documents (Read First)
```
docs/20251218/ux-redesign/00-summary.md
docs/20251218/ux-redesign/01-current-problems.md
docs/20251218/ux-redesign/02-api-design.md
docs/20251218/ux-redesign/03-configuration.md
docs/20251218/ux-redesign/04-progressive-complexity.md
docs/20251218/ux-redesign/05-dsl-improvements.md
docs/20251218/ux-redesign/06-flowstone-ai-integration.md
docs/20251218/ux-redesign/07-migration-guide.md
docs/20251218/ux-redesign/08-examples.md
```

#### Current Implementation (Read to Understand Existing Code)
```
lib/flowstone.ex                           # Main API module
lib/flowstone/pipeline.ex                  # Pipeline DSL
lib/flowstone/asset.ex                     # Asset struct
lib/flowstone/executor.ex                  # Execution orchestration
lib/flowstone/materializer.ex              # Asset execution
lib/flowstone/context.ex                   # Runtime context
lib/flowstone/io.ex                        # IO dispatch
lib/flowstone/io/manager.ex                # IO behavior
lib/flowstone/io/memory.ex                 # Memory implementation
lib/flowstone/io/postgres.ex               # Postgres implementation
lib/flowstone/scatter.ex                   # Scatter orchestration
lib/flowstone/scatter/item_reader.ex       # ItemReader behavior
lib/flowstone/parallel.ex                  # Parallel branches
lib/flowstone/registry.ex                  # Asset registry
lib/flowstone/resources.ex                 # Resource registry
lib/flowstone/resource.ex                  # Resource behavior
lib/flowstone/application.ex               # Supervision tree
lib/flowstone/run_config.ex                # Runtime config
lib/flowstone/error.ex                     # Error types
```

#### Configuration Files
```
config/config.exs
config/dev.exs
config/test.exs
mix.exs
```

#### Existing Tests (Understand Test Patterns)
```
test/flowstone_test.exs
test/flowstone/pipeline_test.exs
test/flowstone/executor_test.exs
test/flowstone/materializer_test.exs
test/flowstone/io_test.exs
test/flowstone/scatter_test.exs
test/support/                              # Test helpers
```

#### flowstone_ai (Separate Package)
```
../flowstone_ai/lib/flowstone_ai.ex
../flowstone_ai/lib/flowstone/ai/resource.ex
../flowstone_ai/lib/flowstone/ai/assets.ex
../flowstone_ai/lib/flowstone/ai/telemetry.ex
```

---

## PHASE 1: NEW API LAYER (TDD)

### 1.1 Create FlowStone.run/2-3

**File:** `lib/flowstone/api.ex` (new file)

**Tests First:** `test/flowstone/api_test.exs`

```elixir
defmodule FlowStone.APITest do
  use ExUnit.Case, async: true

  defmodule TestPipeline do
    use FlowStone.Pipeline
    asset :greeting, do: {:ok, "Hello"}
    asset :doubled do
      depends_on [:greeting]
      execute fn _, %{greeting: g} -> {:ok, g <> g} end
    end
  end

  describe "run/2" do
    test "runs asset synchronously with in-memory storage" do
      assert {:ok, "Hello"} = FlowStone.run(TestPipeline, :greeting)
    end

    test "runs asset with dependencies" do
      assert {:ok, "HelloHello"} = FlowStone.run(TestPipeline, :doubled)
    end

    test "returns error for unknown asset" do
      assert {:error, %FlowStone.Error{type: :asset_not_found}} =
        FlowStone.run(TestPipeline, :unknown)
    end
  end

  describe "run/3 with partition" do
    test "passes partition to context" do
      defmodule PartitionPipeline do
        use FlowStone.Pipeline
        asset :date_asset do
          execute fn ctx, _ -> {:ok, ctx.partition} end
        end
      end

      assert {:ok, ~D[2025-01-15]} =
        FlowStone.run(PartitionPipeline, :date_asset, partition: ~D[2025-01-15])
    end
  end

  describe "run/3 with async: true" do
    # Requires repo configuration - test in integration tests
  end

  describe "run/3 with force: true" do
    test "re-runs even if cached" do
      # Implementation test
    end
  end
end
```

**Implementation Requirements:**
- `FlowStone.run(pipeline, asset)` - sync, in-memory, default partition
- `FlowStone.run(pipeline, asset, opts)` - with options
- Options: `partition`, `async`, `force`, `storage`, `with_deps`, `timeout`
- Auto-registers pipeline if not registered
- Uses configured storage or defaults to memory
- Returns `{:ok, result}` for sync, `{:ok, %Oban.Job{}}` for async
- Proper error types with helpful messages

### 1.2 Create FlowStone.get/2-3

**Tests First:** Add to `test/flowstone/api_test.exs`

```elixir
describe "get/2" do
  test "retrieves previously run asset" do
    {:ok, _} = FlowStone.run(TestPipeline, :greeting)
    assert {:ok, "Hello"} = FlowStone.get(TestPipeline, :greeting)
  end

  test "returns error if not found" do
    assert {:error, :not_found} = FlowStone.get(TestPipeline, :never_run)
  end
end

describe "get/3 with partition" do
  test "retrieves specific partition" do
    {:ok, _} = FlowStone.run(TestPipeline, :greeting, partition: :p1)
    {:ok, _} = FlowStone.run(TestPipeline, :greeting, partition: :p2)

    assert {:ok, "Hello"} = FlowStone.get(TestPipeline, :greeting, partition: :p1)
  end
end
```

### 1.3 Create FlowStone.backfill/3

**Tests First:**

```elixir
describe "backfill/3" do
  test "runs asset for multiple partitions" do
    defmodule BackfillPipeline do
      use FlowStone.Pipeline
      asset :daily do
        execute fn ctx, _ -> {:ok, "data_#{ctx.partition}"} end
      end
    end

    {:ok, stats} = FlowStone.backfill(BackfillPipeline, :daily,
      partitions: [:d1, :d2, :d3]
    )

    assert stats.succeeded == 3
    assert stats.failed == 0
  end

  test "runs in parallel when specified" do
    {:ok, stats} = FlowStone.backfill(BackfillPipeline, :daily,
      partitions: 1..10,
      parallel: 4
    )

    assert stats.succeeded == 10
  end
end
```

### 1.4 Create FlowStone.status/2-3

```elixir
describe "status/2" do
  test "returns status of asset" do
    {:ok, _} = FlowStone.run(TestPipeline, :greeting)

    status = FlowStone.status(TestPipeline, :greeting)
    assert status.state == :completed
    assert status.partition == :default
  end
end
```

### 1.5 Create FlowStone.exists?/2-3

```elixir
describe "exists?/2" do
  test "returns true if asset has been run" do
    refute FlowStone.exists?(TestPipeline, :greeting)
    {:ok, _} = FlowStone.run(TestPipeline, :greeting)
    assert FlowStone.exists?(TestPipeline, :greeting)
  end
end
```

### 1.6 Create FlowStone.invalidate/2-3

```elixir
describe "invalidate/2" do
  test "removes cached result" do
    {:ok, _} = FlowStone.run(TestPipeline, :greeting)
    assert FlowStone.exists?(TestPipeline, :greeting)

    {:ok, 1} = FlowStone.invalidate(TestPipeline, :greeting)
    refute FlowStone.exists?(TestPipeline, :greeting)
  end
end
```

### 1.7 Create FlowStone.graph/1-2

```elixir
describe "graph/1" do
  test "returns ASCII DAG representation" do
    graph = FlowStone.graph(TestPipeline)
    assert graph =~ "greeting"
    assert graph =~ "doubled"
  end
end

describe "graph/2 with format" do
  test "returns mermaid format" do
    graph = FlowStone.graph(TestPipeline, format: :mermaid)
    assert graph =~ "graph TD"
  end
end
```

### 1.8 Update lib/flowstone.ex

Add new API functions that delegate to `FlowStone.API`:

```elixir
defmodule FlowStone do
  # New API (v0.5.0)
  defdelegate run(pipeline, asset), to: FlowStone.API
  defdelegate run(pipeline, asset, opts), to: FlowStone.API
  defdelegate get(pipeline, asset), to: FlowStone.API
  defdelegate get(pipeline, asset, opts), to: FlowStone.API
  defdelegate backfill(pipeline, asset, opts), to: FlowStone.API
  defdelegate status(pipeline, asset), to: FlowStone.API
  defdelegate status(pipeline, asset, opts), to: FlowStone.API
  defdelegate exists?(pipeline, asset), to: FlowStone.API
  defdelegate exists?(pipeline, asset, opts), to: FlowStone.API
  defdelegate invalidate(pipeline, asset), to: FlowStone.API
  defdelegate invalidate(pipeline, asset, opts), to: FlowStone.API
  defdelegate cancel(pipeline, asset), to: FlowStone.API
  defdelegate cancel(pipeline, asset, opts), to: FlowStone.API
  defdelegate graph(pipeline), to: FlowStone.API
  defdelegate graph(pipeline, opts), to: FlowStone.API
  defdelegate assets(pipeline), to: FlowStone.API
  defdelegate asset_info(pipeline, asset), to: FlowStone.API

  # Old API (deprecated, still works)
  @deprecated "Use FlowStone.run/3 instead"
  def materialize(asset, opts \\ []), do: ...

  @deprecated "Pipelines are now auto-registered"
  def register(pipeline, opts \\ []), do: ...
end
```

---

## PHASE 2: CONFIGURATION SYSTEM

### 2.1 Create FlowStone.Config

**File:** `lib/flowstone/config.ex`

**Tests First:** `test/flowstone/config_test.exs`

```elixir
defmodule FlowStone.ConfigTest do
  use ExUnit.Case

  describe "get/0" do
    test "returns default config when nothing configured" do
      config = FlowStone.Config.get()
      assert config.storage == :memory
      assert config.repo == nil
      assert config.async_default == false
    end
  end

  describe "with repo configured" do
    setup do
      Application.put_env(:flowstone, :repo, TestRepo)
      on_exit(fn -> Application.delete_env(:flowstone, :repo) end)
    end

    test "storage defaults to postgres" do
      config = FlowStone.Config.get()
      assert config.storage == :postgres
    end

    test "lineage defaults to true" do
      config = FlowStone.Config.get()
      assert config.lineage == true
    end
  end

  describe "validate!/0" do
    test "raises for invalid storage" do
      Application.put_env(:flowstone, :storage, :invalid)

      assert_raise FlowStone.ConfigError, ~r/Invalid storage/, fn ->
        FlowStone.Config.validate!()
      end
    end

    test "raises for s3 without bucket" do
      Application.put_env(:flowstone, :storage, :s3)

      assert_raise FlowStone.ConfigError, ~r/bucket/, fn ->
        FlowStone.Config.validate!()
      end
    end
  end
end
```

**Implementation:**
- Read from Application env
- Provide sensible defaults
- Infer settings (repo → postgres storage, etc.)
- Validate on access
- Clear error messages

### 2.2 Update FlowStone.Application

Modify supervision tree to:
- Auto-start based on config
- Start Oban if repo configured
- Start registries automatically
- Provide `FlowStone` child spec for user supervision trees

---

## PHASE 3: DSL IMPROVEMENTS

### 3.1 Short-Form Assets

**File:** Update `lib/flowstone/pipeline.ex`

**Tests First:**

```elixir
defmodule FlowStone.Pipeline.ShortFormTest do
  use ExUnit.Case

  describe "one-liner assets" do
    defmodule ShortPipeline do
      use FlowStone.Pipeline

      asset :simple, do: {:ok, "hello"}
      asset :with_fn, do: fn _, _ -> {:ok, "world"} end
    end

    test "simple value works" do
      assert {:ok, "hello"} = FlowStone.run(ShortPipeline, :simple)
    end

    test "function works" do
      assert {:ok, "world"} = FlowStone.run(ShortPipeline, :with_fn)
    end
  end
end
```

### 3.2 Implicit Result Wrapping

**Tests First:**

```elixir
describe "implicit result wrapping" do
  defmodule WrapPipeline do
    use FlowStone.Pipeline, wrap_results: true  # default

    asset :unwrapped do
      execute fn _, _ -> "just a value" end
    end

    asset :explicit_ok do
      execute fn _, _ -> {:ok, "explicit"} end
    end

    asset :explicit_error do
      execute fn _, _ -> {:error, "failed"} end
    end
  end

  test "wraps plain values in {:ok, _}" do
    assert {:ok, "just a value"} = FlowStone.run(WrapPipeline, :unwrapped)
  end

  test "passes through {:ok, _}" do
    assert {:ok, "explicit"} = FlowStone.run(WrapPipeline, :explicit_ok)
  end

  test "passes through {:error, _}" do
    assert {:error, "failed"} = FlowStone.run(WrapPipeline, :explicit_error)
  end
end
```

### 3.3 Pipeline Module Injection

Update `use FlowStone.Pipeline` to inject:

```elixir
def run(asset), do: FlowStone.run(__MODULE__, asset)
def run(asset, opts), do: FlowStone.run(__MODULE__, asset, opts)
def get(asset), do: FlowStone.get(__MODULE__, asset)
def get(asset, opts), do: FlowStone.get(__MODULE__, asset, opts)
def assets(), do: FlowStone.assets(__MODULE__)
def graph(), do: FlowStone.graph(__MODULE__)
```

---

## PHASE 4: ERROR IMPROVEMENTS

### 4.1 Create FlowStone.Error

**File:** `lib/flowstone/error.ex` (update existing)

```elixir
defmodule FlowStone.Error do
  defexception [:message, :type, :details]

  @type t :: %__MODULE__{
    message: String.t(),
    type: error_type(),
    details: map()
  }

  @type error_type ::
    :asset_not_found |
    :dependency_failed |
    :config_error |
    :storage_error |
    :timeout |
    :cancelled |
    :scatter_threshold

  def asset_not_found(pipeline, asset) do
    available = FlowStone.assets(pipeline)
    suggestion = suggest_similar(asset, available)

    %__MODULE__{
      type: :asset_not_found,
      message: """
      Asset #{inspect(asset)} not found in #{inspect(pipeline)}.

      Available assets: #{inspect(available)}
      #{if suggestion, do: "\nDid you mean: #{inspect(suggestion)}?", else: ""}
      """,
      details: %{asset: asset, pipeline: pipeline, available: available}
    }
  end

  def config_error(message, details \\ %{}) do
    %__MODULE__{
      type: :config_error,
      message: message,
      details: details
    }
  end

  # ... more constructors
end
```

---

## PHASE 5: TEST HELPERS

### 5.1 Create FlowStone.Test

**File:** `lib/flowstone/test.ex`

```elixir
defmodule FlowStone.Test do
  @moduledoc """
  Test helpers for FlowStone pipelines.

  ## Usage

      defmodule MyPipelineTest do
        use FlowStone.Test

        test "my asset" do
          {:ok, result} = run_asset(MyPipeline, :asset,
            with_deps: %{upstream: "mocked data"}
          )
          assert result == expected
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import FlowStone.Test

      setup do
        # Start isolated storage for each test
        {:ok, storage} = FlowStone.IO.Memory.start_link([])
        on_exit(fn -> GenServer.stop(storage) end)
        %{storage: storage}
      end
    end
  end

  @doc "Run an asset with optional mocked dependencies"
  def run_asset(pipeline, asset, opts \\ []) do
    with_deps = Keyword.get(opts, :with_deps, %{})
    partition = Keyword.get(opts, :partition, :default)

    # Implementation that mocks dependencies
  end
end
```

**Tests:**

```elixir
defmodule FlowStone.TestTest do
  use FlowStone.Test

  defmodule TestPipeline do
    use FlowStone.Pipeline
    asset :upstream, do: {:ok, "real data"}
    asset :downstream do
      depends_on [:upstream]
      execute fn _, %{upstream: data} -> {:ok, String.upcase(data)} end
    end
  end

  test "run_asset with mocked deps" do
    {:ok, result} = run_asset(TestPipeline, :downstream,
      with_deps: %{upstream: "mocked"}
    )

    assert result == "MOCKED"
  end
end
```

---

## PHASE 6: DOCUMENTATION

### 6.1 Create Guides

Create the following in `guides/`:

**guides/getting-started.md:**
- 5-minute quickstart
- Installation
- First pipeline
- Running assets

**guides/configuration.md:**
- Zero config
- Adding persistence
- Storage backends
- Environment-specific config

**guides/pipelines.md:**
- Defining assets
- Dependencies
- Partitions
- Execution modes

**guides/scatter-gather.md:**
- Fan-out basics
- Batching
- External sources (S3, Postgres, DynamoDB)
- Error handling

**guides/parallel-branches.md:**
- Parallel execution
- Join functions
- Use cases

**guides/routing.md:**
- Conditional routing
- Branch definitions
- Route decisions

**guides/approvals.md:**
- Approval workflows
- Signal gates
- Webhooks

**guides/testing.md:**
- Test helpers
- Mocking dependencies
- Integration tests

**guides/migration-from-0.4.md:**
- API changes
- Config changes
- Deprecations

### 6.2 Update mix.exs

```elixir
def project do
  [
    # ...
    version: "0.5.0",
    docs: [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting-started.md",
        "guides/configuration.md",
        "guides/pipelines.md",
        "guides/scatter-gather.md",
        "guides/parallel-branches.md",
        "guides/routing.md",
        "guides/approvals.md",
        "guides/testing.md",
        "guides/migration-from-0.4.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Core API": [
          FlowStone,
          FlowStone.Pipeline,
          FlowStone.Asset
        ],
        "Storage": [
          FlowStone.IO,
          FlowStone.IO.Manager,
          FlowStone.IO.Memory,
          FlowStone.IO.Postgres,
          FlowStone.IO.S3
        ],
        "Scatter/Gather": [
          FlowStone.Scatter,
          FlowStone.Scatter.ItemReader
        ],
        "Testing": [
          FlowStone.Test
        ]
      ]
    ]
  ]
end
```

### 6.3 Update README.md

Complete rewrite for v0.5.0:

```markdown
# FlowStone

Data pipeline orchestration for Elixir.

## Installation

```elixir
def deps do
  [{:flowstone, "~> 0.5.0"}]
end
```

## Quick Start

```elixir
defmodule MyPipeline do
  use FlowStone.Pipeline

  asset :greeting, do: {:ok, "Hello, World!"}
end

{:ok, "Hello, World!"} = FlowStone.run(MyPipeline, :greeting)
```

## Features

- **Declarative pipelines** - Define assets with dependencies
- **Automatic caching** - Results stored and reused
- **Partitioned data** - Process by date, region, or any key
- **Scatter/gather** - Fan out to process items in parallel
- **Parallel branches** - Run independent work concurrently
- **Conditional routing** - Dynamic branching based on data
- **Approval workflows** - Human-in-the-loop processing
- **Multiple storage backends** - Memory, Postgres, S3, Parquet

## Documentation

- [Getting Started](guides/getting-started.md)
- [Configuration](guides/configuration.md)
- [Full Documentation](https://hexdocs.pm/flowstone)

## License

MIT
```

### 6.4 Create CHANGELOG.md Entry

```markdown
# Changelog

## v0.5.0 (2025-12-18)

### New Features

- **New API**: `FlowStone.run/2-3`, `FlowStone.get/2-3`, `FlowStone.backfill/3`
- **Simplified configuration**: Single `repo:` config unlocks persistence
- **Auto-registration**: Pipelines no longer need manual registration
- **Pipeline methods**: `MyPipeline.run(:asset)` convenience methods
- **Short-form assets**: `asset :name, do: {:ok, value}`
- **Implicit result wrapping**: Plain values wrapped in `{:ok, _}`
- **Test helpers**: `use FlowStone.Test` with `run_asset/3`
- **Better errors**: Structured errors with suggestions

### Deprecations

- `FlowStone.materialize/2` - Use `FlowStone.run/3` instead
- `FlowStone.register/2` - Pipelines are now auto-registered
- `config :flowstone, :io_managers` - Use `config :flowstone, :storage` instead
- `config :flowstone, :start_*` - Services auto-start based on config

### Breaking Changes

None. All existing code continues to work with deprecation warnings.

### Migration

See [Migration Guide](guides/migration-from-0.4.md) for details.
```

---

## PHASE 7: EXAMPLES

### 7.1 Create New Examples

Create in `examples/`:

**examples/01_hello_world.exs:**
```elixir
# The simplest possible FlowStone pipeline
#
# Run: mix run examples/01_hello_world.exs

defmodule HelloPipeline do
  use FlowStone.Pipeline

  asset :greeting, do: {:ok, "Hello, World!"}
end

{:ok, result} = FlowStone.run(HelloPipeline, :greeting)
IO.puts("Result: #{result}")
```

**examples/02_dependencies.exs:**
```elixir
# Pipeline with dependencies
#
# Run: mix run examples/02_dependencies.exs

defmodule TransformPipeline do
  use FlowStone.Pipeline

  asset :numbers, do: {:ok, [1, 2, 3, 4, 5]}

  asset :doubled do
    depends_on [:numbers]
    execute fn _, %{numbers: n} -> {:ok, Enum.map(n, & &1 * 2)} end
  end

  asset :sum do
    depends_on [:doubled]
    execute fn _, %{doubled: n} -> {:ok, Enum.sum(n)} end
  end
end

{:ok, result} = FlowStone.run(TransformPipeline, :sum)
IO.puts("Sum of doubled: #{result}")

IO.puts("\nGraph:")
IO.puts(FlowStone.graph(TransformPipeline))
```

**examples/03_partitions.exs**
**examples/04_scatter_gather.exs**
**examples/05_parallel_branches.exs**
**examples/06_routing.exs**
**examples/07_persistence.exs** (requires postgres)
**examples/08_async_execution.exs** (requires postgres)
**examples/09_testing.exs**

### 7.2 Update examples/README.md

```markdown
# FlowStone Examples

## Running Examples

```bash
# Simple examples (no database needed)
mix run examples/01_hello_world.exs
mix run examples/02_dependencies.exs
mix run examples/03_partitions.exs
mix run examples/04_scatter_gather.exs
mix run examples/05_parallel_branches.exs
mix run examples/06_routing.exs

# Persistence examples (requires postgres)
mix run examples/07_persistence.exs
mix run examples/08_async_execution.exs
```

## Examples Overview

| # | Name | Features | Requires DB |
|---|------|----------|-------------|
| 01 | Hello World | Basic asset | No |
| 02 | Dependencies | Asset dependencies, DAG | No |
| 03 | Partitions | Partitioned data | No |
| 04 | Scatter/Gather | Fan-out processing | No |
| 05 | Parallel Branches | Concurrent execution | No |
| 06 | Routing | Conditional branching | No |
| 07 | Persistence | Postgres storage | Yes |
| 08 | Async Execution | Oban job queue | Yes |
| 09 | Testing | Test helpers | No |
```

### 7.3 Update run_all.exs

```elixir
# Run all examples
# Usage: mix run examples/run_all.exs

examples = [
  "01_hello_world.exs",
  "02_dependencies.exs",
  "03_partitions.exs",
  "04_scatter_gather.exs",
  "05_parallel_branches.exs",
  "06_routing.exs",
  # Skip DB-required examples in basic run
]

for example <- examples do
  IO.puts("\n" <> String.duplicate("=", 60))
  IO.puts("Running: #{example}")
  IO.puts(String.duplicate("=", 60) <> "\n")

  Code.eval_file("examples/#{example}")
end

IO.puts("\n✅ All examples completed successfully!")
```

---

## PHASE 8: FINAL VALIDATION

### 8.1 Run All Tests

```bash
mix test
```

**Expected:** All tests pass

### 8.2 Check Warnings

```bash
mix compile --warnings-as-errors
```

**Expected:** Zero warnings

### 8.3 Run Dialyzer

```bash
mix dialyzer
```

**Expected:** Zero errors

### 8.4 Run Examples

```bash
mix run examples/run_all.exs
```

**Expected:** All examples complete successfully

### 8.5 Generate Docs

```bash
mix docs
```

**Expected:** Docs generate without errors, all links valid

### 8.6 Format Check

```bash
mix format --check-formatted
```

**Expected:** All files formatted

---

## FILE CREATION CHECKLIST

### New Files to Create
- [ ] `lib/flowstone/api.ex`
- [ ] `lib/flowstone/config.ex`
- [ ] `lib/flowstone/test.ex`
- [ ] `test/flowstone/api_test.exs`
- [ ] `test/flowstone/config_test.exs`
- [ ] `test/flowstone/test_test.exs`
- [ ] `guides/getting-started.md`
- [ ] `guides/configuration.md`
- [ ] `guides/pipelines.md`
- [ ] `guides/scatter-gather.md`
- [ ] `guides/parallel-branches.md`
- [ ] `guides/routing.md`
- [ ] `guides/approvals.md`
- [ ] `guides/testing.md`
- [ ] `guides/migration-from-0.4.md`
- [ ] `examples/01_hello_world.exs`
- [ ] `examples/02_dependencies.exs`
- [ ] `examples/03_partitions.exs`
- [ ] `examples/04_scatter_gather.exs`
- [ ] `examples/05_parallel_branches.exs`
- [ ] `examples/06_routing.exs`
- [ ] `examples/07_persistence.exs`
- [ ] `examples/08_async_execution.exs`
- [ ] `examples/09_testing.exs`

### Files to Update
- [ ] `lib/flowstone.ex` - Add new API, deprecate old
- [ ] `lib/flowstone/pipeline.ex` - Short-form, result wrapping, injected methods
- [ ] `lib/flowstone/error.ex` - Structured errors
- [ ] `lib/flowstone/application.ex` - Auto-start services
- [ ] `mix.exs` - Version 0.5.0, docs config
- [ ] `README.md` - Complete rewrite
- [ ] `CHANGELOG.md` - v0.5.0 entry
- [ ] `examples/README.md` - Updated list
- [ ] `examples/run_all.exs` - Updated list
- [ ] `config/config.exs` - Simplified defaults

---

## SUCCESS CRITERIA

The implementation is complete when:

1. **All new tests pass** - `mix test` succeeds
2. **Zero compilation warnings** - `mix compile --warnings-as-errors` succeeds
3. **Zero dialyzer errors** - `mix dialyzer` succeeds
4. **All examples run** - `mix run examples/run_all.exs` succeeds
5. **Docs generate** - `mix docs` succeeds
6. **Code formatted** - `mix format --check-formatted` succeeds
7. **Old API still works** - Existing tests pass with deprecation warnings only
8. **New API works** - New tests cover all documented functionality
9. **Version is 0.5.0** - mix.exs updated
10. **CHANGELOG updated** - v0.5.0 entry with all changes

---

## EXECUTION ORDER

1. Read all design documents
2. Read all relevant source code
3. Create test files first (TDD)
4. Implement API layer
5. Implement configuration
6. Implement DSL improvements
7. Implement error improvements
8. Implement test helpers
9. Update existing files
10. Create guides
11. Create examples
12. Update mix.exs and README
13. Create CHANGELOG entry
14. Run full validation suite
15. Fix any issues
16. Final validation

---

## NOTES FOR AGENT

- **TDD is mandatory** - Write tests before implementation
- **Backward compatibility is critical** - Old code must still work
- **Use deprecation warnings** - Don't just remove old functions
- **Follow existing code style** - Match patterns in existing files
- **Keep commits atomic** - One logical change per commit
- **Test incrementally** - Run tests after each phase
- **Read before writing** - Understand existing code first

# Implementation Prompt: ADR-0010 Elixir DSL, Not YAML

## Objective

Implement Elixir-based DSL for defining FlowStone pipelines with compile-time validation, IDE support, and code reuse capabilities using TDD with Supertester.

## Required Reading

Before starting, read these documents thoroughly:

1. **ADR-0010**: `docs/adr/0010-elixir-dsl-not-yaml.md` - DSL architecture decision
2. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md` - Asset fundamentals
3. **ADR-0009**: `docs/adr/0009-error-handling.md` - Validation and error handling
4. **Supertester Manual**: https://hexdocs.pm/supertester - Testing framework
5. **Metaprogramming Elixir**: https://pragprog.com/titles/cmelixir/metaprogramming-elixir/

## Context

FlowStone uses an Elixir DSL (not YAML) for pipeline definitions to provide:

**Benefits over YAML:**
1. **Type Safety** - Atoms instead of strings, compile-time type checking
2. **IDE Support** - Autocomplete, go-to-definition, refactoring
3. **Early Error Detection** - Validation at compile time, not runtime
4. **Code Reuse** - Macros, modules, functions for common patterns
5. **Expressiveness** - Full Elixir power for complex logic
6. **No Duplicate Validation** - Schema is the code

**Trade-offs:**
- Requires developers to know Elixir (but they should anyway for this ecosystem)
- Non-developers can't edit pipelines directly (use UI for configuration instead)
- Migration effort from existing YAML systems (provide one-time converter)

The DSL uses Elixir macros to build asset definitions with compile-time validation via `@before_compile` hooks.

## Implementation Tasks

### 1. Create Pipeline DSL Module

```elixir
# lib/flowstone/pipeline.ex
defmodule FlowStone.Pipeline do
  @moduledoc """
  DSL for defining FlowStone pipelines.

  ## Example

      defmodule MyApp.Pipeline do
        use FlowStone.Pipeline

        asset :raw_events do
          description "Raw event data from source systems"
          io_manager :s3
          bucket "raw-data"

          execute fn context, _deps ->
            fetch_events(context.partition)
          end
        end

        asset :cleaned_events do
          depends_on [:raw_events]
          io_manager :postgres

          execute fn context, %{raw_events: events} ->
            {:ok, clean_events(events)}
          end
        end
      end
  """

  defmacro __using__(_opts) do
    # Setup module attributes
    # Import DSL macros
    # Register @before_compile hook
  end

  defmacro __before_compile__(env) do
    # Validate all assets at compile time
    # Check for dependency cycles
    # Generate __flowstone_assets__/0 function
  end

  defmacro asset(name, do: block) do
    # Build asset struct from DSL block
  end

  # DSL macros for asset properties
  defmacro description(text)
  defmacro depends_on(deps)
  defmacro io_manager(manager)
  defmacro bucket(name)
  defmacro table(name)
  defmacro path(path_or_fn)
  defmacro partitioned_by(strategy)
  defmacro requires(resources)
  defmacro tags(tag_list)
  defmacro metadata(map)
  defmacro execute(fun)
end
```

### 2. Create DAG Cycle Checker

```elixir
# lib/flowstone/dag.ex
defmodule FlowStone.DAG do
  @doc "Check for dependency cycles in asset definitions"
  def check_cycles(assets) :: :ok | {:error, [atom()]}

  defp build_graph(assets)
  defp detect_cycle(graph)
  defp find_cycle_path(graph, visited, path)
end
```

### 3. Enhance Asset Validator for Compile-Time

```elixir
# Update lib/flowstone/asset/validator.ex
defmodule FlowStone.Asset.Validator do
  def validate(asset_definition) :: :ok | {:error, [error]}

  def format_errors(asset_name, errors) :: String.t()

  defp validate_name(errors, asset)
  defp validate_dependencies(errors, asset)
  defp validate_io_manager(errors, asset)
  defp validate_execute_fn(errors, asset)
  defp validate_partitioning(errors, asset)
  defp validate_resources(errors, asset)
end
```

### 4. Create Common Pattern Macros

```elixir
# lib/flowstone/patterns.ex
defmodule FlowStone.Patterns do
  @moduledoc """
  Reusable asset patterns as macros.
  """

  defmacro daily_report_asset(name, opts) do
    # Common pattern for daily reports
  end

  defmacro incremental_table(name, opts) do
    # Common pattern for incremental tables
  end

  defmacro ml_batch_prediction(name, opts) do
    # Common pattern for ML predictions
  end
end
```

### 5. Create Programmatic Asset Generation

```elixir
# lib/flowstone/pipeline.ex additions
defmodule FlowStone.Pipeline do
  @doc """
  Generate multiple assets programmatically.

  ## Example

      for region <- ["us", "eu", "apac"] do
        asset :"regional_report_\#{region}" do
          depends_on [:global_data]
          execute fn context, deps ->
            generate_regional_report(unquote(region), deps.global_data)
          end
        end
      end
  """
end
```

### 6. Create Configuration Integration

```elixir
# Support Application.compile_env/2 for environment-specific config
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  @config Application.compile_env(:my_app, :pipeline)

  asset :report do
    bucket @config[:report_bucket]
    path @config[:report_path]

    execute fn context, deps ->
      # ...
    end
  end
end
```

### 7. Create YAML Migration Tool (Optional)

```elixir
# lib/flowstone/migrate/from_yaml.ex
defmodule FlowStone.Migrate.FromYAML do
  @doc "Convert YAML pipeline to Elixir source code"
  def convert(yaml_path, output_path)

  defp generate_elixir(yaml_structure)
  defp generate_asset(step)
  defp generate_dependencies(deps)
end
```

### 8. Create Asset Introspection

```elixir
# Add to assets
def __flowstone_assets__, do: @flowstone_assets
def __flowstone_asset__(name), do: Enum.find(@flowstone_assets, &(&1.name == name))
```

## Test Design with Supertester

### Test File Structure

```
test/
├── flowstone/
│   ├── pipeline_test.exs
│   ├── dag_test.exs
│   ├── patterns_test.exs
│   ├── asset/
│   │   └── validator_compile_time_test.exs
│   └── migrate/
│       └── from_yaml_test.exs
└── support/
    ├── test_pipelines.ex
    └── yaml_fixtures/
        ├── simple_pipeline.yaml
        └── complex_pipeline.yaml
```

### Test Cases

#### Pipeline DSL Basic Tests

```elixir
defmodule FlowStone.PipelineTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "asset/2 macro" do
    test "defines simple asset" do
      defmodule SimplePipeline do
        use FlowStone.Pipeline

        asset :simple do
          description "A simple asset"
          execute fn _ctx, _deps -> {:ok, :result} end
        end
      end

      assets = SimplePipeline.__flowstone_assets__()
      assert length(assets) == 1

      asset = hd(assets)
      assert asset.name == :simple
      assert asset.description == "A simple asset"
      assert is_function(asset.execute_fn, 2)
    end

    test "defines asset with all properties" do
      defmodule FullAsset do
        use FlowStone.Pipeline

        asset :full do
          description "Full-featured asset"
          depends_on [:upstream1, :upstream2]
          io_manager :postgres
          table "analytics.events"
          partitioned_by :date
          requires [:database, :api_key]
          tags ["critical", "daily"]
          metadata %{owner: "data-team", sla: "4h"}

          execute fn context, deps ->
            {:ok, transform(deps.upstream1, deps.upstream2)}
          end
        end
      end

      assets = FullAsset.__flowstone_assets__()
      asset = hd(assets)

      assert asset.name == :full
      assert asset.depends_on == [:upstream1, :upstream2]
      assert asset.io_manager == :postgres
      assert asset.io_config.table == "analytics.events"
      assert asset.partitioned_by == :date
      assert asset.requires == [:database, :api_key]
      assert asset.tags == ["critical", "daily"]
      assert asset.metadata.owner == "data-team"
    end

    test "defines multiple assets" do
      defmodule MultiAssetPipeline do
        use FlowStone.Pipeline

        asset :first do
          execute fn _, _ -> {:ok, :first} end
        end

        asset :second do
          depends_on [:first]
          execute fn _, %{first: data} -> {:ok, {:second, data}} end
        end

        asset :third do
          depends_on [:second]
          execute fn _, %{second: data} -> {:ok, {:third, data}} end
        end
      end

      assets = MultiAssetPipeline.__flowstone_assets__()
      assert length(assets) == 3

      names = Enum.map(assets, & &1.name) |> Enum.sort()
      assert names == [:first, :second, :third]
    end

    test "supports nested module organization" do
      defmodule MyApp.Pipelines.DataPipeline do
        use FlowStone.Pipeline

        asset :data_asset do
          execute fn _, _ -> {:ok, :data} end
        end
      end

      assets = MyApp.Pipelines.DataPipeline.__flowstone_assets__()
      asset = hd(assets)

      assert asset.name == :data_asset
      assert asset.module == MyApp.Pipelines.DataPipeline
    end
  end

  describe "DSL property macros" do
    test "description sets description field" do
      defmodule DescribedAsset do
        use FlowStone.Pipeline

        asset :described do
          description "This is a description"
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(DescribedAsset.__flowstone_assets__())
      assert asset.description == "This is a description"
    end

    test "depends_on accepts list of atoms" do
      defmodule DependentAsset do
        use FlowStone.Pipeline

        asset :dependent do
          depends_on [:a, :b, :c]
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(DependentAsset.__flowstone_assets__())
      assert asset.depends_on == [:a, :b, :c]
    end

    test "io_manager sets manager" do
      defmodule ManagedAsset do
        use FlowStone.Pipeline

        asset :managed do
          io_manager :s3
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(ManagedAsset.__flowstone_assets__())
      assert asset.io_manager == :s3
    end

    test "bucket sets io_config.bucket" do
      defmodule BucketAsset do
        use FlowStone.Pipeline

        asset :with_bucket do
          io_manager :s3
          bucket "my-bucket"
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(BucketAsset.__flowstone_assets__())
      assert asset.io_config.bucket == "my-bucket"
    end

    test "table sets io_config.table" do
      defmodule TableAsset do
        use FlowStone.Pipeline

        asset :with_table do
          io_manager :postgres
          table "schema.table_name"
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(TableAsset.__flowstone_assets__())
      assert asset.io_config.table == "schema.table_name"
    end

    test "path accepts string or function" do
      defmodule PathAsset do
        use FlowStone.Pipeline

        asset :static_path do
          path "reports/daily.json"
          execute fn _, _ -> {:ok, nil} end
        end

        asset :dynamic_path do
          path fn partition -> "reports/#{partition}.json" end
          execute fn _, _ -> {:ok, nil} end
        end
      end

      assets = PathAsset.__flowstone_assets__()

      static = Enum.find(assets, &(&1.name == :static_path))
      assert static.io_config.path == "reports/daily.json"

      dynamic = Enum.find(assets, &(&1.name == :dynamic_path))
      assert is_function(dynamic.io_config.path, 1)
      assert dynamic.io_config.path.(~D[2025-01-15]) == "reports/2025-01-15.json"
    end

    test "partitioned_by sets partition strategy" do
      defmodule PartitionedAsset do
        use FlowStone.Pipeline

        asset :by_date do
          partitioned_by :date
          execute fn _, _ -> {:ok, nil} end
        end

        asset :by_datetime do
          partitioned_by :datetime
          execute fn _, _ -> {:ok, nil} end
        end
      end

      assets = PartitionedAsset.__flowstone_assets__()

      by_date = Enum.find(assets, &(&1.name == :by_date))
      assert by_date.partitioned_by == :date

      by_datetime = Enum.find(assets, &(&1.name == :by_datetime))
      assert by_datetime.partitioned_by == :datetime
    end

    test "requires sets resource requirements" do
      defmodule ResourceAsset do
        use FlowStone.Pipeline

        asset :needs_resources do
          requires [:database, :ml_client]
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(ResourceAsset.__flowstone_assets__())
      assert asset.requires == [:database, :ml_client]
    end

    test "tags accepts list of strings" do
      defmodule TaggedAsset do
        use FlowStone.Pipeline

        asset :tagged do
          tags ["important", "daily", "monitored"]
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(TaggedAsset.__flowstone_assets__())
      assert asset.tags == ["important", "daily", "monitored"]
    end

    test "metadata accepts map" do
      defmodule MetadataAsset do
        use FlowStone.Pipeline

        asset :with_metadata do
          metadata %{owner: "team-a", priority: 1, custom: "value"}
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(MetadataAsset.__flowstone_assets__())
      assert asset.metadata.owner == "team-a"
      assert asset.metadata.priority == 1
      assert asset.metadata.custom == "value"
    end
  end

  describe "compile-time validation" do
    test "raises CompileError for nil asset name" do
      assert_raise CompileError, ~r/Asset name/, fn ->
        defmodule NilNameAsset do
          use FlowStone.Pipeline

          asset nil do
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end

    test "raises CompileError for string asset name" do
      assert_raise CompileError, ~r/must be an atom/, fn ->
        defmodule StringNameAsset do
          use FlowStone.Pipeline

          asset "string_name" do
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end

    test "raises CompileError for non-atom dependencies" do
      assert_raise CompileError, ~r/must be atoms/, fn ->
        defmodule BadDepsAsset do
          use FlowStone.Pipeline

          asset :bad_deps do
            depends_on [:valid, "invalid", :another]
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end

    test "raises CompileError for missing execute function" do
      assert_raise CompileError, ~r/execute function/, fn ->
        defmodule NoExecuteAsset do
          use FlowStone.Pipeline

          asset :no_execute do
            description "Missing execute"
          end
        end
      end
    end

    test "raises CompileError for wrong arity execute" do
      assert_raise CompileError, ~r/arity 2/, fn ->
        defmodule WrongArityAsset do
          use FlowStone.Pipeline

          asset :wrong_arity do
            execute fn _ -> {:ok, nil} end  # arity 1, should be 2
          end
        end
      end
    end

    test "raises CompileError for unknown io_manager" do
      assert_raise CompileError, ~r/Unknown I\/O manager/, fn ->
        defmodule UnknownIOAsset do
          use FlowStone.Pipeline

          asset :unknown_io do
            io_manager :nonexistent_manager
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end

    test "raises CompileError for dependency cycle" do
      assert_raise CompileError, ~r/cycle detected/, fn ->
        defmodule CyclicPipeline do
          use FlowStone.Pipeline

          asset :a do
            depends_on [:b]
            execute fn _, _ -> {:ok, nil} end
          end

          asset :b do
            depends_on [:c]
            execute fn _, _ -> {:ok, nil} end
          end

          asset :c do
            depends_on [:a]  # Cycle: a -> b -> c -> a
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end
    end

    test "includes file and line number in compile errors" do
      error = assert_raise CompileError, fn ->
        defmodule BadAssetWithLocation do
          use FlowStone.Pipeline

          asset :bad do
            depends_on ["string"]
            execute fn _, _ -> {:ok, nil} end
          end
        end
      end

      assert error.file =~ "pipeline_test.exs"
      assert is_integer(error.line)
    end
  end

  describe "__flowstone_asset__/1 introspection" do
    test "retrieves specific asset by name" do
      defmodule IntrospectionPipeline do
        use FlowStone.Pipeline

        asset :first do
          execute fn _, _ -> {:ok, :first} end
        end

        asset :second do
          execute fn _, _ -> {:ok, :second} end
        end
      end

      assert asset = IntrospectionPipeline.__flowstone_asset__(:first)
      assert asset.name == :first

      assert asset = IntrospectionPipeline.__flowstone_asset__(:second)
      assert asset.name == :second
    end

    test "returns nil for nonexistent asset" do
      defmodule EmptyPipeline do
        use FlowStone.Pipeline
      end

      assert EmptyPipeline.__flowstone_asset__(:nonexistent) == nil
    end
  end
end
```

#### DAG Cycle Detection Tests

```elixir
defmodule FlowStone.DAGTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.DAG

  describe "check_cycles/1" do
    test "returns :ok for acyclic graph" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: [], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :b, depends_on: [:a], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :c, depends_on: [:b], execute_fn: fn _, _ -> {:ok, nil} end}
      ]

      assert :ok = DAG.check_cycles(assets)
    end

    test "returns :ok for diamond dependency" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: [], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :b, depends_on: [:a], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :c, depends_on: [:a], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :d, depends_on: [:b, :c], execute_fn: fn _, _ -> {:ok, nil} end}
      ]

      assert :ok = DAG.check_cycles(assets)
    end

    test "detects simple cycle" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: [:b], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :b, depends_on: [:a], execute_fn: fn _, _ -> {:ok, nil} end}
      ]

      assert {:error, cycle} = DAG.check_cycles(assets)
      assert :a in cycle
      assert :b in cycle
    end

    test "detects long cycle" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: [:b], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :b, depends_on: [:c], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :c, depends_on: [:d], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :d, depends_on: [:a], execute_fn: fn _, _ -> {:ok, nil} end}
      ]

      assert {:error, cycle} = DAG.check_cycles(assets)
      assert length(cycle) >= 2
    end

    test "detects self-cycle" do
      assets = [
        %FlowStone.Asset{name: :self_ref, depends_on: [:self_ref], execute_fn: fn _, _ -> {:ok, nil} end}
      ]

      assert {:error, [:self_ref]} = DAG.check_cycles(assets)
    end

    test "handles multiple disconnected components" do
      assets = [
        %FlowStone.Asset{name: :a1, depends_on: [], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :a2, depends_on: [:a1], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :b1, depends_on: [], execute_fn: fn _, _ -> {:ok, nil} end},
        %FlowStone.Asset{name: :b2, depends_on: [:b1], execute_fn: fn _, _ -> {:ok, nil} end}
      ]

      assert :ok = DAG.check_cycles(assets)
    end
  end
end
```

#### Pattern Macros Tests

```elixir
defmodule FlowStone.PatternsTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "daily_report_asset/2" do
    test "creates asset with common daily report pattern" do
      defmodule DailyReportPipeline do
        use FlowStone.Pipeline
        import FlowStone.Patterns

        daily_report_asset :user_report do
          depends_on [:users, :events]
          execute fn context, deps ->
            {:ok, generate_user_report(deps)}
          end
        end
      end

      asset = hd(DailyReportPipeline.__flowstone_assets__())

      assert asset.name == :user_report
      assert asset.partitioned_by == :date
      assert asset.io_manager == :s3
      assert asset.io_config.bucket == "reports"
      assert is_function(asset.io_config.path, 1)
    end
  end

  describe "incremental_table/2" do
    test "creates asset with incremental table pattern" do
      defmodule IncrementalPipeline do
        use FlowStone.Pipeline
        import FlowStone.Patterns

        incremental_table :events do
          depends_on [:raw_events]
          table "analytics.events"
          execute fn context, deps ->
            {:ok, process_events(deps.raw_events)}
          end
        end
      end

      asset = hd(IncrementalPipeline.__flowstone_assets__())

      assert asset.name == :events
      assert asset.io_manager == :postgres
      assert asset.partitioned_by == :date
      assert asset.io_config.table == "analytics.events"
    end
  end

  describe "custom pattern macros" do
    test "supports user-defined patterns" do
      defmodule MyPatterns do
        defmacro s3_json_asset(name, opts) do
          quote do
            asset unquote(name) do
              io_manager :s3
              bucket unquote(opts[:bucket])
              path fn partition -> "#{unquote(name)}/#{partition}.json" end
              unquote(opts[:do])
            end
          end
        end
      end

      defmodule CustomPatternPipeline do
        use FlowStone.Pipeline
        import MyPatterns

        s3_json_asset :my_data, bucket: "data-bucket" do
          depends_on [:source]
          execute fn context, deps ->
            {:ok, transform(deps.source)}
          end
        end
      end

      asset = hd(CustomPatternPipeline.__flowstone_assets__())

      assert asset.name == :my_data
      assert asset.io_manager == :s3
      assert asset.io_config.bucket == "data-bucket"
    end
  end
end
```

#### Programmatic Asset Generation Tests

```elixir
defmodule FlowStone.ProgrammaticAssetsTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "programmatic asset generation" do
    test "generates assets in a loop" do
      defmodule RegionalPipeline do
        use FlowStone.Pipeline

        for region <- ["us", "eu", "apac"] do
          asset_name = :"regional_report_#{region}"

          asset asset_name do
            depends_on [:global_data]
            metadata %{region: region}

            execute fn context, deps ->
              generate_regional_report(unquote(region), deps.global_data)
            end
          end
        end
      end

      assets = RegionalPipeline.__flowstone_assets__()
      assert length(assets) == 3

      names = Enum.map(assets, & &1.name) |> Enum.sort()
      assert names == [:regional_report_apac, :regional_report_eu, :regional_report_us]

      # Verify metadata
      us_asset = Enum.find(assets, &(&1.name == :regional_report_us))
      assert us_asset.metadata.region == "us"
    end

    test "generates hierarchical assets" do
      defmodule HierarchicalPipeline do
        use FlowStone.Pipeline

        # Root assets
        for table <- ["users", "orders", "products"] do
          asset :"raw_#{table}" do
            execute fn _, _ -> {:ok, fetch_raw(unquote(table))} end
          end
        end

        # Derived assets
        for table <- ["users", "orders", "products"] do
          asset :"clean_#{table}" do
            depends_on [:"raw_#{table}"]
            execute fn _, deps -> {:ok, clean(deps[:"raw_#{table}"])} end
          end
        end
      end

      assets = HierarchicalPipeline.__flowstone_assets__()
      assert length(assets) == 6

      # Verify dependencies
      clean_users = Enum.find(assets, &(&1.name == :clean_users))
      assert clean_users.depends_on == [:raw_users]
    end

    test "conditionally generates assets" do
      defmodule ConditionalPipeline do
        use FlowStone.Pipeline

        @env Mix.env()

        if @env == :test do
          asset :test_only do
            execute fn _, _ -> {:ok, :test_data} end
          end
        end

        asset :always_present do
          execute fn _, _ -> {:ok, :data} end
        end
      end

      assets = ConditionalPipeline.__flowstone_assets__()
      names = Enum.map(assets, & &1.name)

      assert :always_present in names
      assert :test_only in names  # Because we're running in test env
    end
  end
end
```

#### Configuration Integration Tests

```elixir
defmodule FlowStone.ConfigurationIntegrationTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "Application.compile_env/2 integration" do
    test "uses compile-time config in asset definitions" do
      Application.put_env(:flowstone, :test_pipeline, %{
        bucket: "test-bucket",
        table: "test.table"
      })

      defmodule ConfiguredPipeline do
        use FlowStone.Pipeline

        @config Application.compile_env(:flowstone, :test_pipeline)

        asset :s3_asset do
          io_manager :s3
          bucket @config[:bucket]
          execute fn _, _ -> {:ok, nil} end
        end

        asset :db_asset do
          io_manager :postgres
          table @config[:table]
          execute fn _, _ -> {:ok, nil} end
        end
      end

      assets = ConfiguredPipeline.__flowstone_assets__()

      s3_asset = Enum.find(assets, &(&1.name == :s3_asset))
      assert s3_asset.io_config.bucket == "test-bucket"

      db_asset = Enum.find(assets, &(&1.name == :db_asset))
      assert db_asset.io_config.table == "test.table"
    end

    test "supports environment-specific config" do
      Application.put_env(:flowstone, :env_pipeline, %{
        env: :test,
        bucket: "test-reports"
      })

      defmodule EnvPipeline do
        use FlowStone.Pipeline

        @config Application.compile_env(:flowstone, :env_pipeline)

        asset :env_specific do
          bucket @config[:bucket]
          metadata %{env: @config[:env]}
          execute fn _, _ -> {:ok, nil} end
        end
      end

      asset = hd(EnvPipeline.__flowstone_assets__())
      assert asset.io_config.bucket == "test-reports"
      assert asset.metadata.env == :test
    end
  end
end
```

#### YAML Migration Tests

```elixir
defmodule FlowStone.Migrate.FromYAMLTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias FlowStone.Migrate.FromYAML

  @simple_yaml """
  name: SimplePipeline
  steps:
    - name: raw_data
      execute: fetch_raw
    - name: processed
      depends_on:
        - raw_data
      execute: process_data
  """

  describe "convert/2" do
    test "converts simple YAML to Elixir DSL" do
      yaml_path = write_temp_file(@simple_yaml)
      output_path = temp_file_path("output.ex")

      assert :ok = FromYAML.convert(yaml_path, output_path)

      generated = File.read!(output_path)

      assert generated =~ "defmodule SimplePipelinePipeline do"
      assert generated =~ "use FlowStone.Pipeline"
      assert generated =~ "asset :raw_data do"
      assert generated =~ "asset :processed do"
      assert generated =~ "depends_on [:raw_data]"
    end

    test "preserves dependencies" do
      yaml = """
      name: DependencyTest
      steps:
        - name: a
        - name: b
          depends_on: [a]
        - name: c
          depends_on: [a, b]
      """

      yaml_path = write_temp_file(yaml)
      output_path = temp_file_path("deps.ex")

      FromYAML.convert(yaml_path, output_path)
      generated = File.read!(output_path)

      assert generated =~ ~r/asset :a do.*?end/s
      assert generated =~ ~r/asset :b do.*?depends_on \[:a\].*?end/s
      assert generated =~ ~r/asset :c do.*?depends_on \[:a, :b\].*?end/s
    end

    test "adds TODO comments for execute functions" do
      yaml_path = write_temp_file(@simple_yaml)
      output_path = temp_file_path("todos.ex")

      FromYAML.convert(yaml_path, output_path)
      generated = File.read!(output_path)

      assert generated =~ "# TODO: Implement"
      assert generated =~ "execute fn context, deps ->"
    end
  end

  defp write_temp_file(content) do
    path = temp_file_path("input.yaml")
    File.write!(path, content)
    path
  end

  defp temp_file_path(name) do
    Path.join(System.tmp_dir!(), name)
  end
end
```

#### Concurrency Tests

```elixir
defmodule FlowStone.PipelineConcurrencyTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  alias Supertester.ConcurrentHarness

  describe "concurrent pipeline compilation" do
    test "multiple pipelines compile without interference" do
      scenario = ConcurrentHarness.define_scenario(%{
        name: "concurrent_pipeline_compilation",
        threads: 10,
        operations_per_thread: 5,
        setup: fn -> {:ok, nil, %{}} end,
        operation: fn _state, _context, thread_id, op_num ->
          # Dynamically compile pipeline
          module_name = :"TestPipeline_#{thread_id}_#{op_num}"

          Module.create(module_name, quote do
            use FlowStone.Pipeline

            asset :test_asset do
              execute fn _, _ -> {:ok, unquote(op_num)} end
            end
          end, Macro.Env.location(__ENV__))

          # Verify compilation succeeded
          assets = module_name.__flowstone_assets__()
          assert length(assets) == 1

          :ok
        end,
        cleanup: fn _, _ -> :ok end
      })

      assert {:ok, report} = ConcurrentHarness.run(scenario)
      assert report.metrics.total_operations == 50
      assert report.metrics.errors == 0
    end
  end
end
```

## Supertester Integration Principles

### 1. Use Isolation Modes
```elixir
use Supertester.ExUnitFoundation, isolation: :full_isolation
```

### 2. Test Compile-Time Validation
```elixir
test "raises CompileError for invalid input" do
  assert_raise CompileError, ~r/error message/, fn ->
    defmodule BadPipeline do
      # ...
    end
  end
end
```

### 3. Test Generated Code
```elixir
test "generates correct asset structure" do
  assets = TestPipeline.__flowstone_assets__()
  assert hd(assets).name == :expected_name
end
```

### 4. Test Macro Expansion
```elixir
test "macro expands correctly" do
  ast = quote do
    asset :test do
      execute fn _, _ -> :ok end
    end
  end

  # Verify AST structure
end
```

### 5. Use ConcurrentHarness for Compilation Tests
```elixir
scenario = ConcurrentHarness.define_scenario(...)
{:ok, report} = ConcurrentHarness.run(scenario)
```

## Implementation Order

1. **FlowStone.Pipeline.__using__/1** - Setup module attributes and imports
2. **DSL property macros** - description, depends_on, io_manager, etc.
3. **FlowStone.Pipeline.asset/2** - Core asset definition macro
4. **FlowStone.Asset.Validator** - Compile-time validation
5. **FlowStone.DAG.check_cycles/1** - Dependency cycle detection
6. **FlowStone.Pipeline.__before_compile__/1** - Validation hook and code generation
7. **FlowStone.Patterns** - Reusable pattern macros
8. **FlowStone.Migrate.FromYAML** - Optional YAML converter
9. **Documentation and examples** - Usage guides

## Success Criteria

- [ ] All tests pass with `async: true`
- [ ] 100% test coverage for Pipeline and DAG modules
- [ ] Compile-time validation catches all invalid asset definitions
- [ ] Cycle detection works for complex dependency graphs
- [ ] DSL macros generate correct Asset structs
- [ ] IDE autocomplete works (manually verify in VS Code with ElixirLS)
- [ ] Go-to-definition works for dependencies (manually verify)
- [ ] Pattern macros are reusable and composable
- [ ] YAML converter generates valid Elixir code
- [ ] Dialyzer passes with no warnings
- [ ] Credo passes with no issues
- [ ] Documentation includes comprehensive examples

## Commands

```bash
# Run all DSL tests
mix test test/flowstone/pipeline_test.exs test/flowstone/dag_test.exs test/flowstone/patterns_test.exs

# Run with coverage
mix coveralls.html --umbrella

# Test compile-time validation
mix test test/flowstone/pipeline_test.exs --only compile_time

# Test YAML migration
mix test test/flowstone/migrate/from_yaml_test.exs

# Check types
mix dialyzer

# Check style
mix credo --strict

# Verify IDE integration (manual)
# 1. Open lib/flowstone/pipeline.ex in VS Code
# 2. Type "asset :" and verify autocomplete
# 3. Cmd+click on dependency name to verify go-to-definition
```

## Spawn Subagents

For parallel implementation, spawn subagents for:

1. **Pipeline.__using__ and basic DSL macros** - Module setup and property macros
2. **Pipeline.asset/2 macro** - Core asset definition
3. **Asset.Validator** - Compile-time validation logic
4. **DAG cycle detection** - Dependency graph analysis
5. **Pipeline.__before_compile__ hook** - Validation and code generation
6. **Pattern macros** - Reusable asset patterns
7. **YAML migration tool** - Converter from YAML to Elixir DSL
8. **Documentation and examples** - Usage guides and example pipelines

Each subagent should follow TDD: write tests first using Supertester, then implement.

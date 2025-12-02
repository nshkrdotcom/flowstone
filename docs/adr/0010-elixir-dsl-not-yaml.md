# ADR-0010: Elixir DSL, Not YAML

## Status
Accepted

## Context

pipeline_ex uses YAML for pipeline definition, which has significant problems:

1. **No Type Safety**: Everything is strings until runtime parsing.
2. **No IDE Support**: No autocomplete, no go-to-definition, no refactoring.
3. **Runtime Errors**: Typos and schema violations caught late.
4. **Duplicated Validation**: Massive validation code (600+ lines) to check YAML structure.
5. **Limited Expressiveness**: Complex logic requires awkward workarounds.
6. **No Code Reuse**: Can't share common patterns via modules/functions.

YAML's benefits (non-developers can edit, language-agnostic) are outweighed by its costs for this use case.

## Decision

### 1. Elixir DSL as Primary Interface

Assets are defined using Elixir macros with compile-time validation:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  asset :raw_events do
    description "Raw event data from source systems"
    io_manager :s3
    bucket "raw-data"
    partitioned_by :date

    execute fn context, _deps ->
      fetch_events(context.partition)
    end
  end

  asset :cleaned_events do
    description "Events after validation and cleaning"
    depends_on [:raw_events]
    io_manager :postgres
    table "analytics.cleaned_events"

    execute fn context, %{raw_events: events} ->
      {:ok, clean_events(events)}
    end
  end

  asset :daily_report do
    depends_on [:cleaned_events]
    io_manager :s3
    bucket "reports"
    path fn partition -> "reports/#{partition}.json" end

    execute fn context, %{cleaned_events: events} ->
      {:ok, generate_report(events, context.partition)}
    end
  end
end
```

### 2. Compile-Time Validation

```elixir
defmodule FlowStone.Pipeline do
  defmacro __using__(_opts) do
    quote do
      import FlowStone.Pipeline
      Module.register_attribute(__MODULE__, :flowstone_assets, accumulate: true)
      @before_compile FlowStone.Pipeline
    end
  end

  defmacro __before_compile__(env) do
    assets = Module.get_attribute(env.module, :flowstone_assets)

    # Validate all assets at compile time
    for asset <- assets do
      case FlowStone.Asset.Validator.validate(asset) do
        :ok -> :ok
        {:error, errors} ->
          raise CompileError,
            description: format_validation_errors(asset.name, errors),
            file: env.file,
            line: asset.line
      end
    end

    # Check for dependency cycles
    case FlowStone.DAG.check_cycles(assets) do
      :ok -> :ok
      {:error, cycle} ->
        raise CompileError,
          description: "Dependency cycle detected: #{inspect(cycle)}",
          file: env.file
    end

    # Register assets
    quote do
      def __flowstone_assets__, do: unquote(Macro.escape(assets))
    end
  end

  defmacro asset(name, do: block) do
    quote do
      asset_definition = %FlowStone.Asset{
        name: unquote(name),
        line: unquote(__CALLER__.line),
        module: __MODULE__
      }

      var!(current_asset) = asset_definition
      unquote(block)
      @flowstone_assets var!(current_asset)
    end
  end

  defmacro depends_on(deps) do
    quote do
      var!(current_asset) = %{var!(current_asset) | depends_on: unquote(deps)}
    end
  end

  defmacro io_manager(manager) do
    quote do
      var!(current_asset) = %{var!(current_asset) | io_manager: unquote(manager)}
    end
  end

  defmacro execute(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | execute_fn: unquote(fun)}
    end
  end

  # ... other DSL macros
end
```

### 3. IDE Integration Benefits

With Elixir DSL, developers get:

```elixir
# Autocomplete for asset options
asset :my_asset do
  depends_on [:other_asset]  # Autocomplete shows available assets
  io_manager :postgres       # Autocomplete shows registered managers
  # ...
end

# Go-to-definition
asset :report do
  depends_on [:my_asset]     # Cmd+click jumps to :my_asset definition
  # ...
end

# Compile-time errors
asset :bad_asset do
  depends_on ["string"]      # Compile error: dependencies must be atoms
end
```

### 4. Code Reuse via Modules

```elixir
defmodule MyApp.CommonPatterns do
  defmacro daily_report_asset(name, opts) do
    quote do
      asset unquote(name) do
        partitioned_by :date
        io_manager :s3
        bucket "reports"
        path fn partition -> "#{unquote(name)}/#{partition}.json" end
        unquote(opts[:do])
      end
    end
  end
end

defmodule MyApp.Pipeline do
  use FlowStone.Pipeline
  import MyApp.CommonPatterns

  # Reuse common pattern
  daily_report_asset :user_report do
    depends_on [:users, :events]
    execute fn context, deps ->
      {:ok, generate_user_report(deps)}
    end
  end

  daily_report_asset :revenue_report do
    depends_on [:transactions]
    execute fn context, deps ->
      {:ok, generate_revenue_report(deps)}
    end
  end
end
```

### 5. Programmatic Asset Generation

```elixir
defmodule MyApp.DynamicPipeline do
  use FlowStone.Pipeline

  # Generate assets for each region
  for region <- ["us", "eu", "apac"] do
    asset_name = :"regional_report_#{region}"

    asset asset_name do
      depends_on [:global_data]
      partitioned_by :date

      execute fn context, deps ->
        generate_regional_report(unquote(region), deps.global_data)
      end
    end
  end
end
```

### 6. Configuration via Application Environment

For values that need to change between environments:

```elixir
# config/config.exs
config :my_app, :pipeline,
  report_bucket: "reports-dev",
  max_parallel: 5

# In pipeline module
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  @config Application.compile_env(:my_app, :pipeline)

  asset :report do
    io_manager :s3
    bucket @config[:report_bucket]

    execute fn context, deps ->
      # ...
    end
  end
end
```

### 7. Optional YAML Import (For Migration)

For migrating from YAML-based systems, provide a one-time converter:

```elixir
defmodule FlowStone.Migrate.FromYAML do
  @doc "Convert YAML pipeline to Elixir source code"
  def convert(yaml_path, output_path) do
    yaml = YamlElixir.read_from_file!(yaml_path)
    elixir_source = generate_elixir(yaml)
    File.write!(output_path, elixir_source)
  end

  defp generate_elixir(yaml) do
    """
    defmodule #{yaml["name"]}Pipeline do
      use FlowStone.Pipeline

      #{Enum.map_join(yaml["steps"], "\n\n", &generate_asset/1)}
    end
    """
  end

  defp generate_asset(step) do
    """
      asset :#{step["name"]} do
        #{if step["depends_on"], do: "depends_on #{inspect(step["depends_on"])}"}
        execute fn context, deps ->
          # TODO: Implement
          {:ok, nil}
        end
      end
    """
  end
end
```

## Consequences

### Positive

1. **Type Safety**: Atoms, not strings. Compile-time checks.
2. **IDE Support**: Full autocomplete, refactoring, navigation.
3. **Early Error Detection**: Validation at compile time.
4. **Code Reuse**: Macros, modules, functions for common patterns.
5. **Expressiveness**: Full Elixir power for complex logic.
6. **No Duplicate Validation**: Schema is the code.
7. **Testable**: Assets can be unit tested like any Elixir code.

### Negative

1. **Learning Curve**: Developers must know Elixir (but they should anyway).
2. **Non-Dev Access**: Non-developers can't edit pipelines directly.
3. **Migration Effort**: Existing YAML pipelines need conversion.

### Trade-offs Accepted

| YAML Benefit | FlowStone Approach |
|--------------|-------------------|
| Non-devs can edit | Devs maintain pipelines; use UI for config |
| Language-agnostic | Elixir-only (but that's the ecosystem) |
| Simple for simple cases | Elixir DSL is also simple for simple cases |

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| String keys | Atom keys with compile-time validation |
| 600+ lines validation | Schema is the code |
| Runtime type errors | Compile-time type checking |
| No IDE support | Full IDE integration |
| No code reuse | Macros and modules |
| Duplicated step types | Each asset is unique, patterns via macros |

## References

- Ecto DSL: https://hexdocs.pm/ecto/Ecto.Schema.html
- Phoenix Router DSL: https://hexdocs.pm/phoenix/Phoenix.Router.html
- Metaprogramming Elixir: https://pragprog.com/titles/cmelixir/metaprogramming-elixir/

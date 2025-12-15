# FlowStone Hook Pipeline

## Status

Proposed

## Context

The current `FlowStone.Executor.materialize/2` function is a monolithic ~150 line function that handles multiple cross-cutting concerns in a hardcoded sequence:

- Telemetry emission (start/stop/exception)
- Materialization recording (start/success/failure)
- Audit logging
- Lineage tracking
- Actual asset execution

This design has several drawbacks:

1. **Rigidity**: Users cannot inject custom behavior (caching, rate limiting, metrics)
2. **Testability**: Hard to test individual concerns in isolation
3. **Maintainability**: Adding new cross-cutting concerns requires modifying core code
4. **Configurability**: Cannot disable specific behaviors (e.g., skip audit logging in tests)

## Decision

Implement a **Hook Pipeline** pattern that wraps asset materialization in a composable middleware stack. Each hook handles a single concern and delegates to the next hook in the chain.

## Design

### Hook Behaviour

```elixir
defmodule FlowStone.Hook do
  @moduledoc """
  Behaviour for materialization hooks.

  Hooks wrap asset execution in an onion-style pipeline, allowing
  cross-cutting concerns to be handled in isolated, composable modules.
  """

  alias FlowStone.Hook.Context

  @type next_fn :: (Context.t() -> {:ok, term()} | {:error, term()})
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Execute hook logic, calling `next` to continue the pipeline.

  The hook can:
  - Modify context before calling next
  - Inspect/transform the result after next returns
  - Short-circuit by returning without calling next
  - Handle errors from downstream hooks
  """
  @callback call(context :: Context.t(), next :: next_fn()) :: result()

  @doc """
  Optional callback to validate hook configuration at compile time.
  Returns `:ok` or `{:error, reason}`.
  """
  @callback validate_config(config :: keyword()) :: :ok | {:error, term()}

  @optional_callbacks [validate_config: 1]
end
```

### Hook Context

```elixir
defmodule FlowStone.Hook.Context do
  @moduledoc """
  Execution context passed through the hook pipeline.

  Contains all information needed for materialization plus
  an `assigns` map for hooks to share state.
  """

  @type t :: %__MODULE__{
          asset: FlowStone.Asset.t(),
          partition: term(),
          run_id: String.t(),
          dependencies: map(),
          io_opts: keyword(),
          use_repo: boolean(),
          resource_server: atom(),
          lineage_server: atom(),
          materialization_store: atom(),
          started_at: integer(),
          assigns: map(),
          hooks_config: map()
        }

  defstruct [
    :asset,
    :partition,
    :run_id,
    :dependencies,
    :io_opts,
    :use_repo,
    :resource_server,
    :lineage_server,
    :materialization_store,
    :started_at,
    assigns: %{},
    hooks_config: %{}
  ]

  @doc """
  Store a value in assigns for downstream hooks to access.
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = ctx, key, value) do
    %{ctx | assigns: Map.put(ctx.assigns, key, value)}
  end

  @doc """
  Retrieve a value from assigns.
  """
  @spec get_assign(t(), atom(), term()) :: term()
  def get_assign(%__MODULE__{} = ctx, key, default \\ nil) do
    Map.get(ctx.assigns, key, default)
  end

  @doc """
  Get hook-specific configuration.
  """
  @spec get_hook_config(t(), module(), atom(), term()) :: term()
  def get_hook_config(%__MODULE__{} = ctx, hook_module, key, default \\ nil) do
    ctx.hooks_config
    |> Map.get(hook_module, %{})
    |> Map.get(key, default)
  end
end
```

### Pipeline Runner

```elixir
defmodule FlowStone.Hook.Pipeline do
  @moduledoc """
  Executes a stack of hooks in sequence, forming an onion-style pipeline.
  """

  alias FlowStone.Hook.Context

  @doc """
  Run the hook pipeline with the given context.

  ## Examples

      hooks = [
        FlowStone.Hooks.Telemetry,
        FlowStone.Hooks.Materialization,
        FlowStone.Hooks.Core
      ]

      Pipeline.run(hooks, context)
  """
  @spec run([module()], Context.t()) :: {:ok, term()} | {:error, term()}
  def run([], _ctx) do
    {:error, :empty_hook_pipeline}
  end

  def run(hooks, %Context{} = ctx) do
    dispatch(hooks, ctx)
  end

  defp dispatch([hook], ctx) do
    # Terminal hook - no next function
    hook.call(ctx, fn _ -> {:error, :no_next_hook} end)
  end

  defp dispatch([hook | rest], ctx) do
    next_fn = fn next_ctx -> dispatch(rest, next_ctx) end
    hook.call(ctx, next_fn)
  end
end
```

### Default Hooks

#### Core Hook (Terminal)

```elixir
defmodule FlowStone.Hooks.Core do
  @moduledoc """
  Terminal hook that executes the actual asset function.

  This hook should always be last in the pipeline.
  """

  @behaviour FlowStone.Hook

  alias FlowStone.{Context, Materializer}
  alias FlowStone.Hook.Context, as: HookContext

  @impl true
  def call(%HookContext{} = ctx, _next) do
    # Build execution context for the asset
    exec_context = Context.build(
      ctx.asset,
      ctx.partition,
      ctx.run_id,
      resource_server: ctx.resource_server
    )

    # Execute the asset function
    Materializer.execute(ctx.asset, exec_context, ctx.dependencies)
  end
end
```

#### Telemetry Hook

```elixir
defmodule FlowStone.Hooks.Telemetry do
  @moduledoc """
  Emits telemetry events for materialization lifecycle.

  Events:
  - `[:flowstone, :materialization, :start]`
  - `[:flowstone, :materialization, :stop]`
  - `[:flowstone, :materialization, :exception]`
  """

  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context

  @impl true
  def call(%Context{} = ctx, next) do
    meta = %{
      asset: ctx.asset.name,
      partition: ctx.partition,
      run_id: ctx.run_id
    }

    :telemetry.execute([:flowstone, :materialization, :start], %{
      system_time: System.system_time()
    }, meta)

    start_time = System.monotonic_time(:millisecond)

    try do
      case next.(ctx) do
        {:ok, result} ->
          duration = System.monotonic_time(:millisecond) - start_time
          :telemetry.execute([:flowstone, :materialization, :stop], %{
            duration: duration
          }, meta)
          {:ok, result}

        {:error, reason} = error ->
          duration = System.monotonic_time(:millisecond) - start_time
          :telemetry.execute([:flowstone, :materialization, :exception], %{
            duration: duration
          }, Map.put(meta, :error, reason))
          error
      end
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_time
        :telemetry.execute([:flowstone, :materialization, :exception], %{
          duration: duration
        }, Map.merge(meta, %{kind: :error, reason: e, stacktrace: __STACKTRACE__}))
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time(:millisecond) - start_time
        :telemetry.execute([:flowstone, :materialization, :exception], %{
          duration: duration
        }, Map.merge(meta, %{kind: kind, reason: reason}))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end
```

#### Materialization Recording Hook

```elixir
defmodule FlowStone.Hooks.Materialization do
  @moduledoc """
  Records materialization state transitions to the store.

  Records:
  - Start (status: pending)
  - Success (status: success, duration_ms)
  - Failure (status: failed, error)
  """

  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context
  alias FlowStone.Materializations

  @impl true
  def call(%Context{} = ctx, next) do
    # Record start
    Materializations.record_start(
      ctx.asset.name,
      ctx.partition,
      ctx.run_id,
      store: ctx.materialization_store,
      use_repo: ctx.use_repo
    )

    start_time = System.monotonic_time(:millisecond)

    case next.(ctx) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Materializations.record_success(
          ctx.asset.name,
          ctx.partition,
          ctx.run_id,
          duration,
          store: ctx.materialization_store,
          use_repo: ctx.use_repo
        )
        {:ok, result}

      {:error, error} ->
        Materializations.record_failure(
          ctx.asset.name,
          ctx.partition,
          ctx.run_id,
          error,
          store: ctx.materialization_store,
          use_repo: ctx.use_repo
        )
        {:error, error}
    end
  end
end
```

#### Storage Hook

```elixir
defmodule FlowStone.Hooks.Storage do
  @moduledoc """
  Stores successful materialization results via I/O manager.
  """

  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context
  alias FlowStone.IO

  @impl true
  def call(%Context{} = ctx, next) do
    case next.(ctx) do
      {:ok, result} ->
        case IO.store(ctx.asset.name, result, ctx.partition, ctx.io_opts) do
          :ok -> {:ok, result}
          {:error, reason} -> {:error, {:storage_failed, reason}}
        end

      error ->
        error
    end
  end
end
```

#### Lineage Hook

```elixir
defmodule FlowStone.Hooks.Lineage do
  @moduledoc """
  Records lineage edges after successful materialization.
  """

  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context
  alias FlowStone.LineagePersistence

  @impl true
  def call(%Context{} = ctx, next) do
    case next.(ctx) do
      {:ok, result} ->
        upstream_pairs = Enum.map(ctx.dependencies, fn {dep, _data} ->
          {dep, ctx.partition}
        end)

        LineagePersistence.record(
          ctx.asset.name,
          ctx.partition,
          ctx.run_id,
          upstream_pairs,
          server: ctx.lineage_server,
          use_repo: ctx.use_repo
        )

        {:ok, result}

      error ->
        error
    end
  end
end
```

#### Audit Log Hook

```elixir
defmodule FlowStone.Hooks.AuditLog do
  @moduledoc """
  Records audit log entries for materialization events.
  """

  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context
  alias FlowStone.AuditLogContext

  @impl true
  def call(%Context{} = ctx, next) do
    result = next.(ctx)

    if ctx.use_repo do
      case result do
        {:ok, _} ->
          AuditLogContext.log("asset.materialized",
            actor_id: "system",
            actor_type: "system",
            resource_type: "asset",
            resource_id: Atom.to_string(ctx.asset.name),
            action: "materialized",
            details: %{
              run_id: ctx.run_id,
              partition: ctx.partition
            }
          )

        {:error, error} ->
          AuditLogContext.log("asset.failed",
            actor_id: "system",
            actor_type: "system",
            resource_type: "asset",
            resource_id: Atom.to_string(ctx.asset.name),
            action: "failed",
            details: %{
              run_id: ctx.run_id,
              partition: ctx.partition,
              error: inspect(error)
            }
          )
      end
    end

    result
  end
end
```

### Default Hook Stack

```elixir
defmodule FlowStone.Hooks do
  @moduledoc """
  Default hook stack and utilities for hook management.
  """

  @default_hooks [
    FlowStone.Hooks.Telemetry,
    FlowStone.Hooks.Materialization,
    FlowStone.Hooks.AuditLog,
    FlowStone.Hooks.Lineage,
    FlowStone.Hooks.Storage,
    FlowStone.Hooks.Core
  ]

  @doc """
  Returns the default hook stack.
  """
  @spec default() :: [module()]
  def default, do: @default_hooks

  @doc """
  Prepend hooks to the default stack.

  ## Examples

      Hooks.prepend([MyRateLimiter, MyCache])
      # => [MyRateLimiter, MyCache, Telemetry, ...]
  """
  @spec prepend([module()]) :: [module()]
  def prepend(hooks) when is_list(hooks) do
    hooks ++ @default_hooks
  end

  @doc """
  Insert hooks before the Core hook.

  ## Examples

      Hooks.before_core([MyValidator])
      # => [Telemetry, ..., MyValidator, Core]
  """
  @spec before_core([module()]) :: [module()]
  def before_core(hooks) when is_list(hooks) do
    {pre, [core]} = Enum.split(@default_hooks, -1)
    pre ++ hooks ++ [core]
  end

  @doc """
  Build a minimal hook stack for testing.
  """
  @spec testing() :: [module()]
  def testing do
    [FlowStone.Hooks.Core]
  end

  @doc """
  Build hook stack without persistence (telemetry only).
  """
  @spec ephemeral() :: [module()]
  def ephemeral do
    [
      FlowStone.Hooks.Telemetry,
      FlowStone.Hooks.Storage,
      FlowStone.Hooks.Core
    ]
  end
end
```

### Refactored Executor

```elixir
defmodule FlowStone.Executor do
  @moduledoc """
  Executes a single asset through the hook pipeline.
  """

  alias FlowStone.{Error, Registry}
  alias FlowStone.Hook.{Context, Pipeline}
  alias FlowStone.Hooks

  @spec materialize(atom(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def materialize(asset_name, opts) do
    partition = Keyword.fetch!(opts, :partition)
    registry = Keyword.get(opts, :registry, Registry)
    hooks = Keyword.get(opts, :hooks, Hooks.default())

    with {:ok, asset} <- Registry.fetch(asset_name, server: registry),
         {:ok, deps} <- load_dependencies(asset, partition, opts),
         {:ok, ctx} <- build_context(asset, partition, deps, opts) do
      Pipeline.run(hooks, ctx)
    end
  end

  defp build_context(asset, partition, deps, opts) do
    {:ok, %Context{
      asset: asset,
      partition: partition,
      run_id: Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0),
      dependencies: deps,
      io_opts: Keyword.get(opts, :io, []),
      use_repo: Keyword.get(opts, :use_repo, true),
      resource_server: get_opt(opts, :resource_server, :flowstone, :resources_server, FlowStone.Resources),
      lineage_server: get_opt(opts, :lineage_server, :flowstone, :lineage_server, FlowStone.Lineage),
      materialization_store: get_opt(opts, :materialization_store, :flowstone, :materialization_store, FlowStone.MaterializationStore),
      started_at: System.monotonic_time(:millisecond),
      hooks_config: Keyword.get(opts, :hooks_config, %{})
    }}
  end

  defp load_dependencies(asset, partition, opts) do
    io_opts = Keyword.get(opts, :io, [])
    deps = Map.get(asset, :depends_on, [])

    results =
      Enum.reduce_while(deps, %{}, fn dep, acc ->
        case FlowStone.IO.load(dep, partition, io_opts) do
          {:ok, data} -> {:cont, Map.put(acc, dep, data)}
          {:error, _} -> {:halt, {:missing, dep}}
        end
      end)

    case results do
      {:missing, dep} -> {:error, Error.dependency_not_ready(asset.name, [dep])}
      map when is_map(map) -> {:ok, map}
    end
  end

  defp get_opt(opts, key, app, env_key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> Application.get_env(app, env_key, default)
    end
  end
end
```

## Usage Examples

### Basic Usage (Default Hooks)

```elixir
# Uses default hook stack
FlowStone.materialize(:my_asset, partition: ~D[2024-01-01])
```

### Custom Hooks

```elixir
# Add rate limiting before execution
defmodule MyApp.RateLimitHook do
  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context

  @impl true
  def call(%Context{} = ctx, next) do
    bucket = "asset:#{ctx.asset.name}"

    case Hammer.check_rate(bucket, 60_000, 10) do
      {:allow, _count} -> next.(ctx)
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end
end

# Use custom hook
FlowStone.materialize(:my_asset,
  partition: ~D[2024-01-01],
  hooks: FlowStone.Hooks.prepend([MyApp.RateLimitHook])
)
```

### Testing with Minimal Hooks

```elixir
# Skip telemetry, audit, lineage - just execute
FlowStone.materialize(:my_asset,
  partition: ~D[2024-01-01],
  hooks: FlowStone.Hooks.testing()
)
```

### Hook Configuration

```elixir
defmodule MyApp.RetryHook do
  @behaviour FlowStone.Hook

  alias FlowStone.Hook.Context

  @impl true
  def call(%Context{} = ctx, next) do
    max_retries = Context.get_hook_config(ctx, __MODULE__, :max_retries, 3)
    retry_with_backoff(ctx, next, max_retries, 0)
  end

  defp retry_with_backoff(ctx, next, max, attempt) when attempt >= max do
    next.(ctx)
  end

  defp retry_with_backoff(ctx, next, max, attempt) do
    case next.(ctx) do
      {:ok, _} = success -> success
      {:error, %{retryable: true}} ->
        Process.sleep(backoff(attempt))
        retry_with_backoff(ctx, next, max, attempt + 1)
      error -> error
    end
  end

  defp backoff(attempt), do: :math.pow(2, attempt) |> round() |> Kernel.*(100)
end

# Configure per-call
FlowStone.materialize(:my_asset,
  partition: ~D[2024-01-01],
  hooks: FlowStone.Hooks.prepend([MyApp.RetryHook]),
  hooks_config: %{
    MyApp.RetryHook => %{max_retries: 5}
  }
)
```

## Migration Path

1. **Phase 1**: Implement `FlowStone.Hook` behaviour and `Pipeline` module
2. **Phase 2**: Extract existing logic into default hooks (`Telemetry`, `Materialization`, etc.)
3. **Phase 3**: Refactor `Executor.materialize/2` to use pipeline
4. **Phase 4**: Add hook configuration to `materialize/2` options
5. **Phase 5**: Update `AssetWorker` to pass hooks through job args or RunConfig

## File Structure

```
lib/flowstone/
├── hook.ex                    # Behaviour definition
├── hook/
│   ├── context.ex             # Execution context struct
│   └── pipeline.ex            # Pipeline runner
├── hooks.ex                   # Default stack & utilities
└── hooks/
    ├── telemetry.ex
    ├── materialization.ex
    ├── storage.ex
    ├── lineage.ex
    ├── audit_log.ex
    └── core.ex
```

## Consequences

### Positive

- **Extensibility**: Users can add custom cross-cutting concerns
- **Testability**: Each hook testable in isolation
- **Configurability**: Can enable/disable hooks per-call
- **Separation of Concerns**: Each hook handles one responsibility
- **Reusability**: Hooks can be shared across projects

### Negative

- **Indirection**: Slightly harder to trace execution flow
- **Performance**: Small overhead from function dispatch (negligible)
- **Complexity**: More modules to understand initially

### Neutral

- **Breaking Change**: `Executor.materialize/2` signature unchanged but behavior more configurable

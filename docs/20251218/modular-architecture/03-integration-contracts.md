# Integration Contracts

**Status:** Design Proposal
**Date:** 2025-12-18

## 1. Purpose

This document defines the **behavior and protocol specifications** that form the contract between FlowStone core and its plugins/integrations.

Following the altar_ai pattern, we use:
- **Behaviors** for required implementations (callbacks)
- **Protocols** for runtime dispatch (polymorphism)
- **Registries** for configuration-based resolution

## 2. Core Behaviors

### 2.1 FlowStone.IO.Manager

**Purpose**: Pluggable asset data storage.

```elixir
defmodule FlowStone.IO.Manager do
  @moduledoc """
  Behavior for asset data storage backends.

  Implementations must handle:
  - Storing asset outputs by (asset_name, partition)
  - Loading asset outputs for dependency resolution
  - Checking existence for cache hits
  - Deleting outputs for invalidation
  """

  @type asset_name :: atom()
  @type partition :: term()
  @type data :: term()
  @type opts :: keyword()

  @doc "Load stored asset data for the given partition"
  @callback load(asset_name, partition, opts) ::
    {:ok, data} | {:error, :not_found} | {:error, term()}

  @doc "Store asset output data"
  @callback store(asset_name, data, partition, opts) ::
    :ok | {:error, term()}

  @doc "Check if data exists without loading"
  @callback exists?(asset_name, partition, opts) :: boolean()

  @doc "Delete stored data (for invalidation)"
  @callback delete(asset_name, partition, opts) :: :ok | {:error, term()}

  @doc "Optional: List all partitions for an asset"
  @callback list_partitions(asset_name, opts) :: {:ok, [partition]} | {:error, term()}

  @optional_callbacks [list_partitions: 2]
end
```

**Reference Implementation**: `FlowStone.IO.Memory` (in core)

**Plugin Implementations**:
- `FlowStone.IO.Postgres` (flowstone_io_postgres)
- `FlowStone.IO.S3` (flowstone_io_s3)
- `FlowStone.IO.Parquet` (flowstone_io_parquet)

### 2.2 FlowStone.Scatter.ItemReader

**Purpose**: Streaming item sources for scatter operations.

```elixir
defmodule FlowStone.Scatter.ItemReader do
  @moduledoc """
  Behavior for streaming scatter item sources.

  Implementations provide paginated access to items from external
  sources (S3, DynamoDB, Postgres, etc.) for large-scale scatter
  operations.
  """

  @type state :: term()
  @type item :: map()
  @type config :: map()
  @type deps :: map()
  @type checkpoint :: map()

  @doc "Initialize reader with config and dependencies"
  @callback init(config, deps) ::
    {:ok, state} | {:error, term()}

  @doc "Read next batch of items, return :halt when exhausted"
  @callback read(state, batch_size :: pos_integer()) ::
    {:ok, [item], state | :halt} | {:error, term()}

  @doc "Return total count if known"
  @callback count(state) :: {:ok, non_neg_integer()} | :unknown

  @doc "Serialize state to JSON-safe checkpoint"
  @callback checkpoint(state) :: checkpoint

  @doc "Restore state from checkpoint"
  @callback restore(state, checkpoint) :: state

  @doc "Clean up resources"
  @callback close(state) :: :ok

  @optional_callbacks [count: 1, checkpoint: 1, restore: 2, close: 1]
end
```

**Plugin Implementations**:
- `FlowStone.Scatter.ItemReaders.S3` (flowstone_readers_aws)
- `FlowStone.Scatter.ItemReaders.DynamoDB` (flowstone_readers_aws)
- `FlowStone.Scatter.ItemReaders.Postgres` (flowstone_readers_postgres)
- `FlowStone.Scatter.ItemReaders.Custom` (core - wraps user functions)

### 2.3 FlowStone.Scatter.Coordinator

**Purpose**: Scatter execution coordination.

```elixir
defmodule FlowStone.Scatter.Coordinator do
  @moduledoc """
  Behavior for scatter execution coordination.

  Handles barrier management, result tracking, and gather aggregation.
  """

  @type run_id :: binary()
  @type barrier_id :: binary()
  @type asset_name :: atom()
  @type partition :: term()
  @type scatter_key :: term()
  @type result :: term()
  @type error :: term()
  @type status :: :pending | :complete | :failed | :threshold_exceeded

  @doc "Create coordination barrier for scatter execution"
  @callback create_barrier(run_id, asset_name, partition, opts :: keyword()) ::
    {:ok, barrier_id} | {:error, term()}

  @doc "Insert scatter keys into barrier"
  @callback insert_results(barrier_id, [scatter_key]) ::
    :ok | {:error, term()}

  @doc "Record successful completion of scatter instance"
  @callback complete(barrier_id, scatter_key, result) ::
    {:ok, :pending | :complete} | {:error, term()}

  @doc "Record failure of scatter instance"
  @callback fail(barrier_id, scatter_key, error) ::
    {:ok, :pending | :threshold_exceeded} | {:error, term()}

  @doc "Gather all results after completion"
  @callback gather(barrier_id) ::
    {:ok, %{scatter_key => result}} | {:error, term()}

  @doc "Cancel pending scatter instances"
  @callback cancel(barrier_id) :: :ok | {:error, term()}

  @doc "Get barrier status"
  @callback status(barrier_id) ::
    {:ok, %{status: status, completed: integer(), failed: integer(), total: integer()}} |
    {:error, :not_found}
end
```

### 2.4 FlowStone.Parallel.Coordinator

**Purpose**: Parallel branch execution coordination.

```elixir
defmodule FlowStone.Parallel.Coordinator do
  @moduledoc """
  Behavior for parallel branch execution coordination.

  Handles branch scheduling, completion tracking, and join execution.
  """

  @type execution_id :: binary()
  @type run_id :: binary()
  @type asset_name :: atom()
  @type branch_name :: atom()
  @type result :: term()
  @type error :: term()
  @type status :: :pending | :running | :ready_for_join | :complete | :failed

  @doc "Create parallel execution record"
  @callback create_execution(run_id, asset_name, branches :: [branch_name], opts :: keyword()) ::
    {:ok, execution_id} | {:error, term()}

  @doc "Schedule all branch jobs"
  @callback schedule_branches(execution_id) :: :ok | {:error, term()}

  @doc "Record branch completion"
  @callback complete_branch(execution_id, branch_name, result) ::
    {:ok, :pending | :ready_for_join} | {:error, term()}

  @doc "Record branch failure"
  @callback fail_branch(execution_id, branch_name, error) ::
    {:ok, :pending | :failed} | {:error, term()}

  @doc "Execute join function with branch results"
  @callback execute_join(execution_id, join_fn :: function()) ::
    {:ok, result} | {:error, term()}

  @doc "Get execution status"
  @callback status(execution_id) ::
    {:ok, %{status: status, branches: %{branch_name => branch_status}}} |
    {:error, :not_found}
end
```

### 2.5 FlowStone.Routing.Coordinator

**Purpose**: Route decision management.

```elixir
defmodule FlowStone.Routing.Coordinator do
  @moduledoc """
  Behavior for routing decision persistence and retrieval.
  """

  @type decision_id :: binary()
  @type run_id :: binary()
  @type router_asset :: atom()
  @type partition :: term()
  @type selected_branch :: atom() | nil

  @doc "Record a routing decision"
  @callback record(run_id, router_asset, partition, selected_branch, opts :: keyword()) ::
    {:ok, decision_id} | {:error, term()}

  @doc "Get existing decision for idempotent replay"
  @callback get(run_id, router_asset, partition) ::
    {:ok, selected_branch} | {:error, :not_found}

  @doc "Format decision as asset output"
  @callback to_output(decision_id) :: map()
end
```

### 2.6 FlowStone.Resource (Existing)

**Purpose**: External resource lifecycle management.

```elixir
defmodule FlowStone.Resource do
  @moduledoc """
  Behavior for external resources available to assets.

  Resources are initialized at startup and made available
  via ctx.resources in asset execute functions.
  """

  @callback setup(config :: map()) :: {:ok, resource :: term()} | {:error, term()}
  @callback teardown(resource :: term()) :: :ok
  @callback health_check(resource :: term()) :: :healthy | {:unhealthy, term()}

  @optional_callbacks [health_check: 1]
end
```

**Reference Implementation**: `FlowStone.AI.Resource` (flowstone_ai)

## 3. Core Protocols

### 3.1 FlowStone.Telemetry.Emitter

**Purpose**: Pluggable telemetry emission.

```elixir
defprotocol FlowStone.Telemetry.Emitter do
  @moduledoc """
  Protocol for telemetry emission.

  Allows swapping telemetry backends without changing core code.
  """

  @doc "Execute a telemetry event"
  @spec execute(t, event :: [atom()], measurements :: map(), metadata :: map()) :: :ok
  def execute(emitter, event, measurements, metadata)

  @doc "Execute a span (start/stop pair)"
  @spec span(t, event :: [atom()], metadata :: map(), fun :: (-> result)) :: result
        when result: term()
  def span(emitter, event, metadata, fun)
end

# Default implementation
defimpl FlowStone.Telemetry.Emitter, for: Atom do
  def execute(:default, event, measurements, metadata) do
    :telemetry.execute([:flowstone | event], measurements, metadata)
  end

  def span(:default, event, metadata, fun) do
    start_time = System.monotonic_time()
    :telemetry.execute([:flowstone | event ++ [:start]], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      :telemetry.execute([:flowstone | event ++ [:stop]], %{duration: duration}, metadata)
      result
    rescue
      error ->
        duration = System.monotonic_time() - start_time
        :telemetry.execute([:flowstone | event ++ [:exception]], %{duration: duration}, Map.put(metadata, :error, error))
        reraise error, __STACKTRACE__
    end
  end
end
```

### 3.2 FlowStone.Error.Normalizer

**Purpose**: Normalize errors from different sources.

```elixir
defprotocol FlowStone.Error.Normalizer do
  @moduledoc """
  Protocol for normalizing external errors to FlowStone.Error.
  """

  @doc "Convert external error to FlowStone.Error"
  @spec normalize(t) :: FlowStone.Error.t()
  def normalize(error)
end

# Implementation for common error types
defimpl FlowStone.Error.Normalizer, for: Ecto.Changeset do
  def normalize(changeset) do
    FlowStone.Error.new(:validation_error, Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0)))
  end
end

defimpl FlowStone.Error.Normalizer, for: DBConnection.ConnectionError do
  def normalize(error) do
    FlowStone.Error.new(:database_error, error.message, retryable?: true)
  end
end
```

## 4. Registries

### 4.1 FlowStone.IO.Registry

```elixir
defmodule FlowStone.IO.Registry do
  @moduledoc """
  Registry for IO manager implementations.

  Allows runtime resolution of IO managers by name.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> load_from_config() end, name: __MODULE__)
  end

  @doc "Register an IO manager"
  @spec register(atom(), module(), keyword()) :: :ok
  def register(name, module, config \\ []) do
    Agent.update(__MODULE__, &Map.put(&1, name, {module, config}))
  end

  @doc "Resolve IO manager by name"
  @spec resolve(atom()) :: {:ok, {module(), keyword()}} | {:error, :not_found}
  def resolve(name) do
    case Agent.get(__MODULE__, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  @doc "Get default IO manager"
  @spec default() :: {module(), keyword()}
  def default do
    case resolve(:default) do
      {:ok, result} -> result
      _ -> {FlowStone.IO.Memory, []}
    end
  end

  defp load_from_config do
    Application.get_env(:flowstone, :io_managers, %{})
    |> Enum.map(fn
      {name, module} when is_atom(module) -> {name, {module, []}}
      {name, {module, config}} -> {name, {module, config}}
    end)
    |> Map.new()
  end
end
```

### 4.2 FlowStone.Scatter.ReaderRegistry

```elixir
defmodule FlowStone.Scatter.ReaderRegistry do
  @moduledoc """
  Registry for ItemReader implementations.

  Allows runtime resolution of readers by name, with default config.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> load_from_config() end, name: __MODULE__)
  end

  @doc "Register an ItemReader"
  @spec register(atom(), module(), keyword()) :: :ok
  def register(name, module, default_config \\ []) do
    Agent.update(__MODULE__, &Map.put(&1, name, {module, default_config}))
  end

  @doc "Resolve ItemReader by name"
  @spec resolve(atom()) :: {:ok, {module(), keyword()}} | {:error, :not_found}
  def resolve(name) do
    case Agent.get(__MODULE__, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  @doc "Resolve and merge with asset-level config"
  @spec resolve_with_config(atom(), keyword()) :: {:ok, {module(), keyword()}} | {:error, :not_found}
  def resolve_with_config(name, asset_config) do
    case resolve(name) do
      {:ok, {module, default_config}} ->
        {:ok, {module, Keyword.merge(default_config, asset_config)}}
      error -> error
    end
  end

  defp load_from_config do
    Application.get_env(:flowstone, :item_readers, %{})
    |> Enum.map(fn
      {name, module} when is_atom(module) -> {name, {module, []}}
      {name, {module, config}} -> {name, {module, config}}
    end)
    |> Map.new()
  end
end
```

## 5. Integration Layer Contracts

### 5.1 FlowStone.AI Integration Pattern

Based on the flowstone_ai analysis, integration layers should:

```elixir
defmodule FlowStone.SomeFramework.Resource do
  @behaviour FlowStone.Resource

  @impl true
  def setup(config) do
    # Initialize external framework
    {:ok, %__MODULE__{client: SomeFramework.client(config)}}
  end

  @impl true
  def teardown(_resource), do: :ok

  @impl true
  def health_check(%{client: client}) do
    case SomeFramework.ping(client) do
      :ok -> :healthy
      error -> {:unhealthy, error}
    end
  end
end

defmodule FlowStone.SomeFramework.Helpers do
  @moduledoc "DSL helpers for assets using SomeFramework"

  def do_something(resource, input, opts \\ []) do
    # Delegate to external framework
    # Normalize response to FlowStone types
    case SomeFramework.call(resource.client, input, opts) do
      {:ok, result} -> {:ok, normalize_result(result)}
      {:error, error} -> {:error, FlowStone.Error.Normalizer.normalize(error)}
    end
  end
end
```

### 5.2 Telemetry Bridge Pattern

```elixir
defmodule FlowStone.SomeFramework.Telemetry do
  @moduledoc "Bridges external framework telemetry to FlowStone namespace"

  @external_events [
    [:some_framework, :call, :start],
    [:some_framework, :call, :stop],
    [:some_framework, :call, :exception]
  ]

  def attach do
    :telemetry.attach_many(
      "flowstone-some-framework-bridge",
      @external_events,
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:some_framework | rest], measurements, metadata, _config) do
    # Re-emit under flowstone namespace
    :telemetry.execute([:flowstone, :some_framework | rest], measurements, metadata)
  end
end
```

## 6. Plugin Registration

Plugins should register themselves on application start:

```elixir
defmodule FlowStoneScatter.Application do
  use Application

  def start(_type, _args) do
    # Register coordinator
    Application.put_env(:flowstone, :scatter_coordinator, FlowStone.Scatter.Impl)

    # Register any bundled readers
    FlowStone.Scatter.ReaderRegistry.register(:custom, FlowStone.Scatter.ItemReaders.Custom)

    children = [
      # Plugin supervision tree
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
```

## 7. Contract Versioning

Behaviors should include version information for compatibility checking:

```elixir
defmodule FlowStone.IO.Manager do
  @version "1.0.0"

  @doc "Return behavior version for compatibility checking"
  @callback version() :: String.t()

  @optional_callbacks [version: 0]
end
```

Core can check compatibility:

```elixir
def check_compatibility(module) do
  if function_exported?(module, :version, 0) do
    case Version.compare(module.version(), @min_version) do
      :lt -> {:error, :incompatible_version}
      _ -> :ok
    end
  else
    :ok  # Legacy modules without version are assumed compatible
  end
end
```

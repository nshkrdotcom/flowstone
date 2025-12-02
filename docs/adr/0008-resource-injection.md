# ADR-0008: Resource Injection Pattern

## Status
Accepted

## Context

Assets often need external dependencies:
- Database connections
- API clients
- ML model clients
- Configuration values
- Credentials

These should be:
- Injected, not globally accessed
- Testable with mocks
- Lifecycle-managed (setup/teardown)
- Health-checkable

## Decision

### 1. Resource Behaviour

```elixir
defmodule FlowStone.Resource do
  @callback setup(config :: map()) :: {:ok, resource :: term()} | {:error, term()}
  @callback teardown(resource :: term()) :: :ok
  @callback health_check(resource :: term()) :: :healthy | {:unhealthy, reason :: term()}

  @optional_callbacks [teardown: 1, health_check: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour FlowStone.Resource

      def teardown(_resource), do: :ok
      def health_check(_resource), do: :healthy

      defoverridable teardown: 1, health_check: 1
    end
  end
end
```

### 2. Resource Definitions

```elixir
defmodule MyApp.Resources.Database do
  use FlowStone.Resource

  def setup(config) do
    pool_config = [
      database: config[:database],
      username: config[:username],
      password: config[:password],
      hostname: config[:hostname],
      pool_size: config[:pool_size] || 10
    ]

    case DBConnection.start_link(pool_config) do
      {:ok, pool} -> {:ok, pool}
      {:error, reason} -> {:error, reason}
    end
  end

  def teardown(pool) do
    GenServer.stop(pool)
    :ok
  end

  def health_check(pool) do
    case DBConnection.execute(pool, "SELECT 1", []) do
      {:ok, _} -> :healthy
      {:error, reason} -> {:unhealthy, reason}
    end
  end
end

defmodule MyApp.Resources.MLClient do
  use FlowStone.Resource

  def setup(config) do
    client = %{
      endpoint: config[:endpoint],
      timeout: config[:timeout] || :timer.minutes(5),
      api_key: config[:api_key]
    }

    {:ok, client}
  end

  def health_check(%{endpoint: endpoint}) do
    case Req.get(endpoint <> "/health") do
      {:ok, %{status: 200}} -> :healthy
      {:ok, %{status: status}} -> {:unhealthy, {:status, status}}
      {:error, reason} -> {:unhealthy, reason}
    end
  end
end

defmodule MyApp.Resources.APIKey do
  use FlowStone.Resource

  def setup(config) do
    key = config[:key] || System.fetch_env!("API_KEY")
    {:ok, key}
  end
end
```

### 3. Resource Registration

```elixir
# config/config.exs
config :flowstone, :resources,
  database: {MyApp.Resources.Database, %{
    database: "myapp_prod",
    hostname: "db.example.com",
    username: {:system, "DB_USER"},
    password: {:system, "DB_PASSWORD"}
  }},
  ml_client: {MyApp.Resources.MLClient, %{
    endpoint: "http://ml-service:5000",
    api_key: {:system, "ML_API_KEY"}
  }},
  api_key: {MyApp.Resources.APIKey, %{
    key: {:system, "EXTERNAL_API_KEY"}
  }}
```

### 4. Resource Manager

```elixir
defmodule FlowStone.Resources do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    resources_config = Application.get_env(:flowstone, :resources, %{})

    resources =
      Enum.reduce(resources_config, %{}, fn {name, {module, config}}, acc ->
        config = resolve_config(config)

        case module.setup(config) do
          {:ok, resource} ->
            Map.put(acc, name, %{module: module, resource: resource, healthy: true})

          {:error, reason} ->
            Logger.error("Failed to setup resource #{name}: #{inspect(reason)}")
            acc
        end
      end)

    schedule_health_checks()
    {:ok, %{resources: resources}}
  end

  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  def load do
    GenServer.call(__MODULE__, :load_all)
  end

  def health do
    GenServer.call(__MODULE__, :health)
  end

  def handle_call({:get, name}, _from, %{resources: resources} = state) do
    case Map.get(resources, name) do
      nil -> {:reply, {:error, :not_found}, state}
      %{resource: resource} -> {:reply, {:ok, resource}, state}
    end
  end

  def handle_call(:load_all, _from, %{resources: resources} = state) do
    loaded =
      Enum.reduce(resources, %{}, fn {name, %{resource: resource}}, acc ->
        Map.put(acc, name, resource)
      end)

    {:reply, loaded, state}
  end

  def handle_call(:health, _from, %{resources: resources} = state) do
    health_status =
      Enum.map(resources, fn {name, %{module: module, resource: resource}} ->
        {name, module.health_check(resource)}
      end)
      |> Map.new()

    {:reply, health_status, state}
  end

  def handle_info(:health_check, %{resources: resources} = state) do
    updated_resources =
      Enum.reduce(resources, %{}, fn {name, %{module: module, resource: resource} = entry}, acc ->
        healthy = module.health_check(resource) == :healthy
        Map.put(acc, name, %{entry | healthy: healthy})
      end)

    schedule_health_checks()
    {:noreply, %{state | resources: updated_resources}}
  end

  defp schedule_health_checks do
    Process.send_after(self(), :health_check, :timer.seconds(30))
  end

  defp resolve_config(config) when is_map(config) do
    Enum.reduce(config, %{}, fn
      {key, {:system, env_var}}, acc ->
        Map.put(acc, key, System.get_env(env_var))

      {key, value}, acc when is_map(value) ->
        Map.put(acc, key, resolve_config(value))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end
end
```

### 5. Asset Resource Declaration

```elixir
asset :ml_predictions do
  depends_on [:preprocessed_data]
  requires [:database, :ml_client]

  execute fn context, %{preprocessed_data: data} ->
    %{database: db, ml_client: client} = context.resources

    # Use injected resources
    features = query_features(db, data)
    predictions = call_ml_service(client, features)

    {:ok, predictions}
  end
end
```

### 6. Context with Resources

```elixir
defmodule FlowStone.Context do
  defstruct [
    :asset,
    :partition,
    :run_id,
    :resources,
    :metadata,
    :started_at
  ]

  def build(asset, partition, run_id) do
    required_resources = FlowStone.Asset.requires(asset)
    all_resources = FlowStone.Resources.load()

    # Only include resources the asset declared
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

### 7. Testing with Mock Resources

```elixir
defmodule MyAssetTest do
  use ExUnit.Case
  use FlowStone.AssetCase

  setup do
    # Override resources for test
    mock_resources = %{
      database: MockDB.start_link!(),
      ml_client: MockMLClient.start_link!()
    }

    FlowStone.Resources.override(mock_resources)

    on_exit(fn ->
      FlowStone.Resources.reset()
    end)

    :ok
  end

  test "uses ML client for predictions" do
    MockMLClient.expect(:predict, fn features ->
      %{predictions: [0.8, 0.2, 0.5]}
    end)

    {:ok, result} = FlowStone.materialize(:ml_predictions, partition: ~D[2025-01-01])

    assert result.predictions == [0.8, 0.2, 0.5]
    MockMLClient.verify!()
  end
end
```

## Consequences

### Positive

1. **Testability**: Resources can be mocked without changing asset code.
2. **Lifecycle Management**: Setup/teardown handled centrally.
3. **Health Monitoring**: Periodic health checks for all resources.
4. **Configuration Separation**: Resource config in one place.
5. **Explicit Dependencies**: Assets declare what they need.

### Negative

1. **Indirection**: One more layer between assets and dependencies.
2. **Startup Order**: Resources must be available before assets execute.
3. **Testing Setup**: Requires mock resource infrastructure.

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| Global Application.get_env | Injected resources via context |
| Hidden dependencies | Explicit `requires` declaration |
| No resource cleanup | Supervised lifecycle management |
| Test mode env vars | Mock resource injection |

## References

- Dagster Resources: https://docs.dagster.io/concepts/resources
- Dependency Injection in Elixir: https://blog.appsignal.com/2022/10/25/dependency-injection-in-elixir.html

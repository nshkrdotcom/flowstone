# ADR-0007: Scheduling and Sensor Framework

## Status
Accepted

## Context

Production workflows need to run:
- On a schedule (daily at 2 AM, hourly, etc.)
- In response to events (new file in S3, database row inserted, webhook received)
- With dynamic partition generation (today's date, current hour)

We need a unified framework for time-based and event-based triggering.

## Decision

### 1. Cron Scheduling via Oban

Use Oban's cron plugin for time-based scheduling:

```elixir
# config/runtime.exs
config :flowstone, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Generated from FlowStone.schedule/2 calls at compile time
       {"0 2 * * *", FlowStone.Workers.ScheduledAsset, args: %{asset: "daily_report"}},
       {"*/15 * * * *", FlowStone.Workers.ScheduledAsset, args: %{asset: "realtime_metrics"}}
     ]}
  ]
```

### 2. Schedule API

```elixir
defmodule FlowStone do
  @doc "Schedule an asset for periodic materialization"
  def schedule(asset, opts) do
    cron = Keyword.fetch!(opts, :cron)
    timezone = Keyword.get(opts, :timezone, "UTC")
    partition_fn = Keyword.get(opts, :partition, fn -> Date.utc_today() end)

    schedule = %FlowStone.Schedule{
      asset: asset,
      cron: cron,
      timezone: timezone,
      partition_fn: partition_fn,
      enabled: true
    }

    {:ok, _} = FlowStone.Schedule.create(schedule)
    :ok
  end

  @doc "Remove a schedule"
  def unschedule(asset) do
    FlowStone.Schedule.delete(asset)
  end

  @doc "List all schedules"
  def list_schedules do
    FlowStone.Schedule.list()
  end
end

# Usage
FlowStone.schedule(:daily_report,
  cron: "0 2 * * *",           # 2 AM daily
  timezone: "America/New_York",
  partition: fn -> Date.utc_today() end
)

FlowStone.schedule(:hourly_metrics,
  cron: "0 * * * *",           # Every hour
  partition: fn ->
    DateTime.utc_now()
    |> DateTime.truncate(:hour)
  end
)
```

### 3. Scheduled Worker

```elixir
defmodule FlowStone.Workers.ScheduledAsset do
  use Oban.Worker, queue: :assets

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset" => asset_name}}) do
    asset = String.to_existing_atom(asset_name)

    schedule = FlowStone.Schedule.get(asset)
    partition = schedule.partition_fn.()

    FlowStone.materialize(asset, partition: partition)
  end
end
```

### 4. Sensor Framework

Sensors poll for external events and trigger materializations:

```elixir
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

### 5. Built-In Sensors

#### S3 File Arrival Sensor

```elixir
defmodule FlowStone.Sensors.S3FileArrival do
  @behaviour FlowStone.Sensor

  def init(config) do
    {:ok, %{
      bucket: config.bucket,
      prefix: config.prefix,
      last_keys: MapSet.new(),
      partition_fn: config[:partition_fn] || &extract_date_from_key/1
    }}
  end

  def poll(state) do
    case list_objects(state.bucket, state.prefix) do
      {:ok, current_keys} ->
        new_keys = MapSet.difference(current_keys, state.last_keys)

        case MapSet.to_list(new_keys) do
          [] ->
            {:no_trigger, state}

          [key | _rest] ->
            partition = state.partition_fn.(key)
            new_state = %{state | last_keys: current_keys}
            {:trigger, partition, new_state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp list_objects(bucket, prefix) do
    case ExAws.S3.list_objects(bucket, prefix: prefix) |> ExAws.request() do
      {:ok, %{body: %{contents: contents}}} ->
        keys = contents |> Enum.map(& &1.key) |> MapSet.new()
        {:ok, keys}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_date_from_key(key) do
    # Extract date from key like "data/2025-01-15/events.parquet"
    Regex.run(~r/(\d{4}-\d{2}-\d{2})/, key)
    |> case do
      [_, date_str] -> Date.from_iso8601!(date_str)
      _ -> Date.utc_today()
    end
  end
end
```

#### Database Table Sensor

```elixir
defmodule FlowStone.Sensors.DatabaseChange do
  @behaviour FlowStone.Sensor

  def init(config) do
    {:ok, %{
      query: config.query,
      repo: config[:repo] || FlowStone.Repo,
      last_value: nil,
      partition_fn: config[:partition_fn] || fn _ -> Date.utc_today() end
    }}
  end

  def poll(state) do
    case state.repo.query(state.query) do
      {:ok, %{rows: [[current_value]]}} when current_value != state.last_value ->
        partition = state.partition_fn.(current_value)
        {:trigger, partition, %{state | last_value: current_value}}

      {:ok, _} ->
        {:no_trigger, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
```

#### HTTP Webhook Sensor

```elixir
defmodule FlowStone.Sensors.Webhook do
  @behaviour FlowStone.Sensor

  def init(config) do
    {:ok, %{
      url: config.url,
      headers: config[:headers] || [],
      method: config[:method] || :get,
      check_fn: config[:check_fn] || fn body -> body["ready"] == true end,
      partition_fn: config[:partition_fn] || fn body -> body["partition"] end
    }}
  end

  def poll(state) do
    case Req.request(method: state.method, url: state.url, headers: state.headers) do
      {:ok, %{status: 200, body: body}} ->
        if state.check_fn.(body) do
          partition = state.partition_fn.(body)
          {:trigger, partition, state}
        else
          {:no_trigger, state}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
```

### 6. Sensor Registration

```elixir
sensor :new_data_files do
  type FlowStone.Sensors.S3FileArrival
  config %{
    bucket: "incoming-data",
    prefix: "events/",
    partition_fn: &extract_date/1
  }
  poll_interval :timer.seconds(30)

  on_trigger fn partition ->
    FlowStone.materialize(:raw_events, partition: partition)
  end
end

sensor :database_updates do
  type FlowStone.Sensors.DatabaseChange
  config %{
    query: "SELECT MAX(updated_at) FROM source_data",
    partition_fn: fn _ -> Date.utc_today() end
  }
  poll_interval :timer.minutes(5)

  on_trigger fn partition ->
    FlowStone.materialize(:derived_data, partition: partition)
  end
end
```

### 7. Sensor Supervisor

```elixir
defmodule FlowStone.Sensors.Supervisor do
  use Supervisor

  def start_link(sensors) do
    Supervisor.start_link(__MODULE__, sensors, name: __MODULE__)
  end

  def init(sensors) do
    children =
      Enum.map(sensors, fn sensor ->
        {FlowStone.Sensors.Worker, sensor}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule FlowStone.Sensors.Worker do
  use GenServer

  def start_link(sensor) do
    GenServer.start_link(__MODULE__, sensor, name: via_tuple(sensor.name))
  end

  def init(sensor) do
    {:ok, state} = sensor.module.init(sensor.config)

    schedule_poll(sensor.poll_interval)

    {:ok, %{sensor: sensor, state: state}}
  end

  def handle_info(:poll, %{sensor: sensor, state: state} = data) do
    new_state =
      case sensor.module.poll(state) do
        {:trigger, partition, new_state} ->
          sensor.on_trigger.(partition)
          new_state

        {:no_trigger, new_state} ->
          new_state

        {:error, reason, new_state} ->
          Logger.warning("Sensor #{sensor.name} poll failed: #{inspect(reason)}")
          new_state
      end

    schedule_poll(sensor.poll_interval)
    {:noreply, %{data | state: new_state}}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
```

## Consequences

### Positive

1. **Unified Triggering**: Cron and sensors use the same execution path.
2. **Extensible Sensors**: Easy to add custom sensors via behaviour.
3. **Supervised Polling**: Sensors recover from failures automatically.
4. **Partition Generation**: Dynamic partitions based on trigger context.

### Negative

1. **Polling Overhead**: Sensors poll periodically (not push-based).
2. **Cron Limitations**: Complex schedules may require Oban Pro.
3. **State Management**: Sensors maintain state that must survive restarts.

## References

- Oban Cron Plugin: https://hexdocs.pm/oban/Oban.Plugins.Cron.html
- Dagster Sensors: https://docs.dagster.io/concepts/partitions-schedules-sensors/sensors

# ADR-0011: Observability and Telemetry

## Status
Accepted

## Context

Production orchestration requires visibility into:
- Execution metrics (duration, success rate, throughput)
- Error tracking and alerting
- Resource utilization
- Lineage exploration
- Real-time status

We need a comprehensive observability strategy that integrates with existing monitoring infrastructure.

## Decision

### 1. Telemetry Events

Use `:telemetry` library for all instrumentation:

```elixir
defmodule FlowStone.Telemetry do
  @prefix [:flowstone]

  # Event definitions
  @events [
    # Materialization lifecycle
    [:flowstone, :materialization, :start],
    [:flowstone, :materialization, :stop],
    [:flowstone, :materialization, :exception],

    # I/O operations
    [:flowstone, :io, :load, :start],
    [:flowstone, :io, :load, :stop],
    [:flowstone, :io, :store, :start],
    [:flowstone, :io, :store, :stop],

    # Checkpoint events
    [:flowstone, :checkpoint, :requested],
    [:flowstone, :checkpoint, :approved],
    [:flowstone, :checkpoint, :rejected],
    [:flowstone, :checkpoint, :timeout],

    # Resource events
    [:flowstone, :resource, :health_check],

    # Sensor events
    [:flowstone, :sensor, :poll],
    [:flowstone, :sensor, :trigger]
  ]

  def events, do: @events
end
```

### 2. Telemetry Emission

```elixir
defmodule FlowStone.Materializer do
  def execute(asset, context, deps) do
    metadata = %{
      asset: asset,
      partition: context.partition,
      run_id: context.run_id
    }

    :telemetry.span(
      [:flowstone, :materialization],
      metadata,
      fn ->
        case do_execute(asset, context, deps) do
          {:ok, result} = success ->
            {success, Map.put(metadata, :result_size, estimate_size(result))}

          {:error, error} = failure ->
            {failure, Map.put(metadata, :error_type, error.type)}
        end
      end
    )
  end
end

defmodule FlowStone.IO do
  def load(asset, partition, config) do
    metadata = %{asset: asset, partition: partition, io_manager: config[:io_manager]}

    start_time = System.monotonic_time()
    :telemetry.execute([:flowstone, :io, :load, :start], %{}, metadata)

    result = do_load(asset, partition, config)

    duration = System.monotonic_time() - start_time

    measurements = %{
      duration: duration,
      size_bytes: if({:ok, data} = result, do: estimate_size(data), else: 0)
    }

    :telemetry.execute([:flowstone, :io, :load, :stop], measurements, metadata)

    result
  end
end
```

### 3. Metrics Integration

```elixir
defmodule FlowStone.Telemetry.Metrics do
  use Supervisor
  import Telemetry.Metrics

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      {TelemetryMetricsPrometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Materialization metrics
      counter("flowstone.materialization.start.count",
        tags: [:asset]
      ),
      counter("flowstone.materialization.stop.count",
        tags: [:asset, :status]
      ),
      distribution("flowstone.materialization.duration",
        unit: {:native, :millisecond},
        tags: [:asset]
      ),

      # I/O metrics
      counter("flowstone.io.load.count",
        tags: [:asset, :io_manager]
      ),
      distribution("flowstone.io.load.duration",
        unit: {:native, :millisecond},
        tags: [:asset, :io_manager]
      ),
      sum("flowstone.io.load.size_bytes",
        tags: [:asset, :io_manager]
      ),

      # Checkpoint metrics
      counter("flowstone.checkpoint.requested.count",
        tags: [:checkpoint]
      ),
      counter("flowstone.checkpoint.approved.count",
        tags: [:checkpoint]
      ),
      counter("flowstone.checkpoint.rejected.count",
        tags: [:checkpoint]
      ),
      distribution("flowstone.checkpoint.approval_time",
        unit: {:native, :second},
        tags: [:checkpoint]
      ),

      # Error metrics
      counter("flowstone.error.count",
        tags: [:asset, :error_type, :retryable]
      ),

      # Resource health
      last_value("flowstone.resource.healthy",
        tags: [:resource]
      )
    ]
  end
end
```

### 4. Structured Logging

```elixir
defmodule FlowStone.Logger do
  require Logger

  def log_materialization_start(asset, partition, run_id) do
    Logger.info("Materialization started",
      flowstone: true,
      event: :materialization_start,
      asset: asset,
      partition: serialize(partition),
      run_id: run_id
    )
  end

  def log_materialization_complete(asset, partition, run_id, duration_ms) do
    Logger.info("Materialization completed",
      flowstone: true,
      event: :materialization_complete,
      asset: asset,
      partition: serialize(partition),
      run_id: run_id,
      duration_ms: duration_ms
    )
  end

  def log_materialization_failed(asset, partition, run_id, error) do
    Logger.error("Materialization failed",
      flowstone: true,
      event: :materialization_failed,
      asset: asset,
      partition: serialize(partition),
      run_id: run_id,
      error_type: error.type,
      error_message: error.message,
      retryable: error.retryable
    )
  end

  def log_checkpoint_pending(checkpoint, approval_id) do
    Logger.info("Checkpoint pending approval",
      flowstone: true,
      event: :checkpoint_pending,
      checkpoint: checkpoint,
      approval_id: approval_id
    )
  end

  defp serialize(partition) when is_tuple(partition), do: inspect(partition)
  defp serialize(partition), do: to_string(partition)
end
```

### 5. Audit Log (Immutable)

For environments requiring audit trails:

```elixir
defmodule FlowStone.AuditLog do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "flowstone_audit_log" do
    field :event_type, :string
    field :actor_id, :string
    field :actor_type, :string  # system, user, api
    field :resource_type, :string  # asset, checkpoint, schedule
    field :resource_id, :string
    field :action, :string
    field :details, :map
    field :correlation_id, Ecto.UUID
    field :client_ip, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def log(event_type, opts) do
    %__MODULE__{
      event_type: event_type,
      actor_id: opts[:actor_id] || "system",
      actor_type: opts[:actor_type] || "system",
      resource_type: opts[:resource_type],
      resource_id: opts[:resource_id],
      action: opts[:action],
      details: opts[:details] || %{},
      correlation_id: opts[:correlation_id],
      client_ip: opts[:client_ip],
      user_agent: opts[:user_agent]
    }
    |> Repo.insert!()
  end
end

# Usage
FlowStone.AuditLog.log("checkpoint.approved",
  actor_id: user.id,
  actor_type: "user",
  resource_type: "checkpoint",
  resource_id: approval.id,
  action: "approve",
  details: %{reason: approval.reason},
  correlation_id: run_id
)
```

```sql
-- Immutable audit log table
CREATE TABLE flowstone_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type VARCHAR(100) NOT NULL,
  actor_id VARCHAR(255) NOT NULL,
  actor_type VARCHAR(50) NOT NULL,
  resource_type VARCHAR(100),
  resource_id VARCHAR(255),
  action VARCHAR(100),
  details JSONB DEFAULT '{}',
  correlation_id UUID,
  client_ip INET,
  user_agent TEXT,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- No UPDATE or DELETE allowed
REVOKE UPDATE, DELETE ON flowstone_audit_log FROM PUBLIC;

-- Query indexes
CREATE INDEX idx_audit_event_type ON flowstone_audit_log(event_type);
CREATE INDEX idx_audit_actor ON flowstone_audit_log(actor_id, actor_type);
CREATE INDEX idx_audit_resource ON flowstone_audit_log(resource_type, resource_id);
CREATE INDEX idx_audit_correlation ON flowstone_audit_log(correlation_id);
CREATE INDEX idx_audit_inserted ON flowstone_audit_log(inserted_at DESC);
```

### 6. PubSub for Real-Time Updates

```elixir
defmodule FlowStone.PubSub do
  @pubsub FlowStone.PubSub

  def subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  def broadcast(topic, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic, event)
  end

  # Topic helpers
  def materialization_topic, do: "materializations"
  def checkpoint_topic, do: "checkpoints"
  def asset_topic(asset), do: "asset:#{asset}"
  def run_topic(run_id), do: "run:#{run_id}"
end

# Emit events
FlowStone.PubSub.broadcast("materializations", {:materialization_started, %{
  asset: asset,
  partition: partition,
  run_id: run_id
}})

# Subscribe in LiveView
def mount(_params, _session, socket) do
  if connected?(socket) do
    FlowStone.PubSub.subscribe("materializations")
  end
  {:ok, socket}
end

def handle_info({:materialization_started, data}, socket) do
  {:noreply, update(socket, :running, &[data | &1])}
end
```

### 7. Health Endpoint

```elixir
defmodule FlowStoneWeb.HealthController do
  use FlowStoneWeb, :controller

  def check(conn, _params) do
    health = %{
      status: overall_status(),
      database: check_database(),
      oban: check_oban(),
      resources: FlowStone.Resources.health(),
      timestamp: DateTime.utc_now()
    }

    status_code = if health.status == :healthy, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(health)
  end

  defp overall_status do
    if check_database() == :healthy and check_oban() == :healthy do
      :healthy
    else
      :unhealthy
    end
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> :healthy
      _ -> :unhealthy
    end
  end

  defp check_oban do
    case Oban.check_queue(:assets) do
      %{paused: false} -> :healthy
      _ -> :unhealthy
    end
  end
end
```

## Consequences

### Positive

1. **Standardized Instrumentation**: :telemetry is the Elixir standard.
2. **Flexible Backends**: Prometheus, Datadog, custom handlers.
3. **Structured Logs**: Machine-parseable log format.
4. **Real-Time Updates**: PubSub for live dashboards.
5. **Audit Compliance**: Immutable audit log for regulated environments.

### Negative

1. **Telemetry Overhead**: Small performance cost for instrumentation.
2. **Log Volume**: Structured logging can produce large volumes.
3. **Infrastructure**: Requires Prometheus/Datadog/etc. setup.

## References

- Telemetry: https://hexdocs.pm/telemetry
- Telemetry.Metrics: https://hexdocs.pm/telemetry_metrics
- Phoenix.PubSub: https://hexdocs.pm/phoenix_pubsub

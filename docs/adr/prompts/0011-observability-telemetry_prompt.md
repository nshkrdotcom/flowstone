# Implementation Prompt: ADR-0011 Observability and Telemetry

## Objective

Implement comprehensive observability and telemetry using :telemetry, structured logging, and audit trails with TDD using Supertester.

## Required Reading

1. **ADR-0011**: `docs/adr/0011-observability-telemetry.md`
2. **Telemetry**: https://hexdocs.pm/telemetry
3. **Telemetry.Metrics**: https://hexdocs.pm/telemetry_metrics
4. **Phoenix.PubSub**: https://hexdocs.pm/phoenix_pubsub
5. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

FlowStone requires comprehensive observability for production orchestration:
- Real-time execution metrics (duration, success rate, throughput)
- Error tracking and alerting via telemetry events
- Resource utilization monitoring
- Immutable audit log for compliance
- PubSub for real-time dashboard updates
- Health check endpoints for monitoring

## Implementation Tasks

### 1. Telemetry Event Definitions

```elixir
# lib/flowstone/telemetry.ex
defmodule FlowStone.Telemetry do
  @prefix [:flowstone]

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
  def attach_default_handlers
  def list_handlers
end
```

### 2. Telemetry Metrics Module

```elixir
# lib/flowstone/telemetry/metrics.ex
defmodule FlowStone.Telemetry.Metrics do
  use Supervisor
  import Telemetry.Metrics

  def start_link(opts)
  def init(_opts)
  defp metrics()
end
```

### 3. Structured Logger

```elixir
# lib/flowstone/logger.ex
defmodule FlowStone.Logger do
  require Logger

  def log_materialization_start(asset, partition, run_id)
  def log_materialization_complete(asset, partition, run_id, duration_ms)
  def log_materialization_failed(asset, partition, run_id, error)
  def log_checkpoint_pending(checkpoint, approval_id)
end
```

### 4. Audit Log Schema

```elixir
# lib/flowstone/audit_log.ex
defmodule FlowStone.AuditLog do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "flowstone_audit_log" do
    field :event_type, :string
    field :actor_id, :string
    field :actor_type, :string  # system, user, api
    field :resource_type, :string
    field :resource_id, :string
    field :action, :string
    field :details, :map
    field :correlation_id, Ecto.UUID
    field :client_ip, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def log(event_type, opts)
end
```

### 5. PubSub Integration

```elixir
# lib/flowstone/pubsub.ex
defmodule FlowStone.PubSub do
  def subscribe(topic)
  def broadcast(topic, event)
  def materialization_topic
  def checkpoint_topic
  def asset_topic(asset)
  def run_topic(run_id)
end
```

### 6. Health Check Controller

```elixir
# lib/flowstone_web/controllers/health_controller.ex
defmodule FlowStoneWeb.HealthController do
  use FlowStoneWeb, :controller

  def check(conn, _params)
  defp overall_status
  defp check_database
  defp check_oban
end
```

## Test Design with Supertester

### Telemetry Event Tests

```elixir
defmodule FlowStone.TelemetryTest do
  use FlowStone.DataCase, async: true
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "telemetry events" do
    test "emits materialization start event" do
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:flowstone, :materialization, :start]
      ])

      asset = :test_asset
      partition = ~D[2025-01-15]
      run_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:flowstone, :materialization, :start],
        %{system_time: System.system_time()},
        %{asset: asset, partition: partition, run_id: run_id}
      )

      assert_receive {[:flowstone, :materialization, :start], ^ref, measurements, metadata}
      assert metadata.asset == asset
      assert metadata.partition == partition
      assert metadata.run_id == run_id

      :telemetry.detach(ref)
    end

    test "emits materialization stop event with duration" do
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:flowstone, :materialization, :stop]
      ])

      start_time = System.monotonic_time()
      Process.sleep(10)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:flowstone, :materialization, :stop],
        %{duration: duration},
        %{asset: :test_asset, status: :success}
      )

      assert_receive {[:flowstone, :materialization, :stop], ^ref, measurements, metadata}
      assert measurements.duration > 0
      assert metadata.status == :success

      :telemetry.detach(ref)
    end

    test "emits I/O load events with measurements" do
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:flowstone, :io, :load, :start],
        [:flowstone, :io, :load, :stop]
      ])

      :telemetry.execute(
        [:flowstone, :io, :load, :start],
        %{},
        %{asset: :test_asset, io_manager: :memory}
      )

      assert_receive {[:flowstone, :io, :load, :start], ^ref, _, _}

      :telemetry.execute(
        [:flowstone, :io, :load, :stop],
        %{duration: 1000, size_bytes: 1024},
        %{asset: :test_asset, io_manager: :memory}
      )

      assert_receive {[:flowstone, :io, :load, :stop], ^ref, measurements, _}
      assert measurements.duration == 1000
      assert measurements.size_bytes == 1024

      :telemetry.detach(ref)
    end
  end

  describe "telemetry span" do
    test "wraps execution with start and stop events" do
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:flowstone, :materialization, :start],
        [:flowstone, :materialization, :stop]
      ])

      result = :telemetry.span(
        [:flowstone, :materialization],
        %{asset: :test_asset, partition: ~D[2025-01-15]},
        fn ->
          {:ok, :result}
        end
      )

      assert result == {:ok, :result}
      assert_receive {[:flowstone, :materialization, :start], ^ref, _, _}
      assert_receive {[:flowstone, :materialization, :stop], ^ref, _, _}

      :telemetry.detach(ref)
    end

    test "emits exception event on failure" do
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:flowstone, :materialization, :exception]
      ])

      assert_raise RuntimeError, fn ->
        :telemetry.span(
          [:flowstone, :materialization],
          %{asset: :test_asset},
          fn -> raise "test error" end
        )
      end

      assert_receive {[:flowstone, :materialization, :exception], ^ref, _, metadata}
      assert metadata.kind == :error

      :telemetry.detach(ref)
    end
  end
end
```

### Audit Log Tests

```elixir
defmodule FlowStone.AuditLogTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.AuditLog

  describe "log/2" do
    test "creates immutable audit entry" do
      entry = AuditLog.log("checkpoint.approved", %{
        actor_id: "user_123",
        actor_type: "user",
        resource_type: "checkpoint",
        resource_id: "approval_456",
        action: "approve",
        details: %{reason: "Looks good"},
        correlation_id: Ecto.UUID.generate()
      })

      assert entry.event_type == "checkpoint.approved"
      assert entry.actor_id == "user_123"
      assert entry.actor_type == "user"
      assert entry.resource_type == "checkpoint"
      assert entry.action == "approve"
      assert entry.details.reason == "Looks good"
    end

    test "includes timestamp" do
      entry = AuditLog.log("test.event", %{
        actor_id: "system",
        actor_type: "system"
      })

      assert entry.inserted_at != nil
      refute Map.has_key?(entry, :updated_at)  # Immutable
    end

    test "supports correlation_id for tracing" do
      correlation_id = Ecto.UUID.generate()

      entry1 = AuditLog.log("workflow.started", %{
        actor_id: "system",
        actor_type: "system",
        correlation_id: correlation_id
      })

      entry2 = AuditLog.log("workflow.completed", %{
        actor_id: "system",
        actor_type: "system",
        correlation_id: correlation_id
      })

      assert entry1.correlation_id == correlation_id
      assert entry2.correlation_id == correlation_id

      # Query by correlation
      entries = Repo.all(
        from a in AuditLog,
        where: a.correlation_id == ^correlation_id,
        order_by: [asc: a.inserted_at]
      )

      assert length(entries) == 2
    end

    test "records client metadata" do
      entry = AuditLog.log("api.call", %{
        actor_id: "api_user",
        actor_type: "api",
        client_ip: "192.168.1.1",
        user_agent: "FlowStone-CLI/1.0"
      })

      assert entry.client_ip == "192.168.1.1"
      assert entry.user_agent == "FlowStone-CLI/1.0"
    end
  end

  describe "audit queries" do
    test "queries by event type" do
      AuditLog.log("user.login", %{actor_id: "user1", actor_type: "user"})
      AuditLog.log("user.logout", %{actor_id: "user1", actor_type: "user"})
      AuditLog.log("user.login", %{actor_id: "user2", actor_type: "user"})

      logins = Repo.all(from a in AuditLog, where: a.event_type == "user.login")
      assert length(logins) == 2
    end

    test "queries by actor" do
      AuditLog.log("action1", %{actor_id: "user1", actor_type: "user"})
      AuditLog.log("action2", %{actor_id: "user1", actor_type: "user"})
      AuditLog.log("action3", %{actor_id: "user2", actor_type: "user"})

      user1_actions = Repo.all(
        from a in AuditLog,
        where: a.actor_id == "user1"
      )

      assert length(user1_actions) == 2
    end

    test "queries by resource" do
      resource_id = Ecto.UUID.generate()

      AuditLog.log("resource.created", %{
        actor_id: "system",
        actor_type: "system",
        resource_type: "asset",
        resource_id: resource_id
      })

      AuditLog.log("resource.updated", %{
        actor_id: "user1",
        actor_type: "user",
        resource_type: "asset",
        resource_id: resource_id
      })

      history = Repo.all(
        from a in AuditLog,
        where: a.resource_type == "asset" and a.resource_id == ^resource_id,
        order_by: [asc: a.inserted_at]
      )

      assert length(history) == 2
      assert hd(history).action == nil  # created
      assert List.last(history).actor_type == "user"
    end
  end
end
```

### PubSub Tests

```elixir
defmodule FlowStone.PubSubTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.PubSub

  describe "subscribe/1 and broadcast/2" do
    test "delivers messages to subscribers" do
      PubSub.subscribe("test_topic")

      PubSub.broadcast("test_topic", {:test_event, %{data: "hello"}})

      assert_receive {:test_event, %{data: "hello"}}
    end

    test "does not deliver to unsubscribed processes" do
      # Don't subscribe

      PubSub.broadcast("test_topic", {:event, :data})

      refute_receive {:event, :data}, 100
    end

    test "supports multiple subscribers" do
      parent = self()

      task1 = Task.async(fn ->
        PubSub.subscribe("multi_topic")
        send(parent, {:subscribed, 1})
        assert_receive {:event, :data}
      end)

      task2 = Task.async(fn ->
        PubSub.subscribe("multi_topic")
        send(parent, {:subscribed, 2})
        assert_receive {:event, :data}
      end)

      assert_receive {:subscribed, 1}
      assert_receive {:subscribed, 2}

      PubSub.broadcast("multi_topic", {:event, :data})

      Task.await(task1)
      Task.await(task2)
    end
  end

  describe "topic helpers" do
    test "materialization_topic/0" do
      assert PubSub.materialization_topic() == "materializations"
    end

    test "checkpoint_topic/0" do
      assert PubSub.checkpoint_topic() == "checkpoints"
    end

    test "asset_topic/1" do
      assert PubSub.asset_topic(:daily_report) == "asset:daily_report"
    end

    test "run_topic/1" do
      run_id = Ecto.UUID.generate()
      assert PubSub.run_topic(run_id) == "run:#{run_id}"
    end
  end

  describe "materialization events" do
    test "broadcasts materialization started" do
      PubSub.subscribe(PubSub.materialization_topic())

      event_data = %{
        asset: :test_asset,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }

      PubSub.broadcast(
        PubSub.materialization_topic(),
        {:materialization_started, event_data}
      )

      assert_receive {:materialization_started, ^event_data}
    end

    test "broadcasts to asset-specific topic" do
      PubSub.subscribe(PubSub.asset_topic(:my_asset))

      PubSub.broadcast(
        PubSub.asset_topic(:my_asset),
        {:status_change, :running}
      )

      assert_receive {:status_change, :running}
    end
  end
end
```

### Health Check Tests

```elixir
defmodule FlowStoneWeb.HealthControllerTest do
  use FlowStoneWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 when all systems healthy", %{conn: conn} do
      conn = get(conn, "/health")

      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert response["status"] == "healthy"
      assert response["database"] == "healthy"
      assert response["oban"] == "healthy"
    end

    @tag :skip  # Requires test setup to make DB unhealthy
    test "returns 503 when database unhealthy", %{conn: conn} do
      # Mock database failure
      conn = get(conn, "/health")

      assert json_response(conn, 503)
      response = json_response(conn, 503)
      assert response["status"] == "unhealthy"
      assert response["database"] == "unhealthy"
    end

    test "includes timestamp in response", %{conn: conn} do
      conn = get(conn, "/health")

      response = json_response(conn, 200)
      assert response["timestamp"] != nil
    end
  end
end
```

### Telemetry Integration Tests

```elixir
defmodule FlowStone.Telemetry.IntegrationTest do
  use FlowStone.DataCase, async: false

  describe "materialization telemetry" do
    test "emits telemetry events during execution" do
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:flowstone, :materialization, :start],
        [:flowstone, :materialization, :stop]
      ])

      context = %FlowStone.Context{
        asset: :test_asset,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }

      # Execute materialization (assuming Materializer emits telemetry)
      {:ok, _result} = FlowStone.Materializer.execute(:test_asset, context, %{})

      assert_receive {[:flowstone, :materialization, :start], ^ref, _, metadata}
      assert metadata.asset == :test_asset

      assert_receive {[:flowstone, :materialization, :stop], ^ref, measurements, _}
      assert measurements.duration > 0

      :telemetry.detach(ref)
    end
  end
end
```

### Telemetry Performance Tests

```elixir
defmodule FlowStone.Telemetry.PerformanceTest do
  use FlowStone.DataCase, async: true
  use Supertester.PerformanceHelpers

  describe "telemetry overhead" do
    test "telemetry adds minimal overhead" do
      # Baseline: execute without telemetry
      baseline_duration = measure_duration(fn ->
        Enum.each(1..1000, fn _ ->
          # Simulate work
          :timer.sleep(1)
        end)
      end)

      # With telemetry: execute with telemetry events
      with_telemetry_duration = measure_duration(fn ->
        Enum.each(1..1000, fn _ ->
          :telemetry.execute([:flowstone, :test], %{}, %{})
          :timer.sleep(1)
        end)
      end)

      overhead_percent = ((with_telemetry_duration - baseline_duration) / baseline_duration) * 100

      # Assert overhead is less than 5%
      assert overhead_percent < 5.0
    end
  end

  defp measure_duration(fun) do
    start = System.monotonic_time(:microsecond)
    fun.()
    System.monotonic_time(:microsecond) - start
  end
end
```

## Implementation Order

1. **Telemetry module** - Event definitions and handler attachment
2. **Telemetry.Metrics** - Prometheus/metrics integration
3. **Audit log schema + migration** - Immutable audit trail
4. **PubSub module** - Real-time event broadcasting
5. **Structured logger** - Centralized logging
6. **Health controller** - Monitoring endpoints
7. **Integration with Materializer** - Emit events during execution

## Success Criteria

- [ ] All telemetry events defined and documented
- [ ] Telemetry handlers can be attached/detached
- [ ] Audit log records are immutable (no UPDATE/DELETE)
- [ ] PubSub broadcasts to multiple subscribers
- [ ] Health endpoint returns correct status codes
- [ ] Structured logs include required metadata
- [ ] Telemetry overhead is < 5%
- [ ] Integration tests verify end-to-end telemetry

## Commands

```bash
# Run all telemetry tests
mix test test/flowstone/telemetry_test.exs

# Run audit log tests
mix test test/flowstone/audit_log_test.exs

# Run PubSub tests
mix test test/flowstone/pubsub_test.exs

# Run health check tests
mix test test/flowstone_web/controllers/health_controller_test.exs

# Run integration tests
mix test test/flowstone/telemetry/integration_test.exs

# Check coverage
mix coveralls.html
```

## Spawn Subagents

1. **Telemetry events** - Event definitions and handlers
2. **Audit log** - Schema, migration, and immutable logging
3. **PubSub integration** - Real-time event broadcasting
4. **Health endpoint** - Monitoring and status checks
5. **Metrics integration** - Prometheus/Datadog support

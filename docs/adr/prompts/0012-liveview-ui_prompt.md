# Implementation Prompt: ADR-0012 Phoenix LiveView UI Integration

## Objective

Implement real-time Phoenix LiveView UI with dashboard, asset graph visualization, checkpoint approval interface, and lineage explorer using TDD with Supertester.

## Required Reading

1. **ADR-0012**: `docs/adr/0012-liveview-ui.md`
2. **ADR-0011**: `docs/adr/0011-observability-telemetry.md` (PubSub dependency)
3. **Phoenix LiveView**: https://hexdocs.pm/phoenix_live_view
4. **LiveView Testing**: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html
5. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

FlowStone ships with a Phoenix LiveView-based dashboard:
- Real-time updates via WebSocket (no polling)
- Asset graph visualization with Mermaid.js
- Checkpoint approval workflow UI
- Lineage explorer for data provenance
- Server-rendered UI with same Elixir codebase
- Responsive design for desktop and mobile

## Implementation Tasks

### 1. Dashboard LiveView

```elixir
# lib/flowstone_web/live/dashboard_live.ex
defmodule FlowStoneWeb.DashboardLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(_params, _session, socket)

  @impl true
  def handle_info({:materialization_started, data}, socket)
  def handle_info({:materialization_completed, data}, socket)
  def handle_info({:checkpoint_created, data}, socket)

  @impl true
  def render(assigns)

  defp list_running_materializations
  defp list_recent_materializations(opts)
  defp list_pending_checkpoints
  defp compute_stats
end
```

### 2. Asset Graph LiveView

```elixir
# lib/flowstone_web/live/asset_graph_live.ex
defmodule FlowStoneWeb.AssetGraphLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(_params, _session, socket)

  @impl true
  def handle_info({:materialization_started, %{asset: asset}}, socket)
  def handle_info({:materialization_completed, %{asset: asset, status: status}}, socket)

  @impl true
  def render(assigns)

  defp build_mermaid_graph(assets)
end
```

### 3. Checkpoints LiveView

```elixir
# lib/flowstone_web/live/checkpoints_live.ex
defmodule FlowStoneWeb.CheckpointsLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(_params, _session, socket)

  @impl true
  def handle_event("select", %{"id" => id}, socket)
  def handle_event("approve", %{"id" => id}, socket)
  def handle_event("reject", %{"id" => id, "reason" => reason}, socket)
  def handle_event("modify", %{"id" => id, "modifications" => mods}, socket)

  @impl true
  def handle_info({:checkpoint_created, checkpoint}, socket)
  def handle_info({:checkpoint_resolved, id}, socket)

  @impl true
  def render(assigns)
end
```

### 4. Lineage Explorer LiveView

```elixir
# lib/flowstone_web/live/lineage_live.ex
defmodule FlowStoneWeb.LineageLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(%{"asset" => asset_name}, _session, socket)

  @impl true
  def handle_event("change_partition", %{"partition" => partition}, socket)

  @impl true
  def render(assigns)

  defp latest_partition(asset)
  defp deserialize_partition(partition)
end
```

### 5. Component Library

```elixir
# lib/flowstone_web/components.ex
defmodule FlowStoneWeb.Components do
  use Phoenix.Component

  attr :stats, :map, required: true
  def stats_cards(assigns)

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, default: "gray"
  def stat_card(assigns)

  attr :asset, :atom, required: true
  attr :status, :atom, required: true
  def asset_status_badge(assigns)

  attr :status, :atom, required: true
  def status_icon(assigns)
end
```

### 6. JavaScript Hooks

```javascript
// assets/js/hooks/mermaid_graph.js
import mermaid from 'mermaid';

export const MermaidGraph = {
  mounted() {
    this.renderGraph();
  },

  updated() {
    this.renderGraph();
  },

  renderGraph() {
    // Render Mermaid diagram
    // Add click handlers for nodes
  }
};
```

## Test Design with Supertester

### Dashboard LiveView Tests

```elixir
defmodule FlowStoneWeb.DashboardLiveTest do
  use FlowStoneWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders dashboard with initial data", %{conn: conn} do
      {:ok, view, html} = live(conn, "/flowstone")

      assert html =~ "FlowStone Dashboard"
      assert has_element?(view, "[data-role=stats-cards]")
      assert has_element?(view, "[data-role=running-materializations]")
      assert has_element?(view, "[data-role=pending-checkpoints]")
    end

    test "subscribes to PubSub on connected mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone")

      # Verify subscription by broadcasting event
      FlowStone.PubSub.broadcast("materializations", {:materialization_started, %{
        asset: :test_asset,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }})

      # View should update
      assert render(view) =~ "test_asset"
    end

    test "loads running materializations", %{conn: conn} do
      # Create running materialization
      {:ok, mat} = create_materialization(%{
        asset_name: "test_asset",
        status: :running,
        partition: "2025-01-15"
      })

      {:ok, view, _html} = live(conn, "/flowstone")

      assert has_element?(view, "[data-asset=test_asset]")
    end

    test "loads pending checkpoints", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review"
      })

      {:ok, view, _html} = live(conn, "/flowstone")

      assert has_element?(view, "[data-checkpoint=review]")
    end
  end

  describe "real-time updates" do
    test "adds running materialization on start event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone")

      refute render(view) =~ "new_asset"

      FlowStone.PubSub.broadcast("materializations", {:materialization_started, %{
        asset: :new_asset,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate()
      }})

      assert render(view) =~ "new_asset"
    end

    test "moves to recent on completion", %{conn: conn} do
      run_id = Ecto.UUID.generate()

      {:ok, view, _html} = live(conn, "/flowstone")

      # Start materialization
      FlowStone.PubSub.broadcast("materializations", {:materialization_started, %{
        asset: :test_asset,
        partition: ~D[2025-01-15],
        run_id: run_id
      }})

      assert has_element?(view, "[data-role=running-materializations] [data-asset=test_asset]")

      # Complete materialization
      FlowStone.PubSub.broadcast("materializations", {:materialization_completed, %{
        asset: :test_asset,
        partition: ~D[2025-01-15],
        run_id: run_id,
        status: :success
      }})

      refute has_element?(view, "[data-role=running-materializations] [data-asset=test_asset]")
      assert has_element?(view, "[data-role=recent-activity] [data-asset=test_asset]")
    end

    test "updates stats on completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone")

      initial_completed = view |> element("[data-stat=completed-24h]") |> render()

      FlowStone.PubSub.broadcast("materializations", {:materialization_completed, %{
        asset: :test_asset,
        partition: ~D[2025-01-15],
        run_id: Ecto.UUID.generate(),
        status: :success
      }})

      updated_completed = view |> element("[data-stat=completed-24h]") |> render()

      assert initial_completed != updated_completed
    end

    test "adds pending checkpoint on creation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone")

      checkpoint_data = %{
        id: Ecto.UUID.generate(),
        checkpoint_name: "new_review",
        message: "Please review"
      }

      FlowStone.PubSub.broadcast("checkpoints", {:checkpoint_created, checkpoint_data})

      assert render(view) =~ "new_review"
    end
  end

  describe "stats computation" do
    test "computes running count", %{conn: conn} do
      create_materialization(%{asset_name: "asset1", status: :running})
      create_materialization(%{asset_name: "asset2", status: :running})
      create_materialization(%{asset_name: "asset3", status: :success})

      {:ok, view, _html} = live(conn, "/flowstone")

      assert view |> element("[data-stat=running]") |> render() =~ "2"
    end

    test "computes completed 24h count", %{conn: conn} do
      create_materialization(%{
        asset_name: "asset1",
        status: :success,
        completed_at: DateTime.utc_now()
      })

      create_materialization(%{
        asset_name: "asset2",
        status: :success,
        completed_at: DateTime.add(DateTime.utc_now(), -25, :hour)
      })

      {:ok, view, _html} = live(conn, "/flowstone")

      assert view |> element("[data-stat=completed-24h]") |> render() =~ "1"
    end
  end
end
```

### Asset Graph LiveView Tests

```elixir
defmodule FlowStoneWeb.AssetGraphLiveTest do
  use FlowStoneWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders asset graph", %{conn: conn} do
      {:ok, view, html} = live(conn, "/flowstone/graph")

      assert html =~ "Asset Graph"
      assert has_element?(view, "#mermaid-graph")
    end

    test "builds Mermaid graph from assets", %{conn: conn} do
      # Define test assets
      defmodule TestAssets do
        use FlowStone.Pipeline

        asset :source do
          execute fn _ctx, _deps -> {:ok, [1, 2, 3]} end
        end

        asset :transform do
          depends_on [:source]
          execute fn _ctx, %{source: data} -> {:ok, Enum.map(data, & &1 * 2)} end
        end
      end

      {:ok, view, html} = live(conn, "/flowstone/graph")

      # Should contain Mermaid graph syntax
      assert html =~ "graph TD"
      assert html =~ "source"
      assert html =~ "transform"
      assert html =~ "source --> transform"
    end
  end

  describe "real-time status updates" do
    test "updates asset status on materialization start", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone/graph")

      FlowStone.PubSub.broadcast("materializations", {:materialization_started, %{
        asset: :test_asset
      }})

      # Check status indicator updated
      assert view |> element("[data-asset=test_asset]") |> render() =~ "running"
    end

    test "updates asset status on completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone/graph")

      FlowStone.PubSub.broadcast("materializations", {:materialization_completed, %{
        asset: :test_asset,
        status: :success
      }})

      assert view |> element("[data-asset=test_asset]") |> render() =~ "success"
    end
  end
end
```

### Checkpoints LiveView Tests

```elixir
defmodule FlowStoneWeb.CheckpointsLiveTest do
  use FlowStoneWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders pending checkpoints", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review",
        message: "Please review this data"
      })

      {:ok, view, html} = live(conn, "/flowstone/checkpoints")

      assert html =~ "Pending Approvals"
      assert html =~ "review"
      assert html =~ "Please review this data"
    end

    test "subscribes to checkpoint events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone/checkpoints")

      checkpoint_data = %{
        id: Ecto.UUID.generate(),
        checkpoint_name: "new_checkpoint",
        message: "New approval needed"
      }

      FlowStone.PubSub.broadcast("checkpoints", {:checkpoint_created, checkpoint_data})

      assert render(view) =~ "new_checkpoint"
    end
  end

  describe "select checkpoint" do
    test "displays checkpoint details on selection", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review"
      })

      {:ok, view, _html} = live(conn, "/flowstone/checkpoints")

      refute has_element?(view, "[data-role=checkpoint-detail]")

      view |> element("[data-checkpoint-id=#{approval_id}]") |> render_click()

      assert has_element?(view, "[data-role=checkpoint-detail]")
    end
  end

  describe "approve checkpoint" do
    test "approves checkpoint and removes from list", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review"
      })

      conn = assign(conn, :current_user, %{id: "user_123"})
      {:ok, view, _html} = live(conn, "/flowstone/checkpoints")

      assert has_element?(view, "[data-checkpoint-id=#{approval_id}]")

      view
      |> element("[data-checkpoint-id=#{approval_id}]")
      |> render_click()

      view
      |> element("button[phx-click=approve]")
      |> render_click()

      refute has_element?(view, "[data-checkpoint-id=#{approval_id}]")

      # Verify approval in database
      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :approved
      assert approval.decision_by == "user_123"
    end
  end

  describe "reject checkpoint" do
    test "rejects with reason", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review"
      })

      conn = assign(conn, :current_user, %{id: "user_123"})
      {:ok, view, _html} = live(conn, "/flowstone/checkpoints")

      view
      |> element("[data-checkpoint-id=#{approval_id}]")
      |> render_click()

      view
      |> form("form[phx-submit=reject]", %{reason: "Data quality issues"})
      |> render_submit()

      refute has_element?(view, "[data-checkpoint-id=#{approval_id}]")

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :rejected
      assert approval.reason == "Data quality issues"
    end
  end

  describe "modify checkpoint" do
    test "stores modifications and approves", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review"
      })

      conn = assign(conn, :current_user, %{id: "user_123"})
      {:ok, view, _html} = live(conn, "/flowstone/checkpoints")

      view
      |> element("[data-checkpoint-id=#{approval_id}]")
      |> render_click()

      modifications = %{redacted_fields: ["sensitive"]}

      view
      |> form("form[phx-submit=modify]", %{modifications: Jason.encode!(modifications)})
      |> render_submit()

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :modified
      assert approval.modifications == modifications
    end
  end

  describe "real-time updates" do
    test "removes resolved checkpoint from list", %{conn: conn} do
      {:pending, approval_id} = create_pending_approval(%{
        checkpoint_name: "review"
      })

      {:ok, view, _html} = live(conn, "/flowstone/checkpoints")

      assert has_element?(view, "[data-checkpoint-id=#{approval_id}]")

      # Simulate external approval
      FlowStone.PubSub.broadcast("checkpoints", {:checkpoint_resolved, approval_id})

      refute has_element?(view, "[data-checkpoint-id=#{approval_id}]")
    end
  end
end
```

### Lineage Explorer LiveView Tests

```elixir
defmodule FlowStoneWeb.LineageLiveTest do
  use FlowStoneWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders lineage explorer", %{conn: conn} do
      {:ok, view, html} = live(conn, "/flowstone/lineage/test_asset")

      assert html =~ "Lineage: test_asset"
      assert has_element?(view, "[data-role=lineage-graph]")
    end

    test "loads upstream and downstream lineage", %{conn: conn} do
      # Create lineage records
      create_lineage_entry(%{
        asset_name: "downstream_asset",
        upstream_asset: "test_asset"
      })

      create_lineage_entry(%{
        asset_name: "test_asset",
        upstream_asset: "upstream_asset"
      })

      {:ok, view, html} = live(conn, "/flowstone/lineage/test_asset")

      assert html =~ "upstream_asset"
      assert html =~ "downstream_asset"
    end
  end

  describe "partition selection" do
    test "changes lineage on partition change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flowstone/lineage/test_asset")

      view
      |> element("form[phx-submit=change_partition]")
      |> render_change(%{partition: "2025-01-14"})

      # Verify lineage reloaded for new partition
      assert has_element?(view, "[data-partition='2025-01-14']")
    end
  end
end
```

### Component Tests

```elixir
defmodule FlowStoneWeb.ComponentsTest do
  use FlowStoneWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "stats_cards/1" do
    test "renders all stat cards" do
      assigns = %{
        stats: %{
          running: 5,
          completed_24h: 42,
          failed_24h: 3,
          pending_approvals: 2
        }
      }

      html = rendered_to_string(~H"""
      <FlowStoneWeb.Components.stats_cards stats={@stats} />
      """)

      assert html =~ "5"
      assert html =~ "42"
      assert html =~ "3"
      assert html =~ "2"
    end
  end

  describe "asset_status_badge/1" do
    test "renders running status" do
      assigns = %{asset: :test_asset, status: :running}

      html = rendered_to_string(~H"""
      <FlowStoneWeb.Components.asset_status_badge asset={@asset} status={@status} />
      """)

      assert html =~ "test_asset"
      assert html =~ "running"
    end

    test "renders success status" do
      assigns = %{asset: :test_asset, status: :success}

      html = rendered_to_string(~H"""
      <FlowStoneWeb.Components.asset_status_badge asset={@asset} status={@status} />
      """)

      assert html =~ "success"
    end
  end
end
```

## Implementation Order

1. **Component library** - Reusable UI components
2. **Dashboard LiveView** - Main dashboard with stats
3. **Asset Graph LiveView** - Visualization with Mermaid.js
4. **Checkpoints LiveView** - Approval workflow UI
5. **Lineage LiveView** - Data provenance explorer
6. **JavaScript hooks** - Mermaid rendering, interactions
7. **Router integration** - Mount LiveViews in Phoenix router

## Success Criteria

- [ ] Dashboard renders with real-time updates
- [ ] Asset graph visualizes dependencies correctly
- [ ] Checkpoint approval workflow functional
- [ ] Lineage explorer shows upstream/downstream
- [ ] PubSub updates trigger UI changes
- [ ] Components are reusable and tested
- [ ] JavaScript hooks work for Mermaid rendering
- [ ] All LiveViews handle disconnection gracefully

## Commands

```bash
# Run all LiveView tests
mix test test/flowstone_web/live/

# Run dashboard tests
mix test test/flowstone_web/live/dashboard_live_test.exs

# Run checkpoint tests
mix test test/flowstone_web/live/checkpoints_live_test.exs

# Run component tests
mix test test/flowstone_web/components_test.exs

# Check coverage
mix coveralls.html

# Start Phoenix server
mix phx.server
```

## Spawn Subagents

1. **Component library** - Reusable UI components
2. **Dashboard LiveView** - Main dashboard implementation
3. **Checkpoints LiveView** - Approval workflow UI
4. **Asset Graph LiveView** - Visualization with Mermaid
5. **Lineage LiveView** - Data lineage explorer
6. **JavaScript hooks** - Client-side interactivity

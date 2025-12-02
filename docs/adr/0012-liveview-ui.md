# ADR-0012: Phoenix LiveView UI Integration

## Status
Accepted

## Context

Orchestration UIs typically suffer from:
- Polling-based updates (stale data, server load)
- Separate frontend/backend codebases
- Complex WebSocket management
- Limited real-time capabilities

Phoenix LiveView provides:
- Server-rendered, real-time UI
- WebSocket-based updates out of the box
- Same language for frontend and backend
- Excellent developer experience

## Decision

### 1. LiveView as Primary UI

FlowStone ships with a Phoenix LiveView-based dashboard:

```elixir
# Mount FlowStone UI in your Phoenix router
scope "/flowstone", FlowStoneWeb do
  pipe_through [:browser, :authenticate]

  live "/", DashboardLive, :index
  live "/assets", AssetsLive, :index
  live "/assets/:name", AssetDetailLive, :show
  live "/runs", RunsLive, :index
  live "/runs/:id", RunDetailLive, :show
  live "/checkpoints", CheckpointsLive, :index
  live "/schedules", SchedulesLive, :index
  live "/lineage/:asset", LineageLive, :show
end
```

### 2. Real-Time Dashboard

```elixir
defmodule FlowStoneWeb.DashboardLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      FlowStone.PubSub.subscribe("materializations")
      FlowStone.PubSub.subscribe("checkpoints")
    end

    socket =
      socket
      |> assign(:running, list_running_materializations())
      |> assign(:recent, list_recent_materializations(limit: 20))
      |> assign(:pending_checkpoints, list_pending_checkpoints())
      |> assign(:stats, compute_stats())

    {:ok, socket}
  end

  @impl true
  def handle_info({:materialization_started, data}, socket) do
    {:noreply, update(socket, :running, &[data | &1])}
  end

  def handle_info({:materialization_completed, data}, socket) do
    socket =
      socket
      |> update(:running, &Enum.reject(&1, fn m -> m.run_id == data.run_id end))
      |> update(:recent, &[data | Enum.take(&1, 19)])
      |> update(:stats, &update_stats(&1, data))

    {:noreply, socket}
  end

  def handle_info({:checkpoint_created, data}, socket) do
    {:noreply, update(socket, :pending_checkpoints, &[data | &1])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flowstone-dashboard">
      <.stats_cards stats={@stats} />

      <div class="grid grid-cols-2 gap-4">
        <.running_materializations materializations={@running} />
        <.pending_checkpoints checkpoints={@pending_checkpoints} />
      </div>

      <.recent_activity materializations={@recent} />
    </div>
    """
  end
end
```

### 3. Asset Graph Visualization

```elixir
defmodule FlowStoneWeb.AssetGraphLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    assets = FlowStone.list_assets()
    graph = build_mermaid_graph(assets)

    if connected?(socket) do
      FlowStone.PubSub.subscribe("materializations")
    end

    {:ok, assign(socket, assets: assets, graph: graph, status: %{})}
  end

  @impl true
  def handle_info({:materialization_started, %{asset: asset}}, socket) do
    {:noreply, update(socket, :status, &Map.put(&1, asset, :running))}
  end

  def handle_info({:materialization_completed, %{asset: asset, status: status}}, socket) do
    {:noreply, update(socket, :status, &Map.put(&1, asset, status))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="asset-graph">
      <div id="mermaid-graph" phx-hook="MermaidGraph" data-graph={@graph}>
        <%= raw(@graph) %>
      </div>

      <.asset_legend />

      <div class="asset-list">
        <%= for asset <- @assets do %>
          <.asset_status_badge
            asset={asset}
            status={Map.get(@status, asset.name, :idle)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp build_mermaid_graph(assets) do
    nodes =
      Enum.map(assets, fn asset ->
        "    #{asset.name}[#{asset.name}]"
      end)

    edges =
      Enum.flat_map(assets, fn asset ->
        Enum.map(asset.depends_on, fn dep ->
          "    #{dep} --> #{asset.name}"
        end)
      end)

    """
    graph TD
    #{Enum.join(nodes, "\n")}
    #{Enum.join(edges, "\n")}
    """
  end
end
```

### 4. Checkpoint Approval UI

```elixir
defmodule FlowStoneWeb.CheckpointsLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      FlowStone.PubSub.subscribe("checkpoints")
    end

    checkpoints = FlowStone.Checkpoint.list_pending()
    {:ok, assign(socket, checkpoints: checkpoints, selected: nil)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    checkpoint = FlowStone.Checkpoint.get(id)
    {:noreply, assign(socket, selected: checkpoint)}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    :ok = FlowStone.Checkpoint.approve(id, by: socket.assigns.current_user.id)
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event("reject", %{"id" => id, "reason" => reason}, socket) do
    :ok = FlowStone.Checkpoint.reject(id, reason, by: socket.assigns.current_user.id)
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event("modify", %{"id" => id, "modifications" => mods}, socket) do
    :ok = FlowStone.Checkpoint.modify(id, mods, by: socket.assigns.current_user.id)
    {:noreply, assign(socket, selected: nil)}
  end

  @impl true
  def handle_info({:checkpoint_created, checkpoint}, socket) do
    {:noreply, update(socket, :checkpoints, &[checkpoint | &1])}
  end

  def handle_info({:checkpoint_resolved, id}, socket) do
    checkpoints = Enum.reject(socket.assigns.checkpoints, &(&1.id == id))
    selected = if socket.assigns.selected && socket.assigns.selected.id == id, do: nil, else: socket.assigns.selected
    {:noreply, assign(socket, checkpoints: checkpoints, selected: selected)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="checkpoints-container">
      <h1>Pending Approvals</h1>

      <div class="grid grid-cols-3 gap-4">
        <div class="checkpoint-list col-span-1">
          <%= for checkpoint <- @checkpoints do %>
            <.checkpoint_card
              checkpoint={checkpoint}
              selected={@selected && @selected.id == checkpoint.id}
              on_click="select"
            />
          <% end %>
        </div>

        <div class="checkpoint-detail col-span-2">
          <%= if @selected do %>
            <.checkpoint_detail
              checkpoint={@selected}
              on_approve="approve"
              on_reject="reject"
              on_modify="modify"
            />
          <% else %>
            <p class="text-gray-500">Select a checkpoint to review</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
```

### 5. Lineage Explorer

```elixir
defmodule FlowStoneWeb.LineageLive do
  use FlowStoneWeb, :live_view

  @impl true
  def mount(%{"asset" => asset_name}, _session, socket) do
    asset = String.to_existing_atom(asset_name)
    partition = socket.assigns[:partition] || latest_partition(asset)

    upstream = FlowStone.Lineage.upstream(asset, partition)
    downstream = FlowStone.Lineage.downstream(asset, partition)
    materialization = FlowStone.Materialization.get(asset, partition)

    socket =
      socket
      |> assign(:asset, asset)
      |> assign(:partition, partition)
      |> assign(:upstream, upstream)
      |> assign(:downstream, downstream)
      |> assign(:materialization, materialization)

    {:ok, socket}
  end

  @impl true
  def handle_event("change_partition", %{"partition" => partition}, socket) do
    partition = deserialize_partition(partition)

    upstream = FlowStone.Lineage.upstream(socket.assigns.asset, partition)
    downstream = FlowStone.Lineage.downstream(socket.assigns.asset, partition)
    materialization = FlowStone.Materialization.get(socket.assigns.asset, partition)

    {:noreply, assign(socket,
      partition: partition,
      upstream: upstream,
      downstream: downstream,
      materialization: materialization
    )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lineage-explorer">
      <header>
        <h1>Lineage: <%= @asset %></h1>
        <.partition_selector
          asset={@asset}
          selected={@partition}
          on_change="change_partition"
        />
      </header>

      <div class="lineage-graph">
        <.lineage_tree direction="upstream" nodes={@upstream} />
        <.current_asset asset={@asset} materialization={@materialization} />
        <.lineage_tree direction="downstream" nodes={@downstream} />
      </div>

      <%= if @materialization do %>
        <.materialization_details materialization={@materialization} />
      <% end %>
    </div>
    """
  end
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
    const container = this.el;
    const graph = container.dataset.graph;

    mermaid.initialize({ startOnLoad: false, theme: 'default' });
    mermaid.render('mermaid-svg', graph).then(({ svg }) => {
      container.innerHTML = svg;

      // Add click handlers for nodes
      container.querySelectorAll('.node').forEach(node => {
        node.style.cursor = 'pointer';
        node.addEventListener('click', () => {
          const assetName = node.id.replace('flowchart-', '').split('-')[0];
          this.pushEvent('select_asset', { asset: assetName });
        });
      });
    });
  }
};
```

### 7. Component Library

```elixir
defmodule FlowStoneWeb.Components do
  use Phoenix.Component

  attr :stats, :map, required: true
  def stats_cards(assigns) do
    ~H"""
    <div class="stats-grid">
      <.stat_card title="Running" value={@stats.running} color="blue" />
      <.stat_card title="Completed (24h)" value={@stats.completed_24h} color="green" />
      <.stat_card title="Failed (24h)" value={@stats.failed_24h} color="red" />
      <.stat_card title="Pending Approvals" value={@stats.pending_approvals} color="yellow" />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, default: "gray"
  def stat_card(assigns) do
    ~H"""
    <div class={"stat-card bg-#{@color}-50 border-#{@color}-200"}>
      <div class="stat-value"><%= @value %></div>
      <div class="stat-title"><%= @title %></div>
    </div>
    """
  end

  attr :asset, :atom, required: true
  attr :status, :atom, required: true
  def asset_status_badge(assigns) do
    ~H"""
    <div class={"asset-badge status-#{@status}"}>
      <.status_icon status={@status} />
      <span><%= @asset %></span>
    </div>
    """
  end

  attr :status, :atom, required: true
  def status_icon(assigns) do
    ~H"""
    <%= case @status do %>
      <% :running -> %>
        <svg class="animate-spin">...</svg>
      <% :success -> %>
        <svg class="text-green-500">...</svg>
      <% :failed -> %>
        <svg class="text-red-500">...</svg>
      <% :waiting_approval -> %>
        <svg class="text-yellow-500">...</svg>
      <% _ -> %>
        <svg class="text-gray-400">...</svg>
    <% end %>
    """
  end
end
```

## Consequences

### Positive

1. **Real-Time Updates**: WebSocket-based, no polling.
2. **Single Codebase**: Elixir for frontend and backend.
3. **Fast Development**: LiveView enables rapid UI iteration.
4. **Responsive**: Works on desktop and mobile.
5. **Accessible**: Server-rendered HTML by default.

### Negative

1. **Phoenix Dependency**: Requires Phoenix framework.
2. **JavaScript for Complex Interactions**: Some features need JS hooks.
3. **Latency Sensitivity**: Round-trip for all interactions.

### Anti-Patterns Avoided

| Common Problem | FlowStone Solution |
|----------------|-------------------|
| Polling for updates | WebSocket push via LiveView |
| Separate frontend repo | Elixir-only codebase |
| Stale dashboard data | Real-time PubSub updates |
| Complex state management | Server-side state in LiveView |

## References

- Phoenix LiveView: https://hexdocs.pm/phoenix_live_view
- Mermaid.js: https://mermaid.js.org/
- Tailwind CSS: https://tailwindcss.com/

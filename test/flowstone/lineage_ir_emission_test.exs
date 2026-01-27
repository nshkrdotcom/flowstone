defmodule FlowStone.LineageIRTestAdapter do
  @moduledoc false

  @behaviour LineageIR.Sink.Adapter

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn -> %{events: [], traces: [], spans: [], artifacts: [], edges: []} end,
      name: __MODULE__
    )
  end

  def reset do
    Agent.update(__MODULE__, fn _ ->
      %{events: [], traces: [], spans: [], artifacts: [], edges: []}
    end)
  end

  def data do
    Agent.get(__MODULE__, & &1)
  end

  @impl true
  def write_event(event, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :events, &[event | &1])
    end)

    :ok
  end

  @impl true
  def write_trace(trace, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :traces, &[trace | &1])
    end)

    :ok
  end

  @impl true
  def write_span(span, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :spans, &[span | &1])
    end)

    :ok
  end

  @impl true
  def write_artifact(artifact, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :artifacts, &[artifact | &1])
    end)

    :ok
  end

  @impl true
  def write_edge(edge, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :edges, &[edge | &1])
    end)

    :ok
  end
end

defmodule FlowStone.LineageIREmissionTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :hello do
      execute fn _, _ -> {:ok, "hi"} end
    end
  end

  setup do
    {:ok, _} = start_supervised(FlowStone.LineageIRTestAdapter)

    :ok
  end

  test "emits lineage IR span and artifact events" do
    FlowStone.LineageIRTestAdapter.reset()

    assert {:ok, "hi"} =
             FlowStone.run(Pipeline, :hello,
               lineage_ir: true,
               lineage_opts: [adapter: FlowStone.LineageIRTestAdapter]
             )

    data = FlowStone.LineageIRTestAdapter.data()
    event_types = Enum.map(data.events, & &1.type)

    assert "trace_start" in event_types
    assert "span_start" in event_types
    assert "span_end" in event_types
    assert "artifact" in event_types

    assert [_ | _] = data.spans
    assert [_ | _] = data.artifacts
  end
end

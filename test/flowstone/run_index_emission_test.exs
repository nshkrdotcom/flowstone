defmodule FlowStone.RunIndexTestAdapter do
  @moduledoc false

  @behaviour FlowStone.RunIndex.Adapter

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{runs: [], steps: []} end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{runs: [], steps: []} end)
  end

  def data do
    Agent.get(__MODULE__, & &1)
  end

  @impl true
  def write_run(attrs, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :runs, &[attrs | &1])
    end)

    :ok
  end

  @impl true
  def write_step(attrs, _opts) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :steps, &[attrs | &1])
    end)

    :ok
  end
end

defmodule FlowStone.RunIndexEmissionTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :hello do
      execute fn _, _ -> {:ok, "hi"} end
    end
  end

  setup do
    {:ok, _} = start_supervised(FlowStone.RunIndexTestAdapter)

    :ok
  end

  test "emits run and step records for execution" do
    FlowStone.RunIndexTestAdapter.reset()

    assert {:ok, "hi"} =
             FlowStone.run(Pipeline, :hello, run_index_adapter: FlowStone.RunIndexTestAdapter)

    data = FlowStone.RunIndexTestAdapter.data()

    assert Enum.any?(data.runs, &(&1.status == "running"))
    assert Enum.any?(data.runs, &(&1.status == "succeeded"))

    assert Enum.any?(data.steps, &(&1.status == "running" and &1.step_key == "hello"))
    assert Enum.any?(data.steps, &(&1.status == "succeeded" and &1.step_key == "hello"))
  end
end

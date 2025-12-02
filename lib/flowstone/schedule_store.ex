defmodule FlowStone.ScheduleStore do
  @moduledoc """
  In-memory schedule registry.
  """

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  def put(schedule, server \\ __MODULE__) do
    Agent.update(server, &Map.put(&1, schedule.asset, schedule))
  end

  def delete(asset, server \\ __MODULE__) do
    Agent.update(server, &Map.delete(&1, asset))
  end

  def list(server \\ __MODULE__) do
    Agent.get(server, &Map.values/1)
  end
end

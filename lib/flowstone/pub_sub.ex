defmodule FlowStone.PubSub do
  @moduledoc """
  PubSub helper wrapper.
  """

  @pubsub FlowStone.PubSub.Server

  def child_spec(opts) do
    name = Keyword.get(opts, :name, @pubsub)
    adapter = Keyword.get(opts, :adapter, Phoenix.PubSub.PG2)

    Phoenix.PubSub.child_spec(name: name, adapter: adapter)
  end

  def subscribe(topic, server \\ @pubsub) do
    Phoenix.PubSub.subscribe(server, topic)
  end

  def broadcast(topic, message, server \\ @pubsub) do
    Phoenix.PubSub.broadcast(server, topic, message)
  end

  def materialization_topic, do: "materializations"
  def checkpoint_topic, do: "checkpoints"
  def asset_topic(asset), do: "asset:#{asset}"
  def run_topic(run_id), do: "run:#{run_id}"
end

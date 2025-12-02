defmodule FlowStone.Checkpoint.Notifier do
  @moduledoc """
  Stub notifier for checkpoint events.
  """

  @callback notify(event :: atom(), payload :: map()) :: :ok

  @doc """
  Default no-op notifier.
  """
  @spec notify(atom(), map()) :: :ok
  def notify(_event, _payload), do: :ok
end

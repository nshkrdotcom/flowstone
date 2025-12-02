defmodule FlowStone.Schedule do
  @moduledoc """
  Represents a scheduled asset materialization configuration.
  """

  defstruct [:asset, :cron, timezone: "UTC", partition_fn: nil, enabled: true]

  @type t :: %__MODULE__{
          asset: atom(),
          cron: String.t(),
          timezone: String.t(),
          partition_fn: (-> term()) | nil,
          enabled: boolean()
        }
end

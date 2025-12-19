defmodule FlowStone.ParallelBranch do
  @moduledoc """
  Configuration for a single parallel branch.
  """

  @enforce_keys [:name, :final]
  defstruct [:name, :final, required: true, timeout: nil]

  @type t :: %__MODULE__{
          name: atom(),
          final: atom(),
          required: boolean(),
          timeout: non_neg_integer() | :infinity | nil
        }
end

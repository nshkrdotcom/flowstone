defmodule FlowStone.Sensor do
  @moduledoc """
  Behaviour for polling sensors.
  """

  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback poll(state :: term()) ::
              {:trigger, partition :: term(), new_state :: term()}
              | {:no_trigger, new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}
  @callback cleanup(state :: term()) :: :ok

  @optional_callbacks cleanup: 1
end

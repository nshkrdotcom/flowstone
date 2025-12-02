defmodule FlowStone.Resource do
  @moduledoc """
  Behaviour for defining injectable resources.
  """

  @callback setup(config :: map()) :: {:ok, term()} | {:error, term()}
  @callback teardown(resource :: term()) :: :ok
  @callback health_check(resource :: term()) :: :healthy | {:unhealthy, term()}

  @optional_callbacks teardown: 1, health_check: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour FlowStone.Resource

      @impl true
      def teardown(_resource), do: :ok

      @impl true
      def health_check(_resource), do: :healthy

      defoverridable teardown: 1, health_check: 1
    end
  end
end

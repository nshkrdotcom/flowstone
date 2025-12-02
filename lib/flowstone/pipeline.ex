defmodule FlowStone.Pipeline do
  @moduledoc """
  Elixir DSL for defining FlowStone assets.

  Usage:

      defmodule MyPipeline do
        use FlowStone.Pipeline

        asset :raw do
          description "Raw input"
          execute fn _context, _deps -> {:ok, :raw} end
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import FlowStone.Pipeline
      Module.register_attribute(__MODULE__, :flowstone_assets, accumulate: true)
      @after_compile FlowStone.Pipeline
      @before_compile FlowStone.Pipeline
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __flowstone_assets__ do
        :persistent_term.get({__MODULE__, :flowstone_assets}, [])
      end
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    assets =
      env.module
      |> Module.get_attribute(:flowstone_assets)
      |> Enum.reverse()

    :persistent_term.put({env.module, :flowstone_assets}, assets)
  end

  defmacro asset(name, do: block) do
    quote do
      var!(current_asset) = %FlowStone.Asset{
        name: unquote(name),
        module: __MODULE__,
        line: unquote(__CALLER__.line)
      }

      unquote(block)

      @flowstone_assets var!(current_asset)
    end
  end

  defmacro description(text) do
    quote do
      var!(current_asset) = %{var!(current_asset) | description: unquote(text)}
    end
  end

  defmacro depends_on(deps) when is_list(deps) do
    quote do
      var!(current_asset) = %{var!(current_asset) | depends_on: unquote(deps)}
    end
  end

  defmacro execute(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | execute_fn: unquote(fun)}
    end
  end
end

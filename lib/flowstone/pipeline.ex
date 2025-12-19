defmodule FlowStone.Pipeline do
  @moduledoc """
  Elixir DSL for defining FlowStone assets.

  ## Basic Usage

      defmodule MyPipeline do
        use FlowStone.Pipeline

        asset :raw do
          description "Raw input"
          execute fn _context, _deps -> {:ok, :raw} end
        end
      end

  ## Scatter (Dynamic Fan-Out)

      asset :scraped_article do
        depends_on [:source_urls]

        scatter fn %{source_urls: urls} ->
          Enum.map(urls, &%{url: &1})
        end

        scatter_options do
          max_concurrent 50
          rate_limit {10, :second}
          failure_threshold 0.02
        end

        execute fn ctx, _deps ->
          Scraper.fetch(ctx.scatter_key.url)
        end
      end

  ## Signal Gate (Durable Suspension)

      asset :embedded_documents do
        execute fn ctx, deps ->
          task_id = ECS.start_task(deps.data)
          {:signal_gate, token: task_id, timeout: :timer.hours(1)}
        end

        on_signal fn _ctx, payload ->
          {:ok, payload.result}
        end

        on_timeout fn ctx ->
          {:error, :timeout}
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

  defmacro partition(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | partition_fn: unquote(fun)}
    end
  end

  defmacro partitioned_by(value) do
    quote do
      var!(current_asset) = %{var!(current_asset) | partitioned_by: unquote(value)}
    end
  end

  defmacro execute(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | execute_fn: unquote(fun)}
    end
  end

  @doc """
  Define a scatter function for dynamic fan-out.

  The scatter function receives upstream dependencies and returns
  a list of scatter keys (maps) that define each parallel instance.

  ## Example

      scatter fn %{source_urls: urls} ->
        Enum.map(urls, &%{url: &1})
      end
  """
  defmacro scatter(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | scatter_fn: unquote(fun)}
    end
  end

  @doc """
  Configure scatter execution options.

  ## Available Options

  - `max_concurrent` - Maximum concurrent executions (default: :unlimited)
  - `rate_limit` - Rate limit as `{count, :second | :minute}` tuple
  - `failure_threshold` - Maximum failure rate as decimal (0.0 to 1.0)
  - `failure_mode` - `:partial` or `:all_or_nothing`
  - `retry_strategy` - `:individual` or `:batch`
  - `max_attempts` - Maximum retry attempts per instance
  - `queue` - Oban queue for scatter jobs
  - `priority` - Job priority (0-3)
  - `timeout` - Per-instance timeout in milliseconds

  ## Example

      scatter_options do
        max_concurrent 50
        rate_limit {10, :second}
        failure_threshold 0.05
        failure_mode :partial
      end
  """
  defmacro scatter_options(do: block) do
    quote do
      var!(scatter_opts) = %{}
      unquote(block)
      var!(current_asset) = %{var!(current_asset) | scatter_options: var!(scatter_opts)}
    end
  end

  defmacro max_concurrent(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :max_concurrent, unquote(value))
    end
  end

  defmacro rate_limit(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :rate_limit, unquote(value))
    end
  end

  defmacro failure_threshold(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :failure_threshold, unquote(value))
    end
  end

  defmacro failure_mode(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :failure_mode, unquote(value))
    end
  end

  defmacro retry_strategy(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :retry_strategy, unquote(value))
    end
  end

  defmacro max_attempts(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :max_attempts, unquote(value))
    end
  end

  defmacro queue(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :queue, unquote(value))
    end
  end

  defmacro priority(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :priority, unquote(value))
    end
  end

  defmacro timeout(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :timeout, unquote(value))
    end
  end

  @doc """
  Define a gather function for processing scattered results.

  The gather function receives a map of `scatter_key => result` and
  can transform or aggregate results for downstream assets.

  ## Example

      gather fn results ->
        results
        |> Map.values()
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, data} -> data end)
      end
  """
  defmacro gather(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | gather_fn: unquote(fun)}
    end
  end

  @doc """
  Define a signal handler for Signal Gate completion.

  Called when an external signal arrives for a gated asset.

  ## Example

      on_signal fn ctx, payload ->
        case payload do
          %{"status" => "success", "result" => result} ->
            {:ok, result}
          %{"status" => "failed", "error" => error} ->
            {:error, error}
        end
      end
  """
  defmacro on_signal(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | on_signal_fn: unquote(fun)}
    end
  end

  @doc """
  Define a timeout handler for Signal Gate.

  Called when a Signal Gate times out without receiving a signal.

  ## Example

      on_timeout fn ctx ->
        Logger.warning("Task \#{ctx.gate.token} timed out")
        {:error, :timeout}
      end
  """
  defmacro on_timeout(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | on_timeout_fn: unquote(fun)}
    end
  end
end

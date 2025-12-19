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
  Define routing behavior for an asset.

  Supports either a `route do ... end` block with choices, or
  a direct `route fn deps -> ... end` function.
  """
  defmacro route(do: block) do
    quote do
      var!(route_rules) = %{choices: [], default: nil}
      var!(current_asset) = %{var!(current_asset) | route_error_policy: :fail, route_fn: nil}
      unquote(block)
      var!(current_asset) = %{var!(current_asset) | route_rules: var!(route_rules)}
    end
  end

  defmacro route(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | route_fn: unquote(fun), route_rules: nil}
    end
  end

  defmacro choice(asset, when: fun) do
    quote do
      var!(route_rules) =
        Map.update!(var!(route_rules), :choices, fn choices ->
          choices ++ [{unquote(asset), unquote(fun)}]
        end)
    end
  end

  defmacro default(asset) do
    quote do
      var!(route_rules) = Map.put(var!(route_rules), :default, unquote(asset))
    end
  end

  defmacro on_error(policy) do
    quote do
      var!(current_asset) = %{var!(current_asset) | route_error_policy: unquote(policy)}
    end
  end

  defmacro routed_from(router_asset) do
    quote do
      var!(current_asset) = %{var!(current_asset) | routed_from: unquote(router_asset)}
    end
  end

  defmacro optional_deps(deps) when is_list(deps) do
    quote do
      var!(current_asset) = %{var!(current_asset) | optional_deps: unquote(deps)}
    end
  end

  @doc """
  Define parallel branches for an asset.
  """
  defmacro parallel(do: block) do
    quote do
      var!(parallel_branches) = %{}
      unquote(block)
      var!(current_asset) = %{var!(current_asset) | parallel_branches: var!(parallel_branches)}
    end
  end

  @doc """
  Define a single parallel branch.
  """
  defmacro branch(name, opts \\ []) do
    quote do
      branch_name = unquote(name)
      branch_opts = unquote(opts)
      final_asset = Keyword.get(branch_opts, :final)

      if is_nil(final_asset) do
        raise ArgumentError,
              "parallel branch #{inspect(branch_name)} must define :final asset"
      end

      if Map.has_key?(var!(parallel_branches), branch_name) do
        raise ArgumentError,
              "parallel branch name #{inspect(branch_name)} must be unique"
      end

      branch = %FlowStone.ParallelBranch{
        name: branch_name,
        final: final_asset,
        required: Keyword.get(branch_opts, :required, true),
        timeout: Keyword.get(branch_opts, :timeout)
      }

      var!(parallel_branches) = Map.put(var!(parallel_branches), branch_name, branch)
    end
  end

  @doc """
  Configure parallel execution options.
  """
  defmacro parallel_options(do: block) do
    quote do
      var!(parallel_opts) = %{}
      unquote(block)
      var!(current_asset) = %{var!(current_asset) | parallel_options: var!(parallel_opts)}
    end
  end

  @doc """
  Define a join function for parallel branches.
  """
  defmacro join(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | join_fn: unquote(fun)}
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
  Define a scatter source using an ItemReader.
  """
  defmacro scatter_from(source, do: block) do
    quote do
      var!(scatter_source_config) = %{}
      var!(current_asset) = %{var!(current_asset) | scatter_source: unquote(source)}
      unquote(block)

      var!(current_asset) =
        %{var!(current_asset) | scatter_source_config: var!(scatter_source_config)}
    end
  end

  @doc """
  Define an item selector for ItemReader outputs.
  """
  defmacro item_selector(fun) do
    quote do
      var!(current_asset) = %{var!(current_asset) | item_selector_fn: unquote(fun)}
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
  - `mode` - `:inline` or `:distributed` for ItemReader execution
  - `batch_size` - ItemReader batch size
  - `max_batches` - Max ItemReader batches per run

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

      var!(current_asset) = %{
        var!(current_asset)
        | scatter_options: var!(scatter_opts),
          scatter_mode: Map.get(var!(scatter_opts), :mode)
      }
    end
  end

  defmacro mode(value) do
    env = __CALLER__

    if Macro.Env.has_var?(env, {:scatter_opts, nil}) do
      quote do
        var!(scatter_opts) = Map.put(var!(scatter_opts), :mode, unquote(value))
      end
    else
      raise ArgumentError, "mode must be used inside scatter_options"
    end
  end

  defmacro max_concurrent(value) do
    quote do
      var!(scatter_opts) = Map.put(var!(scatter_opts), :max_concurrent, unquote(value))
    end
  end

  defmacro batch_size(value) do
    env = __CALLER__

    if Macro.Env.has_var?(env, {:scatter_opts, nil}) do
      quote do
        var!(scatter_opts) = Map.put(var!(scatter_opts), :batch_size, unquote(value))
      end
    else
      raise ArgumentError, "batch_size must be used inside scatter_options"
    end
  end

  defmacro max_batches(value) do
    env = __CALLER__

    if Macro.Env.has_var?(env, {:scatter_opts, nil}) do
      quote do
        var!(scatter_opts) = Map.put(var!(scatter_opts), :max_batches, unquote(value))
      end
    else
      raise ArgumentError, "max_batches must be used inside scatter_options"
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
    env = __CALLER__

    cond do
      Macro.Env.has_var?(env, {:parallel_opts, nil}) ->
        quote do
          var!(parallel_opts) = Map.put(var!(parallel_opts), :failure_mode, unquote(value))
        end

      Macro.Env.has_var?(env, {:scatter_opts, nil}) ->
        quote do
          var!(scatter_opts) = Map.put(var!(scatter_opts), :failure_mode, unquote(value))
        end

      true ->
        raise ArgumentError,
              "failure_mode must be used inside scatter_options or parallel_options"
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
    env = __CALLER__

    cond do
      Macro.Env.has_var?(env, {:parallel_opts, nil}) ->
        quote do
          var!(parallel_opts) = Map.put(var!(parallel_opts), :timeout, unquote(value))
        end

      Macro.Env.has_var?(env, {:scatter_opts, nil}) ->
        quote do
          var!(scatter_opts) = Map.put(var!(scatter_opts), :timeout, unquote(value))
        end

      true ->
        raise ArgumentError, "timeout must be used inside scatter_options or parallel_options"
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

  defmacro bucket(value) do
    ensure_scatter_from!(__CALLER__, "bucket")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :bucket, unquote(value))
    end
  end

  defmacro prefix(value) do
    ensure_scatter_from!(__CALLER__, "prefix")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :prefix, unquote(value))
    end
  end

  defmacro start_after(value) do
    ensure_scatter_from!(__CALLER__, "start_after")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :start_after, unquote(value))
    end
  end

  defmacro suffix(value) do
    ensure_scatter_from!(__CALLER__, "suffix")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :suffix, unquote(value))
    end
  end

  defmacro max_items(value) do
    ensure_scatter_from!(__CALLER__, "max_items")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :max_items, unquote(value))
    end
  end

  defmacro reader_batch_size(value) do
    ensure_scatter_from!(__CALLER__, "reader_batch_size")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :reader_batch_size, unquote(value))
    end
  end

  defmacro consistency_delay_ms(value) do
    ensure_scatter_from!(__CALLER__, "consistency_delay_ms")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :consistency_delay_ms, unquote(value))
    end
  end

  defmacro table(value) do
    ensure_scatter_from!(__CALLER__, "table")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :table, unquote(value))
    end
  end

  defmacro index(value) do
    ensure_scatter_from!(__CALLER__, "index")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :index, unquote(value))
    end
  end

  defmacro key_condition(value) do
    ensure_scatter_from!(__CALLER__, "key_condition")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :key_condition, unquote(value))
    end
  end

  defmacro filter_expression(value) do
    ensure_scatter_from!(__CALLER__, "filter_expression")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :filter_expression, unquote(value))
    end
  end

  defmacro projection_expression(value) do
    ensure_scatter_from!(__CALLER__, "projection_expression")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :projection_expression, unquote(value))
    end
  end

  defmacro expression_attribute_values(value) do
    ensure_scatter_from!(__CALLER__, "expression_attribute_values")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :expression_attribute_values, unquote(value))
    end
  end

  defmacro expression_attribute_names(value) do
    ensure_scatter_from!(__CALLER__, "expression_attribute_names")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :expression_attribute_names, unquote(value))
    end
  end

  defmacro consistent_read(value) do
    ensure_scatter_from!(__CALLER__, "consistent_read")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :consistent_read, unquote(value))
    end
  end

  defmacro query(value) do
    ensure_scatter_from!(__CALLER__, "query")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :query, unquote(value))
    end
  end

  defmacro cursor_field(value) do
    ensure_scatter_from!(__CALLER__, "cursor_field")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :cursor_field, unquote(value))
    end
  end

  defmacro order(value) do
    ensure_scatter_from!(__CALLER__, "order")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :order, unquote(value))
    end
  end

  defmacro row_selector(value) do
    ensure_scatter_from!(__CALLER__, "row_selector")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :row_selector, unquote(value))
    end
  end

  defmacro repo(value) do
    ensure_scatter_from!(__CALLER__, "repo")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :repo, unquote(value))
    end
  end

  defmacro init(value) do
    ensure_scatter_from!(__CALLER__, "init")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :init, unquote(value))
    end
  end

  defmacro read(value) do
    ensure_scatter_from!(__CALLER__, "read")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :read, unquote(value))
    end
  end

  defmacro count(value) do
    ensure_scatter_from!(__CALLER__, "count")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :count, unquote(value))
    end
  end

  defmacro checkpoint(value) do
    ensure_scatter_from!(__CALLER__, "checkpoint")

    quote do
      var!(scatter_source_config) =
        Map.put(var!(scatter_source_config), :checkpoint, unquote(value))
    end
  end

  defmacro restore(value) do
    ensure_scatter_from!(__CALLER__, "restore")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :restore, unquote(value))
    end
  end

  defmacro close(value) do
    ensure_scatter_from!(__CALLER__, "close")

    quote do
      var!(scatter_source_config) = Map.put(var!(scatter_source_config), :close, unquote(value))
    end
  end

  defp ensure_scatter_from!(env, name) do
    unless Macro.Env.has_var?(env, {:scatter_source_config, nil}) do
      raise ArgumentError, "#{name} must be used inside scatter_from"
    end
  end
end

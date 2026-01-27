defmodule FlowStone.PlanRunner do
  @moduledoc """
  Executes Jido plans by compiling them to FlowStone assets.
  """

  alias FlowStone.{API, PlanCompiler}
  alias Jido.Plan

  @table :flowstone_plan_assets

  @spec run(Plan.t(), atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(%Plan{} = plan, step_key, opts \\ []) when is_atom(step_key) do
    with {:ok, assets} <- PlanCompiler.compile(plan, opts) do
      pipeline = pipeline_module(plan, opts)
      ensure_assets_table()
      store_assets(pipeline, assets)

      run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)
      metadata = build_metadata(plan, opts)

      api_opts =
        opts
        |> Keyword.drop([:pipeline_module, :metadata])
        |> Keyword.put(:run_id, run_id)
        |> Keyword.put(:metadata, metadata)

      API.run(pipeline, step_key, api_opts)
    end
  end

  @spec assets(module()) :: list()
  def assets(pipeline_module) do
    ensure_assets_table()

    case :ets.lookup(@table, pipeline_module) do
      [{^pipeline_module, assets}] -> assets
      _ -> []
    end
  end

  defp pipeline_module(plan, opts) do
    Keyword.get(opts, :pipeline_module) || default_pipeline_module(plan)
  end

  defp default_pipeline_module(%Plan{id: id}) do
    suffix =
      id
      |> to_string()
      |> String.replace("-", "_")

    Module.concat([__MODULE__, "Plan_#{suffix}"])
  end

  defp ensure_assets_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp store_assets(pipeline, assets) do
    ensure_pipeline_module(pipeline)
    :ets.insert(@table, {pipeline, assets})
  end

  defp ensure_pipeline_module(pipeline) do
    unless Code.ensure_loaded?(pipeline) do
      Module.create(
        pipeline,
        quote do
          def __flowstone_assets__, do: FlowStone.PlanRunner.assets(__MODULE__)
          def __flowstone_wrap_results__, do: false
        end,
        Macro.Env.location(__ENV__)
      )
    end
  end

  defp build_metadata(%Plan{} = plan, opts) do
    base = Keyword.get(opts, :metadata, %{})

    plan_context =
      plan.context
      |> Map.take([
        :trace_id,
        :work_id,
        :plan_id,
        :session_id,
        :actor_id,
        :actor_type,
        :tenant_id
      ])

    base
    |> Map.merge(plan_context)
    |> Map.put_new(:plan_id, plan.id)
    |> maybe_put(:plan_version, Keyword.get(opts, :plan_version))
    |> maybe_put(:plan_hash, Keyword.get(opts, :plan_hash))
    |> maybe_put(:plan_ref, Keyword.get(opts, :plan_ref))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

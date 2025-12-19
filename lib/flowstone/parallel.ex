defmodule FlowStone.Parallel do
  @moduledoc """
  Persistence and orchestration helpers for parallel branches.
  """

  import Ecto.Query

  alias FlowStone.Parallel.{Branch, Execution}
  alias FlowStone.{ParallelBranch, Partition, Repo}
  alias FlowStone.Workers.ParallelJoinWorker

  @spec start_execution(FlowStone.Asset.t(), map(), keyword()) ::
          {:ok, Execution.t()} | {:error, term()}
  def start_execution(asset, context, opts) do
    with :ok <- ensure_repo_running(),
         {:ok, execution} <- create_execution(asset, context) do
      emit_parallel_start(asset, context, execution)
      schedule_branches(asset, context, opts, execution)
      schedule_join(asset, context, opts, execution)
      {:ok, execution}
    end
  end

  def get_execution(execution_id) do
    Repo.get(Execution, execution_id)
  end

  def list_branches(execution_id) do
    Repo.all(from b in Branch, where: b.execution_id == ^execution_id)
  end

  def update_execution(%Execution{} = execution, attrs) do
    execution
    |> Execution.changeset(attrs)
    |> Repo.update()
  end

  def update_branch(%Branch{} = branch, attrs) do
    branch
    |> Branch.changeset(attrs)
    |> Repo.update()
  end

  def update_counts(execution_id, completed_count, failed_count) do
    from(e in Execution, where: e.id == ^execution_id)
    |> Repo.update_all(set: [completed_count: completed_count, failed_count: failed_count])

    :ok
  end

  def mark_joining(execution_id) do
    {updated, _} =
      from(e in Execution, where: e.id == ^execution_id and e.status == :running)
      |> Repo.update_all(set: [status: :joining, updated_at: DateTime.utc_now()])

    if updated == 1, do: :ok, else: :already_running
  end

  defp create_execution(asset, context) do
    branches = Map.values(Map.get(asset, :parallel_branches, %{}))

    if branches == [] do
      {:error, :no_parallel_branches}
    else
      partition = context.partition && Partition.serialize(context.partition)

      attrs = %{
        run_id: context.run_id,
        parent_asset: to_string(asset.name),
        partition: partition,
        status: :running,
        branch_count: length(branches),
        completed_count: 0,
        failed_count: 0,
        metadata: %{}
      }

      Repo.transaction(fn ->
        execution = insert_execution(attrs)
        insert_branches(execution.id, branches)
        execution
      end)
      |> case do
        {:ok, execution} -> {:ok, execution}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp insert_execution(attrs) do
    changeset = Execution.changeset(%Execution{}, attrs)

    {:ok, execution} =
      Repo.insert(changeset,
        on_conflict: :nothing,
        conflict_target: [:run_id, :parent_asset, :partition]
      )

    if execution.id do
      execution
    else
      Repo.get_by!(Execution,
        run_id: attrs.run_id,
        parent_asset: attrs.parent_asset,
        partition: attrs.partition
      )
    end
  end

  defp insert_branches(execution_id, branches) do
    now = DateTime.utc_now()

    records =
      Enum.map(branches, fn %ParallelBranch{} = branch ->
        %{
          id: Ecto.UUID.generate(),
          execution_id: execution_id,
          branch_name: Atom.to_string(branch.name),
          final_asset: Atom.to_string(branch.final),
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Branch, records,
      on_conflict: :nothing,
      conflict_target: [:execution_id, :branch_name]
    )
  end

  defp schedule_branches(asset, context, opts, execution) do
    branches = Map.values(Map.get(asset, :parallel_branches, %{}))

    Enum.each(branches, fn %ParallelBranch{} = branch ->
      emit_branch_start(asset, context, execution, branch)

      FlowStone.materialize_async(
        branch.final,
        Keyword.merge(opts, partition: context.partition, run_id: context.run_id)
      )
    end)
  end

  defp schedule_join(asset, context, opts, execution) do
    args = %{
      "execution_id" => execution.id,
      "run_id" => context.run_id,
      "parent_asset" => to_string(asset.name),
      "partition" => Partition.serialize(context.partition),
      "use_repo" => Keyword.get(opts, :use_repo, true)
    }

    if oban_running?() do
      ParallelJoinWorker.new(args) |> Oban.insert()
    else
      run_config = build_run_config(opts)
      ParallelJoinWorker.perform(%Oban.Job{args: args}, run_config)
    end
  end

  defp build_run_config(opts) do
    [
      registry: Keyword.get(opts, :registry),
      resource_server: Keyword.get(opts, :resource_server),
      lineage_server: Keyword.get(opts, :lineage_server),
      materialization_store: Keyword.get(opts, :materialization_store),
      io_opts: Keyword.get(opts, :io, []),
      io_config: %{}
    ]
  end

  defp oban_running? do
    Process.whereis(Oban.Registry) != nil and Process.whereis(Oban.Config) != nil
  end

  defp ensure_repo_running do
    if Process.whereis(Repo) != nil do
      :ok
    else
      {:error, :repo_not_running}
    end
  end

  defp emit_parallel_start(asset, context, execution) do
    :telemetry.execute([:flowstone, :parallel, :start], %{}, %{
      asset: asset.name,
      run_id: context.run_id,
      partition: context.partition,
      execution_id: execution.id
    })
  end

  defp emit_branch_start(asset, context, execution, branch) do
    :telemetry.execute([:flowstone, :parallel, :branch_start], %{}, %{
      asset: asset.name,
      branch: branch.name,
      final_asset: branch.final,
      run_id: context.run_id,
      partition: context.partition,
      execution_id: execution.id
    })
  end
end

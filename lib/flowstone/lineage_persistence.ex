defmodule FlowStone.LineagePersistence do
  @moduledoc """
  Repo-backed lineage recording and queries with in-memory fallback.
  """

  import Ecto.Query
  alias FlowStone.{Lineage, Lineage.Entry, Materialization, Repo}

  def record(asset, partition, run_id, deps, opts \\ []) do
    server = Keyword.get(opts, :server, Lineage)

    cond do
      use_repo?(opts) ->
        now = DateTime.utc_now()

        naive_now =
          NaiveDateTime.utc_now()
          |> NaiveDateTime.truncate(:second)

        entries =
          Enum.map(deps, fn {dep, dep_partition} ->
            %{
              asset_name: Atom.to_string(asset),
              partition: FlowStone.Partition.serialize(partition),
              run_id: run_id,
              upstream_asset: Atom.to_string(dep),
              upstream_partition: FlowStone.Partition.serialize(dep_partition),
              consumed_at: now,
              inserted_at: naive_now,
              updated_at: naive_now
            }
          end)

        Repo.insert_all(Entry, entries)
        :ok

      server_available?(server) ->
        Lineage.record(asset, partition, run_id, deps, server)

      true ->
        :ok
    end
  end

  def upstream(asset, partition, opts \\ []) do
    server = Keyword.get(opts, :server, Lineage)
    depth = Keyword.get(opts, :depth, :infinity)
    max_depth = normalize_depth(depth)

    cond do
      use_repo?(opts) ->
        query = """
        WITH RECURSIVE upstream_tree AS (
          SELECT
            l.upstream_asset,
            l.upstream_partition,
            l.upstream_materialization_id,
            1 as depth
          FROM flowstone_lineage l
          WHERE l.asset_name = $1 AND l.partition = $2

          UNION ALL

          SELECT
            l.upstream_asset,
            l.upstream_partition,
            l.upstream_materialization_id,
            t.depth + 1
          FROM flowstone_lineage l
          INNER JOIN upstream_tree t
            ON l.asset_name = t.upstream_asset
            AND l.partition = t.upstream_partition
          WHERE t.depth < $3
        )
        SELECT DISTINCT
          upstream_asset,
          upstream_partition,
          upstream_materialization_id,
          MIN(depth) as depth
        FROM upstream_tree
        GROUP BY upstream_asset, upstream_partition, upstream_materialization_id
        ORDER BY depth, upstream_asset
        """

        params = [Atom.to_string(asset), FlowStone.Partition.serialize(partition), max_depth]
        {:ok, %{rows: rows}} = Repo.query(query, params)

        Enum.map(rows, fn [name, part, mat_id, d] ->
          %{
            asset: String.to_atom(name),
            partition: FlowStone.Partition.deserialize(part),
            materialization_id: mat_id,
            depth: d
          }
        end)

      server_available?(server) ->
        Lineage.upstream(asset, partition, server)
        |> Enum.map(&Map.put(&1, :depth, 1))

      true ->
        []
    end
  end

  def downstream(asset, partition, opts \\ []) do
    server = Keyword.get(opts, :server, Lineage)
    depth = Keyword.get(opts, :depth, :infinity)
    max_depth = normalize_depth(depth)

    cond do
      use_repo?(opts) ->
        query = """
        WITH RECURSIVE downstream_tree AS (
          SELECT
            l.asset_name,
            l.partition,
            l.run_id,
            1 as depth
          FROM flowstone_lineage l
          WHERE l.upstream_asset = $1 AND l.upstream_partition = $2

          UNION ALL

          SELECT
            l.asset_name,
            l.partition,
            l.run_id,
            t.depth + 1
          FROM flowstone_lineage l
          INNER JOIN downstream_tree t
            ON l.upstream_asset = t.asset_name
            AND l.upstream_partition = t.partition
          WHERE t.depth < $3
        )
        SELECT DISTINCT
          asset_name,
          partition,
          run_id,
          MIN(depth) as depth
        FROM downstream_tree
        GROUP BY asset_name, partition, run_id
        ORDER BY depth, asset_name
        """

        params = [Atom.to_string(asset), FlowStone.Partition.serialize(partition), max_depth]
        {:ok, %{rows: rows}} = Repo.query(query, params)

        Enum.map(rows, fn [name, part, run_id, d] ->
          %{
            asset: String.to_atom(name),
            partition: FlowStone.Partition.deserialize(part),
            run_id: run_id,
            depth: d
          }
        end)

      server_available?(server) ->
        Lineage.downstream(asset, partition, server)
        |> Enum.map(&Map.put(&1, :depth, 1))

      true ->
        []
    end
  end

  def impact(asset, partition, opts \\ []) do
    downstream(asset, partition, opts)
    |> Enum.map(fn entry ->
      status = latest_status(entry, opts)
      Map.put(entry, :status, status)
    end)
  end

  defp use_repo?(opts), do: Keyword.get(opts, :use_repo, true) and repo_running?()

  defp repo_running?,
    do: Application.get_env(:flowstone, :start_repo, false) and Process.whereis(Repo) != nil

  defp server_available?(nil), do: false

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)

  defp server_available?(server) when is_atom(server), do: Process.whereis(server) != nil

  defp normalize_depth(:infinity), do: 100
  defp normalize_depth(depth) when is_integer(depth) and depth > 0, do: depth
  defp normalize_depth(_), do: 1

  defp latest_status(%{asset: asset, partition: partition}, opts) do
    cond do
      use_repo?(opts) ->
        Repo.one(
          from m in Materialization,
            where:
              m.asset_name == ^Atom.to_string(asset) and
                m.partition == ^FlowStone.Partition.serialize(partition),
            order_by: [desc: m.inserted_at],
            limit: 1,
            select: m.status
        )

      true ->
        nil
    end
  end
end

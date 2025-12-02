defmodule FlowStone.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pubsub()
      |> maybe_add_resources()
      |> maybe_add_materialization_store()
      |> maybe_add_oban()
      |> maybe_add_metrics()
      |> maybe_add_scheduler()

    Supervisor.start_link(children, strategy: :one_for_one, name: FlowStone.Supervisor)
  end

  defp maybe_add_repo(children) do
    if Application.get_env(:flowstone, :start_repo, false) do
      children ++ [FlowStone.Repo]
    else
      children
    end
  end

  defp maybe_add_pubsub(children) do
    if Application.get_env(:flowstone, :start_pubsub, false) do
      children ++ [{FlowStone.PubSub, name: FlowStone.PubSub.Server}]
    else
      children
    end
  end

  defp maybe_add_resources(children) do
    if Application.get_env(:flowstone, :start_resources, false) do
      children ++ [FlowStone.Resources]
    else
      children
    end
  end

  defp maybe_add_materialization_store(children) do
    if Application.get_env(:flowstone, :start_materialization_store, false) do
      children ++ [FlowStone.MaterializationStore]
    else
      children
    end
  end

  defp maybe_add_oban(children) do
    if Application.get_env(:flowstone, :start_oban, false) do
      children ++ [{Oban, Application.fetch_env!(:flowstone, Oban)}]
    else
      children
    end
  end

  defp maybe_add_metrics(children) do
    if Code.ensure_loaded?(TelemetryMetricsPrometheus.Core) do
      metrics = FlowStone.TelemetryMetrics.metrics()

      exporter =
        {TelemetryMetricsPrometheus.Core, name: FlowStone.Prometheus, metrics: metrics}

      children ++ [exporter]
    else
      children
    end
  end

  defp maybe_add_scheduler(children) do
    if Application.get_env(:flowstone, :start_oban, false) do
      children ++ [FlowStone.Schedules.Scheduler]
    else
      children
    end
  end
end

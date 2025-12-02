defmodule FlowStone.Schedules.Scheduler do
  @moduledoc """
  Lightweight cron scheduler that enqueues scheduled assets via Oban.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    server = Keyword.get(opts, :store, FlowStone.ScheduleStore)
    schedules = FlowStone.list_schedules(store: server)
    Enum.each(schedules, &schedule_next/1)
    {:ok, %{schedules: schedules, store: server}}
  end

  def run_now(schedule, server \\ __MODULE__) do
    GenServer.call(server, {:run_now, schedule})
  end

  @impl true
  def handle_call({:run_now, schedule}, _from, state) do
    enqueue(schedule)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:run_schedule, schedule}, state) do
    enqueue(schedule)
    schedule_next(schedule)
    {:noreply, state}
  end

  defp enqueue(%FlowStone.Schedule{} = schedule) do
    partition =
      if is_function(schedule.partition_fn, 0) do
        schedule.partition_fn.()
      else
        Date.utc_today()
      end

    FlowStone.materialize(schedule.asset,
      partition: partition,
      registry: schedule.registry || FlowStone.Registry,
      io: schedule.io || [],
      resource_server: schedule.resource_server,
      lineage_server: schedule.lineage_server,
      use_repo: schedule.use_repo
    )
  end

  defp schedule_next(%FlowStone.Schedule{cron: cron, timezone: tz} = schedule) do
    case next_run(cron, tz) do
      {:ok, next} ->
        ms = max(0, DateTime.diff(next, DateTime.utc_now(), :millisecond))
        Process.send_after(self(), {:run_schedule, schedule}, ms)

      {:error, reason} ->
        Logger.error("Failed to schedule #{inspect(schedule.asset)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp next_run(cron, timezone) do
    with {:ok, dt} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, now} <- now_in_timezone(timezone),
         {:ok, next} <- Crontab.Scheduler.get_next_run_date(dt, now) do
      {:ok, next}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_in_timezone(timezone) do
    timezone
    |> normalize_timezone()
    |> DateTime.now()
    |> case do
      {:ok, dt} ->
        {:ok, dt}

      {:error, reason} ->
        Logger.warning(
          "Falling back to UTC for schedule timezone #{inspect(timezone)}: #{inspect(reason)}"
        )

        {:ok, DateTime.utc_now()}
    end
  end

  defp normalize_timezone(nil), do: "Etc/UTC"
  defp normalize_timezone("UTC"), do: "Etc/UTC"
  defp normalize_timezone(timezone), do: timezone
end

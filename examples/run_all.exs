# Orchestrates all live examples sequentially.

prev_run_all = System.get_env("FLOWSTONE_RUN_ALL")
System.put_env("FLOWSTONE_RUN_ALL", "1")

example_files = [
  "core_example.exs",
  "backfill_example.exs",
  "approval_example.exs",
  "schedule_example.exs",
  "telemetry_example.exs",
  "postgres_io_example.exs",
  "sensor_example.exs",
  "failure_example.exs",
  "conditional_routing_example.exs",
  "parallel_branches_example.exs",
  # v0.3.0 - New features
  "scatter_example.exs",
  "signal_gate_example.exs",
  "rate_limiter_example.exs"
]

Enum.each(example_files, fn file -> Code.require_file(file, __DIR__) end)

if is_nil(prev_run_all) do
  System.delete_env("FLOWSTONE_RUN_ALL")
else
  System.put_env("FLOWSTONE_RUN_ALL", prev_run_all)
end

IO.puts("Running FlowStone live examples...\n")

examples = [
  {Examples.CoreExample, "Core execution"},
  {Examples.BackfillExample, "Partitioned backfill"},
  {Examples.ApprovalExample, "Checkpoint approvals"},
  {Examples.ScheduleExample, "Cron scheduling"},
  {Examples.TelemetryExample, "Telemetry tap"},
  {Examples.PostgresIOExample, "Postgres IO + composite partition"},
  {Examples.SensorExample, "Sensor trigger"},
  {Examples.FailureExample, "Failure & materialization recording"},
  {Examples.ConditionalRoutingExample, "Conditional routing"},
  {Examples.ParallelBranchesExample, "Parallel branches"}
]

Enum.each(examples, fn {mod, label} ->
  IO.puts("==> #{label}")
  result = mod.run()
  IO.inspect(result, label: "Result")
  IO.puts("")
end)

IO.puts("All examples complete.")

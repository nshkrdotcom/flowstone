# Orchestrates all live examples sequentially.

example_files = [
  "core_example.exs",
  "backfill_example.exs",
  "approval_example.exs",
  "schedule_example.exs",
  "telemetry_example.exs",
  "postgres_io_example.exs",
  "sensor_example.exs",
  "failure_example.exs"
]

Enum.each(example_files, fn file -> Code.require_file(file, __DIR__) end)

IO.puts("Running FlowStone live examples...\n")

examples = [
  {Examples.CoreExample, "Core execution"},
  {Examples.BackfillExample, "Partitioned backfill"},
  {Examples.ApprovalExample, "Checkpoint approvals"},
  {Examples.ScheduleExample, "Cron scheduling"},
  {Examples.TelemetryExample, "Telemetry tap"},
  {Examples.PostgresIOExample, "Postgres IO + composite partition"},
  {Examples.SensorExample, "Sensor trigger"},
  {Examples.FailureExample, "Failure & materialization recording"}
]

Enum.each(examples, fn {mod, label} ->
  IO.puts("==> #{label}")
  result = mod.run()
  IO.inspect(result, label: "Result")
  IO.puts("")
end)

IO.puts("All examples complete.")

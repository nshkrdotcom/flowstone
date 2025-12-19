# Live Examples Coverage & Roadmap

This document tracks what the live examples (in `examples/`) currently demonstrate and what remains to be covered.

## Completed Coverage
- Core asset registration and dependency-based execution (synchronous and async/Oban paths).
- Partitioned assets, partition metadata (`partitioned_by/1`), and backfill with auto-partition generation.
- Approval checkpoints: wait-for-approval flow, approvals listing, and explicit approve path (with Oban timeout job scheduling).
- Cron scheduling with dynamic partitions and manual trigger (`run_now/2`), using the in-memory schedule store.
- Telemetry events for materialization and checkpoints, plus basic metrics hooks; health checks for repo/Oban/resources.
- Lineage recording and inspection via the in-memory lineage server.
- Sensors (mock S3 file arrival) triggering materializations.
- External IO via Postgres manager, including composite partitions.
- Failure-path demonstration with materialization recording.
- Parallel branches with join coordination and partial failure handling.
- ItemReader streaming scatter inputs with custom reader checkpointing.
- ItemBatcher batch scatter execution with fixed-size batching and shared batch context.

## Remaining / To Add
- Additional IO manager demos (S3/Parquet real integrations).
- UI-oriented demos (LiveView dashboards for approvals/materializations) once UI code is available.
- Expanded failure modes: retries/backoff tuning, checkpoint timeout escalation behavior.
- Sensor variants (DB/webhook) and multi-tenant context patterns if introduced.

## Usage Note
Run `mix run examples/run_all.exs` (or `bash examples/run_all.sh`) in `MIX_ENV=dev` after database setup to exercise the completed examples.***

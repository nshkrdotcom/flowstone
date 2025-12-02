# Implementation Prompt: ADR-0005 Checkpoint and Approval Gates

## Objective

Implement human-in-the-loop checkpoint gates with approval workflows using TDD with Supertester.

## Required Reading

1. **ADR-0005**: `docs/adr/0005-checkpoint-approval-gates.md`
2. **Oban**: https://hexdocs.pm/oban (for timeout jobs)
3. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

Checkpoints:
- Pause workflow execution
- Wait for human/automated approval
- Support approve, modify, reject
- Handle timeouts with escalation

## Implementation Tasks

### 1. Checkpoint DSL

```elixir
# lib/flowstone/checkpoint.ex
defmodule FlowStone.Checkpoint do
  defmacro checkpoint(name, do: block)

  def request_approval(checkpoint, context, deps)
  def approve(approval_id, opts \\ [])
  def modify(approval_id, modifications, opts \\ [])
  def reject(approval_id, reason, opts \\ [])
  def list_pending(opts \\ [])
end
```

### 2. Approval Schema

```elixir
# lib/flowstone/checkpoint/approval.ex
defmodule FlowStone.Checkpoint.Approval do
  use Ecto.Schema

  schema "flowstone_approvals" do
    field :checkpoint_name, :string
    field :materialization_id, Ecto.UUID
    field :message, :string
    field :context, :map
    field :timeout_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: [:pending, :approved, :modified, :rejected, :escalated, :expired]
    field :decision_by, :string
    field :decision_at, :utc_datetime_usec
    field :reason, :string
    field :modifications, :map
    field :escalated_to, :string
    field :escalation_count, :integer, default: 0

    timestamps()
  end
end
```

### 3. Timeout Worker

```elixir
# lib/flowstone/workers/checkpoint_timeout.ex
defmodule FlowStone.Workers.CheckpointTimeout do
  use Oban.Worker, queue: :checkpoints

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"approval_id" => id}})
end
```

## Test Design with Supertester

### Checkpoint DSL Tests

```elixir
defmodule FlowStone.CheckpointTest do
  use FlowStone.DataCase, async: true
  import Supertester.OTPHelpers

  describe "checkpoint/2 macro" do
    test "defines checkpoint with required fields" do
      defmodule TestCheckpoint do
        use FlowStone.Pipeline

        checkpoint :review do
          depends_on [:data]
          approval_type :manual
          timeout hours(24)

          message fn _ctx, _deps -> "Review needed" end

          on_approve fn _ctx, deps, _approval ->
            {:ok, deps.data}
          end

          on_reject fn _ctx, _deps, approval ->
            {:error, {:rejected, approval.reason}}
          end
        end
      end

      checkpoints = TestCheckpoint.__flowstone_checkpoints__()
      assert length(checkpoints) == 1
      assert hd(checkpoints).name == :review
    end

    test "supports conditional checkpoints" do
      defmodule ConditionalCheckpoint do
        use FlowStone.Pipeline

        checkpoint :conditional_review do
          depends_on [:scan_results]

          condition fn _ctx, %{scan_results: results} ->
            results.flagged == true
          end

          on_skip fn _ctx, deps ->
            {:ok, deps.scan_results}
          end

          # ... rest of checkpoint
        end
      end
    end
  end
end
```

### Approval Workflow Tests

```elixir
defmodule FlowStone.Checkpoint.ApprovalTest do
  use FlowStone.DataCase, async: true
  import Supertester.OTPHelpers
  import Supertester.Assertions

  describe "request_approval/3" do
    test "creates pending approval" do
      checkpoint = build_test_checkpoint()
      context = %{partition: ~D[2025-01-15], run_id: Ecto.UUID.generate()}
      deps = %{data: :test_data}

      {:pending, approval_id} = FlowStone.Checkpoint.request_approval(checkpoint, context, deps)

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :pending
      assert approval.checkpoint_name == "review"
    end

    test "schedules timeout job" do
      checkpoint = build_test_checkpoint(timeout: :timer.hours(24))
      context = %{partition: ~D[2025-01-15], run_id: Ecto.UUID.generate()}

      {:pending, approval_id} = FlowStone.Checkpoint.request_approval(checkpoint, context, %{})

      # Verify Oban job was scheduled
      assert_enqueued(worker: FlowStone.Workers.CheckpointTimeout, args: %{approval_id: approval_id})
    end
  end

  describe "approve/2" do
    test "transitions to approved status" do
      {:pending, approval_id} = create_pending_approval()

      :ok = FlowStone.Checkpoint.approve(approval_id, by: "user_123")

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :approved
      assert approval.decision_by == "user_123"
      assert approval.decision_at != nil
    end

    test "triggers workflow resume" do
      {:pending, approval_id} = create_pending_approval()

      # Subscribe to PubSub
      FlowStone.PubSub.subscribe("checkpoints")

      :ok = FlowStone.Checkpoint.approve(approval_id, by: "user_123")

      assert_receive {:checkpoint_resolved, ^approval_id, :approved}
    end
  end

  describe "modify/3" do
    test "stores modifications and approves" do
      {:pending, approval_id} = create_pending_approval()

      modifications = %{redacted_fields: ["sensitive"]}
      :ok = FlowStone.Checkpoint.modify(approval_id, modifications, by: "user_123")

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :modified
      assert approval.modifications == modifications
    end
  end

  describe "reject/3" do
    test "transitions to rejected status" do
      {:pending, approval_id} = create_pending_approval()

      :ok = FlowStone.Checkpoint.reject(approval_id, "Quality issues", by: "user_123")

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :rejected
      assert approval.reason == "Quality issues"
    end
  end

  describe "list_pending/1" do
    test "returns only pending approvals" do
      create_pending_approval()
      create_pending_approval()
      {:pending, approved_id} = create_pending_approval()
      FlowStone.Checkpoint.approve(approved_id, by: "user")

      pending = FlowStone.Checkpoint.list_pending()
      assert length(pending) == 2
      assert Enum.all?(pending, &(&1.status == :pending))
    end

    test "filters by checkpoint name" do
      create_pending_approval(checkpoint_name: "review_a")
      create_pending_approval(checkpoint_name: "review_b")

      pending = FlowStone.Checkpoint.list_pending(checkpoint: "review_a")
      assert length(pending) == 1
    end
  end
end
```

### Timeout Worker Tests with Oban.Testing

```elixir
defmodule FlowStone.Workers.CheckpointTimeoutTest do
  use FlowStone.DataCase, async: true
  use Oban.Testing, repo: FlowStone.Repo

  describe "perform/1" do
    test "escalates on timeout" do
      {:pending, approval_id} = create_pending_approval(escalation_to: "senior@example.com")

      # Fast-forward past timeout
      Repo.update_all(
        from(a in FlowStone.Checkpoint.Approval, where: a.id == ^approval_id),
        set: [timeout_at: DateTime.add(DateTime.utc_now(), -1, :hour)]
      )

      assert :ok = perform_job(FlowStone.Workers.CheckpointTimeout, %{approval_id: approval_id})

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :escalated
      assert approval.escalation_count == 1
    end

    test "extends timeout when configured" do
      {:pending, approval_id} = create_pending_approval(on_timeout: {:extend, :timer.hours(24)})

      # Simulate timeout
      perform_job(FlowStone.Workers.CheckpointTimeout, %{approval_id: approval_id})

      {:ok, approval} = FlowStone.Checkpoint.get_approval(approval_id)
      assert approval.status == :pending  # Still pending
      assert approval.timeout_at > DateTime.utc_now()  # Extended
    end
  end
end
```

### State Machine Tests

```elixir
defmodule FlowStone.Checkpoint.StateMachineTest do
  use FlowStone.DataCase, async: true

  describe "state transitions" do
    test "pending -> approved" do
      assert valid_transition?(:pending, :approved)
    end

    test "pending -> rejected" do
      assert valid_transition?(:pending, :rejected)
    end

    test "pending -> escalated" do
      assert valid_transition?(:pending, :escalated)
    end

    test "approved -> * is invalid" do
      refute valid_transition?(:approved, :rejected)
      refute valid_transition?(:approved, :pending)
    end

    test "rejected -> * is invalid" do
      refute valid_transition?(:rejected, :approved)
    end
  end
end
```

## Implementation Order

1. **Approval schema + migration** - Data model
2. **Checkpoint DSL** - Macro definition
3. **Request/approve/reject API** - Core operations
4. **Timeout worker** - Oban job
5. **PubSub integration** - Event broadcasting

## Success Criteria

- [ ] Checkpoint DSL compiles correctly
- [ ] Approval workflow transitions work
- [ ] Timeout handling with Oban
- [ ] PubSub events fire on state changes
- [ ] Conditional checkpoints skip when condition false

## Commands

```bash
mix test test/flowstone/checkpoint_test.exs
mix test test/flowstone/workers/checkpoint_timeout_test.exs
mix coveralls.html
```

## Spawn Subagents

1. **Approval schema** - Ecto + migration
2. **Checkpoint DSL** - Macro implementation
3. **Timeout worker** - Oban integration
4. **PubSub integration** - Event broadcasting

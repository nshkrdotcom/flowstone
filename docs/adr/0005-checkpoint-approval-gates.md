# ADR-0005: Checkpoint and Approval Gate Pattern

## Status
Accepted

## Context

Many workflows require human intervention before proceeding:
- **Quality Assurance**: Review generated content before publication.
- **Sensitive Data**: Validate handling of restricted information.
- **High-Stakes Decisions**: Require expert approval for impactful actions.
- **Regulatory Requirements**: Mandate human sign-off for audit trails.

We need a first-class abstraction for pausing workflows, requesting approval, and resuming execution.

## Decision

### 1. Checkpoint as Asset Extension

A **checkpoint** is a special asset that:
- Pauses workflow execution
- Emits a pending approval state
- Waits for human (or automated) decision
- Resumes with approved, rejected, or modified data

```elixir
checkpoint :quality_review do
  description "Senior analyst reviews generated content before delivery"
  depends_on [:generated_content]

  # Only trigger checkpoint if condition is met
  condition fn _context, %{generated_content: content} ->
    content.confidence_score < 0.9 or content.flagged_for_review
  end

  approval_type :manual
  timeout hours(24)
  escalation_to "senior-team@example.com"

  # Message shown to reviewer
  message fn context, deps ->
    """
    Content Review Required

    Partition: #{inspect(context.partition)}
    Confidence: #{deps.generated_content.confidence_score}
    Flags: #{inspect(deps.generated_content.flags)}

    Please review and approve, modify, or reject.
    """
  end

  # Handle approval outcomes
  on_approve fn _context, deps, _approval ->
    {:ok, deps.generated_content}
  end

  on_modify fn _context, deps, approval ->
    modified = apply_modifications(deps.generated_content, approval.modifications)
    {:ok, modified}
  end

  on_reject fn _context, _deps, approval ->
    {:error, {:rejected, approval.reason}}
  end

  on_timeout fn context, deps ->
    # Options: :escalate, :auto_approve, :auto_reject, {:extend, hours(24)}
    :escalate
  end
end
```

### 2. Approval State Machine

```
                        ┌─────────────────┐
                        │    PENDING      │
                        │  (Checkpoint    │
                        │   created)      │
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
    │    APPROVED     │ │    MODIFIED     │ │    REJECTED     │
    │                 │ │                 │ │                 │
    │ (Continue with  │ │ (Continue with  │ │ (Fail workflow  │
    │  original data) │ │  modified data) │ │  with reason)   │
    └────────┬────────┘ └────────┬────────┘ └────────┬────────┘
             │                   │                   │
             ▼                   ▼                   ▼
    ┌─────────────────────────────────────────────────────────┐
    │                    RESUME WORKFLOW                       │
    │              (or halt on rejection)                      │
    └─────────────────────────────────────────────────────────┘

    Timeout Path:
    ┌─────────────────┐
    │    TIMEOUT      │───▶ Escalate / Auto-decide / Extend
    └─────────────────┘
```

### 3. Database Schema

```sql
CREATE TABLE flowstone_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  materialization_id UUID REFERENCES flowstone_materializations(id),
  checkpoint_name VARCHAR(255) NOT NULL,

  -- Request details
  message TEXT,
  context JSONB,
  timeout_at TIMESTAMPTZ NOT NULL,

  -- Decision
  status VARCHAR(50) NOT NULL DEFAULT 'pending',
  -- pending, approved, modified, rejected, escalated, expired
  decision_by VARCHAR(255),
  decision_at TIMESTAMPTZ,
  reason TEXT,
  modifications JSONB,

  -- Escalation
  escalated_to VARCHAR(255),
  escalation_count INTEGER DEFAULT 0,

  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_approvals_status ON flowstone_approvals(status);
CREATE INDEX idx_approvals_timeout ON flowstone_approvals(timeout_at) WHERE status = 'pending';
CREATE INDEX idx_approvals_materialization ON flowstone_approvals(materialization_id);
```

### 4. Approval API

```elixir
defmodule FlowStone.Checkpoint do
  @doc "Request approval for a checkpoint"
  def request_approval(checkpoint, context, deps) do
    approval = %Approval{
      checkpoint_name: checkpoint.name,
      materialization_id: context.materialization_id,
      message: checkpoint.message.(context, deps),
      context: %{partition: context.partition, run_id: context.run_id},
      timeout_at: DateTime.add(DateTime.utc_now(), checkpoint.timeout, :second)
    }

    {:ok, approval} = Repo.insert(approval)

    # Notify via configured channels
    FlowStone.Notifier.send_approval_request(approval)

    # Schedule timeout job
    %{approval_id: approval.id}
    |> FlowStone.Workers.CheckpointTimeout.new(scheduled_at: approval.timeout_at)
    |> Oban.insert()

    {:pending, approval.id}
  end

  @doc "Approve a pending checkpoint"
  def approve(approval_id, opts \\ []) do
    with {:ok, approval} <- get_pending(approval_id),
         {:ok, approval} <- update_decision(approval, :approved, opts) do
      resume_workflow(approval)
    end
  end

  @doc "Modify and approve a checkpoint"
  def modify(approval_id, modifications, opts \\ []) do
    with {:ok, approval} <- get_pending(approval_id),
         {:ok, approval} <- update_decision(approval, :modified, Keyword.put(opts, :modifications, modifications)) do
      resume_workflow(approval)
    end
  end

  @doc "Reject a checkpoint"
  def reject(approval_id, reason, opts \\ []) do
    with {:ok, approval} <- get_pending(approval_id),
         {:ok, approval} <- update_decision(approval, :rejected, Keyword.put(opts, :reason, reason)) do
      fail_workflow(approval, reason)
    end
  end
end
```

### 5. UI Integration

The checkpoint system integrates with Phoenix LiveView:

```elixir
defmodule FlowStoneWeb.ApprovalsLive do
  use FlowStoneWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FlowStone.PubSub, "approvals")
    end

    approvals = FlowStone.Checkpoint.list_pending()
    {:ok, assign(socket, approvals: approvals)}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    :ok = FlowStone.Checkpoint.approve(id, by: socket.assigns.current_user.id)
    {:noreply, socket}
  end

  def handle_event("reject", %{"id" => id, "reason" => reason}, socket) do
    :ok = FlowStone.Checkpoint.reject(id, reason, by: socket.assigns.current_user.id)
    {:noreply, socket}
  end

  def handle_info({:approval_created, approval}, socket) do
    {:noreply, update(socket, :approvals, &[approval | &1])}
  end

  def handle_info({:approval_resolved, approval_id}, socket) do
    {:noreply, update(socket, :approvals, &Enum.reject(&1, fn a -> a.id == approval_id end))}
  end
end
```

### 6. Automated Checkpoints

Checkpoints can also be resolved programmatically:

```elixir
checkpoint :automated_validation do
  depends_on [:data]
  approval_type :automated

  # Automated decision logic
  auto_decide fn context, %{data: data} ->
    cond do
      Validator.valid?(data) -> :approve
      Validator.fixable?(data) -> {:modify, Validator.fix(data)}
      true -> {:reject, "Validation failed: #{Validator.errors(data)}"}
    end
  end
end
```

### 7. Conditional Checkpoints

Checkpoints only trigger when conditions are met:

```elixir
checkpoint :sensitive_data_review do
  depends_on [:processed_data]

  # Only trigger if sensitive data detected
  condition fn _context, %{processed_data: data} ->
    SensitiveDataDetector.detected?(data) and
    SensitiveDataDetector.confidence(data) > 0.8
  end

  # If condition is false, checkpoint is skipped (auto-approved)
  on_skip fn _context, deps ->
    {:ok, deps.processed_data}
  end

  # ... rest of checkpoint config
end
```

## Consequences

### Positive

1. **First-Class Human Review**: Not an afterthought, built into the model.
2. **Audit Trail**: Every approval decision is recorded with who/when/why.
3. **Flexible Triggers**: Conditional checkpoints avoid unnecessary interruptions.
4. **Timeout Handling**: Configurable escalation and auto-decision paths.
5. **Real-Time UI**: LiveView provides instant notification of pending approvals.

### Negative

1. **Workflow Latency**: Human checkpoints add unpredictable delays.
2. **Complexity**: State machine and timeout handling add code complexity.
3. **UI Requirement**: Practical use requires building approval interfaces.

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| No HITL support | First-class checkpoint primitive |
| Manual pause/resume | Automatic state machine |
| No timeout handling | Scheduled timeout jobs |
| No escalation | Configurable escalation chains |

## References

- Dagster Asset Checks: https://docs.dagster.io/concepts/assets/asset-checks
- Temporal Human Tasks: https://docs.temporal.io/workflows#human-in-the-loop

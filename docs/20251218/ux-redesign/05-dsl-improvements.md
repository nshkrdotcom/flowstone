# DSL Improvements

**Status:** Design Proposal
**Date:** 2025-12-18

## Overview

The Pipeline DSL should be concise, expressive, and forgiving. This document proposes improvements to reduce boilerplate and improve clarity.

---

## 1. Shortened Asset Syntax

### Current
```elixir
asset :greeting do
  execute fn _, _ -> {:ok, "Hello"} end
end
```

### Proposed: One-liner Support
```elixir
# Implicit execute for simple cases
asset :greeting, do: {:ok, "Hello"}

# With function
asset :greeting, do: fn _, _ -> {:ok, "Hello"} end

# Still supports block form
asset :greeting do
  description "A friendly greeting"
  execute fn _, _ -> {:ok, "Hello"} end
end
```

### Proposed: Arrow Syntax
```elixir
# Simple value
asset :greeting -> {:ok, "Hello"}

# With dependencies (pattern matched)
asset :doubled, [:raw] -> fn _, %{raw: n} -> {:ok, n * 2} end

# Equivalent to:
asset :doubled do
  depends_on [:raw]
  execute fn _, %{raw: n} -> {:ok, n * 2} end
end
```

---

## 2. Implicit {:ok, value} Wrapping

### Current
```elixir
execute fn _, _ -> {:ok, compute_something()} end
```

### Proposed
```elixir
# Automatic wrapping when return is not {:ok, _} or {:error, _}
execute fn _, _ -> compute_something() end

# Explicit tuples still work
execute fn _, _ ->
  case something() do
    :success -> {:ok, "done"}
    :failure -> {:error, "failed"}
  end
end

# Configure per-pipeline
defmodule MyPipeline do
  use FlowStone.Pipeline, wrap_results: true  # default
  # or
  use FlowStone.Pipeline, wrap_results: false  # explicit tuples required
end
```

**Rules:**
- If return is `{:ok, _}` → pass through
- If return is `{:error, _}` → pass through
- If return is any other value → wrap in `{:ok, value}`
- If function raises → wrap in `{:error, exception}`

---

## 3. Dependency Shorthand

### Current
```elixir
asset :output do
  depends_on [:cleaned, :validated, :enriched]

  execute fn _, deps ->
    process(deps.cleaned, deps.validated, deps.enriched)
  end
end
```

### Proposed: Named Parameters
```elixir
asset :output do
  depends_on cleaned: :cleaned, validated: :validated, enriched: :enriched

  execute fn _, %{cleaned: c, validated: v, enriched: e} ->
    process(c, v, e)
  end
end

# Or with aliasing
asset :output do
  depends_on [
    cleaned: :raw_cleaned_data,      # Use different name internally
    validated: :validation_results,
    enriched: :ai_enrichment
  ]

  execute fn _, %{cleaned: c, validated: v, enriched: e} ->
    # c is from :raw_cleaned_data
    # v is from :validation_results
    # etc.
  end
end
```

### Proposed: Destructuring in Signature
```elixir
# Pattern match dependencies directly
asset :output, [:cleaned, :validated] do
  execute fn _, cleaned, validated ->
    process(cleaned, validated)
  end
end

# Equivalent to:
asset :output do
  depends_on [:cleaned, :validated]
  execute fn _, %{cleaned: cleaned, validated: validated} ->
    process(cleaned, validated)
  end
end
```

---

## 4. Context Access Improvements

### Current
```elixir
execute fn ctx, deps ->
  partition = ctx.partition
  run_id = ctx.run_id
  resources = ctx.resources
  # ...
end
```

### Proposed: Destructuring
```elixir
execute fn %{partition: p, resources: %{ai: ai}}, deps ->
  # Direct access to what you need
end

# Or use module attributes for common patterns
asset :output do
  @partition ctx.partition
  @ai ctx.resources.ai

  execute fn ctx, deps ->
    # Use @partition and @ai
  end
end
```

### Proposed: Context Helpers
```elixir
asset :output do
  execute fn ctx, deps ->
    # New helpers on context
    ctx.partition          # The partition value
    ctx.partition_date     # Parsed as Date if possible
    ctx.partition_string   # As string
    ctx.run_id             # UUID of this run
    ctx.asset_name         # :output
    ctx.pipeline           # MyPipeline
    ctx.attempt            # Retry attempt number (1, 2, 3...)
    ctx.scheduled_at       # When job was scheduled (if async)
    ctx.started_at         # When execution started
  end
end
```

---

## 5. Resource Declaration

### Current
```elixir
# Must manually check for resources
execute fn ctx, deps ->
  ai = ctx.resources[:ai] || raise "AI resource not configured"
  ai.generate(...)
end
```

### Proposed: Explicit Requirements
```elixir
asset :enriched do
  requires [:ai, :cache]  # Validated at registration time

  execute fn ctx, deps ->
    ctx.ai.generate(...)      # Available directly on ctx
    ctx.cache.get(key)
  end
end

# Resources available directly on ctx when declared
# Fails fast at pipeline registration if missing
```

---

## 6. Scatter Improvements

### Current
```elixir
asset :processed do
  depends_on [:items]

  scatter fn %{items: items} ->
    Enum.map(items, fn item -> %{id: item.id} end)
  end

  scatter_options do
    max_concurrent 50
    failure_threshold 0.1
  end

  execute fn ctx, _ ->
    id = ctx.scatter_key.id
    {:ok, process(id)}
  end

  gather fn results ->
    {:ok, Map.values(results)}
  end
end
```

### Proposed: Cleaner Syntax
```elixir
asset :processed do
  depends_on [:items]

  # Scatter with inline options
  scatter from: :items,
          key: & &1.id,
          max_concurrent: 50,
          on_failure: :continue

  # Simpler key access
  execute fn ctx, _ ->
    {:ok, process(ctx.key)}  # ctx.key instead of ctx.scatter_key
  end

  # Optional gather (default: collect as map)
  gather &Map.values/1
end

# Even simpler for common case
asset :processed do
  depends_on [:items]
  scatter :items, by: :id, concurrent: 50
  execute fn ctx, _ -> process(ctx.key) end
end
```

---

## 7. Parallel Branch Improvements

### Current
```elixir
asset :enriched do
  depends_on [:customer]

  parallel do
    branch :credit do
      execute fn _, deps -> fetch_credit(deps.customer) end
    end

    branch :fraud do
      execute fn _, deps -> check_fraud(deps.customer) end
    end
  end

  join fn branch_results, deps ->
    {:ok, merge_results(deps.customer, branch_results)}
  end
end
```

### Proposed: Inline Branches
```elixir
asset :enriched do
  depends_on [:customer]

  parallel(
    credit: fn _, %{customer: c} -> fetch_credit(c) end,
    fraud: fn _, %{customer: c} -> check_fraud(c) end,
    history: fn _, %{customer: c} -> fetch_history(c) end
  )

  join fn %{credit: cr, fraud: fr, history: hi}, %{customer: c} ->
    Map.merge(c, %{credit: cr, fraud: fr, history: hi})
  end
end
```

---

## 8. Route Improvements

### Current
```elixir
asset :routed do
  depends_on [:order]

  route fn %{order: o} ->
    cond do
      o.total > 10000 -> :high_value
      o.subscription -> :subscription
      true -> :standard
    end
  end

  branch :high_value do
    execute fn _, deps -> process_high(deps.order) end
  end

  branch :subscription do
    execute fn _, deps -> process_sub(deps.order) end
  end

  branch :standard do
    execute fn _, deps -> process_std(deps.order) end
  end
end
```

### Proposed: Match Syntax
```elixir
asset :routed do
  depends_on [:order]

  route on: :order do
    match %{total: t} when t > 10000 -> :high_value
    match %{subscription: true} -> :subscription
    default -> :standard
  end

  branch :high_value, do: fn _, %{order: o} -> process_high(o) end
  branch :subscription, do: fn _, %{order: o} -> process_sub(o) end
  branch :standard, do: fn _, %{order: o} -> process_std(o) end
end
```

---

## 9. Approval Improvements

### Current
```elixir
asset :approved do
  depends_on [:staged]

  execute fn _, deps ->
    {:wait_for_approval, %{
      message: "Approve deployment?",
      context: deps.staged,
      timeout_at: DateTime.add(DateTime.utc_now(), 24, :hour)
    }}
  end
end
```

### Proposed: Dedicated DSL
```elixir
asset :approved do
  depends_on [:staged]

  approval do
    message "Approve deployment to production?"
    context fn _, %{staged: s} -> %{version: s.version, changes: s.changes} end
    timeout 24, :hours
    notify :slack, channel: "#deploys"
    notify :email, to: "ops@example.com"
  end
end

# Or inline
asset :approved do
  depends_on [:staged]
  approval "Approve deployment?", timeout: {24, :hours}
end
```

---

## 10. Error Handling

### Current
```elixir
execute fn _, deps ->
  case risky_operation(deps.data) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end
```

### Proposed: Retry Configuration
```elixir
asset :external_call do
  retry attempts: 3,
        delay: :timer.seconds(5),
        backoff: :exponential,
        on: [TimeoutError, ConnectionError]

  execute fn _, deps ->
    call_external_api(deps.data)
  end
end
```

### Proposed: Fallback
```elixir
asset :data do
  execute fn _, _ ->
    fetch_from_primary()
  end

  fallback fn error, ctx, deps ->
    Logger.warn("Primary failed: #{inspect(error)}")
    fetch_from_secondary()
  end
end
```

---

## 11. Documentation Integration

### Proposed: Inline Docs
```elixir
asset :customer_score do
  @moduledoc """
  Calculates customer credit score based on transaction history.

  ## Dependencies
  - `:transactions` - Last 12 months of transactions
  - `:profile` - Customer profile data

  ## Output
  Returns `%{score: integer(), factors: list()}`.
  """

  depends_on [:transactions, :profile]

  execute fn _, %{transactions: txns, profile: p} ->
    calculate_score(txns, p)
  end
end

# Access docs
FlowStone.asset_doc(MyPipeline, :customer_score)
# => "Calculates customer credit score..."
```

---

## 12. Type Specifications

### Proposed
```elixir
asset :customer do
  @type output :: %{id: integer(), name: String.t(), email: String.t()}

  execute fn _, _ ->
    {:ok, fetch_customer()}
  end
end

asset :enriched do
  depends_on [:customer]

  @type input :: %{customer: MyPipeline.customer.output()}
  @type output :: %{customer: map(), score: float()}

  execute fn _, deps ->
    # Type checking available in development
  end
end
```

---

## 13. Testing DSL

### Proposed
```elixir
defmodule MyPipelineTest do
  use FlowStone.Test

  describe "customer_score" do
    test "calculates score correctly" do
      # Provide mock dependencies
      result = run_asset(MyPipeline, :customer_score,
        with_deps: %{
          transactions: [%{amount: 100}, %{amount: 200}],
          profile: %{age: 30, income: 50000}
        }
      )

      assert {:ok, %{score: score}} = result
      assert score > 600
    end

    test "handles missing transactions" do
      result = run_asset(MyPipeline, :customer_score,
        with_deps: %{
          transactions: [],
          profile: %{age: 30}
        }
      )

      assert {:ok, %{score: 0}} = result
    end
  end
end
```

---

## Summary of Changes

| Feature | Current | Proposed |
|---------|---------|----------|
| Simple asset | 3 lines | 1 line |
| Return wrapping | Explicit `{:ok, _}` | Implicit |
| Dependencies | Map access | Destructuring |
| Scatter options | Nested block | Inline keyword |
| Parallel branches | Nested blocks | Inline map |
| Routing | Nested blocks | Match syntax |
| Approvals | Manual tuple | Dedicated DSL |
| Retries | Manual | Declarative |
| Documentation | Separate | Inline `@moduledoc` |
| Testing | Manual setup | `use FlowStone.Test` |

All changes are **backward compatible** - existing DSL continues to work.

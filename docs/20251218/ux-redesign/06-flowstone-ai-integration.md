# FlowStone AI Integration

**Status:** Design Proposal
**Date:** 2025-12-18

## Overview

FlowStone AI (`flowstone_ai`) is a separate optional package that bridges FlowStone with AI providers via `altar_ai`. This document proposes improvements to the AI integration UX.

---

## Current State

### Architecture

```
flowstone (core)
    │
    └── flowstone_ai (optional)
            │
            └── altar_ai (AI adapters)
                    │
                    ├── gemini_ex
                    ├── anthropic SDK
                    └── openai SDK
```

### Current Usage

```elixir
# 1. Add dependencies
{:flowstone_ai, path: "../flowstone_ai"}

# 2. Configure
config :flowstone_ai,
  adapter: Altar.AI.Adapters.Gemini,
  adapter_opts: [api_key: System.get_env("GEMINI_API_KEY")]

# 3. Register resource
FlowStone.Resources.register(:ai, FlowStone.AI.Resource, [])

# 4. Use in assets
asset :classified do
  requires [:ai]

  execute fn ctx, deps ->
    FlowStone.AI.Assets.classify_each(
      ctx.resources.ai,
      deps.feedback,
      & &1.text,
      ["bug", "feature", "question"]
    )
  end
end
```

### Problems

1. **Verbose setup** - 4 steps before AI works
2. **Manual resource registration** - Easy to forget
3. **Awkward helper access** - `FlowStone.AI.Assets.classify_each`
4. **Resource passed explicitly** - `ctx.resources.ai` everywhere
5. **No provider fallback config** - Must configure Composite adapter manually

---

## Proposed Design

### Goal

AI should be as easy as:

```elixir
# mix.exs
{:flowstone_ai, "~> 1.0"}

# config/config.exs
config :flowstone_ai, provider: :anthropic

# Pipeline
defmodule MyPipeline do
  use FlowStone.Pipeline
  use FlowStone.AI

  asset :classified do
    depends_on [:feedback]

    ai_classify & &1.text,
      labels: ["bug", "feature", "question"],
      on: :feedback
  end
end
```

---

## Configuration

### Minimal Config

```elixir
# Just set the provider - API key from environment
config :flowstone_ai, provider: :anthropic
# Uses ANTHROPIC_API_KEY env var
```

### Explicit Config

```elixir
config :flowstone_ai,
  provider: :anthropic,
  api_key: System.get_env("MY_ANTHROPIC_KEY"),
  model: "claude-3-sonnet-20240229"
```

### Multiple Providers (Fallback)

```elixir
config :flowstone_ai,
  providers: [
    {:anthropic, model: "claude-3-sonnet-20240229"},
    {:openai, model: "gpt-4-turbo"},
    {:gemini, model: "gemini-pro"}
  ],
  strategy: :fallback  # or :round_robin, :cost_optimize
```

### Provider Options

| Provider | Env Var | Options |
|----------|---------|---------|
| `:anthropic` | `ANTHROPIC_API_KEY` | `model`, `max_tokens` |
| `:openai` | `OPENAI_API_KEY` | `model`, `temperature` |
| `:gemini` | `GOOGLE_API_KEY` | `model` |
| `:ollama` | (none) | `base_url`, `model` |
| `:bedrock` | AWS credentials | `model`, `region` |

---

## Pipeline Integration

### Using `use FlowStone.AI`

```elixir
defmodule MyPipeline do
  use FlowStone.Pipeline
  use FlowStone.AI  # Enables AI DSL and auto-registers resource

  asset :feedback do
    execute fn _, _ -> {:ok, load_feedback()} end
  end

  asset :classified do
    depends_on [:feedback]

    # New DSL: ai_classify
    ai_classify & &1.comment,
      labels: ["bug", "feature", "praise"],
      on: :feedback
  end

  asset :summaries do
    depends_on [:classified]

    # New DSL: ai_generate
    ai_generate fn %{classified: items} ->
      bugs = Enum.filter(items, & &1.label == "bug")
      "Summarize these bug reports:\n#{format_bugs(bugs)}"
    end
  end

  asset :embeddings do
    depends_on [:feedback]

    # New DSL: ai_embed
    ai_embed & &1.comment, on: :feedback
  end
end
```

### What `use FlowStone.AI` Does

1. **Auto-registers AI resource** - No manual `Resources.register` call
2. **Imports AI DSL macros** - `ai_classify`, `ai_generate`, `ai_embed`
3. **Adds `ctx.ai`** - Direct access to AI client in execute functions
4. **Sets up telemetry bridge** - AI events forwarded to FlowStone namespace

---

## AI DSL Macros

### ai_classify

Classifies items into labels.

```elixir
asset :classified do
  depends_on [:items]

  # Full form
  ai_classify & &1.text,
    labels: ["positive", "negative", "neutral"],
    on: :items,
    confidence_threshold: 0.8,
    default: "unknown"

  # Short form (infers :on from depends_on if single dep)
  ai_classify & &1.text, labels: ~w(positive negative neutral)
end
```

**Generated code:**
```elixir
execute fn ctx, %{items: items} ->
  FlowStone.AI.classify_each(ctx.ai, items,
    text_fn: & &1.text,
    labels: ["positive", "negative", "neutral"],
    confidence_threshold: 0.8,
    default: "unknown"
  )
end
```

### ai_generate

Generates text from a prompt.

```elixir
asset :summary do
  depends_on [:data]

  # With prompt function
  ai_generate fn %{data: d} ->
    "Summarize this: #{inspect(d)}"
  end

  # Or with template
  ai_generate "Summarize: {{data}}"

  # With options
  ai_generate fn %{data: d} -> "..." end,
    model: "claude-3-opus-20240229",
    max_tokens: 1000,
    temperature: 0.7
end
```

### ai_embed

Generates embeddings for text.

```elixir
asset :searchable do
  depends_on [:documents]

  # Embed each document
  ai_embed & &1.content, on: :documents

  # With options
  ai_embed & &1.content,
    on: :documents,
    model: "text-embedding-3-large",
    dimensions: 1024
end
```

**Output:** Each item gets an `:embedding` field added.

### ai_extract

Extracts structured data.

```elixir
asset :entities do
  depends_on [:text]

  ai_extract from: :text,
    schema: %{
      people: [:string],
      locations: [:string],
      dates: [:date]
    }
end
```

### ai_transform

General AI transformation.

```elixir
asset :translated do
  depends_on [:content]

  ai_transform & &1.text,
    on: :content,
    prompt: "Translate to Spanish: {{input}}",
    output_field: :spanish
end
```

---

## Direct API Access

For complex cases, access the AI client directly:

```elixir
asset :complex_ai do
  depends_on [:data]

  execute fn ctx, %{data: data} ->
    # ctx.ai is the configured AI client
    {:ok, response} = ctx.ai.generate("Complex prompt...")

    # Or use the full API
    {:ok, result} = FlowStone.AI.generate(ctx.ai, "...",
      model: "claude-3-opus",
      system: "You are a helpful assistant",
      max_tokens: 2000
    )

    {:ok, process_response(result)}
  end
end
```

---

## Batch Processing

For efficiency with many items:

```elixir
asset :embedded_docs do
  depends_on [:documents]

  # Automatic batching
  ai_embed & &1.content,
    on: :documents,
    batch_size: 100  # Process 100 at a time
end
```

The AI macros automatically handle:
- Batching API calls
- Rate limiting
- Retry on transient errors
- Progress tracking

---

## Integration with Scatter

For large-scale AI processing:

```elixir
asset :ai_processed do
  depends_on [:items]

  scatter from: :items, by: :id

  execute fn ctx, _ ->
    item = ctx.item
    {:ok, result} = ctx.ai.classify(item.text, ~w(spam ham))
    {:ok, Map.put(item, :classification, result)}
  end

  gather &Map.values/1
end
```

This distributes AI calls across scatter workers with:
- Automatic rate limiting
- Parallel execution
- Failure isolation

---

## Error Handling

### Automatic Retry

```elixir
config :flowstone_ai,
  provider: :anthropic,
  retry: [
    attempts: 3,
    delay: 1000,
    backoff: :exponential
  ]
```

### Fallback Providers

```elixir
config :flowstone_ai,
  providers: [:anthropic, :openai],
  strategy: :fallback
```

If Anthropic fails, automatically tries OpenAI.

### Per-Asset Override

```elixir
asset :critical_classification do
  ai_classify & &1.text,
    labels: ~w(urgent normal),
    on: :tickets,
    retry: [attempts: 5],
    fallback: :openai  # Use OpenAI if primary fails
end
```

---

## Telemetry

FlowStone AI emits telemetry events:

```elixir
[:flowstone, :ai, :generate, :start]
[:flowstone, :ai, :generate, :stop]
[:flowstone, :ai, :generate, :exception]

[:flowstone, :ai, :classify, :start]
[:flowstone, :ai, :classify, :stop]

[:flowstone, :ai, :embed, :start]
[:flowstone, :ai, :embed, :stop]

# Metadata includes:
%{
  provider: :anthropic,
  model: "claude-3-sonnet",
  input_tokens: 150,
  output_tokens: 50,
  duration_ms: 1234,
  cost_usd: 0.0012
}
```

---

## Cost Tracking

```elixir
# Enable cost tracking
config :flowstone_ai,
  provider: :anthropic,
  track_costs: true

# Access costs
FlowStone.AI.costs(MyPipeline, :classified, partition: ~D[2025-01-15])
# => %{
#   total_usd: 1.23,
#   input_tokens: 50000,
#   output_tokens: 10000,
#   requests: 500
# }

# Set budget limits
config :flowstone_ai,
  budget: [
    per_run: 10.00,      # Max $10 per run
    per_day: 100.00,     # Max $100 per day
    on_exceed: :fail     # or :warn, :pause
  ]
```

---

## Testing

```elixir
defmodule MyPipelineTest do
  use FlowStone.Test
  use FlowStone.AI.Test  # Adds AI testing helpers

  describe "classified feedback" do
    test "classifies correctly" do
      # Mock AI responses
      mock_ai_classify(%{
        "This is a bug" => "bug",
        "Great feature!" => "praise"
      })

      result = run_asset(MyPipeline, :classified,
        with_deps: %{
          feedback: [
            %{id: 1, text: "This is a bug"},
            %{id: 2, text: "Great feature!"}
          ]
        }
      )

      assert {:ok, [%{label: "bug"}, %{label: "praise"}]} = result
    end
  end
end
```

---

## Should flowstone_ai Merge Into Core?

### Arguments for Keeping Separate

| Reason | Explanation |
|--------|-------------|
| **Heavy deps** | altar_ai brings multiple HTTP clients, JSON libs |
| **Optional** | Not all pipelines need AI |
| **Versioning** | AI providers change frequently |
| **Clear boundary** | Separation of concerns |
| **Testing** | Core tests don't need AI mocks |

### Arguments for Merging

| Reason | Explanation |
|--------|-------------|
| **Simpler install** | One package |
| **Cohesive UX** | No separate `use FlowStone.AI` |
| **Discovery** | Users find AI features naturally |

### Recommendation: Keep Separate

The separation is correct. The improvements should focus on:

1. **Better UX** - `use FlowStone.AI` macro does more work
2. **Simpler config** - Just `provider: :anthropic`
3. **DSL macros** - `ai_classify`, `ai_generate`, etc.
4. **Auto-registration** - No manual resource setup

The package boundary stays, but the developer experience improves.

---

## Migration from Current

### Before
```elixir
# config.exs
config :flowstone_ai,
  adapter: Altar.AI.Adapters.Gemini,
  adapter_opts: [api_key: System.get_env("GEMINI_API_KEY")]

# application.ex
FlowStone.Resources.register(:ai, FlowStone.AI.Resource, [])

# pipeline.ex
defmodule MyPipeline do
  use FlowStone.Pipeline

  asset :classified do
    requires [:ai]

    execute fn ctx, %{feedback: items} ->
      FlowStone.AI.Assets.classify_each(
        ctx.resources.ai,
        items,
        & &1.text,
        ["bug", "feature"]
      )
    end
  end
end
```

### After
```elixir
# config.exs
config :flowstone_ai, provider: :gemini

# pipeline.ex
defmodule MyPipeline do
  use FlowStone.Pipeline
  use FlowStone.AI

  asset :classified do
    depends_on [:feedback]
    ai_classify & &1.text, labels: ~w(bug feature)
  end
end
```

---

## Complete Example

```elixir
# config/config.exs
config :flowstone, repo: MyApp.Repo

config :flowstone_ai,
  provider: :anthropic,
  model: "claude-3-sonnet-20240229"

# lib/my_app/feedback_pipeline.ex
defmodule MyApp.FeedbackPipeline do
  use FlowStone.Pipeline
  use FlowStone.AI

  @moduledoc "Processes customer feedback with AI"

  asset :raw_feedback do
    execute fn ctx, _ ->
      {:ok, MyApp.Feedback.for_date(ctx.partition)}
    end
  end

  asset :classified do
    depends_on [:raw_feedback]

    ai_classify & &1.message,
      labels: ["bug", "feature_request", "praise", "question", "complaint"],
      on: :raw_feedback,
      confidence_threshold: 0.7
  end

  asset :sentiment do
    depends_on [:raw_feedback]

    ai_classify & &1.message,
      labels: ["positive", "neutral", "negative"],
      on: :raw_feedback
  end

  asset :summaries do
    depends_on [:classified, :sentiment]

    execute fn ctx, %{classified: classified, sentiment: sentiment} ->
      by_category = Enum.group_by(classified, & &1.label)

      summaries = for {category, items} <- by_category, into: %{} do
        {:ok, summary} = ctx.ai.generate("""
        Summarize the following #{category} feedback items:

        #{Enum.map_join(items, "\n", & "- #{&1.message}")}

        Provide:
        1. Key themes
        2. Most urgent issues
        3. Suggested actions
        """)

        {category, summary}
      end

      {:ok, %{
        summaries: summaries,
        sentiment_breakdown: Enum.frequencies_by(sentiment, & &1.label)
      }}
    end
  end

  asset :searchable do
    depends_on [:classified]

    ai_embed & &1.message,
      on: :classified,
      dimensions: 768
  end
end

# Run it
FlowStone.run(MyApp.FeedbackPipeline, :summaries, partition: ~D[2025-01-15])
```

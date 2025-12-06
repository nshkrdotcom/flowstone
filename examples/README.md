# FlowStone Live Examples

This folder contains runnable examples that exercise core FlowStone features end-to-end.

## Prerequisites
- Postgres available per `config/dev.exs`.
- One-time setup:
  ```bash
  MIX_ENV=dev mix deps.get
  MIX_ENV=dev mix ecto.create
  MIX_ENV=dev mix ecto.migrate
  ```

## Running
- All examples at once:
  ```bash
  MIX_ENV=dev mix run examples/run_all.exs
  # or
  MIX_ENV=dev bash examples/run_all.sh
  ```
- Individually:
  ```bash
  MIX_ENV=dev mix run examples/core_example.exs
  ```

## Core Examples
- `core_example.exs` — registry + IO + dependency execution.
- `backfill_example.exs` — partitioned asset metadata, partition_fn, backfill skipping.
- `approval_example.exs` — wait-for-approval flow, approvals listing/approval.
- `schedule_example.exs` — cron scheduling with dynamic partitions and manual trigger.
- `telemetry_example.exs` — materialization telemetry tap.
- `postgres_io_example.exs` — Postgres IO manager with composite partitions.
- `sensor_example.exs` — sensor trigger using S3FileArrival with a mock list function.
- `failure_example.exs` — failure path with materialization recording and error capture.

## AI-Powered Examples

These examples demonstrate integrating FlowStone with AI capabilities using the `flowstone_ai` adapter layer.

### Architecture

The AI examples use a three-layer architecture:

```
┌─────────────────────────────────────────────────────┐
│              FlowStone Examples                      │
│   (ai_data_enrichment, content_pipeline, etc.)      │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                   flowstone_ai                       │
│   FlowStone.AI.Resource, FlowStone.AI.Assets        │
│   (classify_each, enrich_each, embed_each)          │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                    altar_ai                          │
│   Protocol-based AI adapters with auto-fallback     │
│   (Gemini, Claude, Codex, Composite, Fallback)      │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│              AI SDKs (Optional)                      │
│   gemini_ex │ claude_agent_sdk │ codex_sdk          │
└─────────────────────────────────────────────────────┘
```

### Prerequisites for AI Examples

Add the following to your `mix.exs` dependencies:

```elixir
{:flowstone_ai, path: "../flowstone_ai"},
{:altar_ai, path: "../altar_ai"}
```

Optionally, install one or more AI SDKs for real AI capabilities:
- **gemini_ex**: Set `GEMINI_API_KEY` environment variable
- **claude_agent_sdk**: Run `claude login` to authenticate
- **codex_sdk**: Set `OPENAI_API_KEY` environment variable

Without any SDKs installed, examples will use the Fallback adapter (heuristic-based).

### Available AI Examples

#### `ai_data_enrichment.exs` — Sentiment Classification
Uses `FlowStone.AI.Assets.classify_each` for batch sentiment analysis. Demonstrates:
- `FlowStone.AI.Resource` for unified AI access
- `FlowStone.AI.Assets.classify_each` for batch classification
- Automatic provider fallback via Composite adapter
- Lineage tracking through AI transformations

```bash
MIX_ENV=dev mix run examples/ai_data_enrichment.exs
```

#### `content_pipeline.exs` — Content Generation
Uses `FlowStone.AI.Resource.generate` for blog post creation. Demonstrates:
- Long-form content generation with automatic provider selection
- Multi-stage content refinement (draft → review → final)
- Quality scoring and automated checks
- Graceful degradation to placeholder content

```bash
MIX_ENV=dev mix run examples/content_pipeline.exs
```

#### `code_analysis_pipeline.exs` — Code Documentation
Uses `FlowStone.AI.Resource.generate` for code analysis. Demonstrates:
- AI-powered code understanding
- Elixir AST parsing combined with AI analysis
- Automated documentation generation
- Complexity metrics calculation

```bash
MIX_ENV=dev mix run examples/code_analysis_pipeline.exs
```

#### `embedding_pipeline.exs` — Vector Embeddings
Uses `FlowStone.AI.Assets.embed_each` for batch embedding. Demonstrates:
- Batch embedding generation via flowstone_ai
- Document preprocessing for embeddings
- Simple vector similarity search
- Fallback to pseudo-embeddings when AI unavailable

```bash
MIX_ENV=dev mix run examples/embedding_pipeline.exs
```

#### `sentiment_analysis.exs` — Sensor-Triggered Analysis
Uses `FlowStone.AI.Assets.classify_each` with sensor patterns. Demonstrates:
- File arrival sensors for triggering pipelines
- Time-window partitioning for streaming data
- Alert generation based on sentiment thresholds
- Trend calculation and issue detection

```bash
MIX_ENV=dev mix run examples/sentiment_analysis.exs
```

## Design Patterns

### FlowStone.AI.Resource Pattern
All AI examples use `FlowStone.AI.Resource` for unified AI access:

```elixir
# Initialize the AI resource (uses Composite adapter by default)
{:ok, ai_resource} = FlowStone.AI.Resource.init()

# Check capabilities
capabilities = FlowStone.AI.Resource.capabilities(ai_resource)
# => %{generate: true, embed: true, classify: true, ...}

# Generate text
{:ok, response} = FlowStone.AI.Resource.generate(ai_resource, "Hello!")
IO.puts(response.content)

# Classify text
{:ok, result} = FlowStone.AI.Resource.classify(
  ai_resource,
  "Great product!",
  ["positive", "negative", "neutral"]
)
# => %{label: "positive", confidence: 0.95}
```

### FlowStone.AI.Assets DSL Pattern
For batch operations, use the DSL helpers:

```elixir
asset :classified_feedback do
  depends_on [:raw_feedback]

  execute fn _ctx, %{raw_feedback: feedback} ->
    ai = Process.get(:ai_resource)

    # Classify each item in the batch
    FlowStone.AI.Assets.classify_each(
      ai,
      feedback,
      & &1.text,  # Extract text from each item
      ["positive", "negative", "neutral"]  # Labels
    )
  end
end

asset :embedded_docs do
  depends_on [:documents]

  execute fn _ctx, %{documents: docs} ->
    ai = Process.get(:ai_resource)

    # Generate embeddings for batch
    FlowStone.AI.Assets.embed_each(
      ai,
      docs,
      & &1.content  # Extract text for embedding
    )
  end
end
```

### Graceful Degradation Pattern
All examples handle AI unavailability gracefully:

```elixir
case FlowStone.AI.Resource.generate(ai, prompt) do
  {:ok, response} ->
    # Use AI-generated content
    {:ok, response.content}

  {:error, _reason} ->
    # Fallback to heuristics or placeholder
    {:ok, fallback_content()}
end
```

### Asset Composition Pattern
```elixir
asset :raw_data do
  execute fn _ctx, _deps -> load_data() end
end

asset :ai_enriched do
  depends_on [:raw_data]
  execute fn _ctx, %{raw_data: data} ->
    ai = Process.get(:ai_resource)
    FlowStone.AI.Assets.enrich_each(ai, data, &build_prompt/1)
  end
end

asset :final_output do
  depends_on [:ai_enriched]
  execute fn _ctx, %{ai_enriched: data} ->
    aggregate_and_format(data)
  end
end
```

## Telemetry Integration

The flowstone_ai package bridges altar_ai telemetry events to FlowStone's namespace:

```elixir
# In your application startup
def start(_type, _args) do
  FlowStone.AI.setup_telemetry()
  # ...
end

# Events are forwarded from [:altar, :ai, ...] to [:flowstone, :ai, ...]
:telemetry.attach(
  "ai-metrics",
  [:flowstone, :ai, :generate, :stop],
  &handle_ai_event/4,
  nil
)
```

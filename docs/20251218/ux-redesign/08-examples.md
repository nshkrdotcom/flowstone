# Complete Examples

**Status:** Design Proposal
**Date:** 2025-12-18

## Overview

This document provides complete, copy-paste-ready examples demonstrating the proposed FlowStone UX.

---

## Example 1: Hello World

The simplest possible pipeline.

### mix.exs
```elixir
defp deps do
  [{:flowstone, "~> 1.0"}]
end
```

### lib/hello_pipeline.ex
```elixir
defmodule HelloPipeline do
  use FlowStone.Pipeline

  asset :greeting, do: {:ok, "Hello, World!"}
end
```

### Usage
```elixir
iex> FlowStone.run(HelloPipeline, :greeting)
{:ok, "Hello, World!"}
```

---

## Example 2: Data Transformation

A pipeline with dependencies.

### lib/transform_pipeline.ex
```elixir
defmodule TransformPipeline do
  use FlowStone.Pipeline

  asset :raw_numbers do
    execute fn _, _ ->
      {:ok, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}
    end
  end

  asset :evens do
    depends_on [:raw_numbers]

    execute fn _, %{raw_numbers: numbers} ->
      {:ok, Enum.filter(numbers, &(rem(&1, 2) == 0))}
    end
  end

  asset :squared do
    depends_on [:evens]

    execute fn _, %{evens: numbers} ->
      {:ok, Enum.map(numbers, &(&1 * &1))}
    end
  end

  asset :sum do
    depends_on [:squared]

    execute fn _, %{squared: numbers} ->
      {:ok, Enum.sum(numbers)}
    end
  end
end
```

### Usage
```elixir
iex> FlowStone.run(TransformPipeline, :sum)
{:ok, 220}

iex> FlowStone.graph(TransformPipeline)
"""
raw_numbers
└── evens
    └── squared
        └── sum
"""
```

---

## Example 3: Daily ETL with Partitions

A date-partitioned pipeline for daily processing.

### config/config.exs
```elixir
config :flowstone, repo: MyApp.Repo
```

### lib/daily_etl.ex
```elixir
defmodule DailyETL do
  use FlowStone.Pipeline

  asset :raw_events do
    description "Load events for the partition date"

    execute fn ctx, _ ->
      date = ctx.partition
      events = MyApp.Events.for_date(date)
      {:ok, events}
    end
  end

  asset :cleaned_events do
    depends_on [:raw_events]

    execute fn _, %{raw_events: events} ->
      cleaned = events
        |> Enum.reject(&is_nil(&1.user_id))
        |> Enum.map(&normalize_event/1)

      {:ok, cleaned}
    end
  end

  asset :user_sessions do
    depends_on [:cleaned_events]

    execute fn _, %{cleaned_events: events} ->
      sessions = events
        |> Enum.group_by(& &1.user_id)
        |> Enum.map(fn {user_id, user_events} ->
          %{
            user_id: user_id,
            session_count: count_sessions(user_events),
            total_duration: sum_durations(user_events)
          }
        end)

      {:ok, sessions}
    end
  end

  asset :daily_metrics do
    depends_on [:user_sessions]

    execute fn ctx, %{user_sessions: sessions} ->
      {:ok, %{
        date: ctx.partition,
        total_users: length(sessions),
        avg_sessions: avg(sessions, & &1.session_count),
        avg_duration: avg(sessions, & &1.total_duration)
      }}
    end
  end

  # Helper functions
  defp normalize_event(event), do: event
  defp count_sessions(events), do: length(events)
  defp sum_durations(events), do: Enum.sum(Enum.map(events, & &1.duration || 0))
  defp avg([], _), do: 0
  defp avg(list, fun), do: Enum.sum(Enum.map(list, fun)) / length(list)
end
```

### Usage
```elixir
# Run for a specific date
iex> FlowStone.run(DailyETL, :daily_metrics, partition: ~D[2025-01-15])
{:ok, %{date: ~D[2025-01-15], total_users: 1234, ...}}

# Backfill a month
iex> FlowStone.backfill(DailyETL, :daily_metrics,
...>   partitions: Date.range(~D[2025-01-01], ~D[2025-01-31]),
...>   parallel: 4
...> )
{:ok, %{succeeded: 31, failed: 0}}

# Check if already computed
iex> FlowStone.exists?(DailyETL, :daily_metrics, partition: ~D[2025-01-15])
true

# Get cached result
iex> FlowStone.get(DailyETL, :daily_metrics, partition: ~D[2025-01-15])
{:ok, %{date: ~D[2025-01-15], ...}}
```

---

## Example 4: Web Scraper with Scatter

Parallel processing of many URLs.

### lib/scraper_pipeline.ex
```elixir
defmodule ScraperPipeline do
  use FlowStone.Pipeline

  asset :urls do
    execute fn _, _ ->
      urls = [
        "https://example.com/page1",
        "https://example.com/page2",
        "https://example.com/page3",
        # ... many more URLs
      ]
      {:ok, urls}
    end
  end

  asset :pages do
    depends_on [:urls]

    # Fan out: one job per URL
    scatter fn %{urls: urls} ->
      Enum.map(urls, &%{url: &1})
    end

    scatter_options do
      max_concurrent 10
      rate_limit {5, :second}  # Max 5 requests per second
      failure_threshold 0.2    # Fail if > 20% fail
    end

    execute fn ctx, _ ->
      url = ctx.scatter_key.url

      case HTTPoison.get(url) do
        {:ok, %{status_code: 200, body: body}} ->
          {:ok, %{url: url, body: body, scraped_at: DateTime.utc_now()}}

        {:ok, %{status_code: code}} ->
          {:error, {:http_error, code}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    gather fn results ->
      pages = Map.values(results)
      {:ok, pages}
    end
  end

  asset :parsed_data do
    depends_on [:pages]

    execute fn _, %{pages: pages} ->
      parsed = Enum.map(pages, fn page ->
        %{
          url: page.url,
          title: extract_title(page.body),
          links: extract_links(page.body),
          scraped_at: page.scraped_at
        }
      end)

      {:ok, parsed}
    end
  end

  defp extract_title(html) do
    case Regex.run(~r/<title>([^<]+)<\/title>/i, html) do
      [_, title] -> String.trim(title)
      nil -> nil
    end
  end

  defp extract_links(html) do
    Regex.scan(~r/href="([^"]+)"/, html)
    |> Enum.map(fn [_, href] -> href end)
  end
end
```

### Usage
```elixir
# Run async (returns immediately)
iex> FlowStone.run(ScraperPipeline, :parsed_data, async: true)
{:ok, %Oban.Job{id: 123}}

# Check progress
iex> FlowStone.status(ScraperPipeline, :pages)
%{
  state: :running,
  scatter: %{total: 100, completed: 45, failed: 2, pending: 53}
}

# Wait for completion
iex> FlowStone.await(ScraperPipeline, :parsed_data, timeout: 300_000)
{:ok, [%{url: "...", title: "...", links: [...]}]}
```

---

## Example 5: ML Feature Engineering

A complex pipeline with parallel branches.

### lib/ml_features.ex
```elixir
defmodule MLFeatures do
  use FlowStone.Pipeline

  asset :raw_data do
    execute fn ctx, _ ->
      {:ok, MyApp.Data.load(ctx.partition)}
    end
  end

  asset :features do
    depends_on [:raw_data]

    parallel do
      branch :numeric_features do
        execute fn _, %{raw_data: data} ->
          features = data
            |> Enum.map(&extract_numeric_features/1)
          {:ok, features}
        end
      end

      branch :categorical_features do
        execute fn _, %{raw_data: data} ->
          features = data
            |> Enum.map(&encode_categorical/1)
          {:ok, features}
        end
      end

      branch :text_features do
        execute fn _, %{raw_data: data} ->
          features = data
            |> Enum.map(&extract_text_features/1)
          {:ok, features}
        end
      end

      branch :temporal_features do
        execute fn _, %{raw_data: data} ->
          features = data
            |> Enum.map(&extract_temporal/1)
          {:ok, features}
        end
      end
    end

    join fn branches, %{raw_data: data} ->
      # Combine all feature sets
      combined = data
        |> Enum.with_index()
        |> Enum.map(fn {record, i} ->
          Map.merge(record, %{
            numeric: Enum.at(branches.numeric_features, i),
            categorical: Enum.at(branches.categorical_features, i),
            text: Enum.at(branches.text_features, i),
            temporal: Enum.at(branches.temporal_features, i)
          })
        end)

      {:ok, combined}
    end
  end

  asset :normalized do
    depends_on [:features]

    execute fn _, %{features: features} ->
      {:ok, normalize_features(features)}
    end
  end

  asset :train_test_split do
    depends_on [:normalized]

    execute fn _, %{normalized: features} ->
      {train, test} = Enum.split(Enum.shuffle(features), round(length(features) * 0.8))
      {:ok, %{train: train, test: test}}
    end
  end

  # Feature extraction helpers
  defp extract_numeric_features(record), do: %{}
  defp encode_categorical(record), do: %{}
  defp extract_text_features(record), do: %{}
  defp extract_temporal(record), do: %{}
  defp normalize_features(features), do: features
end
```

---

## Example 6: AI-Powered Analysis

Using FlowStone.AI for intelligent processing.

### config/config.exs
```elixir
config :flowstone, repo: MyApp.Repo

config :flowstone_ai,
  provider: :anthropic,
  model: "claude-3-sonnet-20240229"
```

### lib/feedback_analysis.ex
```elixir
defmodule FeedbackAnalysis do
  use FlowStone.Pipeline
  use FlowStone.AI

  asset :raw_feedback do
    execute fn ctx, _ ->
      {:ok, MyApp.Feedback.for_date(ctx.partition)}
    end
  end

  asset :classified do
    depends_on [:raw_feedback]

    ai_classify & &1.message,
      labels: ["bug", "feature_request", "praise", "complaint", "question"],
      on: :raw_feedback,
      confidence_threshold: 0.7
  end

  asset :with_sentiment do
    depends_on [:classified]

    ai_classify & &1.message,
      labels: ["positive", "neutral", "negative"],
      on: :classified,
      output_field: :sentiment
  end

  asset :urgent_issues do
    depends_on [:with_sentiment]

    execute fn _, %{with_sentiment: feedback} ->
      urgent = feedback
        |> Enum.filter(fn f ->
          f.label in ["bug", "complaint"] and f.sentiment == "negative"
        end)

      {:ok, urgent}
    end
  end

  asset :bug_summary do
    depends_on [:with_sentiment]

    execute fn ctx, %{with_sentiment: feedback} ->
      bugs = Enum.filter(feedback, & &1.label == "bug")

      if Enum.empty?(bugs) do
        {:ok, "No bugs reported."}
      else
        bug_texts = Enum.map_join(bugs, "\n", & "- #{&1.message}")

        ctx.ai.generate("""
        Analyze these bug reports and provide:
        1. Common themes
        2. Priority ranking
        3. Suggested fixes

        Bug reports:
        #{bug_texts}
        """)
      end
    end
  end

  asset :executive_summary do
    depends_on [:with_sentiment, :bug_summary, :urgent_issues]

    execute fn ctx, deps ->
      %{with_sentiment: feedback, bug_summary: bugs, urgent_issues: urgent} = deps

      by_category = Enum.frequencies_by(feedback, & &1.label)
      by_sentiment = Enum.frequencies_by(feedback, & &1.sentiment)

      ctx.ai.generate("""
      Create an executive summary of customer feedback for #{ctx.partition}:

      Total feedback: #{length(feedback)}

      By category:
      #{inspect(by_category)}

      By sentiment:
      #{inspect(by_sentiment)}

      Urgent issues: #{length(urgent)}

      Bug analysis:
      #{bugs}

      Please provide:
      1. Key insights
      2. Top 3 priorities
      3. Recommended actions
      """)
    end
  end
end
```

### Usage
```elixir
# Run full analysis
iex> FlowStone.run(FeedbackAnalysis, :executive_summary, partition: ~D[2025-01-15])
{:ok, "## Executive Summary\n\nToday we received..."}

# Just get urgent issues
iex> FlowStone.run(FeedbackAnalysis, :urgent_issues, partition: ~D[2025-01-15])
{:ok, [%{message: "App crashes when...", label: "bug", sentiment: "negative"}]}
```

---

## Example 7: Document Processing from S3

Processing files from S3 at scale.

### lib/document_processor.ex
```elixir
defmodule DocumentProcessor do
  use FlowStone.Pipeline
  use FlowStone.AI

  asset :processed_documents do
    # Stream documents from S3
    scatter_from :s3 do
      bucket "my-documents"
      prefix "inbox/"
      suffix ".pdf"
      max_items 10_000
    end

    scatter_options do
      max_concurrent 50
      rate_limit {20, :second}
      failure_threshold 0.05
    end

    batch size: 10

    execute fn ctx, _ ->
      # Process batch of documents
      results = Enum.map(ctx.batch_items, fn item ->
        s3_key = item.key

        # Download
        {:ok, content} = download_from_s3(s3_key)

        # Extract text
        text = extract_text_from_pdf(content)

        # Classify with AI
        {:ok, classification} = ctx.ai.classify(text,
          ["invoice", "contract", "report", "letter", "other"]
        )

        %{
          s3_key: s3_key,
          text_length: String.length(text),
          type: classification.label,
          confidence: classification.confidence,
          processed_at: DateTime.utc_now()
        }
      end)

      {:ok, results}
    end

    gather fn results ->
      all_docs = results
        |> Map.values()
        |> List.flatten()

      {:ok, all_docs}
    end
  end

  asset :by_type do
    depends_on [:processed_documents]

    execute fn _, %{processed_documents: docs} ->
      {:ok, Enum.group_by(docs, & &1.type)}
    end
  end

  asset :summary do
    depends_on [:by_type]

    execute fn _, %{by_type: by_type} ->
      summary = for {type, docs} <- by_type, into: %{} do
        {type, %{
          count: length(docs),
          avg_confidence: avg_confidence(docs)
        }}
      end

      {:ok, summary}
    end
  end

  defp download_from_s3(key), do: {:ok, "content"}
  defp extract_text_from_pdf(content), do: "extracted text"
  defp avg_confidence(docs) do
    Enum.sum(Enum.map(docs, & &1.confidence)) / length(docs)
  end
end
```

---

## Example 8: Approval Workflow

A pipeline requiring human approval.

### lib/deploy_pipeline.ex
```elixir
defmodule DeployPipeline do
  use FlowStone.Pipeline

  asset :build do
    execute fn ctx, _ ->
      version = ctx.partition
      {:ok, %{version: version, artifacts: build_artifacts(version)}}
    end
  end

  asset :test do
    depends_on [:build]

    execute fn _, %{build: build} ->
      results = run_tests(build.artifacts)
      {:ok, %{build: build, test_results: results}}
    end
  end

  asset :deploy_staging do
    depends_on [:test]

    execute fn _, %{test: test_data} ->
      if test_data.test_results.passed? do
        url = deploy_to_staging(test_data.build.artifacts)
        {:ok, %{staging_url: url, build: test_data.build}}
      else
        {:error, :tests_failed}
      end
    end
  end

  asset :approve_production do
    depends_on [:deploy_staging]

    approval do
      message fn _, %{deploy_staging: staging} ->
        """
        Approve deployment of version #{staging.build.version} to production?

        Staging URL: #{staging.staging_url}
        """
      end

      timeout 24, :hours

      notify :slack, channel: "#deployments"
      notify :email, to: ["ops@example.com", "lead@example.com"]

      context fn _, %{deploy_staging: staging} ->
        %{
          version: staging.build.version,
          staging_url: staging.staging_url
        }
      end
    end
  end

  asset :deploy_production do
    depends_on [:approve_production, :deploy_staging]

    execute fn _, %{deploy_staging: staging} ->
      url = deploy_to_production(staging.build.artifacts)
      {:ok, %{production_url: url, version: staging.build.version}}
    end
  end

  # Helpers
  defp build_artifacts(version), do: %{version: version, files: []}
  defp run_tests(_), do: %{passed?: true, count: 42}
  defp deploy_to_staging(_), do: "https://staging.example.com"
  defp deploy_to_production(_), do: "https://example.com"
end
```

### Usage
```elixir
# Start deployment (pauses at approval)
iex> FlowStone.run(DeployPipeline, :deploy_production,
...>   partition: "v1.2.3",
...>   async: true
...> )
{:ok, %Oban.Job{}}

# Check status
iex> FlowStone.status(DeployPipeline, :approve_production, partition: "v1.2.3")
%{state: :pending_approval, ...}

# Approve (from API or UI)
iex> FlowStone.approve(DeployPipeline, :approve_production,
...>   partition: "v1.2.3",
...>   approved_by: "alice@example.com"
...> )
:ok

# Check final status
iex> FlowStone.status(DeployPipeline, :deploy_production, partition: "v1.2.3")
%{state: :completed, ...}

iex> FlowStone.get(DeployPipeline, :deploy_production, partition: "v1.2.3")
{:ok, %{production_url: "https://example.com", version: "v1.2.3"}}
```

---

## Example 9: Testing Pipeline

How to test FlowStone pipelines.

### test/transform_pipeline_test.exs
```elixir
defmodule TransformPipelineTest do
  use FlowStone.Test

  describe "sum" do
    test "calculates sum of squared evens" do
      {:ok, result} = FlowStone.run(TransformPipeline, :sum)
      assert result == 220
    end
  end

  describe "evens" do
    test "filters only even numbers" do
      {:ok, result} = FlowStone.run(TransformPipeline, :evens)
      assert result == [2, 4, 6, 8, 10]
    end
  end

  describe "with mocked dependencies" do
    test "squared works with custom input" do
      {:ok, result} = run_asset(TransformPipeline, :squared,
        with_deps: %{evens: [1, 2, 3]}
      )

      assert result == [1, 4, 9]
    end
  end
end
```

### test/feedback_analysis_test.exs
```elixir
defmodule FeedbackAnalysisTest do
  use FlowStone.Test
  use FlowStone.AI.Test

  describe "classified" do
    test "classifies feedback correctly" do
      # Mock AI responses
      mock_ai_classify(%{
        "The app crashes constantly" => "bug",
        "Love the new feature!" => "praise",
        "Can you add dark mode?" => "feature_request"
      })

      {:ok, result} = run_asset(FeedbackAnalysis, :classified,
        partition: ~D[2025-01-15],
        with_deps: %{
          raw_feedback: [
            %{id: 1, message: "The app crashes constantly"},
            %{id: 2, message: "Love the new feature!"},
            %{id: 3, message: "Can you add dark mode?"}
          ]
        }
      )

      assert Enum.map(result, & &1.label) == ["bug", "praise", "feature_request"]
    end
  end
end
```

---

## Quick Reference

```elixir
# Run asset
FlowStone.run(Pipeline, :asset)
FlowStone.run(Pipeline, :asset, partition: value)
FlowStone.run(Pipeline, :asset, async: true)

# Get result
FlowStone.get(Pipeline, :asset)
FlowStone.get(Pipeline, :asset, partition: value)

# Check status
FlowStone.status(Pipeline, :asset)
FlowStone.exists?(Pipeline, :asset)

# Backfill
FlowStone.backfill(Pipeline, :asset, partitions: enum)

# Cancel/Invalidate
FlowStone.cancel(Pipeline, :asset)
FlowStone.invalidate(Pipeline, :asset)

# Inspection
FlowStone.graph(Pipeline)
FlowStone.assets(Pipeline)
FlowStone.asset_info(Pipeline, :asset)

# Approvals
FlowStone.approve(Pipeline, :asset, approved_by: "user")
FlowStone.reject(Pipeline, :asset, reason: "...")
```

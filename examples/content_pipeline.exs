# Content Generation Pipeline
# Demonstrates using flowstone_ai for AI-powered content creation
#
# This pipeline:
# 1. Takes content briefs as input
# 2. Uses FlowStone.AI.Resource to generate drafts
# 3. Runs quality checks and approval gates
# 4. Produces final publishable content
#
# Usage:
#   MIX_ENV=dev mix run examples/content_pipeline.exs
#
# Requirements:
#   - {:flowstone_ai, path: "../flowstone_ai"} in mix.exs
#   - {:altar_ai, path: "../altar_ai"} in mix.exs
#   - At least one AI SDK installed (gemini_ex, claude_agent_sdk, or codex_sdk)

defmodule Examples.ContentPipeline do
  @moduledoc """
  AI-powered content generation pipeline using FlowStone and flowstone_ai.

  Demonstrates:
  - Using FlowStone.AI.Resource for unified AI access
  - Long-form content generation with automatic provider selection
  - Multi-stage content refinement (draft -> review -> final)
  - Quality scoring and automated checks
  """

  def run do
    ensure_started(FlowStone.Registry, name: :content_registry)
    ensure_started(FlowStone.IO.Memory, name: :content_io)
    ensure_started(FlowStone.Lineage, name: :content_lineage)

    # Initialize AI resource
    {:ok, ai_resource} = FlowStone.AI.Resource.init()
    Process.put(:ai_resource, ai_resource)

    FlowStone.register(Pipeline, registry: :content_registry)

    IO.puts("Starting Content Generation Pipeline...")
    IO.puts("AI capabilities: #{inspect(FlowStone.AI.Resource.capabilities(ai_resource))}")
    IO.puts("Processing content brief: blog_post_001\n")

    result =
      FlowStone.materialize_all(:final_content,
        partition: "blog_post_001",
        registry: :content_registry,
        io: [config: %{agent: :content_io}],
        lineage_server: :content_lineage,
        resource_server: nil
      )

    FlowStone.ObanHelpers.drain()

    case result do
      {:ok, _} ->
        content =
          FlowStone.IO.load(:final_content, "blog_post_001", config: %{agent: :content_io})

        IO.puts("\n=== Final Content ===")
        display_content(content)

      {:error, reason} ->
        IO.puts("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp display_content(%{title: title, body: body, metadata: metadata}) do
    IO.puts("Title: #{title}")
    IO.puts("Word count: #{metadata[:word_count]}")
    IO.puts("Quality score: #{metadata[:quality_score]}")
    IO.puts("\n--- Content Preview ---")
    IO.puts(String.slice(body, 0, 500) <> "...")
  end

  defp display_content(content), do: IO.inspect(content, pretty: true)

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    @moduledoc """
    Asset definitions for the content generation pipeline.
    Uses FlowStone.AI.Resource for AI operations.
    """
    use FlowStone.Pipeline

    @sample_brief %{
      topic: "Introduction to Elixir for Data Engineering",
      target_audience: "Data engineers familiar with Python",
      tone: "technical but approachable",
      key_points: [
        "BEAM VM advantages for data pipelines",
        "Pattern matching for data transformation",
        "OTP for fault-tolerant processing",
        "Comparison with Python/Spark"
      ],
      word_count_target: 800
    }

    asset :content_brief do
      description("Input content brief with requirements")

      execute(fn _context, _deps ->
        # In production, this would load from a CMS or database
        {:ok, @sample_brief}
      end)
    end

    asset :draft_content do
      description("AI-generated first draft")
      depends_on([:content_brief])

      execute(fn _context, %{content_brief: brief} ->
        ai = Process.get(:ai_resource)
        generate_draft(ai, brief)
      end)
    end

    asset :reviewed_content do
      description("Draft with quality checks applied")
      depends_on([:draft_content, :content_brief])

      execute(fn _context, %{draft_content: draft, content_brief: brief} ->
        quality_check(draft, brief)
      end)
    end

    asset :final_content do
      description("Final polished content ready for publication")
      depends_on([:reviewed_content])

      execute(fn _context, %{reviewed_content: reviewed} ->
        finalize_content(reviewed)
      end)
    end

    # AI-powered draft generation using FlowStone.AI.Resource
    defp generate_draft(ai, brief) do
      prompt = """
      Write a blog post with the following specifications:

      Topic: #{brief.topic}
      Target Audience: #{brief.target_audience}
      Tone: #{brief.tone}
      Target Word Count: #{brief.word_count_target}

      Key Points to Cover:
      #{Enum.map_join(brief.key_points, "\n", &"- #{&1}")}

      Please write the full blog post with:
      1. An engaging title
      2. A compelling introduction
      3. Well-organized sections covering each key point
      4. A conclusion with a call to action

      Focus on practical examples and clear explanations.
      """

      case FlowStone.AI.Resource.generate(ai, prompt) do
        {:ok, response} ->
          content = response.content

          {:ok,
           %{
             title: extract_title(content),
             body: content,
             generated_at: DateTime.utc_now(),
             generator: :flowstone_ai
           }}

        {:error, _reason} ->
          # Fallback to placeholder if AI unavailable
          {:ok,
           %{
             title: "Draft: #{brief.topic}",
             body: generate_placeholder_content(brief),
             generated_at: DateTime.utc_now(),
             generator: :fallback
           }}
      end
    end

    defp extract_title(content) do
      case Regex.run(~r/^#\s*(.+)$/m, content) do
        [_, title] ->
          String.trim(title)

        nil ->
          # Try to extract first line if no markdown header
          content
          |> String.split("\n", trim: true)
          |> List.first()
          |> String.slice(0, 100)
      end
    end

    defp generate_placeholder_content(brief) do
      """
      # #{brief.topic}

      ## Introduction

      This article explores #{brief.topic} for #{brief.target_audience}.

      #{Enum.map_join(brief.key_points, "\n\n", fn point -> "## #{point}\n\nContent about #{String.downcase(point)}..." end)}

      ## Conclusion

      [Placeholder content - AI was unavailable]
      """
    end

    # Quality checking
    defp quality_check(draft, brief) do
      word_count = draft.body |> String.split(~r/\s+/) |> length()
      key_points_covered = check_key_points(draft.body, brief.key_points)
      readability_score = calculate_readability(draft.body)

      quality_score =
        calculate_quality_score(
          word_count,
          brief.word_count_target,
          key_points_covered,
          readability_score
        )

      issues = identify_issues(word_count, brief.word_count_target, key_points_covered)

      {:ok,
       %{
         draft: draft,
         quality_assessment: %{
           word_count: word_count,
           target_word_count: brief.word_count_target,
           key_points_covered: key_points_covered,
           readability_score: readability_score,
           quality_score: quality_score,
           issues: issues
         }
       }}
    end

    defp check_key_points(content, key_points) do
      content_lower = String.downcase(content)

      Enum.map(key_points, fn point ->
        # Check if keywords from the point appear in content
        keywords = point |> String.downcase() |> String.split(~r/\s+/)
        matches = Enum.count(keywords, &String.contains?(content_lower, &1))
        coverage = matches / max(length(keywords), 1)
        {point, coverage > 0.5}
      end)
      |> Map.new()
    end

    defp calculate_readability(text) do
      sentences = String.split(text, ~r/[.!?]+/, trim: true)
      words = String.split(text, ~r/\s+/, trim: true)

      avg_sentence_length = length(words) / max(length(sentences), 1)

      # Simple readability heuristic (lower is better)
      cond do
        avg_sentence_length < 15 -> :excellent
        avg_sentence_length < 20 -> :good
        avg_sentence_length < 25 -> :moderate
        true -> :difficult
      end
    end

    defp calculate_quality_score(word_count, target, key_points, readability) do
      word_count_score = 1.0 - min(abs(word_count - target) / target, 1.0)

      coverage_score =
        Enum.count(key_points, fn {_, covered} -> covered end) / max(map_size(key_points), 1)

      readability_score =
        case readability do
          :excellent -> 1.0
          :good -> 0.8
          :moderate -> 0.6
          :difficult -> 0.4
        end

      # Weighted average
      (word_count_score * 0.3 + coverage_score * 0.5 + readability_score * 0.2)
      |> Float.round(2)
    end

    defp identify_issues(word_count, target, key_points) do
      issues = []

      issues =
        if word_count < target * 0.8 do
          ["Content is #{target - word_count} words short of target" | issues]
        else
          issues
        end

      issues =
        if word_count > target * 1.2 do
          ["Content exceeds target by #{word_count - target} words" | issues]
        else
          issues
        end

      uncovered =
        key_points |> Enum.filter(fn {_, covered} -> not covered end) |> Enum.map(&elem(&1, 0))

      if length(uncovered) > 0 do
        ["Missing coverage of: #{Enum.join(uncovered, ", ")}" | issues]
      else
        issues
      end
    end

    # Finalization
    defp finalize_content(%{draft: draft, quality_assessment: qa}) do
      {:ok,
       %{
         title: draft.title,
         body: draft.body,
         metadata: %{
           word_count: qa.word_count,
           quality_score: qa.quality_score,
           readability: qa.readability_score,
           generated_at: draft.generated_at,
           generator: draft.generator,
           issues: qa.issues
         }
       }}
    end
  end
end

# Run the example
Examples.ContentPipeline.run()

# Code Analysis Pipeline
# Demonstrates using flowstone_ai for AI-powered code analysis and documentation
#
# This pipeline:
# 1. Scans source code files
# 2. Uses FlowStone.AI.Resource for code analysis and documentation generation
# 3. Produces documentation and metrics reports
#
# Usage:
#   MIX_ENV=dev mix run examples/code_analysis_pipeline.exs
#
# Requirements:
#   - {:flowstone_ai, path: "../flowstone_ai"} in mix.exs
#   - {:altar_ai, path: "../altar_ai"} in mix.exs
#   - At least one AI SDK installed (gemini_ex, claude_agent_sdk, or codex_sdk)

defmodule Examples.CodeAnalysisPipeline do
  @moduledoc """
  AI-powered code analysis pipeline using FlowStone and flowstone_ai.

  Demonstrates:
  - Using FlowStone.AI.Resource for code understanding
  - Processing multiple files as partitions
  - Generating automated documentation
  - Combining AI analysis with structural parsing
  """

  def run do
    ensure_started(FlowStone.Registry, name: :analysis_registry)
    ensure_started(FlowStone.IO.Memory, name: :analysis_io)
    ensure_started(FlowStone.Lineage, name: :analysis_lineage)

    # Initialize AI resource
    {:ok, ai_resource} = FlowStone.AI.Resource.init()
    Process.put(:ai_resource, ai_resource)

    FlowStone.register(Pipeline, registry: :analysis_registry)

    IO.puts("Starting Code Analysis Pipeline...")
    IO.puts("AI capabilities: #{inspect(FlowStone.AI.Resource.capabilities(ai_resource))}")
    IO.puts("Analyzing module: sample_module\n")

    result =
      FlowStone.materialize_all(:analysis_report,
        partition: "sample_module",
        registry: :analysis_registry,
        io: [config: %{agent: :analysis_io}],
        lineage_server: :analysis_lineage,
        resource_server: nil
      )

    FlowStone.ObanHelpers.drain()

    case result do
      {:ok, _} ->
        report =
          FlowStone.IO.load(:analysis_report, "sample_module", config: %{agent: :analysis_io})

        IO.puts("\n=== Code Analysis Report ===")
        display_report(report)

      {:error, reason} ->
        IO.puts("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp display_report(%{
         module_name: name,
         summary: summary,
         functions: functions,
         metrics: metrics
       }) do
    IO.puts("\nModule: #{name}")
    IO.puts("\nSummary:")
    IO.puts(summary)
    IO.puts("\nMetrics:")
    IO.puts("  - Total functions: #{metrics.function_count}")
    IO.puts("  - Total lines: #{metrics.line_count}")
    IO.puts("  - Average complexity: #{metrics.avg_complexity}")
    IO.puts("\nFunction Documentation:")

    Enum.each(functions, fn func ->
      IO.puts("\n  #{func.name}/#{func.arity}")
      IO.puts("    #{func.description}")
    end)
  end

  defp display_report(report), do: IO.inspect(report, pretty: true)

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    @moduledoc """
    Asset definitions for the code analysis pipeline.
    Uses FlowStone.AI.Resource for AI operations.
    """
    use FlowStone.Pipeline

    # Sample code to analyze (in production, would read from filesystem)
    @sample_code """
    defmodule DataProcessor do
      @moduledoc "Processes and transforms data records."

      def process(records) when is_list(records) do
        records
        |> Enum.filter(&valid?/1)
        |> Enum.map(&transform/1)
        |> Enum.reduce(%{}, &aggregate/2)
      end

      def valid?(%{status: status}) when status in [:active, :pending], do: true
      def valid?(_), do: false

      defp transform(%{value: v} = record) do
        %{record | value: v * 1.1, processed_at: DateTime.utc_now()}
      end

      defp aggregate(record, acc) do
        key = record.category
        Map.update(acc, key, [record], &[record | &1])
      end

      def summarize(processed_data) do
        processed_data
        |> Enum.map(fn {category, records} ->
          {category, %{
            count: length(records),
            total_value: records |> Enum.map(& &1.value) |> Enum.sum()
          }}
        end)
        |> Map.new()
      end
    end
    """

    asset :source_code do
      description("Source code to analyze")

      execute(fn _context, _deps ->
        # In production, this would read from the filesystem
        {:ok,
         %{
           module_name: "DataProcessor",
           code: @sample_code,
           file_path: "lib/data_processor.ex"
         }}
      end)
    end

    asset :parsed_code do
      description("AST and structural analysis of source code")
      depends_on([:source_code])

      execute(fn _context, %{source_code: source} ->
        parse_code(source)
      end)
    end

    asset :ai_analysis do
      description("AI-powered code analysis")
      depends_on([:source_code, :parsed_code])

      execute(fn _context, %{source_code: source, parsed_code: parsed} ->
        ai = Process.get(:ai_resource)
        analyze_with_ai(ai, source, parsed)
      end)
    end

    asset :analysis_report do
      description("Final analysis report with documentation")
      depends_on([:parsed_code, :ai_analysis])

      execute(fn _context, %{parsed_code: parsed, ai_analysis: analysis} ->
        generate_report(parsed, analysis)
      end)
    end

    # Code parsing
    defp parse_code(%{code: code, module_name: name}) do
      case Code.string_to_quoted(code) do
        {:ok, ast} ->
          functions = extract_functions(ast)
          metrics = calculate_metrics(code, functions)

          {:ok,
           %{
             module_name: name,
             ast: ast,
             functions: functions,
             metrics: metrics
           }}

        {:error, reason} ->
          {:error, {:parse_error, reason}}
      end
    end

    defp extract_functions(ast) do
      {_, functions} =
        Macro.prewalk(ast, [], fn
          {:def, _meta, [{name, _, args} | _]} = node, acc when is_atom(name) ->
            arity = if is_list(args), do: length(args), else: 0
            {node, [{name, arity, :public} | acc]}

          {:defp, _meta, [{name, _, args} | _]} = node, acc when is_atom(name) ->
            arity = if is_list(args), do: length(args), else: 0
            {node, [{name, arity, :private} | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(functions)
    end

    defp calculate_metrics(code, functions) do
      lines = String.split(code, "\n")
      non_empty_lines = Enum.reject(lines, &(String.trim(&1) == ""))

      %{
        line_count: length(non_empty_lines),
        function_count: length(functions),
        public_functions: Enum.count(functions, fn {_, _, vis} -> vis == :public end),
        private_functions: Enum.count(functions, fn {_, _, vis} -> vis == :private end),
        avg_complexity: estimate_complexity(code)
      }
    end

    defp estimate_complexity(code) do
      # Simple cyclomatic complexity estimate based on branching keywords
      branches = ~w(if case cond with when)

      count =
        Enum.reduce(branches, 0, fn keyword, acc ->
          acc + (Regex.scan(~r/\b#{keyword}\b/, code) |> length())
        end)

      Float.round(count / 5.0 + 1.0, 1)
    end

    # AI-powered analysis using FlowStone.AI.Resource
    defp analyze_with_ai(ai, %{code: code, module_name: name}, parsed) do
      prompt = """
      Analyze this Elixir module and provide:
      1. A one-paragraph summary of what the module does
      2. For each public function, a one-line description of its purpose

      Module: #{name}

      ```elixir
      #{code}
      ```

      Format your response as JSON:
      {
        "summary": "...",
        "functions": [
          {"name": "function_name", "arity": 1, "description": "..."}
        ]
      }
      """

      case FlowStone.AI.Resource.generate(ai, prompt) do
        {:ok, response} ->
          case extract_json(response.content) do
            {:ok, analysis} ->
              {:ok,
               %{
                 summary: analysis["summary"] || "Module analysis completed.",
                 function_docs: analysis["functions"] || [],
                 generated_by: :flowstone_ai
               }}

            {:error, _} ->
              # Fallback to heuristic analysis
              {:ok,
               %{
                 summary: generate_fallback_summary(name, parsed),
                 function_docs: generate_fallback_docs(parsed.functions),
                 generated_by: :fallback
               }}
          end

        {:error, _reason} ->
          # Fallback to simple heuristic analysis
          {:ok,
           %{
             summary: generate_fallback_summary(name, parsed),
             function_docs: generate_fallback_docs(parsed.functions),
             generated_by: :fallback
           }}
      end
    end

    defp extract_json(text) do
      # Try to find JSON in the response
      case Regex.run(~r/\{[\s\S]*\}/m, text) do
        [json_str | _] ->
          Jason.decode(json_str)

        nil ->
          {:error, :no_json_found}
      end
    end

    defp generate_fallback_summary(name, parsed) do
      """
      #{name} is an Elixir module with #{parsed.metrics.function_count} functions \
      (#{parsed.metrics.public_functions} public, #{parsed.metrics.private_functions} private). \
      It appears to handle data processing operations based on the function names and structure.
      """
      |> String.trim()
    end

    defp generate_fallback_docs(functions) do
      Enum.map(functions, fn {name, arity, visibility} ->
        %{
          "name" => to_string(name),
          "arity" => arity,
          "description" => "#{visibility} function #{name}/#{arity}"
        }
      end)
    end

    # Report generation
    defp generate_report(parsed, analysis) do
      functions =
        Enum.map(parsed.functions, fn {name, arity, _visibility} ->
          doc = find_function_doc(analysis.function_docs, name, arity)

          %{
            name: name,
            arity: arity,
            description: doc || "No documentation available"
          }
        end)

      {:ok,
       %{
         module_name: parsed.module_name,
         summary: analysis.summary,
         functions: functions,
         metrics: parsed.metrics,
         generated_by: analysis.generated_by,
         generated_at: DateTime.utc_now()
       }}
    end

    defp find_function_doc(docs, name, arity) do
      name_str = to_string(name)

      Enum.find_value(docs, fn doc ->
        if doc["name"] == name_str and doc["arity"] == arity do
          doc["description"]
        end
      end)
    end
  end
end

# Run the example
Examples.CodeAnalysisPipeline.run()

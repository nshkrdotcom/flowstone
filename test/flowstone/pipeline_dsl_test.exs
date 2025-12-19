defmodule FlowStone.Pipeline.DSLTest do
  @moduledoc """
  Tests for v0.5.0 DSL improvements.
  """
  use FlowStone.TestCase, isolation: :full_isolation

  import ExUnit.CaptureLog

  alias FlowStone.API

  describe "short-form assets" do
    defmodule ShortFormPipeline do
      use FlowStone.Pipeline

      # Short form with direct value
      asset(:simple, do: {:ok, "hello"})

      # Short form with tuple
      asset(:with_tuple, do: {:ok, %{key: "value"}})
    end

    test "simple value works" do
      assert {:ok, "hello"} = API.run(ShortFormPipeline, :simple)
    end

    test "tuple value works" do
      assert {:ok, %{key: "value"}} = API.run(ShortFormPipeline, :with_tuple)
    end
  end

  describe "short-form with function" do
    defmodule ShortFormFnPipeline do
      use FlowStone.Pipeline

      # Short form with anonymous function
      asset(:with_fn, do: fn _, _ -> {:ok, "computed"} end)
    end

    test "function is executed" do
      assert {:ok, "computed"} = API.run(ShortFormFnPipeline, :with_fn)
    end
  end

  describe "implicit result wrapping" do
    defmodule ImplicitWrapPipeline do
      use FlowStone.Pipeline, wrap_results: true

      asset :unwrapped do
        execute fn _, _ -> "just a value" end
      end

      asset :explicit_ok do
        execute fn _, _ -> {:ok, "explicit"} end
      end

      asset :explicit_error do
        execute fn _, _ -> {:error, "failed"} end
      end

      asset :returns_map do
        execute fn _, _ -> %{status: "done"} end
      end

      asset :returns_list do
        execute fn _, _ -> [1, 2, 3] end
      end
    end

    test "wraps plain values in {:ok, _}" do
      assert {:ok, "just a value"} = API.run(ImplicitWrapPipeline, :unwrapped)
    end

    test "passes through {:ok, _}" do
      assert {:ok, "explicit"} = API.run(ImplicitWrapPipeline, :explicit_ok)
    end

    test "passes through {:error, _}" do
      log =
        capture_log(fn ->
          assert {:error, _} = API.run(ImplicitWrapPipeline, :explicit_error)
        end)

      assert log =~ "FlowStone error"
      assert log =~ "explicit_error"
    end

    test "wraps map results" do
      assert {:ok, %{status: "done"}} = API.run(ImplicitWrapPipeline, :returns_map)
    end

    test "wraps list results" do
      assert {:ok, [1, 2, 3]} = API.run(ImplicitWrapPipeline, :returns_list)
    end
  end

  describe "pipeline module injection" do
    defmodule InjectedPipeline do
      use FlowStone.Pipeline

      asset(:greeting, do: {:ok, "Hello"})

      asset :farewell do
        depends_on([:greeting])
        execute fn _, %{greeting: g} -> {:ok, "#{g} and Goodbye"} end
      end
    end

    test "run/1 is injected into pipeline module" do
      assert {:ok, "Hello"} = InjectedPipeline.run(:greeting)
    end

    test "run/2 with options is injected" do
      assert {:ok, "Hello"} = InjectedPipeline.run(:greeting, partition: :test_partition)
    end

    test "get/1 is injected" do
      {:ok, _} = InjectedPipeline.run(:greeting)
      assert {:ok, "Hello"} = InjectedPipeline.get(:greeting)
    end

    test "assets/0 is injected" do
      assets = InjectedPipeline.assets()
      assert :greeting in assets
      assert :farewell in assets
    end

    test "graph/0 is injected" do
      graph = InjectedPipeline.graph()
      assert is_binary(graph)
      assert graph =~ "greeting"
    end

    test "exists?/1 is injected" do
      refute InjectedPipeline.exists?(:greeting)
      {:ok, _} = InjectedPipeline.run(:greeting)
      assert InjectedPipeline.exists?(:greeting)
    end
  end

  describe "combined short-form with dependencies" do
    defmodule CombinedPipeline do
      use FlowStone.Pipeline

      asset(:base, do: {:ok, 10})

      asset :multiplied do
        depends_on([:base])
        execute fn _, %{base: n} -> {:ok, n * 2} end
      end
    end

    test "works with dependencies" do
      assert {:ok, 20} = API.run(CombinedPipeline, :multiplied)
    end
  end
end

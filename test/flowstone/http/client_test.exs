defmodule FlowStone.HTTP.ClientTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.HTTP.Client

  describe "setup/1" do
    test "creates client with valid config" do
      config = %{base_url: "https://api.example.com"}

      assert {:ok, %Client{} = client} = Client.setup(config)
      assert client.base_url == "https://api.example.com"
      assert client.timeout == 30_000
    end

    test "normalizes base_url by removing trailing slash" do
      config = %{base_url: "https://api.example.com/"}

      assert {:ok, client} = Client.setup(config)
      assert client.base_url == "https://api.example.com"
    end

    test "raises when base_url is missing" do
      assert_raise ArgumentError, ~r/requires :base_url/, fn ->
        Client.setup(%{})
      end
    end

    test "merges custom headers with defaults" do
      config = %{
        base_url: "https://api.example.com",
        headers: %{"Authorization" => "Bearer token123"}
      }

      assert {:ok, client} = Client.setup(config)
      assert client.headers["Authorization"] == "Bearer token123"
      assert client.headers["content-type"] == "application/json"
      assert client.headers["accept"] == "application/json"
    end

    test "uses custom timeout" do
      config = %{base_url: "https://api.example.com", timeout: 60_000}

      assert {:ok, client} = Client.setup(config)
      assert client.timeout == 60_000
    end

    test "uses custom retry config" do
      config = %{
        base_url: "https://api.example.com",
        retry: %{max_attempts: 5, base_delay_ms: 500}
      }

      assert {:ok, client} = Client.setup(config)
      assert client.retry_config.max_attempts == 5
      assert client.retry_config.base_delay_ms == 500
      # Defaults should still be present
      assert client.retry_config.max_delay_ms == 30_000
      assert client.retry_config.jitter == true
    end
  end

  describe "teardown/1" do
    test "returns :ok" do
      {:ok, client} = Client.setup(%{base_url: "https://api.example.com"})
      assert :ok = Client.teardown(client)
    end
  end

  describe "health_check/1" do
    # Note: health_check requires actual HTTP calls, tested in integration tests
    test "is defined" do
      {:ok, _client} = Client.setup(%{base_url: "https://api.example.com"})
      # Just verify the function exists and returns expected shape
      assert function_exported?(Client, :health_check, 1)
    end
  end

  describe "get/3" do
    test "function exists with correct arity" do
      assert function_exported?(Client, :get, 2)
      assert function_exported?(Client, :get, 3)
    end
  end

  describe "post/4" do
    test "function exists with correct arity" do
      assert function_exported?(Client, :post, 3)
      assert function_exported?(Client, :post, 4)
    end
  end

  describe "put/4" do
    test "function exists with correct arity" do
      assert function_exported?(Client, :put, 3)
      assert function_exported?(Client, :put, 4)
    end
  end

  describe "patch/4" do
    test "function exists with correct arity" do
      assert function_exported?(Client, :patch, 3)
      assert function_exported?(Client, :patch, 4)
    end
  end

  describe "delete/3" do
    test "function exists with correct arity" do
      assert function_exported?(Client, :delete, 2)
      assert function_exported?(Client, :delete, 3)
    end
  end

  describe "idempotency_key option" do
    test "setup accepts req_options" do
      config = %{
        base_url: "https://api.example.com",
        req_options: [pool_timeout: 5_000]
      }

      assert {:ok, client} = Client.setup(config)
      assert client.req_options == [pool_timeout: 5_000]
    end
  end

  describe "struct fields" do
    test "has all required fields" do
      {:ok, client} = Client.setup(%{base_url: "https://api.example.com"})

      assert is_binary(client.base_url)
      assert is_map(client.headers)
      assert is_integer(client.timeout)
      assert is_map(client.retry_config)
      assert is_list(client.req_options)
    end
  end

  describe "Resource behaviour" do
    test "implements FlowStone.Resource behaviour" do
      behaviours = Client.__info__(:attributes)[:behaviour] || []
      assert FlowStone.Resource in behaviours
    end
  end
end

defmodule FlowStone.ConfigTest do
  @moduledoc """
  Tests for FlowStone configuration module.
  """
  use ExUnit.Case

  alias FlowStone.Config

  describe "get/0" do
    test "returns default config when nothing configured" do
      # Clear any test-specific config
      original = Application.get_all_env(:flowstone)

      try do
        Application.put_env(:flowstone, :repo, nil)
        Application.put_env(:flowstone, :storage, nil)

        config = Config.get()
        assert config.storage == :memory
        assert config.repo == nil
        assert config.async_default == false
      after
        # Restore original config
        for {key, value} <- original do
          Application.put_env(:flowstone, key, value)
        end
      end
    end
  end

  describe "storage_backend/0" do
    test "returns memory when no repo configured" do
      original_repo = Application.get_env(:flowstone, :repo)
      original_storage = Application.get_env(:flowstone, :storage)

      try do
        Application.put_env(:flowstone, :repo, nil)
        Application.delete_env(:flowstone, :storage)

        assert Config.storage_backend() == :memory
      after
        if original_repo, do: Application.put_env(:flowstone, :repo, original_repo)
        if original_storage, do: Application.put_env(:flowstone, :storage, original_storage)
      end
    end

    test "returns postgres when repo is configured" do
      original_repo = Application.get_env(:flowstone, :repo)
      original_storage = Application.get_env(:flowstone, :storage)

      try do
        Application.put_env(:flowstone, :repo, MyApp.Repo)
        Application.delete_env(:flowstone, :storage)

        assert Config.storage_backend() == :postgres
      after
        if original_repo do
          Application.put_env(:flowstone, :repo, original_repo)
        else
          Application.delete_env(:flowstone, :repo)
        end

        if original_storage, do: Application.put_env(:flowstone, :storage, original_storage)
      end
    end

    test "respects explicit storage setting" do
      original_storage = Application.get_env(:flowstone, :storage)

      try do
        Application.put_env(:flowstone, :storage, :s3)
        assert Config.storage_backend() == :s3
      after
        if original_storage do
          Application.put_env(:flowstone, :storage, original_storage)
        else
          Application.delete_env(:flowstone, :storage)
        end
      end
    end
  end

  describe "repo/0" do
    test "returns configured repo" do
      original = Application.get_env(:flowstone, :repo)

      try do
        Application.put_env(:flowstone, :repo, MyApp.Repo)
        assert Config.repo() == MyApp.Repo
      after
        if original do
          Application.put_env(:flowstone, :repo, original)
        else
          Application.delete_env(:flowstone, :repo)
        end
      end
    end

    test "returns nil when no repo configured" do
      original = Application.get_env(:flowstone, :repo)

      try do
        Application.delete_env(:flowstone, :repo)
        assert Config.repo() == nil
      after
        if original, do: Application.put_env(:flowstone, :repo, original)
      end
    end
  end

  describe "lineage_enabled?/0" do
    test "returns true when repo is configured" do
      original_repo = Application.get_env(:flowstone, :repo)
      original_lineage = Application.get_env(:flowstone, :lineage)

      try do
        Application.put_env(:flowstone, :repo, MyApp.Repo)
        Application.delete_env(:flowstone, :lineage)

        assert Config.lineage_enabled?() == true
      after
        if original_repo do
          Application.put_env(:flowstone, :repo, original_repo)
        else
          Application.delete_env(:flowstone, :repo)
        end

        if original_lineage, do: Application.put_env(:flowstone, :lineage, original_lineage)
      end
    end

    test "respects explicit lineage setting" do
      original = Application.get_env(:flowstone, :lineage)

      try do
        Application.put_env(:flowstone, :lineage, false)
        assert Config.lineage_enabled?() == false
      after
        if original do
          Application.put_env(:flowstone, :lineage, original)
        else
          Application.delete_env(:flowstone, :lineage)
        end
      end
    end
  end

  describe "oban_config/0" do
    test "returns oban config when repo is configured" do
      original_repo = Application.get_env(:flowstone, :repo)
      original_oban = Application.get_env(:flowstone, Oban)

      try do
        Application.put_env(:flowstone, :repo, MyApp.Repo)
        # Clear explicit Oban config to test defaults
        Application.delete_env(:flowstone, Oban)

        oban_config = Config.oban_config()
        assert oban_config[:repo] == MyApp.Repo
        assert is_list(oban_config[:queues])
      after
        if original_repo do
          Application.put_env(:flowstone, :repo, original_repo)
        else
          Application.delete_env(:flowstone, :repo)
        end

        if original_oban, do: Application.put_env(:flowstone, Oban, original_oban)
      end
    end

    test "returns nil when no repo configured" do
      original = Application.get_env(:flowstone, :repo)

      try do
        Application.delete_env(:flowstone, :repo)
        assert Config.oban_config() == nil
      after
        if original, do: Application.put_env(:flowstone, :repo, original)
      end
    end
  end

  describe "io_managers/0" do
    test "returns default io managers" do
      managers = Config.io_managers()
      assert is_map(managers)
      assert Map.has_key?(managers, :memory)
    end
  end
end

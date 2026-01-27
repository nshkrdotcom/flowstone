defmodule FlowStone.Policy do
  @moduledoc """
  Policy metadata helpers used for approval decisions.
  """

  @spec normalize(map() | nil) :: map()
  def normalize(nil), do: %{}

  def normalize(%{} = policy) do
    case command_policy_module() do
      {:ok, module} ->
        module.normalize(policy)

      :error ->
        policy
        |> Enum.reduce(%{}, fn {key, value}, acc ->
          Map.put(acc, to_string(key), normalize_value(value))
        end)
        |> Map.update("approval_class", nil, &normalize_approval_class/1)
        |> Map.update("side_effects", [], &normalize_list/1)
        |> Map.update("capabilities", [], &normalize_list/1)
    end
  end

  @spec approval_required?(map() | nil) :: boolean()
  def approval_required?(policy) do
    case command_policy_module() do
      {:ok, module} ->
        module.approval_required?(policy)

      :error ->
        case approval_class(policy) do
          nil -> false
          "none" -> false
          _ -> true
        end
    end
  end

  @spec approval_class(map() | nil) :: String.t() | nil
  def approval_class(policy) do
    policy
    |> normalize()
    |> Map.get("approval_class")
  end

  @spec from_action(module()) :: map()
  def from_action(action) when is_atom(action) do
    policy =
      cond do
        function_exported?(action, :policy, 0) ->
          action.policy()

        function_exported?(action, :policy_metadata, 0) ->
          action.policy_metadata()

        function_exported?(action, :__action_metadata__, 0) ->
          extract_policy(action.__action_metadata__())

        function_exported?(action, :approval_class, 0) ->
          %{approval_class: action.approval_class()}

        true ->
          %{}
      end

    if function_exported?(action, :approval_class, 0) and
         not Map.has_key?(policy, :approval_class) and
         not Map.has_key?(policy, "approval_class") do
      Map.put(policy, :approval_class, action.approval_class())
    else
      policy
    end
  end

  defp extract_policy(%{} = metadata) do
    cond do
      Map.has_key?(metadata, :policy) -> metadata.policy
      Map.has_key?(metadata, "policy") -> metadata["policy"]
      Map.has_key?(metadata, :policy_metadata) -> metadata.policy_metadata
      Map.has_key?(metadata, "policy_metadata") -> metadata["policy_metadata"]
      Map.has_key?(metadata, :approval_class) -> %{approval_class: metadata.approval_class}
      Map.has_key?(metadata, "approval_class") -> %{approval_class: metadata["approval_class"]}
      true -> %{}
    end
  end

  defp command_policy_module do
    module = Module.concat(["Command", "Policy"])

    if Code.ensure_loaded?(module) and function_exported?(module, :normalize, 1) and
         function_exported?(module, :approval_required?, 1) do
      {:ok, module}
    else
      :error
    end
  end

  defp normalize_approval_class(nil), do: nil
  defp normalize_approval_class(class) when is_atom(class), do: Atom.to_string(class)
  defp normalize_approval_class(class) when is_binary(class), do: String.downcase(class)
  defp normalize_approval_class(class), do: to_string(class)

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(value), do: [to_string(value)]

  defp normalize_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, inner}, acc ->
      Map.put(acc, to_string(key), normalize_value(inner))
    end)
  end

  defp normalize_value(value), do: value
end

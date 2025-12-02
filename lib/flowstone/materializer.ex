defmodule FlowStone.Materializer do
  @moduledoc """
  Executes asset functions with structured error handling.
  """

  alias FlowStone.Error

  @spec execute(struct(), map(), map()) :: {:ok, term()} | {:error, Error.t()}
  def execute(asset, context, deps) do
    execute_fn = Map.fetch!(asset, :execute_fn)

    try do
      case execute_fn.(context, deps) do
        {:ok, value} ->
          {:ok, value}

        {:error, %Error{} = err} ->
          {:error, err}

        {:error, reason} ->
          {:error, Error.execution_error(asset.name, context.partition, wrap(reason), [])}

        other ->
          {:error, Error.unexpected_return(asset.name, context.partition, other)}
      end
    rescue
      exception ->
        {:error, Error.execution_error(asset.name, context.partition, exception, __STACKTRACE__)}
    catch
      :exit, reason ->
        {:error,
         Error.execution_error(
           asset.name,
           context.partition,
           %RuntimeError{message: inspect(reason)},
           []
         )}
    end
  end

  defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
  defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
  defp wrap(reason), do: %RuntimeError{message: inspect(reason)}
end

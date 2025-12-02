defmodule FlowStone.Materializer do
  @moduledoc """
  Executes asset functions with structured error handling.
  """

  alias FlowStone.Error
  alias FlowStone.ErrorRecorder

  @spec execute(struct(), map(), map()) :: {:ok, term()} | {:error, Error.t()}
  def execute(asset, context, deps) do
    execute_fn = Map.fetch!(asset, :execute_fn)

    try do
      case execute_fn.(context, deps) do
        {:ok, value} ->
          {:ok, value}

        {:error, %Error{} = err} ->
          ErrorRecorder.record(err, %{
            asset: asset.name,
            partition: context.partition,
            run_id: context.run_id
          })

          {:error, err}

        {:error, reason} ->
          err = Error.execution_error(asset.name, context.partition, wrap(reason), [])

          ErrorRecorder.record(err, %{
            asset: asset.name,
            partition: context.partition,
            run_id: context.run_id
          })

          {:error, err}

        other ->
          err = Error.unexpected_return(asset.name, context.partition, other)

          ErrorRecorder.record(err, %{
            asset: asset.name,
            partition: context.partition,
            run_id: context.run_id
          })

          {:error, err}
      end
    rescue
      exception ->
        err = Error.execution_error(asset.name, context.partition, exception, __STACKTRACE__)

        ErrorRecorder.record(err, %{
          asset: asset.name,
          partition: context.partition,
          run_id: context.run_id
        })

        {:error, err}
    catch
      :exit, reason ->
        err =
          Error.execution_error(
            asset.name,
            context.partition,
            %RuntimeError{message: inspect(reason)},
            []
          )

        ErrorRecorder.record(err, %{
          asset: asset.name,
          partition: context.partition,
          run_id: context.run_id
        })

        {:error, err}
    end
  end

  defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
  defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
  defp wrap(reason), do: %RuntimeError{message: inspect(reason)}
end

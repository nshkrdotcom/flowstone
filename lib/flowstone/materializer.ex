defmodule FlowStone.Materializer do
  @moduledoc """
  Executes asset functions with structured error handling.
  """

  alias FlowStone.{Error, ErrorRecorder, RouteDecisions}

  @spec execute(struct(), map(), map()) ::
          {:ok, term()} | {:error, Error.t()} | {:skipped, term()}
  def execute(asset, context, deps) do
    cond do
      router_asset?(asset) ->
        execute_router(asset, context, deps)

      routed_asset?(asset) ->
        execute_routed(asset, context, deps)

      true ->
        execute_normal(asset, context, deps)
    end
  end

  defp execute_routed(asset, context, deps) do
    case RouteDecisions.get(context.run_id, asset.routed_from, context.partition) do
      {:ok, decision} ->
        selected_branch = Map.get(decision, :selected_branch)

        if selected_branch == Atom.to_string(asset.name) do
          execute_normal(asset, context, deps)
        else
          {:skipped, :not_selected}
        end

      {:error, :not_found} ->
        {:error, Error.dependency_not_ready(asset.name, [asset.routed_from])}
    end
  end

  defp execute_router(asset, context, deps) do
    emit_route_start(asset, context)

    case RouteDecisions.get(context.run_id, asset.name, context.partition) do
      {:ok, decision} ->
        return_cached_decision(asset, context, decision)

      {:error, :not_found} ->
        compute_new_route(asset, context, deps)
    end
  end

  defp return_cached_decision(asset, context, decision) do
    output = RouteDecisions.to_output(decision)
    emit_route_stop(asset, context, output.selected_branch, decision.id)
    {:ok, output}
  end

  defp compute_new_route(asset, context, deps) do
    available_branches = available_branches(asset, context)

    case evaluate_route(asset, deps) do
      {:ok, selection} ->
        handle_route_selection(asset, context, selection, available_branches)

      {:error, reason} ->
        handle_route_evaluation_error(asset, context, reason, available_branches)
    end
  end

  defp handle_route_selection(asset, context, selection, available_branches) do
    case normalize_selection(selection, available_branches) do
      {:ok, selection} ->
        persist_route_decision(asset, context, selection, available_branches, %{})

      {:error, reason} ->
        handle_route_error(asset, context, reason)
    end
  end

  defp handle_route_evaluation_error(asset, context, reason, available_branches) do
    case Map.get(asset, :route_error_policy, :fail) do
      :fail ->
        handle_route_error(asset, context, reason)

      {:fallback, fallback} ->
        apply_fallback(asset, context, fallback, available_branches, reason)

      other ->
        handle_route_error(asset, context, {:invalid_on_error, other})
    end
  end

  defp apply_fallback(asset, context, fallback, available_branches, original_reason) do
    case normalize_selection(fallback, available_branches) do
      {:ok, selection} ->
        metadata = %{fallback: true, error: inspect(original_reason)}
        persist_route_decision(asset, context, selection, available_branches, metadata)

      {:error, fallback_error} ->
        handle_route_error(asset, context, fallback_error)
    end
  end

  defp execute_normal(asset, context, deps) do
    execute_fn = Map.fetch!(asset, :execute_fn)

    try do
      case execute_fn.(context, deps) do
        {:ok, value} ->
          {:ok, value}

        {:wait_for_approval, approval_attrs} ->
          FlowStone.Approvals.request(asset.name, approval_attrs, use_repo: true)

          FlowStone.Materializations.record_waiting_approval(
            asset.name,
            context.partition,
            context.run_id
          )

          {:error,
           FlowStone.Error.execution_error(
             asset.name,
             context.partition,
             wrap(:waiting_approval),
             []
           )}

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

  defp persist_route_decision(asset, context, selection, available_branches, metadata) do
    case RouteDecisions.record(
           context.run_id,
           asset.name,
           context.partition,
           selection,
           available_branches,
           metadata: metadata
         ) do
      {:ok, decision} ->
        output = RouteDecisions.to_output(decision)
        emit_route_stop(asset, context, output.selected_branch, decision.id)
        {:ok, output}

      {:error, reason} ->
        handle_route_error(asset, context, reason)
    end
  end

  defp evaluate_route(asset, deps) do
    cond do
      Map.get(asset, :route_rules) ->
        evaluate_route_rules(asset.route_rules, deps)

      is_function(Map.get(asset, :route_fn), 1) ->
        evaluate_route_fn(asset.route_fn, deps)

      true ->
        {:error, {:invalid_route, :missing}}
    end
  end

  defp evaluate_route_rules(%{choices: choices, default: default}, deps) do
    result =
      Enum.reduce_while(choices, :no_match, fn {branch, when_fn}, _acc ->
        case safe_eval_condition(when_fn, deps) do
          {:ok, true} ->
            {:halt, {:selected, branch}}

          {:ok, false} ->
            {:cont, :no_match}

          {:error, {:exception, _exception, _stacktrace} = reason} ->
            {:halt, {:error, reason}}

          {:error, {:exit, _reason} = reason} ->
            {:halt, {:error, reason}}

          {:error, reason} ->
            {:halt, {:error, {:choice_error, branch, reason}}}
        end
      end)

    case result do
      {:selected, branch} -> {:ok, branch}
      :no_match -> {:ok, default}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate_route_fn(route_fn, deps) do
    case route_fn.(deps) do
      branch when is_atom(branch) -> {:ok, branch}
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_route_return, other}}
    end
  rescue
    exception ->
      {:error, {:exception, exception, __STACKTRACE__}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  defp safe_eval_condition(fun, deps) do
    result = fun.(deps)

    if is_boolean(result) do
      {:ok, result}
    else
      {:error, {:invalid_choice_return, result}}
    end
  rescue
    exception ->
      {:error, {:exception, exception, __STACKTRACE__}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  defp normalize_selection(selection, available_branches) do
    cond do
      is_nil(selection) ->
        {:ok, nil}

      is_atom(selection) ->
        if available_branches == [] or selection in available_branches do
          {:ok, selection}
        else
          {:error, {:invalid_branch, selection}}
        end

      true ->
        {:error, {:invalid_route_return, selection}}
    end
  end

  defp available_branches(%{route_rules: %{choices: choices, default: default}}, _context) do
    branches = Enum.map(choices, &elem(&1, 0))

    branches =
      if is_nil(default) do
        branches
      else
        branches ++ [default]
      end

    Enum.uniq(branches)
  end

  defp available_branches(_asset, context) do
    case Map.get(context, :metadata) do
      %{route_branches: branches} when is_list(branches) -> branches
      _ -> []
    end
  end

  defp handle_route_error(asset, context, reason) do
    err = build_route_error(asset, context, reason)

    ErrorRecorder.record(err, %{
      asset: asset.name,
      partition: context.partition,
      run_id: context.run_id
    })

    emit_route_error(asset, context, err)
    {:error, err}
  end

  defp build_route_error(asset, context, {:exception, exception, stacktrace}) do
    Error.execution_error(asset.name, context.partition, exception, stacktrace)
  end

  defp build_route_error(asset, context, {:exit, reason}) do
    Error.execution_error(
      asset.name,
      context.partition,
      %RuntimeError{message: inspect(reason)},
      []
    )
  end

  defp build_route_error(asset, context, reason) do
    Error.execution_error(asset.name, context.partition, wrap(reason), [])
  end

  defp router_asset?(asset) do
    not is_nil(Map.get(asset, :route_fn)) or not is_nil(Map.get(asset, :route_rules))
  end

  defp routed_asset?(asset) do
    not is_nil(Map.get(asset, :routed_from))
  end

  defp emit_route_start(asset, context) do
    :telemetry.execute([:flowstone, :route, :start], %{}, %{
      router_asset: asset.name,
      run_id: context.run_id,
      partition: context.partition,
      selected_branch: nil,
      decision_id: nil
    })
  end

  defp emit_route_stop(asset, context, selected_branch, decision_id) do
    :telemetry.execute([:flowstone, :route, :stop], %{}, %{
      router_asset: asset.name,
      run_id: context.run_id,
      partition: context.partition,
      selected_branch: selected_branch,
      decision_id: decision_id
    })
  end

  defp emit_route_error(asset, context, error) do
    :telemetry.execute([:flowstone, :route, :error], %{}, %{
      router_asset: asset.name,
      run_id: context.run_id,
      partition: context.partition,
      selected_branch: nil,
      decision_id: nil,
      error: error
    })
  end

  defp wrap(reason) when is_binary(reason), do: %RuntimeError{message: reason}
  defp wrap(reason) when is_atom(reason), do: %RuntimeError{message: Atom.to_string(reason)}
  defp wrap(reason), do: %RuntimeError{message: inspect(reason)}
end

defmodule PaperTiger.ContractDrift do
  @moduledoc """
  Side-by-side contract drift harness for PaperTiger and Stripe test mode.

  Existing contract tests can run against either backend. This helper runs a
  single scenario against both backends in one ExUnit test, normalizes volatile
  Stripe fields, and reports the first normalized mismatch.
  """

  alias PaperTiger.TestClient

  @timestamp_keys MapSet.new(~w(
    available_on
    canceled_at
    created
    current_period_end
    current_period_start
    due_date
    ended_at
    next_payment_attempt
    period_end
    period_start
    trial_end
    trial_start
  ))

  @default_drop_keys MapSet.new(~w(
    last_response
    request_id
  ))

  @stripe_id_regex Regex.compile!(
                     "\\b(?:acct|apca|ba|btok|card|ch|cs|cus|du|evt|fee|file|fr|ii|in|link|pi|pm|po|price|prod|py|re|seti|si|src|sub|tax|txn|tok|topup|we)_[A-Za-z0-9_]+\\b"
                   )

  defmodule Scenario do
    @moduledoc """
    A scenario that can be executed against both contract backends.

    `run` receives `:paper_tiger` or `:real_stripe` and should return the shape
    to compare. The scenario can return either the value directly or
    `{:ok, value}` / `{:error, reason}`.
    """

    defstruct [:name, :run, normalize_opts: []]
  end

  @doc """
  Runs a scenario against PaperTiger and Stripe test mode, then compares them.
  """
  def run(%Scenario{name: name, normalize_opts: normalize_opts, run: run}, opts \\ [])
      when is_binary(name) and is_function(run, 1) do
    opts = Keyword.merge(normalize_opts, opts)

    with {:ok, paper_tiger} <- run_backend(name, :paper_tiger, run),
         {:ok, stripe} <- run_backend(name, :real_stripe, run) do
      compare(name, paper_tiger, stripe, opts)
    end
  end

  @doc """
  Runs a scenario and raises an ExUnit assertion with a drift report on failure.
  """
  def assert_scenario!(%Scenario{} = scenario, opts \\ []) do
    case run(scenario, opts) do
      :ok -> :ok
      {:error, drift} -> raise ExUnit.AssertionError, message: format_drift(drift)
    end
  end

  @doc """
  Compares already-collected PaperTiger and Stripe scenario results.
  """
  def compare(name, paper_tiger, stripe, opts \\ []) when is_binary(name) do
    normalized_paper_tiger = normalize(paper_tiger, opts)
    normalized_stripe = normalize(stripe, opts)

    case first_diff(normalized_paper_tiger, normalized_stripe) do
      nil ->
        :ok

      diff ->
        {:error,
         %{
           diff: diff,
           name: name,
           paper_tiger: normalized_paper_tiger,
           stripe: normalized_stripe,
           type: :mismatch
         }}
    end
  end

  @doc """
  Normalizes volatile Stripe/PaperTiger values while preserving response shape.
  """
  def normalize(value, opts \\ []) do
    drop_keys =
      opts
      |> Keyword.get(:drop_keys, [])
      |> MapSet.new(&to_string/1)
      |> MapSet.union(@default_drop_keys)

    {normalized, _state} =
      normalize_value(value, %{id_counts: %{}, ids: %{}}, %{drop_keys: drop_keys, parent_key: nil})

    normalized
  end

  @doc """
  Formats a drift result for an assertion failure or CI log.
  """
  def format_drift(%{backend: backend, name: name, reason: reason, type: :backend_error}) do
    """
    Contract drift scenario failed before comparison: #{name}

    Backend: #{backend}
    Error:
    #{format_value(reason)}
    """
  end

  def format_drift(%{diff: diff, name: name, paper_tiger: paper_tiger, stripe: stripe, type: :mismatch}) do
    """
    Contract drift: #{name}

    First mismatch: #{format_path(diff.path)}
    Reason: #{diff.reason}

    Stripe expected:
    #{format_value(diff.stripe)}

    PaperTiger actual:
    #{format_value(diff.paper_tiger)}

    Normalized Stripe result:
    #{format_value(stripe)}

    Normalized PaperTiger result:
    #{format_value(paper_tiger)}
    """
  end

  defp run_backend(name, backend, run) do
    TestClient.with_mode(backend, fn ->
      if backend == :paper_tiger do
        PaperTiger.flush()
      end

      backend
      |> run.()
      |> unwrap_scenario_result(name, backend)
    end)
  rescue
    exception ->
      {:error,
       %{
         backend: backend,
         name: name,
         reason: Exception.format(:error, exception, __STACKTRACE__),
         type: :backend_error
       }}
  catch
    kind, reason ->
      {:error,
       %{
         backend: backend,
         name: name,
         reason: Exception.format(kind, reason, __STACKTRACE__),
         type: :backend_error
       }}
  end

  defp unwrap_scenario_result({:ok, value}, _name, _backend), do: {:ok, value}

  defp unwrap_scenario_result({:error, reason}, name, backend) do
    {:error, %{backend: backend, name: name, reason: reason, type: :backend_error}}
  end

  defp unwrap_scenario_result(value, _name, _backend), do: {:ok, value}

  defp normalize_value(%_{} = struct, state, opts) do
    struct
    |> Map.from_struct()
    |> normalize_value(state, opts)
  end

  defp normalize_value(map, state, opts) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce({%{}, state}, fn {raw_key, raw_value}, {acc, current_state} ->
      key = to_string(raw_key)

      if MapSet.member?(opts.drop_keys, key) do
        {acc, current_state}
      else
        child_opts = %{opts | parent_key: key}
        {value, next_state} = normalize_value(raw_value, current_state, child_opts)
        {Map.put(acc, key, maybe_normalize_timestamp(key, value)), next_state}
      end
    end)
  end

  defp normalize_value(list, state, opts) when is_list(list) do
    Enum.map_reduce(list, state, &normalize_value(&1, &2, opts))
  end

  defp normalize_value(value, state, %{parent_key: parent_key}) when is_integer(value) do
    if MapSet.member?(@timestamp_keys, to_string(parent_key)) do
      {"<timestamp>", state}
    else
      {value, state}
    end
  end

  defp normalize_value(value, state, _opts) when is_binary(value) do
    @stripe_id_regex
    |> Regex.scan(value)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reduce({value, state}, fn id, {normalized, current_state} ->
      {replacement, next_state} = normalize_id(id, current_state)
      {String.replace(normalized, id, replacement), next_state}
    end)
  end

  defp normalize_value(value, state, _opts), do: {value, state}

  defp maybe_normalize_timestamp(key, value) when is_integer(value) do
    if MapSet.member?(@timestamp_keys, key), do: "<timestamp>", else: value
  end

  defp maybe_normalize_timestamp(_key, value), do: value

  defp normalize_id(id, %{ids: ids} = state) do
    case Map.fetch(ids, id) do
      {:ok, replacement} ->
        {replacement, state}

      :error ->
        prefix = id |> String.split("_", parts: 2) |> hd()
        next_count = Map.get(state.id_counts, prefix, 0) + 1
        replacement = "<id:#{prefix}_#{next_count}>"

        {replacement,
         %{
           state
           | id_counts: Map.put(state.id_counts, prefix, next_count),
             ids: Map.put(ids, id, replacement)
         }}
    end
  end

  defp first_diff(paper_tiger, stripe, path \\ [])

  defp first_diff(paper_tiger, stripe, _path) when paper_tiger == stripe, do: nil

  defp first_diff(paper_tiger, stripe, path) when is_map(paper_tiger) and is_map(stripe) do
    paper_keys = Map.keys(paper_tiger)
    stripe_keys = Map.keys(stripe)

    (paper_keys ++ stripe_keys)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find_value(fn key ->
      cond do
        not Map.has_key?(stripe, key) ->
          diff(path ++ [key], :extra_paper_tiger_key, Map.get(paper_tiger, key), nil)

        not Map.has_key?(paper_tiger, key) ->
          diff(path ++ [key], :missing_paper_tiger_key, nil, Map.get(stripe, key))

        true ->
          first_diff(Map.get(paper_tiger, key), Map.get(stripe, key), path ++ [key])
      end
    end)
  end

  defp first_diff(paper_tiger, stripe, path) when is_list(paper_tiger) and is_list(stripe) do
    if length(paper_tiger) == length(stripe) do
      paper_tiger
      |> Enum.zip(stripe)
      |> Enum.with_index()
      |> Enum.find_value(fn {{paper_item, stripe_item}, index} ->
        first_diff(paper_item, stripe_item, path ++ [index])
      end)
    else
      diff(path, :list_length, length(paper_tiger), length(stripe))
    end
  end

  defp first_diff(paper_tiger, stripe, path), do: diff(path, :value, paper_tiger, stripe)

  defp diff(path, reason, paper_tiger, stripe) do
    %{paper_tiger: paper_tiger, path: path, reason: reason, stripe: stripe}
  end

  defp format_path([]), do: "$"

  defp format_path(path) do
    Enum.reduce(path, "$", fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, acc -> "#{acc}.#{key}"
    end)
  end

  defp format_value(value), do: inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)
end

defmodule PaperTiger.ListFilters do
  @moduledoc """
  Shared helpers for Stripe-style list endpoint filtering.

  Resource modules still declare their own supported filters. This module only
  provides typed matching, created-range filtering, and list-item expansion so
  filtering happens before cursor pagination consistently across resources.
  """

  alias PaperTiger.Error

  @type filter ::
          {:boolean, atom()}
          | {:boolean, atom(), atom()}
          | {:string, atom()}
          | {:string, atom(), atom()}
          | {:enum, atom(), [String.t()]}
          | {:enum, atom(), atom(), [String.t()]}
          | {:string_in, atom(), atom(), keyword()}
          | {:nested_enum, [atom()], [String.t()]}
          | {:nested_string, [atom()]}
          | {:created, atom()}

  @range_operators [:gt, :gte, :lt, :lte]

  @doc """
  Applies a resource's declared list filters to `items`.
  """
  @spec apply([map()], map(), [filter()]) :: {:ok, [map()]} | {:error, Error.t()}
  def apply(items, params, filters) when is_list(items) and is_map(params) do
    Enum.reduce_while(filters, {:ok, items}, fn filter, {:ok, acc} ->
      case apply_filter(acc, params, filter) do
        {:ok, filtered} -> {:cont, {:ok, filtered}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Rejects unsupported parameter combinations before filtering.
  """
  @spec reject_combination(map(), atom(), [atom()]) :: :ok | {:error, Error.t()}
  def reject_combination(params, primary, forbidden) do
    if present?(params, primary) do
      case Enum.find(forbidden, &present?(params, &1)) do
        nil ->
          :ok

        param ->
          {:error,
           Error.invalid_request(
             "Cannot specify #{format_param(primary)} with #{format_param(param)}",
             format_param(param)
           )}
      end
    else
      :ok
    end
  end

  @doc """
  Expands objects inside a list response.

  Stripe list expansion paths are usually prefixed with `data.`, for example
  `expand[]=data.product`. Single-object paths are accepted too because tests
  and clients sometimes reuse retrieve-style params with list endpoints.
  """
  @spec expand_page(PaperTiger.List.t(), map()) :: PaperTiger.List.t()
  def expand_page(%PaperTiger.List{} = page, params) do
    expand_params =
      params
      |> PaperTiger.Resource.parse_expand_params()
      |> Enum.map(&strip_data_prefix/1)

    %{page | data: Enum.map(page.data, &PaperTiger.Hydrator.hydrate(&1, expand_params))}
  end

  defp apply_filter(items, params, {:boolean, param}) do
    apply_filter(items, params, {:boolean, param, param})
  end

  defp apply_filter(items, params, {:boolean, param, field}) do
    case fetch_param(params, param) do
      :missing ->
        {:ok, items}

      value ->
        with {:ok, expected} <- parse_boolean(value, param) do
          {:ok, Enum.filter(items, &boolean_match?(value_at(&1, field), expected))}
        end
    end
  end

  defp apply_filter(items, params, {:string, param}) do
    apply_filter(items, params, {:string, param, param})
  end

  defp apply_filter(items, params, {:string, param, field}) do
    case fetch_param(params, param) do
      :missing -> {:ok, items}
      value -> {:ok, Enum.filter(items, &(to_string_or_nil(value_at(&1, field)) == to_string(value)))}
    end
  end

  defp apply_filter(items, params, {:enum, param, values}) do
    apply_filter(items, params, {:enum, param, param, values})
  end

  defp apply_filter(items, params, {:enum, param, field, values}) do
    case fetch_param(params, param) do
      :missing ->
        {:ok, items}

      value ->
        value = to_string(value)

        if value in values do
          {:ok, Enum.filter(items, &(to_string_or_nil(value_at(&1, field)) == value))}
        else
          invalid("Invalid enum value", param)
        end
    end
  end

  defp apply_filter(items, params, {:string_in, param, field, opts}) do
    case fetch_param(params, param) do
      :missing ->
        {:ok, items}

      value ->
        with {:ok, values} <- normalize_string_list(value, param),
             :ok <- validate_max_count(values, Keyword.get(opts, :max), param) do
          {:ok, Enum.filter(items, &(to_string_or_nil(value_at(&1, field)) in values))}
        end
    end
  end

  defp apply_filter(items, params, {:nested_enum, path, values}) do
    case fetch_param(params, path) do
      :missing ->
        {:ok, items}

      value ->
        value = to_string(value)

        if value in values do
          {:ok, Enum.filter(items, &(to_string_or_nil(value_at(&1, path)) == value))}
        else
          invalid("Invalid enum value", path)
        end
    end
  end

  defp apply_filter(items, params, {:nested_string, path}) do
    case fetch_param(params, path) do
      :missing -> {:ok, items}
      value -> {:ok, Enum.filter(items, &(to_string_or_nil(value_at(&1, path)) == to_string(value)))}
    end
  end

  defp apply_filter(items, params, {:created, field}) do
    case fetch_param(params, :created) do
      :missing -> {:ok, items}
      value -> filter_created(items, value, field)
    end
  end

  defp filter_created(items, value, field) when is_map(value) do
    Enum.reduce_while(value, {:ok, items}, fn {operator, raw_value}, {:ok, acc} ->
      operator = normalize_operator(operator)

      with :ok <- validate_operator(operator),
           {:ok, timestamp} <- parse_integer(raw_value, [:created, operator]) do
        {:cont, {:ok, Enum.filter(acc, &created_match?(value_at(&1, field), operator, timestamp))}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp filter_created(items, value, field) do
    with {:ok, timestamp} <- parse_integer(value, :created) do
      {:ok, Enum.filter(items, &(value_at(&1, field) == timestamp))}
    end
  end

  defp created_match?(created, :gt, timestamp), do: created > timestamp
  defp created_match?(created, :gte, timestamp), do: created >= timestamp
  defp created_match?(created, :lt, timestamp), do: created < timestamp
  defp created_match?(created, :lte, timestamp), do: created <= timestamp

  defp parse_boolean(true, _param), do: {:ok, true}
  defp parse_boolean(false, _param), do: {:ok, false}
  defp parse_boolean("true", _param), do: {:ok, true}
  defp parse_boolean("false", _param), do: {:ok, false}
  defp parse_boolean(_value, param), do: invalid("Invalid boolean value", param)

  defp boolean_match?(value, expected) do
    case parse_boolean(value, nil) do
      {:ok, actual} -> actual == expected
      {:error, _error} -> false
    end
  end

  defp normalize_string_list(value, param) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
    |> reject_empty_list(param)
  end

  defp normalize_string_list(value, param) when is_map(value) do
    if indexed_map?(value) do
      values =
        value
        |> Enum.sort_by(fn {index, _value} -> String.to_integer(to_string(index)) end)
        |> Enum.map(fn {_index, entry} -> to_string(entry) end)

      {:ok, values}
      |> reject_empty_list(param)
    else
      invalid("Invalid array value", param)
    end
  end

  defp normalize_string_list(value, param) when is_binary(value) do
    {:ok, [value]}
    |> reject_empty_list(param)
  end

  defp normalize_string_list(_value, param), do: invalid("Invalid array value", param)

  defp reject_empty_list({:ok, []}, param), do: invalid("Invalid array value", param)
  defp reject_empty_list(result, _param), do: result

  defp validate_max_count(_values, nil, _param), do: :ok

  defp validate_max_count(values, max, _param) when length(values) <= max, do: :ok

  defp validate_max_count(_values, max, param) do
    {:error, Error.invalid_request("You can specify up to #{max} values", format_param(param))}
  end

  defp parse_integer(value, _param) when is_integer(value), do: {:ok, value}

  defp parse_integer(value, param) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> invalid("Invalid integer value", param)
    end
  end

  defp parse_integer(_value, param), do: invalid("Invalid integer value", param)

  defp validate_operator(operator) when operator in @range_operators, do: :ok
  defp validate_operator(operator), do: invalid("Received unknown parameter", [:created, operator])

  defp normalize_operator(operator) when is_atom(operator), do: operator

  defp normalize_operator(operator) when is_binary(operator) do
    case operator do
      "gt" -> :gt
      "gte" -> :gte
      "lt" -> :lt
      "lte" -> :lte
      other -> other
    end
  end

  defp present?(params, key), do: fetch_param(params, key) != :missing

  defp fetch_param(params, [key | rest]) do
    case fetch_param(params, key) do
      :missing -> :missing
      value when rest == [] -> value
      value when is_map(value) -> fetch_param(value, rest)
      _value -> :missing
    end
  end

  defp fetch_param(params, key) when is_map(params) and is_atom(key) do
    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, Atom.to_string(key)) -> Map.get(params, Atom.to_string(key))
      true -> :missing
    end
  end

  defp value_at(item, [key | rest]) do
    case value_at(item, key) do
      nil -> nil
      value when rest == [] -> value
      value when is_map(value) -> value_at(value, rest)
      _value -> nil
    end
  end

  defp value_at(item, key) when is_map(item) and is_atom(key) do
    cond do
      Map.has_key?(item, key) -> Map.get(item, key)
      Map.has_key?(item, Atom.to_string(key)) -> Map.get(item, Atom.to_string(key))
      true -> nil
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp indexed_map?(value) do
    Enum.all?(Map.keys(value), fn key ->
      case Integer.parse(to_string(key)) do
        {_integer, ""} -> true
        _other -> false
      end
    end)
  end

  defp strip_data_prefix("data." <> rest), do: rest
  defp strip_data_prefix(path), do: path

  defp invalid(message, param), do: {:error, Error.invalid_request(message, format_param(param))}

  defp format_param(path) when is_list(path) do
    [root | rest] = Enum.map(path, &to_string/1)
    root <> Enum.map_join(rest, "", &"[#{&1}]")
  end

  defp format_param(param), do: to_string(param)
end

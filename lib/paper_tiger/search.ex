defmodule PaperTiger.Search do
  @moduledoc """
  Shared Stripe-style search support.

  This implements the same structural pieces for every search endpoint:
  parsing to a small AST, validating fields against each resource's schema,
  evaluating clauses over resource maps, and returning Stripe's
  `search_result` pagination shape.
  """

  @type field_type :: :numeric | :string | :token
  @type field_schema :: %{required(String.t()) => field_type()}

  @default_limit 10
  @max_limit 100
  @max_clauses 10

  @doc false
  @spec run([map()], map(), keyword()) :: {:ok, map()} | {:error, PaperTiger.Error.t()}
  def run(items, params, opts) when is_list(items) and is_map(params) do
    fields = Keyword.fetch!(opts, :fields)
    url = Keyword.fetch!(opts, :url)
    decorate = Keyword.get(opts, :decorate, & &1)

    with {:ok, query} <- fetch_query(params),
         {:ok, ast} <- compile(query, fields),
         {:ok, limit} <- parse_limit(get_param(params, :limit)),
         {:ok, offset} <- parse_page(get_param(params, :page)) do
      result =
        items
        |> Enum.filter(&matches?(&1, ast))
        |> Enum.sort_by(&sortable_created/1, :desc)
        |> paginate_search(limit, offset, url, decorate, expand_total_count?(params))

      {:ok, result}
    end
  end

  @doc false
  @spec compile(String.t(), field_schema()) :: {:ok, map()} | {:error, PaperTiger.Error.t()}
  def compile(query, fields) when is_binary(query) and is_map(fields) do
    with {:ok, tokens} <- split_query(query),
         {:ok, ast} <- parse_tokens(tokens) do
      validate_ast(ast, fields)
    end
  end

  defp fetch_query(params) do
    case get_param(params, :query) do
      query when is_binary(query) and query != "" ->
        {:ok, query}

      _ ->
        invalid("Missing required parameter", "query")
    end
  end

  defp split_query(query) do
    query
    |> String.graphemes()
    |> do_split_query([], [], nil, false)
  end

  defp do_split_query([], current, tokens, nil, _escaped) do
    tokens =
      current
      |> flush_token(tokens)
      |> Enum.reverse()

    if tokens == [] do
      invalid("Missing required parameter", "query")
    else
      {:ok, tokens}
    end
  end

  defp do_split_query([], _current, _tokens, _quote, _escaped) do
    invalid("Unterminated quoted string")
  end

  defp do_split_query(["\\" | rest], current, tokens, quote, false) when not is_nil(quote) do
    do_split_query(rest, ["\\" | current], tokens, quote, true)
  end

  defp do_split_query([char | rest], current, tokens, quote, true) do
    do_split_query(rest, [char | current], tokens, quote, false)
  end

  defp do_split_query([char | rest], current, tokens, char, false) when char in ["\"", "'"] do
    do_split_query(rest, [char | current], tokens, nil, false)
  end

  defp do_split_query([char | rest], current, tokens, nil, false) when char in ["\"", "'"] do
    do_split_query(rest, [char | current], tokens, char, false)
  end

  defp do_split_query([char | rest], current, tokens, nil, false) when char in [" ", "\t", "\n", "\r"] do
    do_split_query(rest, [], flush_token(current, tokens), nil, false)
  end

  defp do_split_query([char | rest], current, tokens, quote, false) do
    do_split_query(rest, [char | current], tokens, quote, false)
  end

  defp flush_token([], tokens), do: tokens

  defp flush_token(current, tokens) do
    token =
      current
      |> Enum.reverse()
      |> Enum.join()

    if token == "" do
      tokens
    else
      [token | tokens]
    end
  end

  defp parse_tokens(tokens), do: parse_tokens(tokens, [], [], true)

  defp parse_tokens([], [], _connectors, _expect_clause), do: invalid("Missing required parameter", "query")
  defp parse_tokens([], _clauses, _connectors, true), do: invalid("Search query cannot end with a connector")

  defp parse_tokens([], clauses, connectors, false) do
    connector =
      cond do
        Enum.member?(connectors, :and) and Enum.member?(connectors, :or) ->
          :mixed

        Enum.member?(connectors, :or) ->
          :or

        true ->
          :and
      end

    case connector do
      :mixed ->
        invalid("Search queries cannot mix AND and OR")

      _ when length(clauses) > @max_clauses ->
        invalid("Search queries cannot contain more than #{@max_clauses} clauses")

      _ ->
        {:ok, %{clauses: Enum.reverse(clauses), connector: connector}}
    end
  end

  defp parse_tokens([token | rest], clauses, connectors, true) do
    if connector_token?(token) do
      invalid("Search query cannot start with a connector")
    else
      with {:ok, clause} <- parse_clause(token) do
        parse_tokens(rest, [clause | clauses], connectors, false)
      end
    end
  end

  defp parse_tokens([token | rest], clauses, connectors, false) do
    if connector_token?(token) do
      parse_tokens(rest, clauses, [connector_token(token) | connectors], true)
    else
      with {:ok, clause} <- parse_clause(token) do
        parse_tokens(rest, [clause | clauses], [:and | connectors], false)
      end
    end
  end

  defp connector_token?(token), do: connector_token(token) in [:and, :or]

  defp connector_token(token) do
    case String.upcase(token) do
      "AND" -> :and
      "OR" -> :or
      _ -> nil
    end
  end

  defp parse_clause(token) do
    {negated, clause} =
      case token do
        "-" <> rest -> {true, rest}
        _ -> {false, token}
      end

    with {:ok, field, operator, value} <- split_clause(clause),
         {:ok, field} <- parse_field(field),
         {:ok, value} <- parse_value(value) do
      {:ok,
       %{
         field: field.name,
         negated: negated,
         operator: operator,
         path: field.path,
         quoted?: value.quoted?,
         value: value.value
       }}
    end
  end

  defp split_clause(clause) do
    clause
    |> String.graphemes()
    |> find_clause_operator([])
  end

  defp find_clause_operator([], _field) do
    invalid("Search clause is missing an operator")
  end

  defp find_clause_operator([">", "=" | rest], field), do: clause_parts(field, :gte, rest)
  defp find_clause_operator(["<", "=" | rest], field), do: clause_parts(field, :lte, rest)
  defp find_clause_operator([":" | rest], field), do: clause_parts(field, :exact, rest)
  defp find_clause_operator(["~" | rest], field), do: clause_parts(field, :substring, rest)
  defp find_clause_operator([">" | rest], field), do: clause_parts(field, :gt, rest)
  defp find_clause_operator(["<" | rest], field), do: clause_parts(field, :lt, rest)
  defp find_clause_operator(["=" | rest], field), do: clause_parts(field, :equals, rest)

  defp find_clause_operator([quote | rest], field) when quote in ["\"", "'"] do
    find_clause_operator_in_quote(rest, [quote | field], quote, false)
  end

  defp find_clause_operator([char | rest], field) do
    find_clause_operator(rest, [char | field])
  end

  defp find_clause_operator_in_quote([], _field, _quote, _escaped) do
    invalid("Unterminated quoted string")
  end

  defp find_clause_operator_in_quote(["\\" | rest], field, quote, false) do
    find_clause_operator_in_quote(rest, ["\\" | field], quote, true)
  end

  defp find_clause_operator_in_quote([char | rest], field, quote, true) do
    find_clause_operator_in_quote(rest, [char | field], quote, false)
  end

  defp find_clause_operator_in_quote([quote | rest], field, quote, false) do
    find_clause_operator(rest, [quote | field])
  end

  defp find_clause_operator_in_quote([char | rest], field, quote, false) do
    find_clause_operator_in_quote(rest, [char | field], quote, false)
  end

  defp clause_parts(field, operator, value) do
    field =
      field
      |> Enum.reverse()
      |> Enum.join()
      |> String.trim()

    value =
      value
      |> Enum.join()
      |> String.trim()

    cond do
      field == "" -> invalid("Search clause is missing a field")
      value == "" -> invalid("Search clause is missing a value")
      true -> {:ok, field, operator, value}
    end
  end

  defp parse_field("metadata[" <> rest) do
    case parse_metadata_field(rest) do
      {:ok, key} ->
        {:ok, %{name: "metadata", path: ["metadata", key]}}

      :error ->
        invalid("Invalid metadata search field")
    end
  end

  defp parse_field(field) do
    if Regex.match?(~r/\A[a-zA-Z0-9_.]+\z/, field) do
      {:ok, %{name: field, path: String.split(field, ".")}}
    else
      invalid("Invalid search field")
    end
  end

  defp parse_metadata_field("\"" <> rest), do: parse_metadata_field(rest, "\"")
  defp parse_metadata_field("'" <> rest), do: parse_metadata_field(rest, "'")
  defp parse_metadata_field(_rest), do: :error

  defp parse_metadata_field(rest, quote) do
    suffix = "#{quote}]"

    if String.ends_with?(rest, suffix) do
      key = String.slice(rest, 0, byte_size(rest) - byte_size(suffix))
      if key == "", do: :error, else: {:ok, key}
    else
      :error
    end
  end

  defp parse_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") ->
        parse_quoted_value(String.slice(value, 1..-1//1), "\"")

      String.starts_with?(value, "'") ->
        parse_quoted_value(String.slice(value, 1..-1//1), "'")

      String.downcase(value) == "null" ->
        {:ok, %{quoted?: false, value: :null}}

      true ->
        {:ok, %{quoted?: false, value: value}}
    end
  end

  defp parse_quoted_value(value, quote) do
    value
    |> String.graphemes()
    |> parse_quoted_value([], quote, false)
  end

  defp parse_quoted_value([], _acc, _quote, _escaped), do: invalid("Unterminated quoted string")

  defp parse_quoted_value(["\\" | rest], acc, quote, false) do
    parse_quoted_value(rest, acc, quote, true)
  end

  defp parse_quoted_value([char | rest], acc, quote, true) do
    parse_quoted_value(rest, [char | acc], quote, false)
  end

  defp parse_quoted_value([quote | rest], acc, quote, false) do
    rest
    |> Enum.join()
    |> String.trim()
    |> case do
      "" ->
        {:ok, %{quoted?: true, value: acc |> Enum.reverse() |> Enum.join()}}

      _ ->
        invalid("Unexpected characters after quoted value")
    end
  end

  defp parse_quoted_value([char | rest], acc, quote, false) do
    parse_quoted_value(rest, [char | acc], quote, false)
  end

  defp validate_ast(%{clauses: clauses} = ast, fields) do
    with {:ok, clauses} <- validate_clauses(clauses, fields) do
      {:ok, %{ast | clauses: clauses}}
    end
  end

  defp validate_clauses(clauses, fields) do
    clauses
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      case validate_clause(clause, fields) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, clauses} -> {:ok, Enum.reverse(clauses)}
      error -> error
    end
  end

  defp validate_clause(%{field: field} = clause, fields) do
    with {:ok, type} <- field_type(fields, field),
         :ok <- validate_operator(clause.operator, type, clause.value),
         {:ok, value} <- normalize_clause_value(clause.value, clause.operator, type) do
      {:ok, clause |> Map.put(:type, type) |> Map.put(:value, value)}
    end
  end

  defp field_type(fields, field) do
    case Map.fetch(fields, field) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        invalid("Unsupported search field '#{field}'")
    end
  end

  defp validate_operator(:exact, _type, _value), do: :ok
  defp validate_operator(:substring, :string, value) when value != :null, do: validate_substring_value(value)

  defp validate_operator(operator, :numeric, value) when operator in [:gt, :gte, :lt, :lte, :equals] and value != :null,
    do: :ok

  defp validate_operator(:substring, _type, _value) do
    invalid("Substring search is only supported for string fields")
  end

  defp validate_operator(operator, _type, _value) when operator in [:gt, :gte, :lt, :lte, :equals] do
    invalid("Numeric comparison is only supported for numeric fields")
  end

  defp validate_operator(_operator, _type, :null) do
    invalid("Null search only supports exact-match syntax")
  end

  defp validate_substring_value(value) when is_binary(value) and byte_size(value) >= 3, do: :ok
  defp validate_substring_value(_value), do: invalid("Substring search terms must contain at least 3 characters")

  defp normalize_clause_value(:null, _operator, _type), do: {:ok, :null}

  defp normalize_clause_value(value, operator, :numeric) when operator in [:exact, :equals, :gt, :gte, :lt, :lte] do
    case parse_number(value) do
      {:ok, number} -> {:ok, number}
      :error -> invalid("Numeric search values must be valid numbers")
    end
  end

  defp normalize_clause_value(value, _operator, _type), do: {:ok, value}

  defp matches?(item, %{clauses: clauses, connector: :and}) do
    Enum.all?(clauses, &matches_clause?(item, &1))
  end

  defp matches?(item, %{clauses: clauses, connector: :or}) do
    Enum.any?(clauses, &matches_clause?(item, &1))
  end

  defp matches_clause?(item, clause) do
    matched =
      item
      |> value_at(clause.path)
      |> value_matches?(clause)

    if clause.negated, do: not matched, else: matched
  end

  defp value_matches?(actual, %{operator: :exact, value: :null}) do
    is_nil(actual) or actual == ""
  end

  defp value_matches?(actual, %{operator: operator, type: :numeric, value: expected}) do
    case parse_number(actual) do
      {:ok, actual} -> compare_numbers(actual, operator, expected)
      :error -> false
    end
  end

  defp value_matches?(actual, %{operator: :exact, type: :string, value: expected}) do
    actual
    |> string_value()
    |> case do
      nil -> false
      actual -> String.contains?(normalize_search_string(actual), normalize_search_string(expected))
    end
  end

  defp value_matches?(actual, %{operator: :substring, type: :string, value: expected}) do
    actual
    |> string_value()
    |> case do
      nil -> false
      actual -> String.contains?(normalize_search_string(actual), normalize_search_string(expected))
    end
  end

  defp value_matches?(actual, %{operator: :exact, type: :token, value: expected}) do
    case token_value(actual) do
      nil -> false
      actual -> actual == normalize_token(expected)
    end
  end

  defp value_matches?(_actual, _clause), do: false

  defp compare_numbers(actual, :exact, expected), do: actual == expected
  defp compare_numbers(actual, :equals, expected), do: actual == expected
  defp compare_numbers(actual, :gt, expected), do: actual > expected
  defp compare_numbers(actual, :gte, expected), do: actual >= expected
  defp compare_numbers(actual, :lt, expected), do: actual < expected
  defp compare_numbers(actual, :lte, expected), do: actual <= expected

  defp value_at(item, ["metadata", key]) do
    case value_at(item, ["metadata"]) do
      metadata when is_map(metadata) ->
        fetch_map_value(metadata, key)
        |> case do
          {:ok, value} -> value
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp value_at(item, path) do
    Enum.reduce_while(path, item, fn key, acc ->
      case fetch_map_value(acc, key) do
        {:ok, value} -> {:cont, value}
        :error -> {:halt, nil}
      end
    end)
  end

  defp fetch_map_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      atom = existing_atom(key) ->
        if Map.has_key?(map, atom) do
          {:ok, Map.fetch!(map, atom)}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp fetch_map_value(_value, _key), do: :error

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp parse_number(value) when is_integer(value), do: {:ok, value}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    cond do
      Regex.match?(~r/\A-?\d+\z/, value) ->
        {number, ""} = Integer.parse(value)
        {:ok, number}

      Regex.match?(~r/\A-?\d+\.\d+\z/, value) ->
        {number, ""} = Float.parse(value)
        {:ok, number}

      true ->
        :error
    end
  end

  defp parse_number(_value), do: :error

  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value) when is_float(value), do: Float.to_string(value)
  defp string_value(_value), do: nil

  defp token_value(nil), do: nil
  defp token_value(value), do: value |> to_string() |> normalize_token()

  defp normalize_token(value), do: value |> to_string() |> String.downcase()

  defp normalize_search_string(value) do
    value
    |> to_string()
    |> String.downcase()
  end

  defp paginate_search(items, limit, offset, url, decorate, include_total_count?) do
    page = items |> Enum.drop(offset) |> Enum.take(limit + 1)
    has_more = length(page) > limit

    data =
      page
      |> Enum.take(limit)
      |> Enum.map(decorate)

    %{
      data: data,
      has_more: has_more,
      next_page: if(has_more, do: encode_page(offset + limit)),
      object: "search_result",
      url: url
    }
    |> maybe_put_total_count(include_total_count?, length(items))
  end

  defp maybe_put_total_count(result, true, total_count), do: Map.put(result, :total_count, total_count)
  defp maybe_put_total_count(result, false, _total_count), do: result

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(limit) when is_integer(limit) do
    if limit > 0 do
      {:ok, min(limit, @max_limit)}
    else
      invalid("Invalid positive integer", "limit")
    end
  end

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> parse_limit(limit)
      _ -> invalid("Invalid positive integer", "limit")
    end
  end

  defp parse_limit(_limit), do: invalid("Invalid positive integer", "limit")

  defp parse_page(nil), do: {:ok, 0}

  defp parse_page("pt_search_" <> offset) do
    case Integer.parse(offset) do
      {offset, ""} when offset >= 0 -> {:ok, offset}
      _ -> invalid("Invalid page cursor", "page")
    end
  end

  defp parse_page(_page), do: invalid("Invalid page cursor", "page")

  defp encode_page(offset), do: "pt_search_#{offset}"

  defp sortable_created(item) do
    case value_at(item, ["created"]) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> parse_number() |> elem_or_zero()
      _ -> 0
    end
  end

  defp elem_or_zero({:ok, value}), do: value
  defp elem_or_zero(:error), do: 0

  defp expand_total_count?(params) do
    case get_param(params, :expand) do
      values when is_list(values) -> Enum.member?(values, "total_count")
      "total_count" -> true
      _ -> false
    end
  end

  defp get_param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, to_string(key))
  end

  defp invalid(message, param \\ "query") do
    {:error, PaperTiger.Error.invalid_request(message, param)}
  end
end

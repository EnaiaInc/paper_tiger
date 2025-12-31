defmodule PaperTiger.Plugs.UnflattenParams do
  @moduledoc """
  Converts Stripe's form-encoded nested parameters into proper nested maps.

  Stripe's API uses bracket notation for nested parameters in form-encoded requests.
  This plug transforms them into nested Elixir maps.

  ## Examples

      # Single-level nesting
      card[number]=4242424242424242
      => %{card: %{number: "4242424242424242"}}

      # Multi-level nesting
      payment_method_data[billing_details][name]=John Doe
      => %{payment_method_data: %{billing_details: %{name: "John Doe"}}}

      # Arrays
      expand[]=customer
      expand[]=subscription
      => %{expand: ["customer", "subscription"]}

      # Metadata
      metadata[user_id]=123
      metadata[session_id]=abc
      => %{metadata: %{user_id: "123", session_id: "abc"}}

  ## Usage

      # In router
      plug PaperTiger.Plugs.UnflattenParams
  """

  @behaviour Plug

  require Logger

  # DoS protection limits
  @max_nesting_depth 10
  @max_array_index 1000
  @max_params_count 1000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    %{conn | params: unflatten_params(conn.params)}
  rescue
    e in ArgumentError ->
      Logger.error("UnflattenParams: #{e.message}")

      Plug.Conn.send_resp(conn, 400, Jason.encode!(%{error: %{message: e.message}}))
      |> Plug.Conn.halt()
  end

  ## Private Functions

  @doc """
  Transforms flat params with bracket notation into nested maps.

  ## DoS Protection

  Enforces limits to prevent denial-of-service attacks:
  - Maximum nesting depth: #{@max_nesting_depth}
  - Maximum array index: #{@max_array_index}
  - Maximum parameters: #{@max_params_count}
  """
  def unflatten_params(params) when is_map(params) do
    # Check total parameter count
    if map_size(params) > @max_params_count do
      raise ArgumentError, "Too many parameters (max: #{@max_params_count})"
    end

    result =
      params
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        put_nested(acc, parse_key(key), value, 0)
      end)

    # Convert indexed maps to lists (e.g., %{"0" => ..., "1" => ...} => [...])
    convert_indexed_maps_to_lists(result)
  end

  @doc """
  Parses a key like "card[number]" into ["card", "number"].
  """
  def parse_key(key) when is_binary(key) do
    case String.split(key, ["[", "]"], trim: true) do
      [single] -> [single]
      parts -> parts
    end
  end

  def parse_key(key), do: [key]

  @doc """
  Puts a value into a nested map structure with depth tracking for DoS protection.

  ## Examples

      put_nested(%{}, ["card", "number"], "4242", 0)
      => %{card: %{number: "4242"}}

      put_nested(%{}, ["expand", ""], "customer", 0)
      => %{expand: ["customer"]}
  """
  def put_nested(map, [key], value, _depth) when is_binary(key) do
    Map.put(map, String.to_atom(key), value)
  end

  def put_nested(map, [key, "" | _rest], value, _depth) when is_binary(key) do
    # Array syntax: expand[] = "customer"
    key_atom = String.to_atom(key)

    Map.update(map, key_atom, [value], fn existing ->
      if is_list(existing) do
        existing ++ [value]
      else
        [existing, value]
      end
    end)
  end

  def put_nested(map, [key | rest], value, depth) when is_binary(key) do
    # Check nesting depth limit
    if depth >= @max_nesting_depth do
      raise ArgumentError, "Nesting depth exceeds maximum (#{@max_nesting_depth})"
    end

    # Nested object: card[number] = "4242"
    key_atom = String.to_atom(key)

    nested =
      case Map.get(map, key_atom) do
        nil -> put_nested(%{}, rest, value, depth + 1)
        existing when is_map(existing) -> put_nested(existing, rest, value, depth + 1)
        _other -> put_nested(%{}, rest, value, depth + 1)
      end

    Map.put(map, key_atom, nested)
  end

  def put_nested(map, _invalid_path, _value, _depth) do
    Logger.warning("UnflattenParams: invalid nested path")
    map
  end

  @doc """
  Converts maps with numeric string keys to lists.

  ## DoS Protection

  Validates that array indices are within reasonable bounds (max: #{@max_array_index})
  to prevent memory exhaustion from sparse arrays like items[999999].

  ## Examples

      convert_indexed_maps_to_lists(%{"0" => "a", "1" => "b"})
      => ["a", "b"]

      convert_indexed_maps_to_lists(%{items: %{"0" => %{price: "p1"}, "1" => %{price: "p2"}}})
      => %{items: [%{price: "p1"}, %{price: "p2"}]}
  """
  def convert_indexed_maps_to_lists(value) when is_map(value) do
    if indexed_map?(value) do
      # Validate max index before converting
      max_index =
        value
        |> Map.keys()
        |> Enum.map(&String.to_integer/1)
        |> Enum.max()

      if max_index > @max_array_index do
        raise ArgumentError, "Array index exceeds maximum (#{@max_array_index})"
      end

      # Convert to list, sorted by index
      value
      |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
      |> Enum.map(fn {_k, v} -> convert_indexed_maps_to_lists(v) end)
    else
      # Recursively process nested maps
      Map.new(value, fn {k, v} -> {k, convert_indexed_maps_to_lists(v)} end)
    end
  end

  def convert_indexed_maps_to_lists(value), do: value

  # Checks if a map has only numeric string keys (0, 1, 2, ...)
  defp indexed_map?(map) when is_map(map) and map_size(map) > 0 do
    map
    |> Map.keys()
    |> Enum.all?(fn
      key when is_binary(key) ->
        case Integer.parse(key) do
          {_num, ""} -> true
          _ -> false
        end

      _other ->
        false
    end)
  end

  defp indexed_map?(_), do: false
end

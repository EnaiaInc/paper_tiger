defmodule PaperTiger.Resource do
  @moduledoc """
  Shared utilities for resource handlers.

  Provides helper functions for:
  - JSON responses
  - Error handling
  - ID generation
  - Parameter extraction
  - Expand parameter parsing
  - Idempotency handling

  ## Usage

      defmodule PaperTiger.Resources.Customer do
        import PaperTiger.Resource

        def create(conn) do
          with {:ok, params} <- validate_params(conn.params, [:email]),
               customer <- build_customer(params),
               {:ok, customer} <- Store.Customers.insert(customer) do
            json_response(conn, 200, customer)
          else
            {:error, :invalid_params, field} ->
              error_response(conn, PaperTiger.Error.invalid_request("Missing param", field))
          end
        end
      end
  """

  import Plug.Conn

  require Logger

  @doc """
  Sends a JSON response with the given status code and body.
  """
  @spec json_response(Plug.Conn.t(), integer(), map() | struct()) :: Plug.Conn.t()
  def json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc """
  Sends an error response using a PaperTiger.Error struct.
  """
  @spec error_response(Plug.Conn.t(), PaperTiger.Error.t()) :: Plug.Conn.t()
  def error_response(conn, %PaperTiger.Error{} = error) do
    json_response(conn, error.status, PaperTiger.Error.to_json(error))
  end

  @doc """
  Generates a Stripe-style ID with the given prefix.

  ## Examples

      generate_id("cus")  => "cus_1234567890abcdef"
      generate_id("sub")  => "sub_abcdef1234567890"
  """
  @spec generate_id(String.t()) :: String.t()
  def generate_id(prefix) do
    random_part =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{prefix}_#{random_part}"
  end

  @doc """
  Validates that required parameters are present.

  ## Examples

      validate_params(%{email: "test@example.com"}, [:email])
      => {:ok, %{email: "test@example.com"}}

      validate_params(%{}, [:email])
      => {:error, :invalid_params, :email}
  """
  @spec validate_params(map(), [atom()]) :: {:ok, map()} | {:error, :invalid_params, atom()}
  def validate_params(params, required_fields) do
    missing_field =
      Enum.find(required_fields, fn field ->
        is_nil(Map.get(params, field)) or Map.get(params, field) == ""
      end)

    case missing_field do
      nil -> {:ok, params}
      field -> {:error, :invalid_params, field}
    end
  end

  @doc """
  Parses expand[] parameters from request params.

  ## Examples

      parse_expand_params(%{expand: ["customer", "subscription"]})
      => ["customer", "subscription"]

      parse_expand_params(%{})
      => []
  """
  @spec parse_expand_params(map()) :: [String.t()]
  def parse_expand_params(params) do
    case Map.get(params, :expand) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  @doc """
  Stores a response for idempotency if an idempotency key is present.
  """
  @spec maybe_store_idempotency(Plug.Conn.t(), map()) :: :ok
  def maybe_store_idempotency(conn, response) do
    case Map.get(conn.assigns, :idempotency_key) do
      nil ->
        :ok

      key ->
        PaperTiger.Idempotency.store(key, response)
    end
  end

  @doc """
  Extracts pagination parameters from request params.

  ## Examples

      parse_pagination_params(%{limit: "10", starting_after: "cus_123"})
      => %{limit: 10, starting_after: "cus_123"}
  """
  @spec parse_pagination_params(map()) :: map()
  def parse_pagination_params(params) do
    %{}
    |> maybe_put_limit(params)
    |> maybe_put_cursor(:starting_after, params)
    |> maybe_put_cursor(:ending_before, params)
  end

  defp maybe_put_limit(acc, params) do
    case Map.get(params, :limit) do
      nil -> acc
      limit when is_integer(limit) -> Map.put(acc, :limit, limit)
      limit when is_binary(limit) -> Map.put(acc, :limit, String.to_integer(limit))
    end
  end

  defp maybe_put_cursor(acc, key, params) do
    case Map.get(params, key) do
      nil -> acc
      cursor when is_binary(cursor) -> Map.put(acc, key, cursor)
    end
  end

  @doc """
  Merges update parameters into an existing resource.

  Filters out nil values and immutable fields.
  """
  @spec merge_updates(map(), map(), [atom()]) :: map()
  def merge_updates(existing, updates, immutable_fields \\ [:id, :object, :created]) do
    updates
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.drop(immutable_fields)
    |> then(&Map.merge(existing, &1))
  end

  @doc """
  Converts a value to boolean.

  ## Examples

      to_boolean(true) => true
      to_boolean("true") => true
      to_boolean("false") => false
      to_boolean(nil) => false
  """
  def to_boolean(true), do: true
  def to_boolean("true"), do: true
  def to_boolean(false), do: false
  def to_boolean("false"), do: false
  def to_boolean(nil), do: false
  def to_boolean(_), do: false

  @doc """
  Converts a value to integer.

  ## Examples

      to_integer(123) => 123
      to_integer("123") => 123
      to_integer(nil) => 0
  """
  def to_integer(value) when is_integer(value), do: value

  def to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> 0
    end
  end

  def to_integer(_), do: 0
end

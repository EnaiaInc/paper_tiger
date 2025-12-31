defmodule PaperTiger.List do
  @moduledoc """
  Handles Stripe-style pagination for list endpoints.

  Stripe uses cursor-based pagination with `starting_after`, `ending_before`, and `limit`.

  ## Examples

      # First page (default limit: 10)
      {:ok, page1} = Stripe.Customer.list()
      assert length(page1.data) == 10
      assert page1.has_more == true

      # Next page using cursor
      last_id = List.last(page1.data).id
      {:ok, page2} = Stripe.Customer.list(starting_after: last_id)

  ## Pagination Behavior

  - Items are sorted by `created` timestamp (newest first, like Stripe)
  - `starting_after`: Returns items after the specified ID
  - `ending_before`: Returns items before the specified ID
  - If both provided, `ending_before` takes precedence
  - `has_more`: true if there are more results beyond this page
  """

  @enforce_keys [:object, :data, :has_more, :url]
  @derive Jason.Encoder
  defstruct [:data, :has_more, :object, :url]

  @type t :: %__MODULE__{
          data: [map()],
          has_more: boolean(),
          object: String.t(),
          url: String.t()
        }

  @default_limit 10
  @max_limit 100

  @doc """
  Paginates a list of items using Stripe's pagination parameters.

  ## Options

  - `:limit` - Number of items to return (default: 10, max: 100)
  - `:starting_after` - Return items after this ID
  - `:ending_before` - Return items before this ID
  - `:url` - The endpoint URL (for the response)

  ## Examples

      items = [...list of structs with .id and .created...]
      PaperTiger.List.paginate(items, limit: 20, url: "/v1/customers")
  """
  @spec paginate([map()], keyword() | map()) :: t()
  def paginate(items, opts \\ %{}) when is_list(items) do
    opts = normalize_opts(opts)

    limit = min(opts[:limit] || @default_limit, @max_limit)
    starting_after = opts[:starting_after]
    ending_before = opts[:ending_before]

    # Sort by created timestamp descending (newest first, like Stripe)
    sorted = Enum.sort_by(items, & &1.created, :desc)

    # Apply cursor filtering
    filtered = apply_cursor(sorted, starting_after, ending_before)

    # Take limit + 1 to check if there are more results
    page = Enum.take(filtered, limit + 1)

    has_more = length(page) > limit
    data = Enum.take(page, limit)

    %__MODULE__{
      data: data,
      has_more: has_more,
      object: "list",
      url: opts[:url] || "/v1/unknown"
    }
  end

  ## Private Functions

  defp normalize_opts(opts) when is_map(opts) do
    # Convert string keys to atoms for consistency
    for {k, v} <- opts, into: [] do
      key =
        case k do
          k when is_binary(k) -> String.to_existing_atom(k)
          k when is_atom(k) -> k
        end

      {key, v}
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: opts

  defp apply_cursor(items, nil, nil), do: items

  defp apply_cursor(items, starting_after, nil) when is_binary(starting_after) do
    # Return items after the specified ID
    items
    |> Enum.drop_while(fn item -> item.id != starting_after end)
    |> Enum.drop(1)
  end

  defp apply_cursor(items, nil, ending_before) when is_binary(ending_before) do
    # Return items before the specified ID
    Enum.take_while(items, fn item -> item.id != ending_before end)
  end

  defp apply_cursor(items, _starting_after, ending_before) do
    # If both provided, ending_before takes precedence (matches Stripe behavior)
    apply_cursor(items, nil, ending_before)
  end
end

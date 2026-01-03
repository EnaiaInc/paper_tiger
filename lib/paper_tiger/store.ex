defmodule PaperTiger.Store do
  @moduledoc """
  Shared behavior for all ETS-backed resource stores.

  Provides GenServer-wrapped ETS storage with:
  - Concurrent reads (direct ETS access)
  - Serialized writes (through GenServer)
  - Common CRUD operations
  - Pagination support
  - Test isolation via namespacing (see `PaperTiger.Test`)

  ## Usage

      defmodule PaperTiger.Store.Customers do
        use PaperTiger.Store,
          table: :paper_tiger_customers,
          resource: "customer"

        # Optionally add resource-specific queries
        def find_by_email(email) when is_binary(email) do
          namespace = PaperTiger.Test.current_namespace()
          :ets.match_object(@table, {{namespace, :_}, %{email: email}})
          |> Enum.map(fn {_key, customer} -> customer end)
        end
      end

  This generates all standard store functions:
  - `get/1`, `list/1`, `count/0` (reads - direct ETS)
  - `insert/1`, `update/1`, `delete/1`, `clear/0` (writes - via GenServer)
  - `clear_namespace/1` (for test cleanup)
  - GenServer callbacks

  ## Namespacing

  All data is stored with a composite key `{namespace, id}` where namespace
  is either `:global` (default) or the PID of the test process when using
  `PaperTiger.Test.checkout_paper_tiger/1`.

  This allows concurrent tests to have isolated data without interference.
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    resource = Keyword.fetch!(opts, :resource)
    plural = Keyword.get(opts, :plural, "#{resource}s")
    url_path = Keyword.get(opts, :url_path, "/v1/#{plural}")

    [
      quote_module_setup(table, resource, plural, url_path),
      quote_read_functions(table, resource, plural, url_path),
      quote_write_functions(resource, plural),
      quote_namespace_functions(table, plural),
      quote_callbacks(table, resource, plural)
    ]
  end

  defp quote_module_setup(table, resource, plural, url_path) do
    quote do
      use GenServer

      require Logger

      @table unquote(table)
      @resource unquote(resource)
      @plural unquote(plural)
      @url_path unquote(url_path)

      @doc """
      Starts the #{unquote(resource)} store GenServer.
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc """
      Returns the ETS table name for this store.
      """
      @spec table_name() :: atom()
      def table_name, do: @table

      # Returns the current namespace for data isolation
      defp current_namespace do
        PaperTiger.Test.current_namespace()
      end
    end
  end

  defp quote_read_functions(table, resource, plural, url_path) do
    quote do
      @doc """
      Retrieves a #{unquote(resource)} by ID.

      **Direct ETS access** - does not go through GenServer.
      Data is scoped to the current test namespace.
      """
      @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
      def get(id) when is_binary(id) do
        namespace = current_namespace()
        key = {namespace, id}

        case :ets.lookup(unquote(table), key) do
          [{^key, item}] -> {:ok, item}
          [] -> {:error, :not_found}
        end
      end

      @doc """
      Lists all #{unquote(plural)} with optional pagination.

      **Direct ETS access** - does not go through GenServer.
      Data is scoped to the current test namespace.

      ## Options

      - `:limit` - Number of items (default: 10, max: 100)
      - `:starting_after` - Cursor for pagination
      - `:ending_before` - Reverse cursor
      """
      @spec list(keyword() | map()) :: PaperTiger.List.t()
      def list(opts \\ %{}) do
        opts = if is_list(opts), do: Map.new(opts), else: opts
        namespace = current_namespace()

        # Match only items in current namespace
        :ets.match_object(unquote(table), {{namespace, :_}, :_})
        |> Enum.map(fn {_key, item} -> item end)
        |> PaperTiger.List.paginate(Map.put(opts, :url, unquote(url_path)))
      end

      @doc """
      Counts total #{unquote(plural)} in current namespace.

      **Direct ETS access** - does not go through GenServer.
      """
      @spec count() :: non_neg_integer()
      def count do
        namespace = current_namespace()

        :ets.match_object(unquote(table), {{namespace, :_}, :_})
        |> length()
      end
    end
  end

  defp quote_write_functions(resource, _plural) do
    quote do
      @doc """
      Inserts a #{unquote(resource)} into the store.

      **Serialized write** - goes through GenServer to prevent race conditions.
      Data is scoped to the current test namespace.
      """
      @spec insert(map()) :: {:ok, map()}
      def insert(item) when is_map(item) do
        namespace = current_namespace()
        GenServer.call(__MODULE__, {:insert, namespace, item})
      end

      @doc """
      Updates a #{unquote(resource)} in the store.

      **Serialized write** - goes through GenServer.
      Data is scoped to the current test namespace.
      """
      @spec update(map()) :: {:ok, map()}
      def update(item) when is_map(item) do
        namespace = current_namespace()
        GenServer.call(__MODULE__, {:update, namespace, item})
      end

      @doc """
      Deletes a #{unquote(resource)} from the store.

      **Serialized write** - goes through GenServer.
      Data is scoped to the current test namespace.
      """
      @spec delete(String.t()) :: :ok
      def delete(id) when is_binary(id) do
        namespace = current_namespace()
        GenServer.call(__MODULE__, {:delete, namespace, id})
      end

      @doc """
      Clears all #{unquote(resource)}s from the store (all namespaces).

      **Serialized write** - goes through GenServer.

      Useful for test cleanup. Note: This clears ALL data, not just
      the current namespace. For namespace-specific cleanup, use
      `clear_namespace/1`.
      """
      @spec clear() :: :ok
      def clear do
        GenServer.call(__MODULE__, :clear)
      end
    end
  end

  defp quote_namespace_functions(table, plural) do
    quote do
      @doc """
      Clears all #{unquote(plural)} for a specific namespace.

      Used by `PaperTiger.Test` to clean up after each test.
      """
      @spec clear_namespace(pid() | :global) :: :ok
      def clear_namespace(namespace) do
        GenServer.call(__MODULE__, {:clear_namespace, namespace})
      end

      @doc """
      Returns all items in a specific namespace.

      Useful for debugging test isolation.
      """
      @spec list_namespace(pid() | :global) :: [map()]
      def list_namespace(namespace) do
        :ets.match_object(unquote(table), {{namespace, :_}, :_})
        |> Enum.map(fn {_key, item} -> item end)
      end
    end
  end

  defp quote_callbacks(table, resource, plural) do
    quote do
      @impl true
      def init(_opts) do
        :ets.new(unquote(table), [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: false
        ])

        Logger.info("#{__MODULE__} started")
        {:ok, %{}}
      end

      @impl true
      def handle_call({:insert, namespace, item}, _from, state) do
        key = {namespace, item.id}
        :ets.insert(unquote(table), {key, item})
        Logger.debug("#{String.capitalize(unquote(resource))} inserted: #{item.id}")
        {:reply, {:ok, item}, state}
      end

      def handle_call({:update, namespace, item}, _from, state) do
        key = {namespace, item.id}
        :ets.insert(unquote(table), {key, item})
        Logger.debug("#{String.capitalize(unquote(resource))} updated: #{item.id}")
        {:reply, {:ok, item}, state}
      end

      def handle_call({:delete, namespace, id}, _from, state) do
        key = {namespace, id}
        :ets.delete(unquote(table), key)
        Logger.debug("#{String.capitalize(unquote(resource))} deleted: #{id}")
        {:reply, :ok, state}
      end

      def handle_call(:clear, _from, state) do
        :ets.delete_all_objects(unquote(table))
        Logger.debug("#{String.capitalize(unquote(plural))} store cleared")
        {:reply, :ok, state}
      end

      def handle_call({:clear_namespace, namespace}, _from, state) do
        # Delete all entries matching the namespace
        :ets.match_delete(unquote(table), {{namespace, :_}, :_})
        Logger.debug("#{String.capitalize(unquote(plural))} cleared for namespace")
        {:reply, :ok, state}
      end

      @impl true
      def terminate(_reason, _state) do
        :ok
      end

      defoverridable init: 1,
                     handle_call: 3,
                     terminate: 2,
                     get: 1,
                     list: 1,
                     count: 0,
                     insert: 1,
                     update: 1,
                     delete: 1,
                     clear: 0,
                     clear_namespace: 1,
                     list_namespace: 1
    end
  end
end

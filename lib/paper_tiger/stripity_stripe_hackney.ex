defmodule PaperTiger.StripityStripeHackney do
  @moduledoc """
  HTTP module for stripity_stripe that enables PaperTiger sandbox isolation.

  When using stripity_stripe with PaperTiger, this module ensures that all
  HTTP requests include the namespace header needed for test isolation.

  ## Configuration

  In your `config/test.exs`:

      config :stripity_stripe,
        http_module: PaperTiger.StripityStripeHackney

  ## How It Works

  1. Test calls `PaperTiger.Test.checkout_paper_tiger(%{})` which sets up namespace
  2. This module reads the namespace and adds it as an HTTP header
  3. PaperTiger's Sandbox plug reads the header and scopes all operations
  4. Test data is isolated between tests

  ## Child Process Support

  For tests that spawn child processes (like Phoenix LiveView tests), the
  namespace is automatically shared via Application env. When you call
  `checkout_paper_tiger/1`, it sets both the process dictionary (for the
  test process) and Application env (for child processes like LiveView).

  This means LiveView tests "just work" - no extra configuration needed.

  ## Example

      defmodule MyApp.BillingTest do
        use MyApp.ConnCase, async: true

        import PaperTiger.Test

        setup do
          :ok = checkout_paper_tiger(%{})
          # ... rest of setup
        end

        test "creates subscription", %{conn: conn} do
          # Stripe calls from this test AND from LiveView are isolated
          {:ok, _sub} = Stripe.Subscription.create(%{...})

          {:ok, live, _html} = live(conn, "/billing")
          # LiveView's Stripe calls use the same sandbox!
        end
      end
  """

  @compile {:no_warn_undefined, :hackney}
  @namespace_key :paper_tiger_namespace
  @namespace_header "x-paper-tiger-namespace"
  @shared_namespace_key :paper_tiger_shared_namespace

  @doc """
  Wraps `:hackney.request/5` and injects the PaperTiger namespace header.

  This function has the same signature as `:hackney.request/5` so it can
  be used as a drop-in replacement via stripity_stripe's `http_module` config.
  """
  @spec request(atom(), String.t(), list(), iodata(), list()) ::
          {:ok, integer(), list(), any()} | {:error, term()}
  def request(method, url, headers, body, opts) do
    headers = inject_namespace_header(headers)
    :hackney.request(method, url, headers, body, opts)
  end

  defp inject_namespace_header(headers) do
    case get_namespace() do
      nil ->
        # No namespace - running outside sandbox or in global mode
        headers

      :global ->
        # Explicitly global - no namespace header needed
        headers

      pid when is_pid(pid) ->
        # Add namespace header for test isolation
        [{@namespace_header, inspect(pid)} | headers]

      namespace when is_atom(namespace) ->
        # Named namespace (less common)
        [{@namespace_header, Atom.to_string(namespace)} | headers]
    end
  end

  # Check process dictionary first (test process), then Application env (child processes)
  defp get_namespace do
    case Process.get(@namespace_key) do
      nil ->
        # Not in test process - check shared namespace for child processes
        Application.get_env(:paper_tiger, @shared_namespace_key)

      namespace ->
        namespace
    end
  end
end

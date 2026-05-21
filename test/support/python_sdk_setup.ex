defmodule PaperTiger.PythonSdkSetup do
  @moduledoc """
  Test infrastructure for running the official Python `stripe` SDK against
  PaperTiger's `Router` over real HTTP.

  Why this exists separately from the existing `TestClient` contract suite:
  every existing contract test goes through `stripity_stripe`. A
  `stripity_stripe`-side quirk (HTTP/2 negotiation, header casing, form
  encoding edge cases) presents as a PaperTiger bug or a real-Stripe bug
  and takes real debugging to disentangle. Driving the official Python
  SDK against PaperTiger over real HTTP eliminates that whole class of
  confusion: if the test fails, PaperTiger's wire shape doesn't match
  what the canonical Stripe SDK expects, full stop.

  Responsibilities:

    * Boot `PaperTiger.Router` on an ephemeral port via Bandit so the
      Python SDK can make real HTTP requests against it.
    * Provision a Python virtualenv under `_build/test/` with the
      official `stripe` package pinned, reused across runs.
    * Activate the venv in the calling Erlang process via
      `erlang_python` so `:py.eval/2` and `:py.call/4` can import
      `stripe`.
    * Configure `stripe.api_base` to point at the local Bandit endpoint
      and `stripe.api_key` to a test sentinel.

  See `PaperTiger.Contract.PythonSdkTest` for usage. Tagged
  `:python_sdk` and excluded by default; opt in via
  `VALIDATE_PYTHON_SDK=true`.
  """

  @venv_path Path.join([Mix.Project.build_path(), "python_sdk_venv"])
  @stripe_pin "stripe==9.10.0"

  @doc """
  Returns the path to the venv used by Python-SDK tests, creating and
  populating it if missing. Idempotent.
  """
  @spec ensure_venv!() :: Path.t()
  def ensure_venv! do
    if File.exists?(Path.join([@venv_path, "bin", "python"])) do
      @venv_path
    else
      File.mkdir_p!(Path.dirname(@venv_path))

      {_, 0} = System.cmd("python3", ["-m", "venv", @venv_path], stderr_to_stdout: true)

      pip = Path.join([@venv_path, "bin", "pip"])
      {_, 0} = System.cmd(pip, ["install", "--quiet", "--upgrade", "pip"], stderr_to_stdout: true)
      {_, 0} = System.cmd(pip, ["install", "--quiet", @stripe_pin], stderr_to_stdout: true)

      @venv_path
    end
  end

  @doc """
  Starts a Bandit server hosting `PaperTiger.Router` on an ephemeral
  port. Returns `{:ok, port}`. The server is started under the test's
  supervision (use from a `setup` block that calls `start_supervised!`)
  so it tears down with the test.

  The port is captured from Bandit after start via
  `ThousandIsland.listener_info/1` — Bandit picks an OS-assigned port
  when `port: 0`.
  """
  @spec start_router!() :: non_neg_integer()
  def start_router! do
    spec =
      {Bandit, plug: PaperTiger.Router, port: 0, scheme: :http, ip: {127, 0, 0, 1}}

    pid = ExUnit.Callbacks.start_supervised!(spec)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc """
  Activates the Python venv in the calling process and configures the
  `stripe` SDK to talk to `http://127.0.0.1:<port>`.

  Must be called from the test process that will subsequently use
  `:py.eval/2`, because `erlang_python` scopes Python state per Erlang
  process (see README § Process-Bound Environments).
  """
  @spec configure_stripe_sdk!(non_neg_integer()) :: :ok
  def configure_stripe_sdk!(port) when is_integer(port) do
    venv = ensure_venv!()
    :ok = :erlang.apply(:py, :activate_venv, [venv])

    # `erlang_python` scopes Python state per Erlang process (see
    # README § Process-Bound Environments), so this MUST be called
    # from the same process that will subsequently run `:py.eval`
    # statements. In ExUnit terms: call from `setup`, not `setup_all`
    # — `setup_all` runs in a separate process and the import would
    # not be visible to the test function's Python state.
    #
    # Multi-statement setup goes through `:py.exec/1` (wraps Python's
    # `exec()`); `:py.eval/2` is expression-only. The port is embedded
    # in the exec'd code rather than passed as a binding because exec
    # doesn't take a locals map — the port comes from `start_router!/0`,
    # not from untrusted input.
    #
    # stripe-python appends `/v1` itself when api_base has no path
    # component, so we set the bare host:port.
    #
    # `max_network_retries = 0` trims the SDK's exponential-backoff
    # behaviour: tests want a deterministic single-shot call, not a
    # retry loop that masks a wire-shape bug as flakiness.
    :ok =
      :erlang.apply(:py, :exec, [
        """
        import json
        import stripe

        stripe.api_base = "http://127.0.0.1:#{port}"
        stripe.api_key = "sk_pt_test"
        stripe.max_network_retries = 0

        # Convert a StripeObject (or anything JSON-encodable via stripe's
        # serializer) to a plain recursive dict, the shape test assertions
        # care about. Avoids stripe-python 9.x's to_dict_recursive()
        # deprecation warning while staying fully recursive.
        def _d(obj):
            return json.loads(str(obj)) if obj is not None else None
        """
      ])

    :ok
  end

  @doc """
  Evaluates a Python expression through `erlang_python`.

  The optional `:py` module is invoked dynamically so normal, non-Python test
  runs can compile this support module without loading the dependency.
  """
  @spec eval(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def eval(code, locals) when is_binary(code) and is_map(locals) do
    :erlang.apply(:py, :eval, [code, locals])
  end
end

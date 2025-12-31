defmodule PaperTiger.Clock do
  @moduledoc """
  Manages time for PaperTiger. Three modes:

  - `:real` - Uses System.system_time(:second)
  - `:accelerated` - Real time × multiplier (1 real sec = N PaperTiger secs)
  - `:manual` - Frozen time, advance via `PaperTiger.advance_time/1`

  ## Examples

      # Real time (production/PR apps)
      config :paper_tiger, time_mode: :real

      # Accelerated time (integration tests)
      config :paper_tiger,
        time_mode: :accelerated,
        time_multiplier: 100  # 1 real second = 100 Stripe seconds

      # Manual time (unit tests)
      config :paper_tiger, time_mode: :manual

      # Advance time in tests
      PaperTiger.advance_time(days: 30)
      PaperTiger.advance_time(seconds: 3600)
  """

  use GenServer

  require Logger

  @type mode :: :real | :accelerated | :manual
  @type state :: %{
          mode: mode(),
          multiplier: pos_integer(),
          offset: integer(),
          started_at: integer()
        }

  ## Client API

  @doc """
  Starts the Clock GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current PaperTiger time as Unix timestamp (seconds).

  Behaves differently based on time mode:
  - `:real` - Returns actual system time
  - `:accelerated` - Returns system time × multiplier
  - `:manual` - Returns frozen time + manual offset
  """
  @spec now() :: integer()
  def now do
    GenServer.call(__MODULE__, :now)
  end

  @doc """
  Advances time by the given amount (manual mode only).

  ## Examples

      PaperTiger.Clock.advance(seconds: 3600)
      PaperTiger.Clock.advance(days: 30)
      PaperTiger.Clock.advance(86400)  # 1 day in seconds
  """
  @spec advance(integer() | keyword()) :: :ok
  def advance(seconds) when is_integer(seconds) do
    GenServer.call(__MODULE__, {:advance, seconds})
  end

  def advance(opts) when is_list(opts) do
    seconds = Keyword.get(opts, :seconds, 0)
    minutes = Keyword.get(opts, :minutes, 0)
    hours = Keyword.get(opts, :hours, 0)
    days = Keyword.get(opts, :days, 0)

    total_seconds = seconds + minutes * 60 + hours * 3600 + days * 86_400
    advance(total_seconds)
  end

  @doc """
  Changes the time mode dynamically.

  This is useful for tests that need to switch between modes.

  ## Options

  - `:multiplier` - Time multiplier for accelerated mode (default: 1)
  - `:timestamp` - Starting timestamp for manual mode (default: current time)
  """
  @spec set_mode(mode(), keyword()) :: :ok
  def set_mode(mode, opts \\ []) do
    multiplier = Keyword.get(opts, :multiplier, 1)
    GenServer.call(__MODULE__, {:set_mode, mode, multiplier})
  end

  @doc """
  Resets the clock to current system time.

  Useful for cleaning up between tests.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Returns the current clock mode.

  ## Examples

      PaperTiger.Clock.get_mode()
      #=> :real
  """
  @spec get_mode() :: mode()
  def get_mode do
    GenServer.call(__MODULE__, :get_mode)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    mode = Application.get_env(:paper_tiger, :time_mode, :real)
    multiplier = Application.get_env(:paper_tiger, :time_multiplier, 1)

    state = %{
      mode: mode,
      multiplier: multiplier,
      offset: 0,
      started_at: System.system_time(:second)
    }

    Logger.info("PaperTiger.Clock started in #{mode} mode (multiplier: #{multiplier}x)")

    {:ok, state}
  end

  @impl true
  def handle_call(:now, _from, %{mode: :real} = state) do
    {:reply, System.system_time(:second), state}
  end

  def handle_call(:now, _from, %{mode: :accelerated, multiplier: m, offset: offset, started_at: start} = state) do
    elapsed = System.system_time(:second) - start
    accelerated_time = start + elapsed * m + offset
    {:reply, accelerated_time, state}
  end

  def handle_call(:now, _from, %{mode: :manual, offset: offset, started_at: start} = state) do
    {:reply, start + offset, state}
  end

  def handle_call({:advance, seconds}, _from, state) do
    new_offset = state.offset + seconds
    Logger.debug("PaperTiger.Clock advanced by #{seconds}s (total offset: #{new_offset}s)")
    {:reply, :ok, %{state | offset: new_offset}}
  end

  def handle_call({:set_mode, mode, multiplier}, _from, state) do
    Logger.info("PaperTiger.Clock mode changed: #{state.mode} -> #{mode}")

    {:reply, :ok,
     %{
       state
       | mode: mode,
         multiplier: multiplier,
         offset: 0,
         started_at: System.system_time(:second)
     }}
  end

  def handle_call(:reset, _from, state) do
    Logger.debug("PaperTiger.Clock reset")

    {:reply, :ok, %{state | offset: 0, started_at: System.system_time(:second)}}
  end

  def handle_call(:get_mode, _from, state) do
    {:reply, state.mode, state}
  end
end

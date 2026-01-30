defmodule PaperTiger.PortTest do
  use ExUnit.Case, async: false

  setup do
    env_port = System.get_env("PAPER_TIGER_PORT")
    config_port = Application.get_env(:paper_tiger, :port)
    actual_port = Application.get_env(:paper_tiger, :actual_port)

    on_exit(fn ->
      if is_nil(env_port) do
        System.delete_env("PAPER_TIGER_PORT")
      else
        System.put_env("PAPER_TIGER_PORT", env_port)
      end

      if is_nil(config_port) do
        Application.delete_env(:paper_tiger, :port)
      else
        Application.put_env(:paper_tiger, :port, config_port)
      end

      if is_nil(actual_port) do
        Application.delete_env(:paper_tiger, :actual_port)
      else
        Application.put_env(:paper_tiger, :actual_port, actual_port)
      end
    end)

    :ok
  end

  test "get_port resolves and caches before startup" do
    System.delete_env("PAPER_TIGER_PORT")
    Application.delete_env(:paper_tiger, :port)
    Application.delete_env(:paper_tiger, :actual_port)

    port = PaperTiger.get_port()

    assert is_integer(port)
    assert port >= 59_000
    assert port <= 60_000
    assert Application.get_env(:paper_tiger, :port) == port
    assert PaperTiger.get_port() == port
  end
end

exclude =
  []
  |> then(fn acc ->
    if System.get_env("VALIDATE_CONTRACT_DRIFT") == "true" do
      acc
    else
      [{:stripe_live, true} | acc]
    end
  end)
  |> then(fn acc ->
    if System.get_env("VALIDATE_PYTHON_SDK") == "true" do
      # erlang_python is required for the Python-SDK contract tests; only
      # start it when opting in so a default `mix test` run doesn't pay
      # the venv setup cost or require Python 3.12+ to be present.
      {:ok, _} = Application.ensure_all_started(:erlang_python)
      acc
    else
      [{:python_sdk, true} | acc]
    end
  end)

ExUnit.start(exclude: exclude)

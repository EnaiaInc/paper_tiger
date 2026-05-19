exclude =
  if System.get_env("VALIDATE_CONTRACT_DRIFT") == "true" do
    []
  else
    [stripe_live: true]
  end

ExUnit.start(exclude: exclude)

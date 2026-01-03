import Config

# Configure stripity_stripe at runtime
# Uses PaperTiger by default, real Stripe when VALIDATE_AGAINST_STRIPE=true
if config_env() == :test do
  if System.get_env("VALIDATE_AGAINST_STRIPE") == "true" do
    config :stripity_stripe,
      api_key: System.get_env("STRIPE_API_KEY")
  else
    config :stripity_stripe, PaperTiger.stripity_stripe_config()
  end
end

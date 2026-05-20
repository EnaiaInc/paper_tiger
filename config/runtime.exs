import Config

# Configure stripity_stripe at runtime
# Uses PaperTiger by default, real Stripe when VALIDATE_AGAINST_STRIPE=true
if config_env() == :test do
  if System.get_env("VALIDATE_AGAINST_STRIPE") == "true" do
    config :stripity_stripe,
      api_key: System.get_env("STRIPE_API_KEY"),
      # stripity_stripe sends the HTTP/1-only Connection header. hackney 4 can
      # negotiate HTTP/2 by default, which Stripe rejects as a protocol error.
      hackney_opts: [protocols: [:http1]]
  else
    config :stripity_stripe, PaperTiger.stripity_stripe_config()
  end
end

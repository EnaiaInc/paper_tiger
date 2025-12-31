import Config

# Stripity Stripe configuration for contract testing
# Only used when VALIDATE_AGAINST_STRIPE=true
config :stripity_stripe,
  api_key: System.get_env("STRIPE_API_KEY") || "sk_test_mock",
  log_level: :info

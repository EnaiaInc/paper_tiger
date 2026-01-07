import Config

# Stripity Stripe base configuration for test
# Runtime config in runtime.exs handles PaperTiger vs real Stripe switching
config :paper_tiger, enable_bootstrap: false

config :stripity_stripe, log_level: :info

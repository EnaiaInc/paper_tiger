defmodule PaperTiger.DataSource do
  @moduledoc """
  Behaviour for an external data source that can preload PaperTiger stores.

  Implementations should return lists of maps with atom keys matching Stripe
  resource shapes (e.g. `%{id: "price_123", unit_amount: 500, ...}`).

  This behaviour is intentionally minimal and supports only loading the
  resources PaperTiger needs at bootstrap but can be extended.
  """

  @doc "Return a list of Price-like maps with atom keys."
  @callback load_prices() :: [map()]

  @doc "Return a list of Product-like maps with atom keys."
  @callback load_products() :: [map()]

  @doc "Return a list of Customer-like maps with atom keys."
  @callback load_customers() :: [map()]

  @doc "Return a list of Plan-like maps with atom keys."
  @callback load_plans() :: [map()]

  @doc "Return a list of Subscription-like maps with atom keys."
  @callback load_subscriptions() :: [map()]

  @doc "Return a list of PaymentMethod-like maps with atom keys."
  @callback load_payment_methods() :: [map()]

  @doc "Return a list of SubscriptionItem-like maps with atom keys."
  @callback load_subscription_items() :: [map()]
end

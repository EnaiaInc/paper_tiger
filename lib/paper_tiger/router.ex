defmodule PaperTiger.Router do
  @moduledoc """
  HTTP router for PaperTiger Stripe mock server.

  Handles all Stripe API endpoints with DRY macro-based routing.

  ## Plugs

  - `PaperTiger.Plugs.CORS` - Cross-origin requests
  - `PaperTiger.Plugs.Auth` - Verifies API key
  - `PaperTiger.Plugs.Idempotency` - Prevents duplicate requests
  - `PaperTiger.Plugs.UnflattenParams` - Converts card[number] to %{card: %{number: ...}}

  ## Endpoints

  ### Stripe API (v1)
  - `/v1/customers` - Customer management
  - `/v1/subscriptions` - Subscription management
  - `/v1/invoices` - Invoice management
  - etc. (28 total resource types)

  ### Config API (testing)
  - `POST /_config/webhooks` - Register webhook endpoint
  - `DELETE /_config/data` - Flush all data
  - `POST /_config/time/advance` - Advance time (manual mode)

  ## Resource Macro

  The `stripe_resource/3` macro generates standard CRUD routes:

      stripe_resource "customers", PaperTiger.Resources.Customer

  Generates:
  - POST   /v1/customers          -> Customer.create/1
  - GET    /v1/customers/:id      -> Customer.retrieve/2
  - POST   /v1/customers/:id      -> Customer.update/2
  - DELETE /v1/customers/:id      -> Customer.delete/2
  - GET    /v1/customers          -> Customer.list/1

  With :only / :except support:

      stripe_resource "tokens", PaperTiger.Resources.Token, only: [:create, :retrieve]
      stripe_resource "events", PaperTiger.Resources.Event, except: [:delete]
  """

  use Plug.Router

  import PaperTiger.Router.Macros

  alias PaperTiger.Plug.APIChaos
  alias PaperTiger.Plugs.Auth
  alias PaperTiger.Plugs.CORS
  alias PaperTiger.Plugs.GetFormBody
  alias PaperTiger.Plugs.Idempotency
  alias PaperTiger.Plugs.Sandbox
  alias PaperTiger.Plugs.UnflattenParams
  alias PaperTiger.Resources.ApplicationFee
  alias PaperTiger.Resources.BalanceTransaction
  alias PaperTiger.Resources.BankAccount
  alias PaperTiger.Resources.BillingPortalConfiguration
  alias PaperTiger.Resources.BillingPortalSession
  alias PaperTiger.Resources.Card
  alias PaperTiger.Resources.CashBalance
  alias PaperTiger.Resources.Charge
  alias PaperTiger.Resources.CheckoutSession
  alias PaperTiger.Resources.ConfirmationToken
  alias PaperTiger.Resources.Coupon
  alias PaperTiger.Resources.CreditNote
  alias PaperTiger.Resources.Customer
  alias PaperTiger.Resources.CustomerBalanceTransaction
  alias PaperTiger.Resources.CustomerSession
  alias PaperTiger.Resources.Dispute
  alias PaperTiger.Resources.Event
  alias PaperTiger.Resources.Invoice
  alias PaperTiger.Resources.InvoiceItem
  alias PaperTiger.Resources.Mandate
  alias PaperTiger.Resources.PaymentIntent
  alias PaperTiger.Resources.PaymentLink
  alias PaperTiger.Resources.PaymentMethod
  alias PaperTiger.Resources.PaymentMethodConfiguration
  alias PaperTiger.Resources.PaymentMethodDomain
  alias PaperTiger.Resources.Payout
  alias PaperTiger.Resources.Plan
  alias PaperTiger.Resources.Price
  alias PaperTiger.Resources.Product
  alias PaperTiger.Resources.PromotionCode
  alias PaperTiger.Resources.Refund
  alias PaperTiger.Resources.Review
  alias PaperTiger.Resources.SetupAttempt
  alias PaperTiger.Resources.SetupIntent
  alias PaperTiger.Resources.Source
  alias PaperTiger.Resources.Subscription
  alias PaperTiger.Resources.SubscriptionItem
  alias PaperTiger.Resources.SubscriptionSchedule
  alias PaperTiger.Resources.TaxRate
  alias PaperTiger.Resources.Token
  alias PaperTiger.Resources.Topup
  alias PaperTiger.Resources.Webhook

  # Plug pipeline
  plug(:match)
  plug(CORS)
  plug(Sandbox)
  plug(APIChaos)
  plug(GetFormBody)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Auth)
  plug(Idempotency)
  plug(UnflattenParams)
  plug(:dispatch)

  # Health check endpoint
  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{service: "paper_tiger", status: "ok"}))
  end

  ## Config API (for test orchestration)

  post "/_config/webhooks" do
    # Register webhook endpoint
    case conn.params do
      %{secret: secret, url: url} = params ->
        events = Map.get(params, :events)
        PaperTiger.register_webhook(url: url, secret: secret, events: events)

        send_resp(
          conn,
          200,
          Jason.encode!(%{message: "Webhook registered", success: true})
        )

      _invalid ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{
            error: %{message: "Missing url or secret", type: "invalid_request_error"}
          })
        )
    end
  end

  delete "/_config/data" do
    PaperTiger.flush()

    send_resp(
      conn,
      200,
      Jason.encode!(%{message: "All data flushed", success: true})
    )
  end

  post "/_config/time/advance" do
    case conn.params do
      %{seconds: seconds} when is_integer(seconds) ->
        PaperTiger.advance_time(seconds)

        send_resp(
          conn,
          200,
          Jason.encode!(%{now: PaperTiger.now(), success: true})
        )

      %{days: days} when is_integer(days) ->
        PaperTiger.advance_time(days: days)

        send_resp(
          conn,
          200,
          Jason.encode!(%{now: PaperTiger.now(), success: true})
        )

      _invalid ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{
            error: %{message: "Missing seconds or days parameter", type: "invalid_request_error"}
          })
        )
    end
  end

  ## Test API (for test orchestration)

  post "/_test/checkout/sessions/:id/complete" do
    CheckoutSession.complete(conn, id)
  end

  # Browser-accessible checkout completion endpoint.
  # When a checkout session URL is visited (via redirect), this auto-completes
  # the session and redirects to the success_url. This makes checkout flows
  # work transparently without special handling in application code.
  get "/checkout/:id/complete" do
    CheckoutSession.browser_complete(conn, id)
  end

  get "/payment_links/:id" do
    PaymentLink.browser_checkout(conn, id)
  end

  get "/payment_links/:id/complete" do
    PaymentLink.browser_complete(conn, id)
  end

  get "/billing_portal/sessions/:id" do
    BillingPortalSession.browser_enter(conn, id)
  end

  ## Resource Routes

  # Core resources (Phase 1)
  post "/v1/customer_sessions" do
    CustomerSession.create(conn)
  end

  get "/v1/customers/search" do
    Customer.search(conn)
  end

  post "/v1/customers/:customer_id/balance_transactions" do
    CustomerBalanceTransaction.create(conn, customer_id)
  end

  get "/v1/customers/:customer_id/balance_transactions/:id" do
    CustomerBalanceTransaction.retrieve(conn, customer_id, id)
  end

  post "/v1/customers/:customer_id/balance_transactions/:id" do
    CustomerBalanceTransaction.update(conn, customer_id, id)
  end

  get "/v1/customers/:customer_id/balance_transactions" do
    CustomerBalanceTransaction.list(conn, customer_id)
  end

  get "/v1/customers/:customer_id/cash_balance" do
    CashBalance.retrieve(conn, customer_id)
  end

  post "/v1/customers/:customer_id/cash_balance" do
    CashBalance.update(conn, customer_id)
  end

  stripe_resource("customers", Customer, [])

  get "/v1/subscriptions/search" do
    Subscription.search(conn)
  end

  stripe_resource("subscriptions", Subscription, [])
  stripe_resource("products", Product, [])
  stripe_resource("prices", Price, except: [:delete])

  post "/v1/billing_portal/sessions" do
    BillingPortalSession.create(conn)
  end

  stripe_resource("billing_portal/configurations", BillingPortalConfiguration, except: [:delete])

  get "/v1/payment_links/:id/line_items" do
    PaymentLink.line_items(conn, id)
  end

  stripe_resource("payment_links", PaymentLink, except: [:delete])

  # Custom invoice endpoints — must come BEFORE stripe_resource so they
  # match before the generic GET /v1/invoices/:id route.
  get "/v1/invoices/upcoming" do
    Invoice.upcoming(conn)
  end

  post "/v1/invoices/create_preview" do
    Invoice.create_preview(conn)
  end

  get "/v1/invoices/search" do
    Invoice.search(conn)
  end

  stripe_resource("invoices", Invoice, [])
  stripe_resource("payment_methods", PaymentMethod, [])
  stripe_resource("payment_method_domains", PaymentMethodDomain, except: [:delete])
  stripe_resource("payment_method_configurations", PaymentMethodConfiguration, except: [:delete])

  post "/v1/test_helpers/confirmation_tokens" do
    ConfirmationToken.create_test_helper(conn)
  end

  stripe_resource("confirmation_tokens", ConfirmationToken, only: [:retrieve])

  # Custom payment intent endpoints — must come BEFORE stripe_resource
  get "/v1/payment_intents/search" do
    PaymentIntent.search(conn)
  end

  post "/v1/payment_intents/:id/confirm" do
    PaymentIntent.confirm(conn, id)
  end

  post "/v1/payment_intents/:id/cancel" do
    PaymentIntent.cancel(conn, id)
  end

  post "/v1/payment_intents/:id/capture" do
    PaymentIntent.capture(conn, id)
  end

  stripe_resource("payment_intents", PaymentIntent, except: [:delete])
  stripe_resource("mandates", Mandate, only: [:retrieve])
  # Custom setup intent endpoints — must come BEFORE stripe_resource
  post "/v1/setup_intents/:id/confirm" do
    SetupIntent.confirm(conn, id)
  end

  post "/v1/setup_intents/:id/cancel" do
    SetupIntent.cancel(conn, id)
  end

  post "/v1/setup_intents/:id/verify_microdeposits" do
    SetupIntent.verify_microdeposits(conn, id)
  end

  stripe_resource("setup_intents", SetupIntent, except: [:delete])
  stripe_resource("setup_attempts", SetupAttempt, only: [:list])

  get "/v1/charges/search" do
    Charge.search(conn)
  end

  stripe_resource("charges", Charge, except: [:delete])
  stripe_resource("refunds", Refund, except: [:delete])
  stripe_resource("coupons", Coupon, [])
  stripe_resource("promotion_codes", PromotionCode, except: [:delete])
  stripe_resource("plans", Plan, [])
  stripe_resource("tax_rates", TaxRate, except: [:delete])
  stripe_resource("payouts", Payout, except: [:delete])
  stripe_resource("sources", Source, except: [:delete])
  stripe_resource("cards", Card, [])
  stripe_resource("bank_accounts", BankAccount, [])
  stripe_resource("subscription_items", SubscriptionItem, [])
  stripe_resource("subscription_schedules", SubscriptionSchedule, except: [:delete])
  stripe_resource("invoiceitems", InvoiceItem, [])
  stripe_resource("topups", Topup, except: [:delete])
  stripe_resource("balance_transactions", BalanceTransaction, only: [:retrieve, :list])
  stripe_resource("disputes", Dispute, only: [:retrieve, :update, :list])
  stripe_resource("application_fees", ApplicationFee, only: [:retrieve, :list])
  stripe_resource("reviews", Review, only: [:retrieve, :update, :list])
  stripe_resource("webhook_endpoints", Webhook, [])
  stripe_resource("events", Event, only: [:retrieve, :list])
  stripe_resource("tokens", Token, only: [:create, :retrieve])
  stripe_resource("checkout/sessions", CheckoutSession, only: [:create, :retrieve, :update, :list])

  get "/v1/credit_notes/preview/lines" do
    CreditNote.preview_lines(conn)
  end

  get "/v1/credit_notes/preview" do
    CreditNote.preview(conn)
  end

  get "/v1/credit_notes/:id/lines" do
    CreditNote.lines(conn, id)
  end

  post "/v1/credit_notes/:id/void" do
    CreditNote.void(conn, id)
  end

  stripe_resource("credit_notes", CreditNote, except: [:delete])

  ## Custom Checkout Session Endpoints

  get "/v1/checkout/sessions/:id/line_items" do
    CheckoutSession.line_items(conn, id)
  end

  post "/v1/checkout/sessions/:id/expire" do
    CheckoutSession.expire(conn, id)
  end

  ## Custom Subscription Endpoints

  post "/v1/subscriptions/:id/cancel" do
    Subscription.cancel(conn, id)
  end

  ## Custom Subscription Schedule Endpoints

  post "/v1/subscription_schedules/:id/cancel" do
    SubscriptionSchedule.cancel(conn, id)
  end

  post "/v1/subscription_schedules/:id/release" do
    SubscriptionSchedule.release(conn, id)
  end

  ## Custom Invoice Endpoints

  post "/v1/invoices/:id/finalize" do
    Invoice.finalize(conn, id)
  end

  post "/v1/invoices/:id/pay" do
    Invoice.pay(conn, id)
  end

  post "/v1/invoices/:id/void" do
    Invoice.void_invoice(conn, id)
  end

  post "/v1/invoices/:id/send" do
    Invoice.send_invoice(conn, id)
  end

  post "/v1/invoices/:id/mark_uncollectible" do
    Invoice.mark_uncollectible(conn, id)
  end

  post "/v1/invoices/:id/attach_payment" do
    Invoice.attach_payment(conn, id)
  end

  ## Custom PaymentMethod Endpoints

  post "/v1/payment_methods/:id/attach" do
    PaymentMethod.attach(conn, id)
  end

  post "/v1/payment_methods/:id/detach" do
    PaymentMethod.detach(conn, id)
  end

  # Fallback for unmatched routes
  match _ do
    send_resp(
      conn,
      404,
      Jason.encode!(%{
        error: %{
          message: "Unrecognized request URL (#{conn.method} #{conn.request_path}).",
          type: "invalid_request_error"
        }
      })
    )
  end
end

defmodule PaperTiger.BillingEngine do
  @moduledoc """
  Simulates Stripe's subscription billing lifecycle.

  The billing engine processes subscriptions whose `current_period_end` has passed,
  creating invoices, processing payments, and firing appropriate webhooks.

  ## Billing Modes

  Payment chaos is now managed by `PaperTiger.ChaosCoordinator`. Use:

      PaperTiger.ChaosCoordinator.configure(%{
        payment: %{
          failure_rate: 0.1,
          decline_codes: [:card_declined, :insufficient_funds],
          decline_weights: %{card_declined: 0.7, insufficient_funds: 0.3}
        }
      })

  Legacy `set_mode/2` API is still supported for backwards compatibility.

  ## Clock Integration

  The billing engine respects PaperTiger's clock modes:

  - `:real` - Polls every second for due subscriptions
  - `:accelerated` - Same polling, but time moves faster
  - `:manual` - Call `process_billing/0` after `advance_time/1`

  ## Usage

      # Process all due subscriptions immediately
      PaperTiger.BillingEngine.process_billing()

      # Simulate payment failure for a specific customer (delegates to ChaosCoordinator)
      PaperTiger.ChaosCoordinator.simulate_failure("cus_xxx", :card_declined)

      # Clear failure simulation
      PaperTiger.ChaosCoordinator.clear_simulation("cus_xxx")
  """

  use GenServer

  alias PaperTiger.ChaosCoordinator
  alias PaperTiger.Store.Charges
  alias PaperTiger.Store.Customers
  alias PaperTiger.Store.InvoiceItems
  alias PaperTiger.Store.Invoices
  alias PaperTiger.Store.PaymentIntents
  alias PaperTiger.Store.Plans
  alias PaperTiger.Store.Prices
  alias PaperTiger.Store.Subscriptions

  require Logger

  @poll_interval_ms 1_000

  ## Client API

  @doc """
  Starts the billing engine.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Processes all subscriptions that are due for billing.

  This is called automatically on each poll interval, but can also be
  called manually (useful in manual clock mode after advancing time).
  """
  @spec process_billing() :: {:ok, map()}
  def process_billing do
    GenServer.call(__MODULE__, :process_billing, 30_000)
  end

  @doc """
  Sets the billing mode (legacy API, delegates to ChaosCoordinator).

  ## Modes

  - `:happy_path` - All payments succeed
  - `:chaos` - Random failures based on configured rates

  ## Options (for chaos mode)

  - `:payment_failure_rate` - Probability of payment failure (0.0 - 1.0)
  - `:decline_codes` - List of decline codes to use randomly
  - `:decline_code_weights` - Map of decline code to weight for realistic distribution

  Prefer using `PaperTiger.ChaosCoordinator.configure/1` directly for new code.
  """
  @spec set_mode(atom(), keyword()) :: :ok
  def set_mode(mode, opts \\ [])

  def set_mode(:happy_path, _opts) do
    ChaosCoordinator.configure(%{payment: %{failure_rate: 0.0}})
  end

  def set_mode(:chaos, opts) do
    config = %{
      decline_codes: Keyword.get(opts, :decline_codes, ChaosCoordinator.default_decline_codes()),
      decline_weights: Keyword.get(opts, :decline_code_weights),
      failure_rate: Keyword.get(opts, :payment_failure_rate, 0.1)
    }

    ChaosCoordinator.configure(%{payment: config})
  end

  @doc """
  Gets the current billing mode (legacy API).

  Returns `:chaos` if payment failure rate > 0, otherwise `:happy_path`.
  """
  @spec get_mode() :: atom()
  def get_mode do
    config = ChaosCoordinator.get_config()
    failure_rate = get_in(config, [:payment, :failure_rate]) || 0.0

    if failure_rate > 0.0, do: :chaos, else: :happy_path
  end

  @doc """
  Simulates a payment failure for a specific customer (delegates to ChaosCoordinator).
  """
  @spec simulate_failure(String.t(), atom()) :: :ok
  def simulate_failure(customer_id, decline_code) do
    ChaosCoordinator.simulate_failure(customer_id, decline_code)
  end

  @doc """
  Clears any payment simulation for a customer (delegates to ChaosCoordinator).
  """
  @spec clear_simulation(String.t()) :: :ok
  def clear_simulation(customer_id) do
    ChaosCoordinator.clear_simulation(customer_id)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    auto_process = Application.get_env(:paper_tiger, :billing_auto_process, true)

    state = %{
      stats: %{invoices_created: 0, payments_failed: 0, payments_succeeded: 0}
    }

    if auto_process do
      schedule_poll()
    end

    Logger.info("PaperTiger.BillingEngine started")
    {:ok, state}
  end

  @impl true
  def handle_call(:process_billing, _from, state) do
    {stats, new_state} = do_process_billing(state)
    {:reply, {:ok, stats}, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_stats, new_state} = do_process_billing(state)
    schedule_poll()
    {:noreply, new_state}
  end

  ## Private Functions

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp do_process_billing(state) do
    now = PaperTiger.now()
    due_subscriptions = find_due_subscriptions(now)

    stats =
      Enum.reduce(due_subscriptions, %{failed: 0, processed: 0, succeeded: 0}, fn sub, acc ->
        case process_subscription(sub, state) do
          :ok ->
            %{acc | processed: acc.processed + 1, succeeded: acc.succeeded + 1}

          {:error, _reason} ->
            %{acc | failed: acc.failed + 1, processed: acc.processed + 1}
        end
      end)

    if stats.processed > 0 do
      Logger.info(
        "BillingEngine processed #{stats.processed} subscriptions: " <>
          "#{stats.succeeded} succeeded, #{stats.failed} failed"
      )
    end

    {stats, state}
  end

  defp find_due_subscriptions(now) do
    Subscriptions.find_active()
    |> Enum.filter(fn sub ->
      period_end = sub[:current_period_end] || sub["current_period_end"]
      period_end && period_end <= now
    end)
  end

  defp process_subscription(subscription, state) do
    customer_id = subscription[:customer] || subscription["customer"]

    with {:ok, customer} <- Customers.get(customer_id),
         {:ok, amount, currency} <- get_subscription_amount(subscription),
         {:ok, invoice} <- get_or_create_invoice(subscription, customer, amount, currency),
         {:ok, payment_result} <- attempt_payment(invoice, customer, state) do
      case payment_result do
        :succeeded ->
          finalize_successful_payment(invoice, subscription, amount)
          :ok

        {:failed, decline_code} ->
          handle_failed_payment(invoice, subscription, decline_code)
          {:error, decline_code}
      end
    else
      {:error, reason} ->
        Logger.warning("Failed to process subscription #{subscription.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_or_create_invoice(subscription, customer, amount, currency) do
    # Check if there's already an open invoice for this subscription
    case find_open_invoice_for_subscription(subscription.id) do
      {:ok, existing_invoice} ->
        {:ok, existing_invoice}

      :not_found ->
        create_subscription_invoice(subscription, customer, amount, currency)
    end
  end

  defp find_open_invoice_for_subscription(subscription_id) do
    %{data: invoices} = Invoices.list(%{limit: 100})

    case Enum.find(invoices, fn inv ->
           (inv[:subscription] == subscription_id or inv["subscription"] == subscription_id) and
             (inv[:status] == "open" or inv["status"] == "open")
         end) do
      nil -> :not_found
      invoice -> {:ok, invoice}
    end
  end

  defp get_subscription_amount(subscription) do
    items = subscription[:items] || subscription["items"] || %{}
    item_data = items[:data] || items["data"] || []

    case item_data do
      [first_item | _] -> get_price_amount(first_item[:price] || first_item["price"])
      [] -> get_amount_from_plan(subscription)
    end
  end

  defp get_amount_from_plan(subscription) do
    plan_id = subscription[:plan] || subscription["plan"]
    if plan_id, do: get_plan_amount(plan_id), else: {:error, :no_price_or_plan}
  end

  defp get_price_amount(price_id) when is_binary(price_id) do
    case Prices.get(price_id) do
      {:ok, price} ->
        {:ok, price[:unit_amount] || price["unit_amount"] || 0, price[:currency] || price["currency"] || "usd"}

      {:error, :not_found} ->
        {:error, :price_not_found}
    end
  end

  defp get_price_amount(%{} = price) do
    {:ok, price[:unit_amount] || price["unit_amount"] || 0, price[:currency] || price["currency"] || "usd"}
  end

  defp get_plan_amount(plan_id) when is_binary(plan_id) do
    case Plans.get(plan_id) do
      {:ok, plan} ->
        {:ok, plan[:amount] || plan["amount"] || 0, plan[:currency] || plan["currency"] || "usd"}

      {:error, :not_found} ->
        {:error, :plan_not_found}
    end
  end

  defp get_plan_amount(%{} = plan) do
    {:ok, plan[:amount] || plan["amount"] || 0, plan[:currency] || plan["currency"] || "usd"}
  end

  defp create_subscription_invoice(subscription, customer, amount, currency) do
    now = PaperTiger.now()
    invoice_id = PaperTiger.Resource.generate_id("in")

    invoice = %{
      amount_due: amount,
      amount_paid: 0,
      amount_remaining: amount,
      auto_advance: true,
      billing_reason: "subscription_cycle",
      collection_method: "charge_automatically",
      created: now,
      currency: currency,
      customer: customer.id,
      id: invoice_id,
      lines: %{data: [], has_more: false, object: "list", url: "/v1/invoices/#{invoice_id}/lines"},
      livemode: false,
      metadata: %{},
      object: "invoice",
      paid: false,
      period_end: subscription[:current_period_end] || now,
      period_start: subscription[:current_period_start] || now,
      status: "draft",
      subscription: subscription.id,
      subtotal: amount,
      total: amount
    }

    # Create invoice item
    invoice_item = %{
      amount: amount,
      created: now,
      currency: currency,
      customer: customer.id,
      description: "Subscription renewal",
      id: PaperTiger.Resource.generate_id("ii"),
      invoice: invoice_id,
      livemode: false,
      metadata: %{},
      object: "invoiceitem",
      subscription: subscription.id
    }

    {:ok, _item} = InvoiceItems.insert(invoice_item)
    {:ok, inv} = Invoices.insert(invoice)

    # Fire invoice.created event
    :telemetry.execute([:paper_tiger, :invoice, :created], %{}, %{object: inv})

    {:ok, inv}
  end

  defp attempt_payment(_invoice, customer, _state) do
    customer_id = customer.id

    case ChaosCoordinator.should_payment_fail?(customer_id) do
      {:ok, :succeed} -> {:ok, :succeeded}
      {:ok, {:fail, decline_code}} -> {:ok, {:failed, decline_code}}
    end
  end

  defp finalize_successful_payment(invoice, subscription, amount) do
    now = PaperTiger.now()

    # Create payment intent
    payment_intent = %{
      amount: amount,
      created: now,
      currency: invoice.currency,
      customer: invoice.customer,
      id: PaperTiger.Resource.generate_id("pi"),
      invoice: invoice.id,
      livemode: false,
      metadata: %{},
      object: "payment_intent",
      status: "succeeded"
    }

    {:ok, pi} = PaymentIntents.insert(payment_intent)
    :telemetry.execute([:paper_tiger, :payment_intent, :created], %{}, %{object: pi})
    :telemetry.execute([:paper_tiger, :payment_intent, :succeeded], %{}, %{object: pi})

    # Create charge
    charge = %{
      amount: amount,
      captured: true,
      created: now,
      currency: invoice.currency,
      customer: invoice.customer,
      id: PaperTiger.Resource.generate_id("ch"),
      invoice: invoice.id,
      livemode: false,
      metadata: %{},
      object: "charge",
      paid: true,
      payment_intent: pi.id,
      status: "succeeded"
    }

    {:ok, ch} = Charges.insert(charge)
    :telemetry.execute([:paper_tiger, :charge, :succeeded], %{}, %{object: ch})

    # Update invoice to paid
    paid_invoice =
      invoice
      |> Map.put(:status, "paid")
      |> Map.put(:amount_paid, amount)
      |> Map.put(:amount_remaining, 0)
      |> Map.put(:paid, true)

    {:ok, paid_inv} = Invoices.update(paid_invoice)
    :telemetry.execute([:paper_tiger, :invoice, :finalized], %{}, %{object: paid_inv})
    :telemetry.execute([:paper_tiger, :invoice, :paid], %{}, %{object: paid_inv})
    :telemetry.execute([:paper_tiger, :invoice, :payment_succeeded], %{}, %{object: paid_inv})

    # Advance subscription period
    advance_subscription_period(subscription)
  end

  defp handle_failed_payment(invoice, subscription, decline_code) do
    now = PaperTiger.now()

    # Create failed payment intent
    payment_intent = %{
      amount: invoice.amount_due,
      created: now,
      currency: invoice.currency,
      customer: invoice.customer,
      id: PaperTiger.Resource.generate_id("pi"),
      invoice: invoice.id,
      last_payment_error: %{
        code: to_string(decline_code),
        message: decline_code_message(decline_code),
        type: "card_error"
      },
      livemode: false,
      metadata: %{},
      object: "payment_intent",
      status: "requires_payment_method"
    }

    {:ok, pi} = PaymentIntents.insert(payment_intent)
    :telemetry.execute([:paper_tiger, :payment_intent, :created], %{}, %{object: pi})
    :telemetry.execute([:paper_tiger, :payment_intent, :payment_failed], %{}, %{object: pi})

    # Create failed charge
    charge = %{
      amount: invoice.amount_due,
      captured: false,
      created: now,
      currency: invoice.currency,
      customer: invoice.customer,
      failure_code: to_string(decline_code),
      failure_message: decline_code_message(decline_code),
      id: PaperTiger.Resource.generate_id("ch"),
      invoice: invoice.id,
      livemode: false,
      metadata: %{},
      object: "charge",
      paid: false,
      payment_intent: pi.id,
      status: "failed"
    }

    {:ok, ch} = Charges.insert(charge)
    :telemetry.execute([:paper_tiger, :charge, :failed], %{}, %{object: ch})

    # Update invoice
    attempt_count = (invoice[:attempt_count] || invoice["attempt_count"] || 0) + 1

    failed_invoice =
      invoice
      |> Map.put(:status, "open")
      |> Map.put(:attempt_count, attempt_count)
      |> Map.put(:next_payment_attempt, now + retry_delay(attempt_count))

    {:ok, failed_inv} = Invoices.update(failed_invoice)
    :telemetry.execute([:paper_tiger, :invoice, :payment_failed], %{}, %{object: failed_inv})

    # Update subscription status if too many failures
    if attempt_count >= 4 do
      mark_subscription_past_due(subscription)
    end
  end

  defp advance_subscription_period(subscription) do
    {interval, interval_count} = get_billing_interval(subscription)
    current_end = subscription[:current_period_end] || subscription["current_period_end"] || PaperTiger.now()
    new_end = calculate_next_period_end(current_end, interval, interval_count)

    updated =
      subscription
      |> Map.put(:current_period_start, current_end)
      |> Map.put(:current_period_end, new_end)

    {:ok, updated_sub} = Subscriptions.update(updated)
    :telemetry.execute([:paper_tiger, :subscription, :updated], %{}, %{object: updated_sub})
  end

  defp get_billing_interval(subscription) do
    plan = subscription[:plan] || subscription["plan"]
    extract_interval_from_plan(plan, subscription)
  end

  defp extract_interval_from_plan(%{} = plan_map, _subscription) do
    {
      plan_map[:interval] || plan_map["interval"] || "month",
      plan_map[:interval_count] || plan_map["interval_count"] || 1
    }
  end

  defp extract_interval_from_plan(plan_id, subscription) when is_binary(plan_id) do
    case Plans.get(plan_id) do
      {:ok, plan} -> extract_interval_from_plan(plan, subscription)
      _ -> {get_interval_from_items(subscription) || "month", 1}
    end
  end

  defp extract_interval_from_plan(_, subscription) do
    {get_interval_from_items(subscription) || "month", 1}
  end

  defp get_interval_from_items(subscription) do
    items = subscription[:items] || %{}
    item_data = items[:data] || []

    case item_data do
      [first | _] ->
        price = first[:price]

        if is_map(price) do
          recurring = price[:recurring] || %{}
          recurring[:interval]
        end

      _ ->
        nil
    end
  end

  defp calculate_next_period_end(current_end, interval, interval_count) do
    seconds =
      case interval do
        "day" -> 86_400 * interval_count
        "week" -> 604_800 * interval_count
        "month" -> 2_592_000 * interval_count
        "year" -> 31_536_000 * interval_count
        _ -> 2_592_000
      end

    current_end + seconds
  end

  defp mark_subscription_past_due(subscription) do
    updated = Map.put(subscription, :status, "past_due")
    {:ok, updated_sub} = Subscriptions.update(updated)
    :telemetry.execute([:paper_tiger, :subscription, :updated], %{}, %{object: updated_sub})
  end

  defp retry_delay(attempt_count) do
    # Stripe's smart retry schedule (approximate)
    case attempt_count do
      1 -> 86_400
      2 -> 259_200
      3 -> 432_000
      _ -> 604_800
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp decline_code_message(code) do
    case code do
      # Default codes
      :card_declined -> "Your card was declined."
      :insufficient_funds -> "Your card has insufficient funds."
      :expired_card -> "Your card has expired."
      :processing_error -> "An error occurred while processing your card."
      # Card Issues
      :do_not_honor -> "Your card was declined."
      :lost_card -> "Your card has been reported lost."
      :stolen_card -> "Your card has been reported stolen."
      :card_not_supported -> "Your card type is not supported."
      :currency_not_supported -> "Your card does not support this currency."
      :duplicate_transaction -> "A duplicate transaction was detected."
      # Fraud
      :fraudulent -> "Your card was declined due to suspected fraud."
      :merchant_blacklist -> "Your card cannot be used with this merchant."
      :security_violation -> "A security violation was detected."
      :pickup_card -> "Your card has been declined. Please contact your card issuer."
      # Limits
      :card_velocity_exceeded -> "Your card has exceeded its velocity limit."
      :withdrawal_count_limit_exceeded -> "Your card has exceeded its withdrawal limit."
      # Authentication
      :authentication_required -> "Authentication is required for this payment."
      :incorrect_cvc -> "The card security code is incorrect."
      :incorrect_zip -> "The postal code is incorrect."
      # Generic
      :generic_decline -> "Your card was declined."
      :try_again_later -> "Your card was declined. Please try again later."
      :issuer_not_available -> "Your card issuer is currently unavailable."
      _ -> "Your card was declined."
    end
  end
end

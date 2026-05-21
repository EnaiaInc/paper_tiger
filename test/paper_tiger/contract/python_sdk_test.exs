defmodule PaperTiger.Contract.PythonSdkTest do
  @moduledoc """
  Drives the **official Python `stripe` SDK** against PaperTiger over
  real HTTP and asserts the SDK is satisfied with PaperTiger's wire
  shape across the closed FR surface.

  Orthogonal to the existing `TestClient` contract suite, which goes
  through `stripity_stripe`. Any `stripity_stripe`-side quirk (HTTP/2
  negotiation, header casing, form encoding) is filtered out here, so a
  failure points unambiguously at PaperTiger.

  Excluded by default. Opt in with:

      VALIDATE_PYTHON_SDK=true mix test test/paper_tiger/contract/python_sdk_test.exs

  Requires Python 3.12+ on PATH and a working C toolchain (for the
  `erlang_python` NIF). The venv at `_build/test/python_sdk_venv/` is
  created and `stripe` pip-installed on first run, then cached.

  ## Conventions

    * Multi-statement Python (`import`, assignments) runs through
      `:py.exec/1`.
    * Each assertion-bearing call uses `:py.eval/2` with a single
      expression and a `Locals` map for dynamic values.
    * The `stripe` module and the `_d/1` recursive-dict helper are
      imported once per test process in `setup/1` and persist across
      `:py.eval` calls in that process (per-process Python state per
      `erlang_python` README § Process-Bound Environments).
    * Most expressions are wrapped in `_d(...)` so the returned shape
      is a plain recursive dict for Elixir-side assertion.
  """

  use ExUnit.Case, async: false

  alias PaperTiger.PythonSdkSetup

  @moduletag :python_sdk

  setup_all do
    port = PythonSdkSetup.start_router!()
    _ = PythonSdkSetup.ensure_venv!()
    {:ok, port: port}
  end

  setup %{port: port} do
    PythonSdkSetup.configure_stripe_sdk!(port)
    :ok
  end

  ## Helpers ##
  defp uniq, do: System.unique_integer([:positive])
  defp uniq_email(label), do: "py-sdk-#{label}-#{uniq()}@example.com"

  defp eval!(code, locals) do
    {:ok, result} = PythonSdkSetup.eval(code, locals)
    result
  end

  defp create_customer(opts \\ %{}) do
    email = Map.get_lazy(opts, :email, fn -> uniq_email("c") end)

    eval!(
      ~s|_d(stripe.Customer.create(email=email, name=name, metadata={"py_sdk": "true"}))|,
      %{email: email, name: Map.get(opts, :name, "PT SDK Test")}
    )
  end

  defp create_product(name \\ nil) do
    name = name || "PT SDK Product #{uniq()}"
    eval!(~s|_d(stripe.Product.create(name=name))|, %{name: name})
  end

  defp create_price(product_id, opts \\ %{}) do
    eval!(
      ~s|_d(stripe.Price.create(product=pid, currency=currency, unit_amount=amount, recurring=recurring))|,
      %{
        amount: Map.get(opts, :amount, 1500),
        currency: Map.get(opts, :currency, "usd"),
        pid: product_id,
        recurring: Map.get(opts, :recurring, %{"interval" => "month"})
      }
    )
  end

  ## Customer ##

  describe "Customer lifecycle through stripe-python" do
    test "create / retrieve / update / delete round-trips via the official SDK" do
      created = create_customer(%{name: "PaperTiger Python SDK Test"})

      assert created["object"] == "customer"
      assert is_binary(created["id"])
      assert String.starts_with?(created["id"], "cus_")
      assert created["name"] == "PaperTiger Python SDK Test"
      assert created["metadata"]["py_sdk"] == "true"
      cid = created["id"]

      retrieved = eval!("_d(stripe.Customer.retrieve(cid))", %{cid: cid})
      assert retrieved["id"] == cid
      assert retrieved["email"] == created["email"]

      updated =
        eval!(
          ~s|_d(stripe.Customer.modify(cid, name="updated", metadata={"py_sdk": "true", "phase": "updated"}))|,
          %{cid: cid}
        )

      assert updated["name"] == "updated"
      assert updated["metadata"]["phase"] == "updated"

      deleted = eval!("_d(stripe.Customer.delete(cid))", %{cid: cid})
      assert deleted["id"] == cid
      assert deleted["deleted"] == true
    end

    test "list with limit returns paginated shape the SDK can iterate" do
      for _ <- 1..3, do: create_customer()

      page = eval!("_d(stripe.Customer.list(limit=2))", %{})
      assert page["object"] == "list"
      assert is_list(page["data"])
      assert length(page["data"]) <= 2
      assert is_boolean(page["has_more"])
    end
  end

  ## Product + Price (list filters from FR #90) ##

  describe "Product + Price list filters" do
    test "Price.list(product=...) filters by product and supports expand=data.product" do
      product = create_product()
      _p1 = create_price(product["id"], %{amount: 1000})
      _p2 = create_price(product["id"], %{amount: 2000})

      other_product = create_product()
      _other = create_price(other_product["id"], %{amount: 500})

      filtered =
        eval!(
          ~s|_d(stripe.Price.list(product=pid, expand=["data.product"]))|,
          %{pid: product["id"]}
        )

      assert filtered["object"] == "list"
      assert length(filtered["data"]) == 2

      for price <- filtered["data"] do
        assert price["product"]["id"] == product["id"]
        assert price["product"]["object"] == "product"
      end
    end

    test "Product.list(active=false) filters by active flag" do
      p_active = create_product()

      p_inactive = create_product()

      _ =
        eval!(
          ~s|_d(stripe.Product.modify(pid, active=False))|,
          %{pid: p_inactive["id"]}
        )

      inactive = eval!(~s|_d(stripe.Product.list(active=False, limit=100))|, %{})
      ids = Enum.map(inactive["data"], & &1["id"])
      assert p_inactive["id"] in ids
      refute p_active["id"] in ids
    end
  end

  ## PaymentMethod ##

  describe "PaymentMethod attach + list filter" do
    test "attach two PMs to a customer; list filtered by customer returns only theirs" do
      customer = create_customer()

      pm1 =
        eval!(
          ~s|_d(stripe.PaymentMethod.attach("pm_card_visa", customer=cid))|,
          %{cid: customer["id"]}
        )

      pm2 =
        eval!(
          ~s|_d(stripe.PaymentMethod.attach("pm_card_mastercard", customer=cid))|,
          %{cid: customer["id"]}
        )

      other = create_customer()

      _other_pm =
        eval!(
          ~s|_d(stripe.PaymentMethod.attach("pm_card_amex", customer=cid))|,
          %{cid: other["id"]}
        )

      assert pm1["id"] != "pm_card_visa"
      assert pm2["id"] != "pm_card_mastercard"
      assert pm1["id"] != pm2["id"]

      result =
        eval!(
          ~s|_d(stripe.PaymentMethod.list(customer=cid))|,
          %{cid: customer["id"]}
        )

      assert length(result["data"]) == 2
      assert Enum.all?(result["data"], &(&1["customer"] == customer["id"]))
    end

    test "same pm_card token can attach to multiple customers as distinct payment methods" do
      customer1 = create_customer()
      customer2 = create_customer()

      pm1 =
        eval!(
          ~s|_d(stripe.PaymentMethod.attach("pm_card_visa", customer=cid))|,
          %{cid: customer1["id"]}
        )

      pm2 =
        eval!(
          ~s|_d(stripe.PaymentMethod.attach("pm_card_visa", customer=cid))|,
          %{cid: customer2["id"]}
        )

      assert pm1["id"] != pm2["id"]
      assert pm1["customer"] == customer1["id"]
      assert pm2["customer"] == customer2["id"]
      assert pm1["card"]["last4"] == "4242"
      assert pm2["card"]["last4"] == "4242"
    end
  end

  ## PaymentIntent ##

  describe "PaymentIntent — automatic capture (FR #58)" do
    test "create + confirm produces succeeded PI with latest_charge populated" do
      customer = create_customer()

      pi =
        eval!(
          ~s|_d(stripe.PaymentIntent.create(amount=2500, currency="usd", customer=cid, payment_method="pm_card_visa", payment_method_types=["card"]))|,
          %{cid: customer["id"]}
        )

      assert pi["status"] == "requires_confirmation"
      assert pi["amount"] == 2500
      assert pi["amount_received"] == 0

      confirmed = eval!("_d(stripe.PaymentIntent.confirm(pi_id))", %{pi_id: pi["id"]})

      assert confirmed["status"] == "succeeded"
      assert confirmed["amount_received"] == 2500
      assert confirmed["amount_capturable"] == 0
      assert is_binary(confirmed["latest_charge"])

      charge = eval!("_d(stripe.Charge.retrieve(ch_id))", %{ch_id: confirmed["latest_charge"]})
      assert charge["status"] == "succeeded"
      assert charge["captured"] == true
      assert charge["amount_captured"] == 2500
    end
  end

  describe "PaymentIntent — manual capture (FR #76)" do
    test "confirm with capture_method=manual yields requires_capture and uncaptured Charge" do
      customer = create_customer()

      pi =
        eval!(
          ~s|_d(stripe.PaymentIntent.create(amount=5000, currency="usd", capture_method="manual", customer=cid, payment_method="pm_card_visa", payment_method_types=["card"]))|,
          %{cid: customer["id"]}
        )

      confirmed = eval!("_d(stripe.PaymentIntent.confirm(pid))", %{pid: pi["id"]})
      assert confirmed["status"] == "requires_capture"
      assert confirmed["amount_capturable"] == 5000
      assert confirmed["amount_received"] == 0
      assert is_binary(confirmed["latest_charge"])

      charge =
        eval!("_d(stripe.Charge.retrieve(ch_id))", %{ch_id: confirmed["latest_charge"]})

      assert charge["captured"] == false
      assert charge["amount_captured"] == 0
    end

    test "full capture flips PI to succeeded and Charge.captured=true" do
      pi = manual_authorize(5000)

      captured = eval!("_d(stripe.PaymentIntent.capture(pid))", %{pid: pi["id"]})

      assert captured["status"] == "succeeded"
      assert captured["amount_capturable"] == 0
      assert captured["amount_received"] == 5000

      ch = eval!("_d(stripe.Charge.retrieve(ch_id))", %{ch_id: captured["latest_charge"]})
      assert ch["captured"] == true
      assert ch["amount_captured"] == 5000
    end

    test "final partial capture releases the remainder" do
      pi = manual_authorize(5000)

      captured =
        eval!(
          "_d(stripe.PaymentIntent.capture(pid, amount_to_capture=1800))",
          %{pid: pi["id"]}
        )

      assert captured["status"] == "succeeded"
      assert captured["amount_capturable"] == 0
      assert captured["amount_received"] == 1800

      ch = eval!("_d(stripe.Charge.retrieve(ch_id))", %{ch_id: captured["latest_charge"]})
      assert ch["amount_captured"] == 1800
    end

    test "non-final partial capture then final capture accumulates correctly" do
      pi = manual_authorize(5000)

      partial =
        eval!(
          "_d(stripe.PaymentIntent.capture(pid, amount_to_capture=1800, final_capture=False))",
          %{pid: pi["id"]}
        )

      assert partial["status"] == "requires_capture"
      assert partial["amount_capturable"] == 3200
      assert partial["amount_received"] == 1800

      final = eval!("_d(stripe.PaymentIntent.capture(pid))", %{pid: pi["id"]})

      assert final["status"] == "succeeded"
      assert final["amount_capturable"] == 0
      assert final["amount_received"] == 5000

      ch = eval!("_d(stripe.Charge.retrieve(ch_id))", %{ch_id: final["latest_charge"]})
      assert ch["amount_captured"] == 5000
    end

    test "cancel from requires_payment_method transitions to canceled" do
      pi =
        eval!(
          ~s|_d(stripe.PaymentIntent.create(amount=1200, currency="usd"))|,
          %{}
        )

      canceled =
        eval!(
          ~s|_d(stripe.PaymentIntent.cancel(pid, cancellation_reason="requested_by_customer"))|,
          %{pid: pi["id"]}
        )

      assert canceled["status"] == "canceled"
      assert canceled["cancellation_reason"] == "requested_by_customer"
      assert is_integer(canceled["canceled_at"])
    end
  end

  defp manual_authorize(amount) do
    customer = create_customer()

    pi =
      eval!(
        ~s|_d(stripe.PaymentIntent.create(amount=amt, currency="usd", capture_method="manual", customer=cid, payment_method="pm_card_visa", payment_method_types=["card"]))|,
        %{amt: amount, cid: customer["id"]}
      )

    eval!("_d(stripe.PaymentIntent.confirm(pid))", %{pid: pi["id"]})
  end

  ## SetupIntent (FR #78) ##

  describe "SetupIntent lifecycle through stripe-python" do
    test "confirm with a card PM transitions to succeeded" do
      customer = create_customer()

      si =
        eval!(
          ~s|_d(stripe.SetupIntent.create(customer=cid, payment_method="pm_card_visa", payment_method_types=["card"]))|,
          %{cid: customer["id"]}
        )

      assert si["status"] == "requires_confirmation"

      confirmed = eval!("_d(stripe.SetupIntent.confirm(sid))", %{sid: si["id"]})
      assert confirmed["status"] == "succeeded"
      assert is_binary(confirmed["payment_method"])
      assert confirmed["payment_method"] != "pm_card_visa"
    end

    test "cancel transitions a non-terminal SI to canceled" do
      si = eval!("_d(stripe.SetupIntent.create())", %{})
      assert si["status"] == "requires_payment_method"

      canceled =
        eval!(
          ~s|_d(stripe.SetupIntent.cancel(sid, cancellation_reason="requested_by_customer"))|,
          %{sid: si["id"]}
        )

      assert canceled["status"] == "canceled"
      assert canceled["cancellation_reason"] == "requested_by_customer"
    end
  end

  ## Subscription (FR #58 + FR #79 search) ##

  describe "Subscription create + cancel through stripe-python" do
    test "subscription items[].price is the full price object, not just an id" do
      customer = create_customer()
      product = create_product()
      price = create_price(product["id"], %{amount: 1500})

      sub =
        eval!(
          ~s|_d(stripe.Subscription.create(customer=cid, items=[{"price": pid}], payment_behavior="allow_incomplete"))|,
          %{cid: customer["id"], pid: price["id"]}
        )

      assert sub["object"] == "subscription"
      item = Enum.at(sub["items"]["data"], 0)
      assert is_map(item["price"])
      assert item["price"]["id"] == price["id"]
      assert item["price"]["unit_amount"] == 1500
    end

    test "subscription cancel transitions to canceled" do
      customer = create_customer()
      product = create_product()
      price = create_price(product["id"])

      sub =
        eval!(
          ~s|_d(stripe.Subscription.create(customer=cid, items=[{"price": pid}], payment_behavior="allow_incomplete"))|,
          %{cid: customer["id"], pid: price["id"]}
        )

      canceled = eval!("_d(stripe.Subscription.cancel(sid))", %{sid: sub["id"]})
      assert canceled["status"] == "canceled"
    end
  end

  ## Invoice lifecycle (FR #81) ##

  describe "Invoice lifecycle through stripe-python" do
    test "draft → finalize → mark_uncollectible round-trips" do
      customer = create_customer()

      _ =
        eval!(
          ~s|_d(stripe.InvoiceItem.create(customer=cid, amount=2400, currency="usd"))|,
          %{cid: customer["id"]}
        )

      draft =
        eval!(
          ~s|_d(stripe.Invoice.create(customer=cid, collection_method="send_invoice", days_until_due=30, auto_advance=False))|,
          %{cid: customer["id"]}
        )

      assert draft["status"] == "draft"

      finalized = eval!("_d(stripe.Invoice.finalize_invoice(iid))", %{iid: draft["id"]})
      assert finalized["status"] == "open"

      sent = eval!("_d(stripe.Invoice.send_invoice(iid))", %{iid: draft["id"]})
      assert sent["status"] == "open"

      uncollectible =
        eval!("_d(stripe.Invoice.mark_uncollectible(iid))", %{iid: draft["id"]})

      assert uncollectible["status"] == "uncollectible"
    end

    test "list(status='draft') filters correctly" do
      customer = create_customer()

      _ =
        eval!(
          ~s|_d(stripe.InvoiceItem.create(customer=cid, amount=500, currency="usd"))|,
          %{cid: customer["id"]}
        )

      draft =
        eval!(
          ~s|_d(stripe.Invoice.create(customer=cid, auto_advance=False))|,
          %{cid: customer["id"]}
        )

      page =
        eval!(
          ~s|_d(stripe.Invoice.list(customer=cid, status="draft"))|,
          %{cid: customer["id"]}
        )

      ids = Enum.map(page["data"], & &1["id"])
      assert draft["id"] in ids
      assert Enum.all?(page["data"], &(&1["status"] == "draft"))
    end
  end

  ## Refund (FR #90 fidelity tightening) ##

  describe "Refund creation through stripe-python" do
    test "partial then full refund accumulates and flips charge.refunded=true" do
      ch = create_succeeded_charge(2_000)

      partial =
        eval!(
          ~s|_d(stripe.Refund.create(charge=cid, amount=600))|,
          %{cid: ch["id"]}
        )

      assert partial["amount"] == 600
      assert partial["object"] == "refund"

      after_partial = eval!("_d(stripe.Charge.retrieve(cid))", %{cid: ch["id"]})
      assert after_partial["amount_refunded"] == 600
      assert after_partial["refunded"] == false

      full = eval!("_d(stripe.Refund.create(charge=cid))", %{cid: ch["id"]})
      assert full["amount"] == 1_400

      after_full = eval!("_d(stripe.Charge.retrieve(cid))", %{cid: ch["id"]})
      assert after_full["amount_refunded"] == 2_000
      assert after_full["refunded"] == true
    end

    test "over-refund raises stripe.error.InvalidRequestError" do
      ch = create_succeeded_charge(2_000)

      assert {:error, {:InvalidRequestError, _msg}} =
               PythonSdkSetup.eval(
                 ~s|_d(stripe.Refund.create(charge=cid, amount=3_000))|,
                 %{cid: ch["id"]}
               )
    end

    test "Refund.list(charge=...) returns only refunds for that charge" do
      ch1 = create_succeeded_charge(1_000)
      ch2 = create_succeeded_charge(1_000)

      _ = eval!("_d(stripe.Refund.create(charge=cid, amount=200))", %{cid: ch1["id"]})
      _ = eval!("_d(stripe.Refund.create(charge=cid, amount=300))", %{cid: ch2["id"]})

      page = eval!("_d(stripe.Refund.list(charge=cid))", %{cid: ch1["id"]})
      assert Enum.all?(page["data"], &(&1["charge"] == ch1["id"]))
    end
  end

  defp create_succeeded_charge(amount) do
    customer = create_customer()

    pi =
      eval!(
        ~s|_d(stripe.PaymentIntent.create(amount=amt, currency="usd", customer=cid, payment_method="pm_card_visa", payment_method_types=["card"]))|,
        %{amt: amount, cid: customer["id"]}
      )

    confirmed = eval!("_d(stripe.PaymentIntent.confirm(pid))", %{pid: pi["id"]})
    eval!("_d(stripe.Charge.retrieve(ch_id))", %{ch_id: confirmed["latest_charge"]})
  end

  ## Search (FR #79) ##

  describe "Search endpoints through stripe-python" do
    test "Customer.search by metadata predicate finds the right customer" do
      tag = "py-sdk-search-#{uniq()}"

      target =
        eval!(
          ~s|_d(stripe.Customer.create(email=email, metadata={"search_tag": tag}))|,
          %{email: uniq_email("s"), tag: tag}
        )

      _other = create_customer()

      # Search results in stripe-python are returned as ListObject with
      # `data` array. Some endpoints have eventual-consistency delay in
      # real Stripe; for paper_tiger they're synchronous so a single
      # query should return immediately.
      result =
        eval!(
          ~s|_d(stripe.Customer.search(query=f"metadata['search_tag']:'{tag}'"))|,
          %{tag: tag}
        )

      ids = Enum.map(result["data"], & &1["id"])
      assert target["id"] in ids
    end
  end

  ## ConfirmationToken (FR #80) ##

  describe "ConfirmationToken through stripe-python" do
    test "create test-helper ConfirmationToken and retrieve it" do
      ct =
        eval!(
          ~s|_d(stripe.ConfirmationToken.TestHelpers.create(payment_method="pm_card_visa"))|,
          %{}
        )

      assert ct["object"] == "confirmation_token"
      assert is_binary(ct["id"])

      retrieved = eval!("_d(stripe.ConfirmationToken.retrieve(ctid))", %{ctid: ct["id"]})
      assert retrieved["id"] == ct["id"]
    end
  end

  ## CustomerSession (FR #80) ##

  describe "CustomerSession through stripe-python" do
    test "create CustomerSession returns a client_secret" do
      customer = create_customer()

      session =
        eval!(
          ~s|_d(stripe.CustomerSession.create(customer=cid, components={"buy_button": {"enabled": True}}))|,
          %{cid: customer["id"]}
        )

      assert session["object"] == "customer_session"
      assert session["customer"] == customer["id"]
      assert is_binary(session["client_secret"])
    end
  end

  ## PaymentMethodDomain + PaymentMethodConfiguration (FR #80) ##

  describe "PaymentMethodDomain through stripe-python" do
    test "create + retrieve + list" do
      domain = "pt-sdk-#{uniq()}.example.com"

      created =
        eval!(
          ~s|_d(stripe.PaymentMethodDomain.create(domain_name=domain))|,
          %{domain: domain}
        )

      assert created["object"] == "payment_method_domain"
      assert created["domain_name"] == domain

      retrieved =
        eval!("_d(stripe.PaymentMethodDomain.retrieve(did))", %{did: created["id"]})

      assert retrieved["id"] == created["id"]

      page = eval!("_d(stripe.PaymentMethodDomain.list(limit=10))", %{})
      assert page["object"] == "list"
    end
  end

  describe "PaymentMethodConfiguration through stripe-python" do
    test "create + retrieve + list" do
      created =
        eval!(
          ~s|_d(stripe.PaymentMethodConfiguration.create(name=name, card={"display_preference": {"preference": "on"}}))|,
          %{name: "PT SDK PMC #{uniq()}"}
        )

      assert created["object"] == "payment_method_configuration"
      assert is_binary(created["id"])

      retrieved =
        eval!(
          "_d(stripe.PaymentMethodConfiguration.retrieve(pid))",
          %{pid: created["id"]}
        )

      assert retrieved["id"] == created["id"]
    end
  end

  ## Connect (FR #84) ##

  describe "Connect — Account + AccountLink through stripe-python" do
    test "Account.create + retrieve" do
      account =
        eval!(
          ~s|_d(stripe.Account.create(type="standard", email=email))|,
          %{email: uniq_email("acct")}
        )

      assert account["object"] == "account"
      assert is_binary(account["id"])
      assert String.starts_with?(account["id"], "acct_")

      retrieved = eval!("_d(stripe.Account.retrieve(aid))", %{aid: account["id"]})
      assert retrieved["id"] == account["id"]
    end

    test "AccountLink.create produces a URL" do
      account =
        eval!(
          ~s|_d(stripe.Account.create(type="standard"))|,
          %{}
        )

      link =
        eval!(
          ~s|_d(stripe.AccountLink.create(account=aid, refresh_url="https://example.com/r", return_url="https://example.com/x", type="account_onboarding"))|,
          %{aid: account["id"]}
        )

      assert link["object"] == "account_link"
      assert is_binary(link["url"])
    end
  end

  describe "Connect — Transfer + Reversal through stripe-python" do
    test "Transfer.create + Transfer.create_reversal (nested)" do
      account = eval!(~s|_d(stripe.Account.create(type="custom"))|, %{})

      transfer =
        eval!(
          ~s|_d(stripe.Transfer.create(amount=1000, currency="usd", destination=aid))|,
          %{aid: account["id"]}
        )

      assert transfer["object"] == "transfer"
      assert transfer["amount"] == 1000
      assert transfer["destination"] == account["id"]

      reversal =
        eval!(
          ~s|_d(stripe.Transfer.create_reversal(tid, amount=400))|,
          %{tid: transfer["id"]}
        )

      assert reversal["object"] == "transfer_reversal"
      assert reversal["amount"] == 400
    end
  end

  describe "Connect — Stripe-Account header request scoping" do
    test "Customer created with stripe_account isolates per-account storage" do
      account = eval!(~s|_d(stripe.Account.create(type="standard"))|, %{})

      platform_customer = create_customer()

      connected_customer =
        eval!(
          ~s|_d(stripe.Customer.create(email=email, stripe_account=aid))|,
          %{aid: account["id"], email: uniq_email("conn")}
        )

      # Platform-scope list should NOT see the connected-account customer
      platform_page =
        eval!(~s|_d(stripe.Customer.list(limit=100))|, %{})

      platform_ids = Enum.map(platform_page["data"], & &1["id"])
      assert platform_customer["id"] in platform_ids
      refute connected_customer["id"] in platform_ids

      # Connected-account scope SHOULD see it
      connected_page =
        eval!(
          ~s|_d(stripe.Customer.list(limit=100, stripe_account=aid))|,
          %{aid: account["id"]}
        )

      connected_ids = Enum.map(connected_page["data"], & &1["id"])
      assert connected_customer["id"] in connected_ids
      refute platform_customer["id"] in connected_ids
    end
  end

  ## Error handling ##

  describe "Error handling through stripe-python" do
    test "retrieving a missing customer raises stripe.error.InvalidRequestError" do
      result =
        PythonSdkSetup.eval(
          ~s|_d(stripe.Customer.retrieve("cus_does_not_exist_#{uniq()}"))|,
          %{}
        )

      assert {:error, {:InvalidRequestError, _msg}} = result
    end

    test "invalid PI cancel from succeeded state raises InvalidRequestError" do
      ch_amount = 2_000
      ch = create_succeeded_charge(ch_amount)
      pi_id = ch["payment_intent"]

      result =
        PythonSdkSetup.eval(
          ~s|_d(stripe.PaymentIntent.cancel(pid))|,
          %{pid: pi_id}
        )

      assert {:error, {:InvalidRequestError, _msg}} = result
    end
  end
end

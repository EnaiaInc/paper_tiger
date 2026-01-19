defmodule PaperTiger.TestTokens do
  @moduledoc """
  Pre-defined Stripe test tokens that are always available in PaperTiger.

  Stripe provides special test tokens like `pm_card_visa` and `tok_visa` that work
  without creating payment methods from card details. PaperTiger must provide these
  same tokens so that library users don't have to change their code when switching
  between real Stripe and PaperTiger.

  ## Supported Payment Method Tokens (pm_card_*)

  ### By Card Brand
  - `pm_card_visa` - Visa (4242424242424242)
  - `pm_card_visa_debit` - Visa Debit
  - `pm_card_mastercard` - Mastercard (5555555555554444)
  - `pm_card_mastercard_debit` - Mastercard Debit
  - `pm_card_mastercard_prepaid` - Mastercard Prepaid
  - `pm_card_amex` - American Express (378282246310005)
  - `pm_card_discover` - Discover (6011111111111117)
  - `pm_card_diners` - Diners Club (3056930009020004)
  - `pm_card_jcb` - JCB (3566002020360505)
  - `pm_card_unionpay` - UnionPay (6200000000000005)

  ### Special Behavior Cards
  - `pm_card_chargeDeclined` - Always declines
  - `pm_card_chargeDeclinedInsufficientFunds` - Declines with insufficient funds
  - `pm_card_chargeDeclinedFraudulent` - Declines as fraudulent

  ## Supported Token Tokens (tok_*)

  - `tok_visa`, `tok_mastercard`, `tok_amex`, etc. (same brands as pm_card_*)

  ## Usage

  These tokens are automatically loaded when PaperTiger starts.
  """

  alias PaperTiger.Store.PaymentMethods
  alias PaperTiger.Store.Tokens

  require Logger

  # Card brand configurations
  @card_brands %{
    "amex" => %{
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_amex_fingerprint",
      funding: "credit",
      last4: "0005"
    },
    "diners" => %{
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_diners_fingerprint",
      funding: "credit",
      last4: "0004"
    },
    "discover" => %{
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_discover_fingerprint",
      funding: "credit",
      last4: "1117"
    },
    "jcb" => %{
      country: "JP",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_jcb_fingerprint",
      funding: "credit",
      last4: "0505"
    },
    "mastercard" => %{
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_mastercard_fingerprint",
      funding: "credit",
      last4: "4444"
    },
    "mastercard_debit" => %{
      brand: "mastercard",
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_mastercard_debit_fingerprint",
      funding: "debit",
      last4: "0000"
    },
    "mastercard_prepaid" => %{
      brand: "mastercard",
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_mastercard_prepaid_fingerprint",
      funding: "prepaid",
      last4: "5100"
    },
    "unionpay" => %{
      country: "CN",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_unionpay_fingerprint",
      funding: "credit",
      last4: "0005"
    },
    "visa" => %{
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_visa_fingerprint",
      funding: "credit",
      last4: "4242"
    },
    "visa_debit" => %{
      brand: "visa",
      country: "US",
      exp_month: 12,
      exp_year: 2030,
      fingerprint: "pm_card_visa_debit_fingerprint",
      funding: "debit",
      last4: "5556"
    }
  }

  # Special decline cards
  @decline_cards %{
    "chargeDeclined" => %{
      brand: "visa",
      decline_code: "generic_decline",
      last4: "0002"
    },
    "chargeDeclinedExpiredCard" => %{
      brand: "visa",
      decline_code: "expired_card",
      last4: "0069"
    },
    "chargeDeclinedFraudulent" => %{
      brand: "visa",
      decline_code: "fraudulent",
      last4: "0019"
    },
    "chargeDeclinedIncorrectCvc" => %{
      brand: "visa",
      decline_code: "incorrect_cvc",
      last4: "0127"
    },
    "chargeDeclinedInsufficientFunds" => %{
      brand: "visa",
      decline_code: "insufficient_funds",
      last4: "9995"
    },
    "chargeDeclinedProcessingError" => %{
      brand: "visa",
      decline_code: "processing_error",
      last4: "0119"
    }
  }

  @doc """
  Loads all pre-defined test tokens into PaperTiger stores.

  Called automatically on PaperTiger startup.
  Returns `{:ok, stats}` with counts of loaded tokens.
  """
  @spec load() :: {:ok, map()}
  def load do
    pm_count = load_payment_methods()
    tok_count = load_tokens()

    stats = %{payment_methods: pm_count, tokens: tok_count}

    if pm_count > 0 or tok_count > 0 do
      Logger.debug("PaperTiger loaded #{pm_count} test payment methods, #{tok_count} test tokens")
    end

    {:ok, stats}
  end

  @doc """
  Returns a list of all supported pm_card_* token IDs.
  """
  @spec payment_method_ids() :: [String.t()]
  def payment_method_ids do
    brand_ids = Enum.map(Map.keys(@card_brands), &"pm_card_#{&1}")
    decline_ids = Enum.map(Map.keys(@decline_cards), &"pm_card_#{&1}")
    brand_ids ++ decline_ids
  end

  @doc """
  Returns a list of all supported tok_* token IDs.
  """
  @spec token_ids() :: [String.t()]
  def token_ids do
    Enum.map(Map.keys(@card_brands), &"tok_#{&1}")
  end

  ## Private Functions

  defp load_payment_methods do
    count = load_brand_payment_methods() + load_decline_payment_methods()
    count
  end

  defp load_brand_payment_methods do
    Enum.reduce(@card_brands, 0, fn {name, config}, count ->
      id = "pm_card_#{name}"
      brand = Map.get(config, :brand, name)

      payment_method = %{
        billing_details: %{
          address: %{
            city: nil,
            country: nil,
            line1: nil,
            line2: nil,
            postal_code: nil,
            state: nil
          },
          email: nil,
          name: nil,
          phone: nil
        },
        card: %{
          brand: normalize_brand(brand),
          checks: %{
            address_line1_check: nil,
            address_postal_code_check: nil,
            cvc_check: "pass"
          },
          country: config.country,
          exp_month: config.exp_month,
          exp_year: config.exp_year,
          fingerprint: config.fingerprint,
          funding: config.funding,
          last4: config.last4,
          three_d_secure_usage: %{supported: true},
          wallet: nil
        },
        created: PaperTiger.now(),
        customer: nil,
        id: id,
        livemode: false,
        metadata: %{},
        object: "payment_method",
        type: "card"
      }

      {:ok, _} = PaymentMethods.insert(payment_method)
      count + 1
    end)
  end

  defp load_decline_payment_methods do
    Enum.reduce(@decline_cards, 0, fn {name, config}, count ->
      id = "pm_card_#{name}"

      payment_method = %{
        id: id,
        object: "payment_method",
        created: PaperTiger.now(),
        type: "card",
        customer: nil,
        metadata: %{
          # Store decline code in metadata for PaperTiger to use
          _paper_tiger_decline_code: config.decline_code
        },
        livemode: false,
        billing_details: %{
          address: %{
            city: nil,
            country: nil,
            line1: nil,
            line2: nil,
            postal_code: nil,
            state: nil
          },
          email: nil,
          name: nil,
          phone: nil
        },
        card: %{
          brand: config.brand,
          checks: %{
            address_line1_check: nil,
            address_postal_code_check: nil,
            cvc_check: "pass"
          },
          country: "US",
          exp_month: 12,
          exp_year: 2030,
          fingerprint: "pm_card_#{name}_fingerprint",
          funding: "credit",
          last4: config.last4,
          three_d_secure_usage: %{supported: true},
          wallet: nil
        }
      }

      {:ok, _} = PaymentMethods.insert(payment_method)
      count + 1
    end)
  end

  defp load_tokens do
    Enum.reduce(@card_brands, 0, fn {name, config}, count ->
      id = "tok_#{name}"
      brand = Map.get(config, :brand, name)

      token = %{
        card: %{
          brand: normalize_brand(brand),
          country: config.country,
          exp_month: config.exp_month,
          exp_year: config.exp_year,
          fingerprint: "tok_#{name}_fingerprint",
          funding: config.funding,
          id: "card_#{name}",
          last4: config.last4,
          object: "card"
        },
        created: PaperTiger.now(),
        id: id,
        livemode: false,
        object: "token",
        type: "card",
        used: false
      }

      {:ok, _} = Tokens.insert(token)
      count + 1
    end)
  end

  # Normalize brand names to match Stripe's format
  defp normalize_brand("visa"), do: "visa"
  defp normalize_brand("visa_debit"), do: "visa"
  defp normalize_brand("mastercard"), do: "mastercard"
  defp normalize_brand("mastercard_debit"), do: "mastercard"
  defp normalize_brand("mastercard_prepaid"), do: "mastercard"
  defp normalize_brand("amex"), do: "amex"
  defp normalize_brand("discover"), do: "discover"
  defp normalize_brand("diners"), do: "diners"
  defp normalize_brand("jcb"), do: "jcb"
  defp normalize_brand("unionpay"), do: "unionpay"
  defp normalize_brand(brand), do: brand
end

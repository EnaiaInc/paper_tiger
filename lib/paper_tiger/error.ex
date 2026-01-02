defmodule PaperTiger.Error do
  @moduledoc """
  Stripe-compatible error responses.

  Matches Stripe's error structure and HTTP status codes.

  ## Error Types

  - `invalid_request_error` - Bad request (400)
  - `api_error` - Server error (500)
  - `card_error` - Card declined (402)
  - `rate_limit_error` - Too many requests (429)

  ## Examples

      # Not found error
      PaperTiger.Error.not_found("customer", "cus_123")
      # => %PaperTiger.Error{
      #      type: "invalid_request_error",
      #      message: "No such customer: 'cus_123'",
      #      status: 404
      #    }

      # Card declined
      PaperTiger.Error.card_declined()
      # => %PaperTiger.Error{
      #      type: "card_error",
      #      code: "card_declined",
      #      message: "Your card was declined.",
      #      status: 402
      #    }
  """

  defexception [:type, :message, :code, :param, :status]

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          param: String.t() | nil,
          status: integer() | nil,
          type: String.t() | nil
        }

  ## Constructors

  @doc """
  Creates an invalid request error (400).

  If a param is provided, it will be appended to the message in the format:
  "message: param"

  ## Examples

      PaperTiger.Error.invalid_request("Missing required parameter", :customer)
      # => %PaperTiger.Error{
      #      message: "Missing required parameter: customer",
      #      param: "customer",
      #      status: 400,
      #      type: "invalid_request_error"
      #    }
  """
  @spec invalid_request(String.t(), String.t() | atom() | nil) :: t()
  def invalid_request(message, param \\ nil) do
    # Format the message to include the field name if param is provided
    formatted_message =
      if param do
        param_str = if is_atom(param), do: Atom.to_string(param), else: param
        "#{message}: #{param_str}"
      else
        message
      end

    %__MODULE__{
      message: formatted_message,
      param: param,
      status: 400,
      type: "invalid_request_error"
    }
  end

  @doc """
  Creates a not found error (404).

  Returns the same error format as Stripe's API for missing resources.

  ## Param Values by Resource Type

  Stripe uses different `param` values depending on the resource:
  - `customer`, `product`, `subscription` -> `"id"`
  - `price` -> `"price"`
  - `plan` -> `"plan"`
  - `invoice` -> `"invoice"`
  - `payment_intent` -> `"intent"`

  ## Examples

      PaperTiger.Error.not_found("customer", "cus_123")
      # => %PaperTiger.Error{
      #      code: "resource_missing",
      #      message: "No such customer: 'cus_123'",
      #      param: "id",
      #      status: 404,
      #      type: "invalid_request_error"
      #    }
  """
  @spec not_found(String.t(), String.t()) :: t()
  def not_found(resource_type, id) do
    %__MODULE__{
      code: "resource_missing",
      message: "No such #{resource_type}: '#{id}'",
      param: param_for_resource(resource_type),
      status: 404,
      type: "invalid_request_error"
    }
  end

  # Returns the param value Stripe uses for each resource type
  defp param_for_resource("price"), do: "price"
  defp param_for_resource("plan"), do: "plan"
  defp param_for_resource("invoice"), do: "invoice"
  defp param_for_resource("payment_intent"), do: "intent"
  defp param_for_resource("charge"), do: "charge"
  defp param_for_resource("refund"), do: "refund"
  defp param_for_resource("coupon"), do: "coupon"
  defp param_for_resource(_resource_type), do: "id"

  @doc """
  Creates a card declined error (402).

  ## Options

  - `:code` - Decline code (default: "card_declined")

  Possible codes:
  - `card_declined` - Generic decline
  - `insufficient_funds` - Not enough money
  - `expired_card` - Card expired
  - `incorrect_cvc` - CVC check failed
  """
  @spec card_declined(keyword()) :: t()
  def card_declined(opts \\ []) do
    code = Keyword.get(opts, :code, "card_declined")

    message =
      case code do
        "insufficient_funds" -> "Your card has insufficient funds."
        "expired_card" -> "Your card has expired."
        "incorrect_cvc" -> "Your card's security code is incorrect."
        _ -> "Your card was declined."
      end

    %__MODULE__{
      code: code,
      message: message,
      status: 402,
      type: "card_error"
    }
  end

  @doc """
  Creates a rate limit error (429).
  """
  @spec rate_limit() :: t()
  def rate_limit do
    %__MODULE__{
      message: "Too many requests. Please slow down.",
      status: 429,
      type: "rate_limit_error"
    }
  end

  @doc """
  Creates an API error (500).
  """
  @spec api_error(String.t()) :: t()
  def api_error(message \\ "An error occurred with our API.") do
    %__MODULE__{
      message: message,
      status: 500,
      type: "api_error"
    }
  end

  @doc """
  Converts error to Stripe's JSON format.

  ## Examples

      PaperTiger.Error.not_found("customer", "cus_123")
      |> PaperTiger.Error.to_json()
      # => %{
      #   error: %{
      #     type: "invalid_request_error",
      #     message: "No such customer: 'cus_123'"
      #   }
      # }
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = error) do
    error_data = %{
      message: error.message,
      type: error.type
    }

    error_data =
      if error.code do
        Map.put(error_data, :code, error.code)
      else
        error_data
      end

    error_data =
      if error.param do
        Map.put(error_data, :param, error.param)
      else
        error_data
      end

    %{error: error_data}
  end
end

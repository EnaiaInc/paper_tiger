defmodule PaperTiger.MandateHelper do
  @moduledoc """
  Builds and stores Mandate objects for successful intent flows.
  """

  import PaperTiger.Resource, only: [generate_id: 1]

  alias PaperTiger.Store.Mandates

  @mandate_payment_method_types ~w(
    acss_debit
    au_becs_debit
    bacs_debit
    nz_bank_account
    payto
    sepa_debit
    us_bank_account
  )

  @doc """
  Ensures a SetupIntent has a stored Mandate when its payment method requires one.
  """
  @spec ensure_for_setup_intent(map(), map(), map()) :: {:ok, String.t() | nil}
  def ensure_for_setup_intent(setup_intent, payment_method, params \\ %{}) do
    ensure_mandate(setup_intent, payment_method, params, "multi_use")
  end

  @doc """
  Ensures a PaymentIntent has a stored Mandate when its payment method requires one.
  """
  @spec ensure_for_payment_intent(map(), map() | nil, map()) :: {:ok, String.t() | nil}
  def ensure_for_payment_intent(payment_intent, payment_method, params \\ %{})

  def ensure_for_payment_intent(_payment_intent, nil, _params), do: {:ok, nil}

  def ensure_for_payment_intent(payment_intent, payment_method, params) do
    type =
      if present?(Map.get(payment_intent, :setup_future_usage) || param(params, :setup_future_usage)) do
        "multi_use"
      else
        "single_use"
      end

    ensure_mandate(payment_intent, payment_method, params, type)
  end

  defp ensure_mandate(intent, payment_method, params, type) do
    cond do
      is_binary(Map.get(intent, :mandate)) ->
        {:ok, Map.get(intent, :mandate)}

      !mandate_required?(payment_method) ->
        {:ok, nil}

      true ->
        mandate = build_mandate(intent, payment_method, params, type)
        {:ok, mandate} = Mandates.insert(mandate)
        {:ok, mandate.id}
    end
  end

  defp mandate_required?(%{type: type}) when type in @mandate_payment_method_types, do: true
  defp mandate_required?(_payment_method), do: false

  defp build_mandate(intent, payment_method, params, type) do
    %{
      customer_acceptance: customer_acceptance(intent, params),
      id: generate_id("mandate"),
      livemode: false,
      object: "mandate",
      payment_method: payment_method.id,
      payment_method_details: payment_method_details(payment_method),
      status: "active",
      type: type
    }
  end

  defp customer_acceptance(intent, params) do
    mandate_data =
      param(params, :mandate_data) ||
        Map.get(intent, :mandate_data) ||
        %{}

    mandate_data
    |> param(:customer_acceptance)
    |> case do
      acceptance when is_map(acceptance) ->
        acceptance

      _missing ->
        %{
          accepted_at: PaperTiger.now(),
          offline: %{},
          online: nil,
          type: "offline"
        }
    end
  end

  defp payment_method_details(%{type: "card"} = payment_method) do
    %{
      card: Map.get(payment_method, :card),
      type: "card"
    }
  end

  defp payment_method_details(%{type: type} = payment_method) when is_binary(type) do
    details = dynamic_param(payment_method, type) || %{}
    Map.put(%{type: type}, type, details)
  end

  defp payment_method_details(_payment_method), do: %{}

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp param(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp param(_map, _key), do: nil

  defp dynamic_param(map, key) when is_map(map) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key) || if(atom_key, do: Map.get(map, atom_key))
  end
end

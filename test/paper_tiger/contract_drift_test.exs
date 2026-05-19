defmodule PaperTiger.ContractDriftTest do
  @moduledoc """
  Live Stripe drift tests.

  These tests are excluded by default. Run with:

      VALIDATE_CONTRACT_DRIFT=true STRIPE_API_KEY=sk_test_xxx mix test test/paper_tiger/contract_drift_test.exs
  """

  use ExUnit.Case, async: false

  alias PaperTiger.ContractDrift
  alias PaperTiger.ContractDrift.Scenario
  alias PaperTiger.TestClient

  @moduletag :contract_drift
  @moduletag :stripe_live

  setup_all do
    TestClient.validate_test_mode_key!()
    :ok
  end

  test "customer create/retrieve/update/delete lifecycle matches Stripe" do
    email = "paper-tiger-drift-#{System.unique_integer([:positive])}@example.com"

    scenario = %Scenario{
      name: "customer create/retrieve/update/delete",
      run: fn backend -> customer_lifecycle_shape(email, backend) end
    }

    ContractDrift.assert_scenario!(scenario)
  end

  defp customer_lifecycle_shape(email, _backend) do
    {:ok, created} =
      TestClient.create_customer(%{
        "email" => email,
        "metadata" => %{"contract_drift" => "true"},
        "name" => "PaperTiger Drift"
      })

    try do
      {:ok, retrieved} = TestClient.get_customer(created["id"])

      {:ok, updated} =
        TestClient.update_customer(created["id"], %{
          "metadata" => %{"contract_drift" => "true", "phase" => "updated"},
          "name" => "PaperTiger Drift Updated"
        })

      {:ok, deleted} = TestClient.delete_customer(created["id"])

      %{
        "created" => customer_shape(created),
        "deleted" => deleted_shape(deleted),
        "retrieved" => customer_shape(retrieved),
        "updated" => customer_shape(updated)
      }
    after
      safe_delete_customer(created["id"])
    end
  end

  defp safe_delete_customer(customer_id) do
    _ = TestClient.delete_customer(customer_id)
    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp customer_shape(customer) do
    %{
      "created" => customer["created"],
      "email" => customer["email"],
      "id" => customer["id"],
      "livemode" => customer["livemode"],
      "metadata" => Map.take(customer["metadata"] || %{}, ["contract_drift", "phase"]),
      "name" => customer["name"],
      "object" => customer["object"]
    }
  end

  defp deleted_shape(deleted) do
    %{
      "deleted" => deleted["deleted"],
      "id" => deleted["id"]
    }
  end
end

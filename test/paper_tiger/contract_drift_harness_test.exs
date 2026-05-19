defmodule PaperTiger.ContractDriftHarnessTest do
  use ExUnit.Case, async: true

  alias PaperTiger.ContractDrift
  alias PaperTiger.TestClient

  describe "normalize/2" do
    test "scrubs volatile ids and timestamps while preserving relationships" do
      normalized =
        ContractDrift.normalize(%{
          "created" => 1_766_000_000,
          "customer" => "cus_real_123",
          "id" => "pi_real_123_secret_456",
          "nested" => %{"customer" => "cus_real_123"}
        })

      assert normalized == %{
               "created" => "<timestamp>",
               "customer" => "<id:cus_1>",
               "id" => "<id:pi_1>",
               "nested" => %{"customer" => "<id:cus_1>"}
             }
    end
  end

  describe "compare/4" do
    test "returns ok for normalized matches" do
      paper_tiger = %{"created" => 1, "id" => "cus_mock_123", "object" => "customer"}
      stripe = %{"created" => 2, "id" => "cus_real_456", "object" => "customer"}

      assert :ok = ContractDrift.compare("customer create", paper_tiger, stripe)
    end

    test "reports the first mismatch with both backend shapes" do
      assert {:error, drift} =
               ContractDrift.compare(
                 "customer create",
                 %{"email" => "mock@example.com", "object" => "customer"},
                 %{"email" => "stripe@example.com", "object" => "customer"}
               )

      report = ContractDrift.format_drift(drift)

      assert report =~ "Contract drift: customer create"
      assert report =~ "$.email"
      assert report =~ "Stripe expected:"
      assert report =~ "PaperTiger actual:"
      assert report =~ "stripe@example.com"
      assert report =~ "mock@example.com"
    end
  end

  describe "TestClient.with_mode/2" do
    test "forces PaperTiger mode in the current process and restores the previous mode" do
      assert TestClient.mode() == :paper_tiger

      assert TestClient.with_mode(:paper_tiger, fn ->
               TestClient.mode()
             end) == :paper_tiger

      assert TestClient.mode() == :paper_tiger
    end
  end
end

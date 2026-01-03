defmodule PaperTigerTest do
  use ExUnit.Case, async: true

  import PaperTiger.Test

  alias PaperTiger.Store.Customers

  doctest PaperTiger

  setup :checkout_paper_tiger

  describe "Clock" do
    test "real mode returns system time" do
      PaperTiger.Clock.set_mode(:real)
      now1 = PaperTiger.now()
      Process.sleep(100)
      now2 = PaperTiger.now()
      assert now2 >= now1
    end

    test "manual mode allows time advancement" do
      PaperTiger.Clock.set_mode(:manual)
      PaperTiger.Clock.reset()

      start_time = PaperTiger.now()
      PaperTiger.advance_time(days: 30)
      end_time = PaperTiger.now()

      assert end_time == start_time + 30 * 86_400
    end

    # NOTE: Accelerated mode is tested in integration tests
    # Unit test removed due to timing flakiness with Process.sleep()
  end

  describe "Store.Customers" do
    test "inserts and retrieves customers" do
      customer = %{
        created: PaperTiger.now(),
        email: "test@example.com",
        id: "cus_test123"
      }

      {:ok, _} = Customers.insert(customer)
      {:ok, retrieved} = Customers.get("cus_test123")

      assert retrieved.email == "test@example.com"
    end

    test "returns not_found for missing customer" do
      assert {:error, :not_found} = Customers.get("cus_missing")
    end

    test "lists customers with pagination" do
      # Insert 5 customers
      for i <- 1..5 do
        customer = %{
          created: PaperTiger.now() + i,
          email: "user#{i}@example.com",
          id: "cus_#{i}"
        }

        Customers.insert(customer)
      end

      result = Customers.list(limit: 2)
      assert length(result.data) == 2
      assert result.has_more == true
    end

    test "clears all customers" do
      customer = %{created: PaperTiger.now(), email: "test@example.com", id: "cus_123"}
      Customers.insert(customer)

      Customers.clear()

      assert {:error, :not_found} = Customers.get("cus_123")
    end
  end

  describe "Idempotency" do
    test "caches responses by key" do
      key = "test_key_#{:rand.uniform(1_000_000)}"
      response = %{email: "test@example.com", id: "cus_123"}

      # First check - new request
      assert :new_request = PaperTiger.Idempotency.check(key)

      # Store response
      :ok = PaperTiger.Idempotency.store(key, response)

      # Second check - cached
      assert {:cached, ^response} = PaperTiger.Idempotency.check(key)
    end

    test "clears all keys" do
      key = "test_key"
      response = %{id: "cus_123"}

      PaperTiger.Idempotency.store(key, response)
      PaperTiger.Idempotency.clear()

      assert :new_request = PaperTiger.Idempotency.check(key)
    end
  end

  describe "List pagination" do
    test "paginates items with limit" do
      items = [
        %{created: 100, id: "1"},
        %{created: 200, id: "2"},
        %{created: 300, id: "3"}
      ]

      result = PaperTiger.List.paginate(items, limit: 2)

      assert length(result.data) == 2
      assert result.has_more == true
      # Should be sorted descending by created
      assert Enum.at(result.data, 0).id == "3"
    end

    test "handles starting_after cursor" do
      items = [
        %{created: 100, id: "1"},
        %{created: 200, id: "2"},
        %{created: 300, id: "3"}
      ]

      result = PaperTiger.List.paginate(items, starting_after: "2", limit: 10)

      assert length(result.data) == 1
      assert Enum.at(result.data, 0).id == "1"
    end
  end

  describe "Error handling" do
    test "creates not_found error" do
      error = PaperTiger.Error.not_found("customer", "cus_123")

      assert error.type == "invalid_request_error"
      assert error.status == 404
      assert error.message =~ "cus_123"
    end

    test "creates card_declined error" do
      error = PaperTiger.Error.card_declined(code: "insufficient_funds")

      assert error.type == "card_error"
      assert error.code == "insufficient_funds"
      assert error.status == 402
    end

    test "converts error to JSON" do
      error = PaperTiger.Error.invalid_request("Missing required parameter", "email")
      json = PaperTiger.Error.to_json(error)

      assert json.error.type == "invalid_request_error"
      assert json.error.param == "email"
    end
  end
end

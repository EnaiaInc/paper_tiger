defmodule PaperTiger.Resources.SubscriptionScheduleTest do
  use ExUnit.Case, async: false

  import PaperTiger.Test

  alias PaperTiger.Router

  setup :checkout_paper_tiger

  setup do
    previous_mode = PaperTiger.clock_mode()
    PaperTiger.set_clock_mode(:manual)

    on_exit(fn ->
      PaperTiger.set_clock_mode(previous_mode)
    end)

    :ok
  end

  defp request(method, path, params \\ nil) do
    Plug.Test.conn(method, path, params)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer sk_test_schedule_key")
    |> then(fn conn ->
      Enum.reduce(sandbox_headers(), conn, fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)
    end)
    |> Router.call([])
  end

  defp json_response(conn), do: Jason.decode!(conn.resp_body)

  defp create_customer do
    request(:post, "/v1/customers", %{"email" => "schedule@example.test"})
    |> json_response()
  end

  defp create_price(interval \\ "month") do
    product =
      request(:post, "/v1/products", %{"name" => "Schedule Product"})
      |> json_response()

    request(:post, "/v1/prices", %{
      "currency" => "usd",
      "product" => product["id"],
      "recurring" => %{"interval" => interval},
      "unit_amount" => 2_000
    })
    |> json_response()
  end

  defp create_subscription(customer, price) do
    request(:post, "/v1/subscriptions", %{
      "customer" => customer["id"],
      "items" => [%{"price" => price["id"], "quantity" => 1}]
    })
    |> json_response()
  end

  defp create_schedule(params) do
    request(:post, "/v1/subscription_schedules", params)
    |> json_response()
  end

  describe "create" do
    test "normalizes an immediate phase into active Stripe-shaped dates and items" do
      customer = create_customer()
      price = create_price()
      now = PaperTiger.now()

      schedule =
        create_schedule(%{
          "customer" => customer["id"],
          "end_behavior" => "release",
          "phases" => [
            %{
              "duration" => %{"interval" => "month", "interval_count" => 1},
              "items" => [%{"price" => price["id"], "quantity" => 2}],
              "metadata" => %{"phase" => "one"}
            }
          ],
          "start_date" => "now"
        })

      assert schedule["object"] == "subscription_schedule"
      assert schedule["customer"] == customer["id"]
      assert schedule["status"] == "active"
      assert schedule["current_phase"]["start_date"] >= now
      assert schedule["current_phase"]["end_date"] == schedule["current_phase"]["start_date"] + 30 * 86_400
      assert schedule["subscription"] =~ "sub_"

      [phase] = schedule["phases"]
      assert phase["start_date"] == schedule["current_phase"]["start_date"]
      assert phase["end_date"] == schedule["current_phase"]["end_date"]
      assert [%{"price" => price_id, "quantity" => 2}] = phase["items"]
      assert price_id == price["id"]
      assert [%{"plan" => ^price_id, "quantity" => 2}] = phase["plans"]

      subscription =
        request(:get, "/v1/subscriptions/#{schedule["subscription"]}")
        |> json_response()

      assert subscription["schedule"] == schedule["id"]
      assert subscription["current_period_start"] == phase["start_date"]
      assert subscription["current_period_end"] == phase["end_date"]
      assert [%{"price" => %{"id" => ^price_id}, "quantity" => 2}] = subscription["items"]["data"]
    end

    test "normalizes contiguous multi-phase schedules with explicit and iteration-derived dates" do
      customer = create_customer()
      monthly = create_price("month")
      start_date = PaperTiger.now() + 10 * 86_400
      first_end = start_date + 14 * 86_400

      schedule =
        create_schedule(%{
          "customer" => customer["id"],
          "phases" => [
            %{
              "end_date" => first_end,
              "items" => [%{"price" => monthly["id"]}]
            },
            %{
              "items" => [%{"price" => monthly["id"], "quantity" => 3}],
              "iterations" => 2
            }
          ],
          "start_date" => start_date
        })

      assert schedule["status"] == "not_started"
      assert schedule["subscription"] == nil
      assert schedule["current_phase"] == nil

      [first, second] = schedule["phases"]
      assert first["start_date"] == start_date
      assert first["end_date"] == first_end
      assert second["start_date"] == first_end
      assert second["end_date"] == first_end + 2 * 30 * 86_400
    end

    test "creates from an existing subscription" do
      customer = create_customer()
      price = create_price()
      subscription = create_subscription(customer, price)

      schedule = create_schedule(%{"from_subscription" => subscription["id"]})

      assert schedule["status"] == "active"
      assert schedule["from_subscription"] == subscription["id"]
      assert schedule["subscription"] == subscription["id"]
      assert schedule["customer"] == customer["id"]

      assert schedule["current_phase"] == %{
               "end_date" => subscription["current_period_end"],
               "start_date" => subscription["current_period_start"]
             }

      assert [%{"items" => [%{"price" => price_id}]}] = schedule["phases"]
      assert price_id == price["id"]
    end

    test "rejects non-contiguous phase start dates and invalid duration combinations" do
      customer = create_customer()
      price = create_price()
      start_date = PaperTiger.now() + 100
      first_end = start_date + 100

      bad_start =
        request(:post, "/v1/subscription_schedules", %{
          "customer" => customer["id"],
          "phases" => [
            %{"end_date" => first_end, "items" => [%{"price" => price["id"]}]},
            %{
              "end_date" => first_end + 100,
              "items" => [%{"price" => price["id"]}],
              "start_date" => first_end + 1
            }
          ],
          "start_date" => start_date
        })

      assert bad_start.status == 400
      assert json_response(bad_start)["error"]["param"] == "phases[1][start_date]"

      bad_duration =
        request(:post, "/v1/subscription_schedules", %{
          "customer" => customer["id"],
          "phases" => [
            %{
              "duration" => %{"interval" => "month"},
              "end_date" => first_end,
              "items" => [%{"price" => price["id"]}]
            }
          ],
          "start_date" => start_date
        })

      assert bad_duration.status == 400
      assert json_response(bad_duration)["error"]["param"] == "phases[0][duration]"
    end
  end

  describe "update, cancel, release, list" do
    test "updates future phases and preserves elapsed phases" do
      customer = create_customer()
      monthly = create_price("month")
      weekly = create_price("week")
      start_date = PaperTiger.now() - 10
      first_end = start_date + 20

      schedule =
        create_schedule(%{
          "customer" => customer["id"],
          "phases" => [
            %{"end_date" => first_end, "items" => [%{"price" => monthly["id"]}]},
            %{"duration" => %{"interval" => "month"}, "items" => [%{"price" => monthly["id"]}]}
          ],
          "start_date" => start_date
        })

      assert schedule["status"] == "active"
      PaperTiger.advance_time(seconds: 25)

      update_conn =
        request(:post, "/v1/subscription_schedules/#{schedule["id"]}", %{
          "metadata" => %{"updated" => "true"},
          "phases" => [
            %{
              "duration" => %{"interval" => "week", "interval_count" => 3},
              "items" => [%{"price" => weekly["id"]}],
              "start_date" => first_end
            }
          ]
        })

      assert update_conn.status == 200
      updated = json_response(update_conn)
      [past, future] = updated["phases"]

      assert past["end_date"] == first_end
      assert future["start_date"] == first_end
      assert future["end_date"] == first_end + 3 * 7 * 86_400
      assert updated["metadata"] == %{"updated" => "true"}
    end

    test "cancel and release enforce active/not_started states and update subscription links" do
      customer = create_customer()
      price = create_price()

      cancel_schedule =
        create_schedule(%{
          "customer" => customer["id"],
          "phases" => [%{"duration" => %{"interval" => "month"}, "items" => [%{"price" => price["id"]}]}]
        })

      cancel_conn = request(:post, "/v1/subscription_schedules/#{cancel_schedule["id"]}/cancel", %{})
      assert cancel_conn.status == 200
      canceled = json_response(cancel_conn)
      assert canceled["status"] == "canceled"
      assert canceled["canceled_at"]
      assert canceled["subscription"] == nil

      canceled_again = request(:post, "/v1/subscription_schedules/#{cancel_schedule["id"]}/cancel", %{})
      assert canceled_again.status == 400

      release_schedule =
        create_schedule(%{
          "customer" => customer["id"],
          "phases" => [%{"duration" => %{"interval" => "month"}, "items" => [%{"price" => price["id"]}]}]
        })

      release_conn = request(:post, "/v1/subscription_schedules/#{release_schedule["id"]}/release", %{})
      assert release_conn.status == 200
      released = json_response(release_conn)
      assert released["status"] == "released"
      assert released["released_at"]
      assert released["released_subscription"] == release_schedule["subscription"]
      assert released["subscription"] == nil
    end

    test "lists schedules with documented filters before pagination" do
      customer = create_customer()
      other_customer = create_customer()
      price = create_price()
      future = PaperTiger.now() + 86_400

      active =
        create_schedule(%{
          "customer" => customer["id"],
          "phases" => [%{"duration" => %{"interval" => "month"}, "items" => [%{"price" => price["id"]}]}]
        })

      scheduled =
        create_schedule(%{
          "customer" => customer["id"],
          "phases" => [%{"duration" => %{"interval" => "month"}, "items" => [%{"price" => price["id"]}]}],
          "start_date" => future
        })

      _other =
        create_schedule(%{
          "customer" => other_customer["id"],
          "phases" => [%{"duration" => %{"interval" => "month"}, "items" => [%{"price" => price["id"]}]}]
        })

      by_customer =
        request(:get, "/v1/subscription_schedules?customer=#{customer["id"]}&limit=10")
        |> json_response()

      assert Enum.map(by_customer["data"], & &1["id"]) |> Enum.sort() ==
               [active["id"], scheduled["id"]] |> Enum.sort()

      scheduled_only =
        request(:get, "/v1/subscription_schedules?customer=#{customer["id"]}&scheduled=true&limit=10")
        |> json_response()

      assert Enum.map(scheduled_only["data"], & &1["id"]) == [scheduled["id"]]
    end
  end
end

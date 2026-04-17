defmodule ReqAcumatica.RESTTest do
  use ExUnit.Case, async: true

  @entity_base "/entity/Default/24.200.001"

  defp new_req(bypass) do
    ReqAcumatica.new(
      base_url: "http://localhost:#{bypass.port}",
      tenant: "TEST",
      auth: {:basic, "admin", "pass"}
    )
  end

  describe "list/3" do
    test "lists entities" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "#{@entity_base}/SalesOrder", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!([
            %{"OrderNbr" => %{"value" => "SO-001"}, "Status" => %{"value" => "Open"}},
            %{"OrderNbr" => %{"value" => "SO-002"}, "Status" => %{"value" => "Hold"}}
          ])
        )
      end)

      assert {:ok, orders} = ReqAcumatica.REST.list(new_req(bypass), "SalesOrder")
      assert length(orders) == 2
    end

    test "passes query params" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "#{@entity_base}/SalesOrder", fn conn ->
        params = conn.query_string |> URI.decode_query()
        assert params["$filter"] == "Status eq 'Open'"
        assert params["$top"] == "10"
        assert params["$expand"] == "Details"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end)

      assert {:ok, []} =
               ReqAcumatica.REST.list(new_req(bypass), "SalesOrder",
                 filter: "Status eq 'Open'",
                 top: 10,
                 expand: "Details"
               )
    end
  end

  describe "get/3" do
    test "gets a single entity" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "#{@entity_base}/SalesOrder/SO-001", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "OrderNbr" => %{"value" => "SO-001"},
            "Status" => %{"value" => "Open"},
            "OrderTotal" => %{"value" => 1500.0}
          })
        )
      end)

      assert {:ok, order} = ReqAcumatica.REST.get(new_req(bypass), "SalesOrder/SO-001")
      assert order["OrderNbr"]["value"] == "SO-001"
    end

    test "returns error on 404" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "#{@entity_base}/SalesOrder/NOPE", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"Message" => "Entity not found"}))
      end)

      assert {:error, %ReqAcumatica.Error{status: 404, message: "Entity not found"}} =
               ReqAcumatica.REST.get(new_req(bypass), "SalesOrder/NOPE")
    end
  end

  describe "create/3" do
    test "creates an entity" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "PUT", "#{@entity_base}/SalesOrder", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        data = Jason.decode!(body)
        assert data["CustomerID"]["value"] == "CUST01"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "OrderNbr" => %{"value" => "SO-NEW"},
            "CustomerID" => %{"value" => "CUST01"},
            "Status" => %{"value" => "Open"}
          })
        )
      end)

      body = %{
        "CustomerID" => %{"value" => "CUST01"},
        "Description" => %{"value" => "Test order"}
      }

      assert {:ok, created} = ReqAcumatica.REST.create(new_req(bypass), "SalesOrder", body)
      assert created["OrderNbr"]["value"] == "SO-NEW"
    end
  end

  describe "update/3" do
    test "updates an entity" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "PUT", "#{@entity_base}/SalesOrder", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        data = Jason.decode!(body)
        assert data["Description"]["value"] == "Updated"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "OrderNbr" => %{"value" => "SO-001"},
            "Description" => %{"value" => "Updated"}
          })
        )
      end)

      body = %{
        "OrderNbr" => %{"value" => "SO-001"},
        "OrderType" => %{"value" => "SO"},
        "Description" => %{"value" => "Updated"}
      }

      assert {:ok, updated} = ReqAcumatica.REST.update(new_req(bypass), "SalesOrder", body)
      assert updated["Description"]["value"] == "Updated"
    end
  end

  describe "delete/3" do
    test "deletes an entity" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "#{@entity_base}/Customer/CUST01", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = ReqAcumatica.REST.delete(new_req(bypass), "Customer/CUST01")
    end

    test "returns error on failure" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "DELETE", "#{@entity_base}/Customer/CUST01", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{"exceptionMessage" => "Cannot delete: has related records"})
        )
      end)

      assert {:error, %ReqAcumatica.Error{status: 400, message: msg}} =
               ReqAcumatica.REST.delete(new_req(bypass), "Customer/CUST01")

      assert msg =~ "Cannot delete"
    end
  end

  describe "action/4" do
    test "invokes an entity action" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "POST",
        "#{@entity_base}/SalesOrder/ReleaseFromHold",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          data = Jason.decode!(body)
          assert data["entity"]["OrderNbr"]["value"] == "SO-001"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "Released"}))
        end
      )

      body = %{
        "entity" => %{
          "OrderType" => %{"value" => "SO"},
          "OrderNbr" => %{"value" => "SO-001"}
        }
      }

      assert {:ok, result} =
               ReqAcumatica.REST.action(new_req(bypass), "SalesOrder", "ReleaseFromHold", body)

      assert result["status"] == "Released"
    end

    test "handles 202 Accepted for long-running operations" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "POST",
        "#{@entity_base}/Shipment/ConfirmShipment",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "/api/status/12345")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(202, Jason.encode!(%{"status" => "In Progress"}))
        end
      )

      assert {:ok, result} =
               ReqAcumatica.REST.action(
                 new_req(bypass),
                 "Shipment",
                 "ConfirmShipment",
                 %{"entity" => %{}}
               )

      assert result["status"] == "In Progress"
    end
  end

  describe "unwrap_values/1" do
    test "unwraps simple values" do
      input = %{
        "OrderNbr" => %{"value" => "SO-001"},
        "Status" => %{"value" => "Open"},
        "Total" => %{"value" => 1500.0}
      }

      assert ReqAcumatica.REST.unwrap_values(input) == %{
               "OrderNbr" => "SO-001",
               "Status" => "Open",
               "Total" => 1500.0
             }
    end

    test "unwraps nested maps and lists" do
      input = %{
        "OrderNbr" => %{"value" => "SO-001"},
        "Details" => [
          %{"InventoryID" => %{"value" => "ITEM1"}, "Qty" => %{"value" => 10}},
          %{"InventoryID" => %{"value" => "ITEM2"}, "Qty" => %{"value" => 5}}
        ]
      }

      result = ReqAcumatica.REST.unwrap_values(input)

      assert result["OrderNbr"] == "SO-001"
      assert length(result["Details"]) == 2
      assert hd(result["Details"])["InventoryID"] == "ITEM1"
    end

    test "passes through non-value maps" do
      input = %{"id" => "abc", "custom" => %{"nested" => "data"}}
      result = ReqAcumatica.REST.unwrap_values(input)

      assert result["id"] == "abc"
      assert result["custom"] == %{"nested" => "data"}
    end

    test "handles nil and scalars" do
      assert ReqAcumatica.REST.unwrap_values(nil) == nil
      assert ReqAcumatica.REST.unwrap_values("hello") == "hello"
      assert ReqAcumatica.REST.unwrap_values(42) == 42
    end
  end

  describe "attach_file/4" do
    test "uploads binary content" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "PUT",
        "#{@entity_base}/PurchaseOrder/PO-001/files/doc.pdf",
        fn conn ->
          assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body == "pdf-binary-data"
          Plug.Conn.resp(conn, 200, "")
        end
      )

      assert :ok =
               ReqAcumatica.REST.attach_file(
                 new_req(bypass),
                 "PurchaseOrder/PO-001",
                 "doc.pdf",
                 {:binary, "pdf-binary-data"}
               )
    end
  end

  describe "download_file/3" do
    test "downloads binary content" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "GET",
        "#{@entity_base}/PurchaseOrder/PO-001/files/doc.pdf",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/pdf")
          |> Plug.Conn.resp(200, "pdf-binary-data")
        end
      )

      assert {:ok, "pdf-binary-data"} =
               ReqAcumatica.REST.download_file(
                 new_req(bypass),
                 "PurchaseOrder/PO-001",
                 "doc.pdf"
               )
    end
  end

  describe "custom fields" do
    test "get_custom_field extracts value" do
      entity = %{
        "custom" => %{
          "Item" => %{
            "UsrMyField" => %{"type" => "CustomStringField", "value" => "hello"},
            "UsrCount" => %{"type" => "CustomIntField", "value" => 42}
          }
        }
      }

      assert ReqAcumatica.REST.get_custom_field(entity, "Item", "UsrMyField") == "hello"
      assert ReqAcumatica.REST.get_custom_field(entity, "Item", "UsrCount") == 42
      assert ReqAcumatica.REST.get_custom_field(entity, "Item", "Nope") == nil
      assert ReqAcumatica.REST.get_custom_field(entity, "BadView", "UsrMyField") == nil
    end

    test "get_custom_fields returns flat map" do
      entity = %{
        "custom" => %{
          "Item" => %{
            "UsrA" => %{"value" => "alpha"},
            "UsrB" => %{"value" => 99}
          }
        }
      }

      assert %{"UsrA" => "alpha", "UsrB" => 99} =
               ReqAcumatica.REST.get_custom_fields(entity, "Item")
    end

    test "build_custom_fields creates correct structure" do
      result = ReqAcumatica.REST.build_custom_fields("Item", %{"UsrX" => "val", "UsrY" => 10})

      assert result == %{
               "custom" => %{
                 "Item" => %{
                   "UsrX" => %{"value" => "val"},
                   "UsrY" => %{"value" => 10}
                 }
               }
             }
    end
  end

  describe "401 auth retry" do
    test "retries on 401 with session auth" do
      bypass = Bypass.open()
      call_count = :counters.new(1, [:atomics])

      # Login endpoint for session refresh
      Bypass.expect(bypass, "POST", "/entity/auth/login", fn conn ->
        conn
        |> Plug.Conn.prepend_resp_headers([
          {"set-cookie", "ASP.NET_SessionId=refreshed; path=/"},
          {"set-cookie", ".ASPXAUTH=newauth; path=/"}
        ])
        |> Plug.Conn.resp(204, "")
      end)

      # First call returns 401, second succeeds
      Bypass.expect(bypass, "GET", "#{@entity_base}/StockItem", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        if count <= 1 do
          Plug.Conn.resp(conn, 401, "")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!([%{"InventoryID" => %{"value" => "ITEM1"}}]))
        end
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth:
            {:session_token,
             %ReqAcumatica.Session{
               cookies: "old-cookie",
               logged_in_at: DateTime.utc_now(),
               base_url: "http://localhost:#{bypass.port}",
               username: "admin",
               password: "pass",
               company: "TEST"
             }}
        )

      assert {:ok, [item]} = ReqAcumatica.REST.list(req, "StockItem", top: 1)
      assert item["InventoryID"]["value"] == "ITEM1"
      # Should have retried (2 calls to StockItem)
      assert :counters.get(call_count, 1) == 2
    end
  end
end

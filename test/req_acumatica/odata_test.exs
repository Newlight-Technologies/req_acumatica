defmodule ReqAcumatica.ODataTest do
  use ExUnit.Case, async: true

  describe "query/3" do
    test "queries a generic inquiry" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/odata/TEST/My%20Inquiry", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "value" => [
              %{"OrderNbr" => "SO-001", "Status" => "Open"},
              %{"OrderNbr" => "SO-002", "Status" => "Hold"}
            ]
          })
        )
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, result} = ReqAcumatica.OData.query(req, "My Inquiry")
      assert length(result.rows) == 2
      assert hd(result.rows)["OrderNbr"] == "SO-001"
    end

    test "passes OData query params" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/odata/TEST/GI", fn conn ->
        params = conn.query_string |> URI.decode_query()
        assert params["$filter"] == "Status eq 'Open'"
        assert params["$top"] == "25"
        assert params["$orderby"] == "Total desc"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"value" => []}))
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, _} =
               ReqAcumatica.OData.query(req, "GI",
                 filter: "Status eq 'Open'",
                 top: 25,
                 orderby: "Total desc"
               )
    end

    test "returns error on non-200" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/odata/TEST/Bad", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:error, %ReqAcumatica.Error{status: 404}} =
               ReqAcumatica.OData.query(req, "Bad")
    end
  end

  describe "list_inquiries/1" do
    test "returns list of GI names" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/odata/TEST/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "value" => [
              %{"name" => "Sales Orders", "url" => "SalesOrders"},
              %{"name" => "Inventory", "url" => "Inventory"}
            ]
          })
        )
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, names} = ReqAcumatica.OData.list_inquiries(req)
      assert "Sales Orders" in names
      assert "Inventory" in names
    end
  end

  describe "metadata/2" do
    test "returns XML metadata" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/odata/TEST/MyGI/$metadata", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, "<edmx:Edmx>...</edmx:Edmx>")
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, xml} = ReqAcumatica.OData.metadata(req, "MyGI")
      assert xml =~ "edmx:Edmx"
    end
  end

  describe "query_all/3" do
    test "paginates through all results" do
      bypass = Bypass.open()
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/odata/TEST/GI", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        params = conn.query_string |> URI.decode_query()

        rows =
          case params["$skip"] do
            nil -> Enum.map(1..2, &%{"id" => &1})
            "0" -> Enum.map(1..2, &%{"id" => &1})
            "2" -> Enum.map(3..4, &%{"id" => &1})
            "4" -> []
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"value" => rows}))
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, result} = ReqAcumatica.OData.query_all(req, "GI", page_size: 2)
      assert length(result.rows) == 4
    end

    test "respects max_results" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/odata/TEST/GI", fn conn ->
        rows = Enum.map(1..10, &%{"id" => &1})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"value" => rows}))
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, result} =
               ReqAcumatica.OData.query_all(req, "GI", page_size: 10, max_results: 5)

      assert length(result.rows) == 5
    end
  end
end

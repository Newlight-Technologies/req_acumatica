defmodule ReqAcumaticaTest do
  use ExUnit.Case, async: true

  describe "new/1" do
    test "builds client with basic auth" do
      client =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "MY TENANT",
          auth: {:basic, "admin", "pass123"}
        )

      assert %Req.Request{} = client

      # Verify private fields
      assert client.private[:acumatica_base_url] == "https://example.acumatica.com"
      assert client.private[:acumatica_tenant] == "MY TENANT"
      assert client.private[:acumatica_api_version] == "24.200.001"

      auth_header =
        Enum.find(client.headers, fn {k, _} -> k == "authorization" end)

      assert {"authorization", ["Basic " <> _]} = auth_header
    end

    test "builds client with bearer auth" do
      client =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "LIVE",
          auth: {:bearer, "my-token-123"}
        )

      auth_header =
        Enum.find(client.headers, fn {k, _} -> k == "authorization" end)

      assert {"authorization", ["Bearer my-token-123"]} = auth_header
    end

    test "sets JSON accept header" do
      client =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "LIVE",
          auth: {:basic, "admin", "pass"}
        )

      accept_header =
        Enum.find(client.headers, fn {k, _} -> k == "accept" end)

      assert {"accept", ["application/json"]} = accept_header
    end

    test "custom api_version" do
      client =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "LIVE",
          auth: {:basic, "admin", "pass"},
          api_version: "23.100.001"
        )

      assert client.private[:acumatica_api_version] == "23.100.001"
    end
  end

  describe "attach/2" do
    test "attaches plugin to existing Req" do
      req =
        Req.new(retry: false)
        |> ReqAcumatica.attach(
          base_url: "https://example.acumatica.com",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert %Req.Request{} = req
      assert req.private[:acumatica_base_url] == "https://example.acumatica.com"
      assert req.private[:acumatica_tenant] == "TEST"
    end

    test "strips trailing slash from base_url" do
      req =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com/",
          tenant: "LIVE",
          auth: {:basic, "admin", "pass"}
        )

      assert req.private[:acumatica_base_url] == "https://example.acumatica.com"
    end
  end

  describe "odata_url/2" do
    test "builds OData URL with encoded tenant" do
      req =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "MAIN",
          auth: {:basic, "admin", "pass"}
        )

      assert ReqAcumatica.odata_url(req) ==
               "https://example.acumatica.com/odata/MAIN/"

      assert ReqAcumatica.odata_url(req, "MyInquiry") ==
               "https://example.acumatica.com/odata/MAIN/MyInquiry"
    end
  end

  describe "rest_url/2" do
    test "builds REST URL with version" do
      req =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "LIVE",
          auth: {:basic, "admin", "pass"}
        )

      assert ReqAcumatica.rest_url(req) ==
               "https://example.acumatica.com/entity/Default/24.200.001/"

      assert ReqAcumatica.rest_url(req, "SalesOrder") ==
               "https://example.acumatica.com/entity/Default/24.200.001/SalesOrder"
    end

    test "uses custom api_version" do
      req =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "LIVE",
          auth: {:basic, "admin", "pass"},
          api_version: "23.100.001"
        )

      assert ReqAcumatica.rest_url(req, "Customer") ==
               "https://example.acumatica.com/entity/Default/23.100.001/Customer"
    end
  end

  describe "request/2" do
    test "delegates to Req.request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      req =
        ReqAcumatica.new(
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, %Req.Response{status: 200}} =
               ReqAcumatica.request(req, url: "http://localhost:#{bypass.port}/test")
    end
  end
end

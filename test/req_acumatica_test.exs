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

      # Verify base URL includes encoded tenant
      assert client.options.base_url == "https://example.acumatica.com/odata/MY%20TENANT"

      # Verify auth header
      auth_header =
        Enum.find(client.headers, fn {k, _} -> k == "authorization" end)

      assert {"authorization", "Basic " <> _} = auth_header
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

      assert {"authorization", "Bearer my-token-123"} = auth_header
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

      assert {"accept", "application/json"} = accept_header
    end

    test "encodes tenant with spaces" do
      client =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com",
          tenant: "NEWLIGHT LIVE",
          auth: {:basic, "admin", "pass"}
        )

      assert client.options.base_url == "https://example.acumatica.com/odata/NEWLIGHT%20LIVE"
    end

    test "strips trailing slash from base_url" do
      client =
        ReqAcumatica.new(
          base_url: "https://example.acumatica.com/",
          tenant: "LIVE",
          auth: {:basic, "admin", "pass"}
        )

      assert client.options.base_url == "https://example.acumatica.com/odata/LIVE"
    end
  end
end

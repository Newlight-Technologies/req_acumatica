defmodule ReqAcumatica.ClientServerTest do
  use ExUnit.Case

  alias ReqAcumatica.ClientServer

  describe "start_link/1 with basic auth" do
    test "starts and returns a client" do
      {:ok, pid} =
        ClientServer.start_link(
          name: :test_basic,
          base_url: "https://example.acumatica.com",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert Process.alive?(pid)

      assert {:ok, %Req.Request{}} = ClientServer.get_client(:test_basic)

      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with oauth2" do
    test "acquires token and returns client" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/identity/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "server-token",
            "refresh_token" => "server-refresh",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        )
      end)

      {:ok, pid} =
        ClientServer.start_link(
          name: :test_oauth,
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:oauth2, "cid", "csecret", "user", "pass"}
        )

      assert {:ok, client} = ClientServer.get_client(:test_oauth)
      assert %Req.Request{} = client

      assert {:ok, info} = ClientServer.token_info(:test_oauth)
      assert info.has_refresh_token == true
      assert %DateTime{} = info.expires_at

      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with failed auth" do
    test "starts but returns error on get_client, retries" do
      bypass = Bypass.open()

      # First call fails (init), second fails (retry in handle_continue),
      # third succeeds (get_client)
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/identity/connect/token", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        if count <= 2 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "access_token" => "recovered-token",
              "token_type" => "Bearer",
              "expires_in" => 3600
            })
          )
        end
      end)

      {:ok, pid} =
        ClientServer.start_link(
          name: :test_retry,
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:oauth2, "cid", "csecret", "user", "pass"}
        )

      # Wait for the retry in handle_continue (5s sleep + request)
      Process.sleep(6_000)

      # Third attempt via get_client should succeed
      assert {:ok, %Req.Request{}} = ClientServer.get_client(:test_retry)

      GenServer.stop(pid)
    end
  end

  describe "refresh/1" do
    test "forces token refresh" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/identity/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "refreshed-token-#{System.unique_integer([:positive])}",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        )
      end)

      {:ok, pid} =
        ClientServer.start_link(
          name: :test_refresh,
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:oauth2, "cid", "csecret", "user", "pass"}
        )

      assert {:ok, _client} = ClientServer.refresh(:test_refresh)

      GenServer.stop(pid)
    end
  end

  describe "token_info/1" do
    test "returns :no_token when client is nil" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/identity/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "bad"}))
      end)

      {:ok, pid} =
        ClientServer.start_link(
          name: :test_no_token,
          base_url: "http://localhost:#{bypass.port}",
          tenant: "TEST",
          auth: {:oauth2, "cid", "csecret", "user", "bad"}
        )

      # Give init time to fail
      Process.sleep(100)

      assert {:error, :no_token} = ClientServer.token_info(:test_no_token)

      GenServer.stop(pid)
    end

    test "returns static type for basic auth" do
      {:ok, pid} =
        ClientServer.start_link(
          name: :test_static_info,
          base_url: "https://example.acumatica.com",
          tenant: "TEST",
          auth: {:basic, "admin", "pass"}
        )

      assert {:ok, %{type: :static}} = ClientServer.token_info(:test_static_info)

      GenServer.stop(pid)
    end
  end
end

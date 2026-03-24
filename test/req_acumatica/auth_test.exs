defmodule ReqAcumatica.AuthTest do
  use ExUnit.Case, async: true

  alias ReqAcumatica.Auth

  describe "acquire_token/1" do
    test "acquires token from identity server" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/identity/connect/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "password"
        assert params["client_id"] == "test-client"
        assert params["client_secret"] == "test-secret"
        assert params["username"] == "admin"
        assert params["password"] == "pass123"
        assert params["scope"] == "api offline_access"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "test-access-token",
            "refresh_token" => "test-refresh-token",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        )
      end)

      assert {:ok, token} =
               Auth.acquire_token(
                 base_url: "http://localhost:#{bypass.port}",
                 client_id: "test-client",
                 client_secret: "test-secret",
                 username: "admin",
                 password: "pass123"
               )

      assert token.access_token == "test-access-token"
      assert token.refresh_token == "test-refresh-token"
      assert token.token_type == "Bearer"
      assert token.expires_in == 3600
      assert %DateTime{} = token.expires_at
    end

    test "appends tenant to client_id when provided" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/identity/connect/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["client_id"] == "test-client@NEWLIGHT LIVE"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "tok",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        )
      end)

      assert {:ok, _token} =
               Auth.acquire_token(
                 base_url: "http://localhost:#{bypass.port}",
                 client_id: "test-client",
                 client_secret: "test-secret",
                 username: "admin",
                 password: "pass",
                 tenant: "NEWLIGHT LIVE"
               )
    end

    test "returns error on auth failure" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/identity/connect/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Invalid username or password"
          })
        )
      end)

      assert {:error, %ReqAcumatica.Error{status: 400, message: message}} =
               Auth.acquire_token(
                 base_url: "http://localhost:#{bypass.port}",
                 client_id: "test-client",
                 client_secret: "test-secret",
                 username: "admin",
                 password: "wrong"
               )

      assert message =~ "invalid_grant"
      assert message =~ "Invalid username or password"
    end
  end

  describe "refresh_token/2" do
    test "refreshes an existing token" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/identity/connect/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "old-refresh-token"
        assert params["client_id"] == "test-client"
        assert params["client_secret"] == "test-secret"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new-access-token",
            "refresh_token" => "new-refresh-token",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        )
      end)

      old_token = %Auth{
        access_token: "old-access-token",
        refresh_token: "old-refresh-token",
        token_type: "Bearer"
      }

      assert {:ok, new_token} =
               Auth.refresh_token(old_token,
                 base_url: "http://localhost:#{bypass.port}",
                 client_id: "test-client",
                 client_secret: "test-secret"
               )

      assert new_token.access_token == "new-access-token"
      assert new_token.refresh_token == "new-refresh-token"
    end

    test "returns error when no refresh_token available" do
      token = %Auth{
        access_token: "some-token",
        refresh_token: nil,
        token_type: "Bearer"
      }

      assert {:error, %ReqAcumatica.Error{message: message}} =
               Auth.refresh_token(token,
                 base_url: "http://example.com",
                 client_id: "c",
                 client_secret: "s"
               )

      assert message =~ "no refresh_token"
    end
  end

  describe "expired?/2" do
    test "returns false when expires_at is nil" do
      token = %Auth{access_token: "tok", expires_at: nil}
      refute Auth.expired?(token)
    end

    test "returns false when token is still valid" do
      token = %Auth{
        access_token: "tok",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      refute Auth.expired?(token)
    end

    test "returns true when token has expired" do
      token = %Auth{
        access_token: "tok",
        expires_at: DateTime.add(DateTime.utc_now(), -10, :second)
      }

      assert Auth.expired?(token)
    end

    test "returns true when within buffer window" do
      token = %Auth{
        access_token: "tok",
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      }

      # Default 60s buffer — 30s remaining means expired
      assert Auth.expired?(token)
      # With smaller buffer, not expired
      refute Auth.expired?(token, 10)
    end
  end
end

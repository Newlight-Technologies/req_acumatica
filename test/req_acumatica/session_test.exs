defmodule ReqAcumatica.SessionTest do
  use ExUnit.Case, async: true

  alias ReqAcumatica.Session

  defp login_bypass(bypass, opts \\ []) do
    status = Keyword.get(opts, :status, 204)

    cookies =
      Keyword.get(opts, :cookies, [
        "ASP.NET_SessionId=abc123; path=/; HttpOnly",
        ".ASPXAUTH=token456; path=/; secure; HttpOnly",
        "UserBranch=1; path=/",
        "CompanyID=TEST; path=/"
      ])

    Bypass.expect_once(bypass, "POST", "/entity/auth/login", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)

      assert data["name"] == "admin"
      assert data["password"] == "pass123"
      assert data["company"] == "TEST CO"

      conn
      |> Plug.Conn.prepend_resp_headers(Enum.map(cookies, &{"set-cookie", &1}))
      |> Plug.Conn.resp(status, "")
    end)
  end

  describe "login/1" do
    test "logs in and captures cookies" do
      bypass = Bypass.open()
      login_bypass(bypass)

      assert {:ok, session} =
               Session.login(
                 base_url: "http://localhost:#{bypass.port}",
                 username: "admin",
                 password: "pass123",
                 company: "TEST CO"
               )

      assert session.cookies =~ "ASP.NET_SessionId=abc123"
      assert session.cookies =~ ".ASPXAUTH=token456"
      assert %DateTime{} = session.logged_in_at
      assert session.username == "admin"
      assert session.company == "TEST CO"
    end

    test "returns error on auth failure" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/entity/auth/login", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"exceptionMessage" => "Invalid credentials"}))
      end)

      assert {:error, %ReqAcumatica.Error{status: 401, message: "Invalid credentials"}} =
               Session.login(
                 base_url: "http://localhost:#{bypass.port}",
                 username: "admin",
                 password: "wrong",
                 company: "TEST CO"
               )
    end
  end

  describe "refresh/1" do
    test "re-authenticates and returns fresh session" do
      bypass = Bypass.open()

      # refresh calls login again
      Bypass.expect_once(bypass, "POST", "/entity/auth/login", fn conn ->
        conn
        |> Plug.Conn.prepend_resp_headers([
          {"set-cookie", "ASP.NET_SessionId=new789; path=/"},
          {"set-cookie", ".ASPXAUTH=newtoken; path=/"}
        ])
        |> Plug.Conn.resp(204, "")
      end)

      old_session = %Session{
        cookies: "old",
        logged_in_at: DateTime.add(DateTime.utc_now(), -1200, :second),
        base_url: "http://localhost:#{bypass.port}",
        username: "admin",
        password: "pass123",
        company: "TEST CO"
      }

      assert {:ok, new_session} = Session.refresh(old_session)
      assert new_session.cookies =~ "ASP.NET_SessionId=new789"
    end
  end

  describe "logout/1" do
    test "logs out the session" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/entity/auth/logout", fn conn ->
        assert Plug.Conn.get_req_header(conn, "cookie") == ["session-cookies"]
        Plug.Conn.resp(conn, 204, "")
      end)

      session = %Session{
        cookies: "session-cookies",
        logged_in_at: DateTime.utc_now(),
        base_url: "http://localhost:#{bypass.port}",
        username: "admin",
        password: "pass",
        company: "TEST"
      }

      assert :ok = Session.logout(session)
    end
  end

  describe "expired?/2" do
    test "returns false for fresh session" do
      session = %Session{logged_in_at: DateTime.utc_now()}
      refute Session.expired?(session)
    end

    test "returns true for old session" do
      session = %Session{
        logged_in_at: DateTime.add(DateTime.utc_now(), -1200, :second)
      }

      assert Session.expired?(session)
    end

    test "returns true when logged_in_at is nil" do
      session = %Session{logged_in_at: nil}
      assert Session.expired?(session)
    end

    test "custom timeout" do
      session = %Session{
        logged_in_at: DateTime.add(DateTime.utc_now(), -120, :second)
      }

      # 2 minutes old, 1 minute timeout = expired
      assert Session.expired?(session, 1)
      # 2 minutes old, 5 minute timeout = not expired
      refute Session.expired?(session, 5)
    end
  end
end

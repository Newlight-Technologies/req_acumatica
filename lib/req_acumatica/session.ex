defmodule ReqAcumatica.Session do
  @moduledoc """
  Cookie-based session authentication for Acumatica APIs.

  Authenticates via `POST /entity/auth/login` and manages session cookies
  (`.ASPXAUTH`, `ASP.NET_SessionId`, etc.) for subsequent requests.

  This is the auth method used by the Acumatica web UI and is required
  for the Contract-Based REST API when OAuth2 Connected Applications
  are not configured.

  ## Usage

      {:ok, session} = ReqAcumatica.Session.login(
        base_url: "https://mycompany.acumatica.com",
        username: "apiuser",
        password: "secret",
        company: "NEWLIGHT LIVE"
      )

      session.cookies
      # => "ASP.NET_SessionId=...; .ASPXAUTH=...; ..."

      # Check if session is still valid (20 min timeout)
      ReqAcumatica.Session.expired?(session)
  """

  defstruct [:cookies, :logged_in_at, :base_url, :username, :password, :company]

  @type t :: %__MODULE__{
          cookies: String.t(),
          logged_in_at: DateTime.t(),
          base_url: String.t(),
          username: String.t(),
          password: String.t(),
          company: String.t()
        }

  @login_path "/entity/auth/login"
  @logout_path "/entity/auth/logout"
  @session_timeout_minutes 15

  @doc """
  Logs in to Acumatica and returns a session with cookies.

  ## Options

    * `:base_url` (required) — Acumatica instance URL
    * `:username` (required) — Acumatica username
    * `:password` (required) — Acumatica password
    * `:company` (required) — Tenant/company name
    * `:branch` — Optional branch name
  """
  @spec login(keyword()) :: {:ok, t()} | {:error, term()}
  def login(opts) do
    base_url = Keyword.fetch!(opts, :base_url) |> String.trim_trailing("/")
    username = Keyword.fetch!(opts, :username)
    password = Keyword.fetch!(opts, :password)
    company = Keyword.fetch!(opts, :company)
    branch = Keyword.get(opts, :branch)

    body =
      %{"name" => username, "password" => password, "company" => company}
      |> then(fn b -> if branch, do: Map.put(b, "branch", branch), else: b end)

    url = base_url <> @login_path

    case Req.post(Req.new(redirect: false), url: url, json: body) do
      {:ok, %Req.Response{status: 204} = resp} ->
        cookies = extract_cookies(resp)

        {:ok,
         %__MODULE__{
           cookies: cookies,
           logged_in_at: DateTime.utc_now(),
           base_url: base_url,
           username: username,
           password: password,
           company: company
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        message =
          if is_map(body),
            do: body["exceptionMessage"] || body["message"] || inspect(body),
            else: inspect(body)

        {:error, %ReqAcumatica.Error{status: status, message: message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Re-authenticates using stored credentials, returning a fresh session.
  """
  @spec refresh(t()) :: {:ok, t()} | {:error, term()}
  def refresh(%__MODULE__{} = session) do
    login(
      base_url: session.base_url,
      username: session.username,
      password: session.password,
      company: session.company
    )
  end

  @doc """
  Logs out the current session.
  """
  @spec logout(t()) :: :ok | {:error, term()}
  def logout(%__MODULE__{base_url: base_url, cookies: cookies}) do
    url = base_url <> @logout_path

    case Req.post(Req.new(redirect: false),
           url: url,
           headers: [{"cookie", cookies}]
         ) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %ReqAcumatica.Error{status: status, message: inspect(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true if the session has likely expired (default 15 min timeout).

  Acumatica sessions typically expire after 20 minutes of inactivity.
  We use a 15-minute buffer to be safe.
  """
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(session, timeout_minutes \\ @session_timeout_minutes)
  def expired?(%__MODULE__{logged_in_at: nil}, _timeout), do: true

  def expired?(%__MODULE__{logged_in_at: logged_in_at}, timeout_minutes) do
    cutoff = DateTime.add(logged_in_at, timeout_minutes * 60, :second)
    DateTime.compare(DateTime.utc_now(), cutoff) != :lt
  end

  defp extract_cookies(%Req.Response{headers: headers}) do
    headers
    |> Map.get("set-cookie", [])
    |> Enum.map(fn cookie -> cookie |> String.split(";") |> hd() end)
    |> Enum.uniq_by(fn cookie -> cookie |> String.split("=") |> hd() end)
    |> Enum.join("; ")
  end
end

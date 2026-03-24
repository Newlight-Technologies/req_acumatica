# ReqAcumatica

[Req](https://hex.pm/packages/req) plugin for the [Acumatica](https://www.acumatica.com/) OData API.

Query Generic Inquiries exposed via OData from Elixir with a clean, composable API.

## Installation

```elixir
def deps do
  [
    {:req_acumatica, path: "../req_acumatica"}
  ]
end
```

## Quick Start

```elixir
# Create a client
client = ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:basic, "apiuser", "secret"}
)

# List available Generic Inquiries
{:ok, inquiries} = ReqAcumatica.list_inquiries(client)

# Query a GI with OData filters
{:ok, result} = ReqAcumatica.query(client, "Sales Orders and Quotes",
  filter: "Status eq 'Open'",
  top: 25,
  orderby: "OrderTotal desc"
)

result.rows
# => [%{"OrderNbr" => "SO-001234", "Status" => "Open", ...}, ...]
```

## Filter Builder

Instead of hand-writing OData filter strings, use the composable filter DSL:

```elixir
import ReqAcumatica.Filter

filter =
  eq("Status", "Open")
  |> and_filter(gt("OrderTotal", 1000))
  |> and_filter(contains("CustomerName", "Newlight"))

ReqAcumatica.query(client, "Sales Orders", filter: to_string(filter))
```

## Pagination

### Fetch all results

```elixir
{:ok, result} = ReqAcumatica.query_all(client, "Large Inquiry",
  filter: "Active eq true",
  page_size: 200,
  max_results: 5000
)
```

### Lazy streaming

```elixir
client
|> ReqAcumatica.stream("Inventory Items", page_size: 100)
|> Stream.filter(& &1["QtyOnHand"] > 0)
|> Enum.take(50)
```

## Authentication

Three auth methods are supported.

### Basic Auth

```elixir
ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:basic, "username", "password"}
)
```

### OAuth2 Bearer Token (pre-obtained)

Obtain a token via Acumatica's Connected Applications (SM303010 screen),
then pass it directly:

```elixir
ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:bearer, "eyJhbGciOi..."}
)
```

### OAuth2 Resource Owner (automatic token management)

Uses Acumatica's `/identity/connect/token` endpoint with `grant_type=password`.
The token is acquired automatically on client creation and refreshed transparently
before expiry on each request.

**Prerequisites:** Create a Connected Application in Acumatica (SM303010 screen)
with Flow Type = "Resource Owner Password Credentials".

```elixir
client = ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:oauth2, "client-id", "client-secret", "apiuser", "password"},
  scope: "api offline_access"
)
```

The client embeds a Req request step that automatically refreshes the token when
it's about to expire. If refresh fails, it falls back to a full re-acquisition.

## ClientServer (long-lived cached client)

For applications that make many requests, `ReqAcumatica.ClientServer` provides a
GenServer that holds a single shared client and proactively refreshes its token
before expiry.

### Configuration

```elixir
# config/runtime.exs
config :req_acumatica,
  base_url: System.fetch_env!("ACUMATICA_BASE_URL"),
  tenant: System.fetch_env!("ACUMATICA_TENANT"),
  auth: {:oauth2,
    System.fetch_env!("ACUMATICA_CLIENT_ID"),
    System.fetch_env!("ACUMATICA_CLIENT_SECRET"),
    System.fetch_env!("ACUMATICA_USERNAME"),
    System.fetch_env!("ACUMATICA_PASSWORD")},
  scope: "api offline_access"
```

### Supervision tree

```elixir
# application.ex
children = [
  ReqAcumatica.ClientServer
]
```

### Usage

```elixir
{:ok, client} = ReqAcumatica.ClientServer.get_client()
{:ok, result} = ReqAcumatica.query(client, "My Inquiry")
```

## OData URL Pattern

For Acumatica, the OData endpoint follows this pattern:

```
https://{instance}/odata/{Tenant Name}/{Generic Inquiry Name}
```

For example:
```
https://newlight.acumatica.com/odata/NEWLIGHT%20LIVE/Sales%20Orders%20and%20Quotes
```

## Using with Ash Framework and Daisy

This library is designed to integrate with [Ash](https://hexdocs.pm/ash/) manual
actions, allowing Acumatica Generic Inquiries to be exposed as Ash resources.
In Daisy, users authenticate via LDAP — the Acumatica connection uses a shared
service account so users don't need separate Acumatica credentials.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Daisy User (LDAP session)                                  │
│  current_user = %Daisy.Accounts.User{...}                   │
└──────────────────────┬──────────────────────────────────────┘
                       │ actor: current_user
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Daisy.Acumatica Domain                                     │
│  define :list_shipment_details, action: :list               │
│  Ash policies check actor's LDAP groups / permissions       │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Ash Resource (Ash.DataLayer.Simple)                        │
│  Manual read action → calls ReqAcumatica                    │
│  Maps OData rows → Ash resource structs                     │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  ReqAcumatica.ClientServer                                  │
│  Shared OAuth2 service account, auto-refreshing token       │
│  Configured from app env vars                               │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Acumatica OData API                                        │
│  GET /odata/{tenant}/{GI Name}?$filter=...&$top=...         │
└─────────────────────────────────────────────────────────────┘
```

### Step 1: Add dependency to Daisy

```elixir
# mix.exs
{:req_acumatica, path: "../req_acumatica"}
```

### Step 2: Configure the service account

```elixir
# config/runtime.exs
config :req_acumatica,
  base_url: System.fetch_env!("ACUMATICA_BASE_URL"),
  tenant: System.fetch_env!("ACUMATICA_TENANT"),
  auth: {:oauth2,
    System.fetch_env!("ACUMATICA_CLIENT_ID"),
    System.fetch_env!("ACUMATICA_CLIENT_SECRET"),
    System.fetch_env!("ACUMATICA_USERNAME"),
    System.fetch_env!("ACUMATICA_PASSWORD")},
  scope: "api offline_access"
```

### Step 3: Add ClientServer to supervision tree

```elixir
# lib/daisy/application.ex
children = [
  # ... existing children ...
  ReqAcumatica.ClientServer
]
```

### Step 4: Define an Ash resource wrapping a Generic Inquiry

```elixir
defmodule Daisy.Acumatica.ShipmentDetail do
  use Ash.Resource,
    domain: Daisy.Acumatica

  # No data layer — manual reads from external API

  attributes do
    attribute :order_nbr, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :shipment_nbr, :string, public?: true
    attribute :customer_id, :string, public?: true
    attribute :customer_name, :string, public?: true
    attribute :status, :string, public?: true
    attribute :inventory_id, :string, public?: true
    attribute :ship_date, :date, public?: true
    attribute :shipped_qty, :integer, public?: true
    attribute :uom, :string, public?: true
    attribute :description, :string, public?: true
  end

  actions do
    read :list do
      argument :status, :string
      argument :customer_name, :string

      manual Daisy.Acumatica.ShipmentDetail.ListAction
    end
  end
end
```

### Step 5: Implement the manual read action

```elixir
defmodule Daisy.Acumatica.ShipmentDetail.ListAction do
  use Ash.Resource.ManualRead

  @gi_name "Shipment Labels with GI V7"

  @impl true
  def read(query, _data_layer_query, _opts, _context) do
    with {:ok, client} <- ReqAcumatica.ClientServer.get_client() do
      odata_opts = build_odata_opts(query)

      case ReqAcumatica.query(client, @gi_name, odata_opts) do
        {:ok, result} ->
          records = Enum.map(result.rows, &row_to_struct/1)
          {:ok, records}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp build_odata_opts(query) do
    opts = [top: 200]

    opts =
      case Ash.Query.get_argument(query, :status) do
        nil -> opts
        status -> Keyword.put(opts, :filter, "Status eq '#{status}'")
      end

    opts
  end

  defp row_to_struct(row) do
    %Daisy.Acumatica.ShipmentDetail{
      order_nbr: row["OrderNbr"],
      shipment_nbr: row["ShipmentNbr"],
      customer_id: row["CustomerID"],
      customer_name: row["CustomerName"],
      status: row["Status"],
      inventory_id: row["InventoryID"],
      ship_date: parse_date(row["ShipDate"]),
      shipped_qty: row["ShippedQty"],
      uom: row["UOM"],
      description: row["Description"]
    }
  end

  defp parse_date(nil), do: nil
  defp parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
```

### Step 6: Define the Ash domain with code interfaces

```elixir
defmodule Daisy.Acumatica do
  use Ash.Domain

  resources do
    resource Daisy.Acumatica.ShipmentDetail do
      define :list_shipment_details, action: :list
    end
  end
end
```

### Step 7: Use from LiveViews

The logged-in LDAP user is the actor — no separate Acumatica login needed:

```elixir
defmodule DaisyWeb.Acumatica.ShipmentLive do
  use DaisyWeb, :live_view

  def mount(_params, _session, socket) do
    shipments =
      Daisy.Acumatica.list_shipment_details!(
        %{status: "Shipping"},
        actor: socket.assigns.current_user
      )

    {:ok, assign(socket, :shipments, shipments)}
  end
end
```

### Step 8: Add Ash policies for authorization

Control which LDAP users can access Acumatica data:

```elixir
# In ShipmentDetail resource
policies do
  policy action_type(:read) do
    authorize_if actor_present()
    # Or restrict to specific LDAP groups:
    # authorize_if expr(^actor(:ldap_groups) |> contains("acumatica-users"))
  end
end
```

## License

MIT

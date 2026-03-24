# ReqAcumatica

[Req](https://hex.pm/packages/req) plugin for the [Acumatica](https://www.acumatica.com/) API.

Provides authenticated access to both the **OData API** (Generic Inquiries) and the
**Contract-Based REST API** (entity CRUD + actions) following the
[Dashbit Req SDK pattern](https://dashbit.co/blog/sdks-with-req-s3).

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
# Create a client (convenience for Req.new() |> ReqAcumatica.attach(...))
req = ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:basic, "apiuser", "secret"}
)

# OData: Query a Generic Inquiry
{:ok, result} = ReqAcumatica.OData.query(req, "Sales Orders and Quotes",
  filter: "Status eq 'Open'",
  top: 25,
  orderby: "OrderTotal desc"
)

result.rows
# => [%{"OrderNbr" => "SO-001234", "Status" => "Open", ...}, ...]

# REST: Get a sales order
{:ok, order} = ReqAcumatica.REST.get(req, "SalesOrder/SO-001234")

# REST: Create a customer
{:ok, customer} = ReqAcumatica.REST.create(req, "Customer", %{
  "CustomerID" => %{"value" => "NEWCUST"},
  "CustomerName" => %{"value" => "New Customer Inc"}
})
```

## Plugin Pattern

Following the Dashbit Req SDK pattern, `ReqAcumatica` is a Req plugin.
Use `attach/2` to augment any existing Req request:

```elixir
# Attach to an existing Req with custom options
req = Req.new(retry: :transient, connect_options: [timeout: 30_000])
      |> ReqAcumatica.attach(
        base_url: "https://mycompany.acumatica.com",
        tenant: "MY TENANT",
        auth: {:oauth2, "client-id", "client-secret", "user", "pass"}
      )

# Or use the convenience function
req = ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:basic, "apiuser", "secret"},
  req_options: [retry: :transient]
)

# Low-level: use Req directly with the configured client
{:ok, resp} = ReqAcumatica.request(req, url: "/custom/endpoint")
resp = ReqAcumatica.request!(req, url: "/custom/endpoint")
```

## OData API (Generic Inquiries)

Read-only access to Acumatica Generic Inquiries via `ReqAcumatica.OData`.

```elixir
# List available GIs
{:ok, inquiries} = ReqAcumatica.OData.list_inquiries(req)

# Query with filters
{:ok, result} = ReqAcumatica.OData.query(req, "Shipment Labels with GI V7",
  filter: "Status eq 'Shipping'",
  top: 100,
  select: ["OrderNbr", "ShipmentNbr", "CustomerName"]
)

# Get metadata (XML)
{:ok, xml} = ReqAcumatica.OData.metadata(req, "InvoicedItems")

# Paginate through all results
{:ok, all} = ReqAcumatica.OData.query_all(req, "Large Inquiry",
  page_size: 200,
  max_results: 5000
)

# Lazy streaming (memory-efficient)
req
|> ReqAcumatica.OData.stream("Inventory Items", page_size: 100)
|> Stream.filter(& &1["QtyOnHand"] > 0)
|> Enum.take(50)
```

## REST API (Entity CRUD + Actions)

Full create/read/update/delete on Acumatica business entities via `ReqAcumatica.REST`.

```elixir
# List entities with filters
{:ok, orders} = ReqAcumatica.REST.list(req, "SalesOrder",
  filter: "Status eq 'Open'",
  top: 50,
  expand: "Details"
)

# Get a single entity by key
{:ok, order} = ReqAcumatica.REST.get(req, "SalesOrder/SO-001234")

# Create (Acumatica uses PUT for create/upsert)
{:ok, created} = ReqAcumatica.REST.create(req, "SalesOrder", %{
  "OrderType" => %{"value" => "SO"},
  "CustomerID" => %{"value" => "CUSTOMER01"},
  "Description" => %{"value" => "New order from API"}
})

# Update (include key fields to identify the record)
{:ok, updated} = ReqAcumatica.REST.update(req, "SalesOrder", %{
  "OrderType" => %{"value" => "SO"},
  "OrderNbr" => %{"value" => "SO-001234"},
  "Description" => %{"value" => "Updated via API"}
})

# Delete
:ok = ReqAcumatica.REST.delete(req, "Customer/OLDCUST")

# Invoke entity action
{:ok, _} = ReqAcumatica.REST.action(req, "SalesOrder", "ReleaseFromHold", %{
  "entity" => %{
    "OrderType" => %{"value" => "SO"},
    "OrderNbr" => %{"value" => "SO-001234"}
  }
})

# Unwrap Acumatica's %{"value" => x} format
flat = ReqAcumatica.REST.unwrap_values(order)
# %{"OrderNbr" => "SO-001", "Status" => "Open", ...}
```

## Filter Builder

Instead of hand-writing OData filter strings, use the composable filter DSL:

```elixir
import ReqAcumatica.Filter

filter =
  eq("Status", "Open")
  |> and_filter(gt("OrderTotal", 1000))
  |> and_filter(contains("CustomerName", "Newlight"))

ReqAcumatica.OData.query(req, "Sales Orders", filter: to_string(filter))
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

```elixir
ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:bearer, "eyJhbGciOi..."}
)
```

### OAuth2 Resource Owner (automatic token management)

Uses `/identity/connect/token` with `grant_type=password`. Requires a Connected
Application (SM303010) with Flow Type = "Resource Owner Password Credentials".

```elixir
req = ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:oauth2, "client-id", "client-secret", "apiuser", "password"},
  scope: "api offline_access"
)
```

Tokens are refreshed transparently before expiry on each request.

## ClientServer (long-lived cached client)

For applications that make many requests, `ReqAcumatica.ClientServer` provides a
GenServer that holds a shared client and proactively refreshes its OAuth2 token.

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

# application.ex
children = [ReqAcumatica.ClientServer]

# usage
{:ok, req} = ReqAcumatica.ClientServer.get_client()
{:ok, result} = ReqAcumatica.OData.query(req, "My Inquiry")
```

## Using with Ash Framework and Daisy

This library integrates with [Ash](https://hexdocs.pm/ash/) manual actions,
allowing Acumatica data to be exposed as Ash resources. In Daisy, users authenticate
via LDAP — the Acumatica connection uses a shared service account so users
don't need separate credentials.

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
│  Manual read action → calls ReqAcumatica.OData / REST      │
│  Maps API response → Ash resource structs                   │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  ReqAcumatica.ClientServer                                  │
│  Shared OAuth2 service account, auto-refreshing token       │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Acumatica APIs                                             │
│  OData: GET /odata/{tenant}/{GI}?$filter=...                │
│  REST:  GET/PUT/DELETE /entity/Default/{ver}/{Entity}       │
└─────────────────────────────────────────────────────────────┘
```

### Setup in Daisy

**1. Add dependency:**
```elixir
# mix.exs
{:req_acumatica, path: "../req_acumatica"}
```

**2. Configure service account:**
```elixir
# config/runtime.exs
config :req_acumatica,
  base_url: System.fetch_env!("ACUMATICA_BASE_URL"),
  tenant: System.fetch_env!("ACUMATICA_TENANT"),
  auth: {:oauth2,
    System.fetch_env!("ACUMATICA_CLIENT_ID"),
    System.fetch_env!("ACUMATICA_CLIENT_SECRET"),
    System.fetch_env!("ACUMATICA_USERNAME"),
    System.fetch_env!("ACUMATICA_PASSWORD")}
```

**3. Add to supervision tree:**
```elixir
# lib/daisy/application.ex
children = [
  # ...
  ReqAcumatica.ClientServer
]
```

**4. Define Ash resource with manual read:**
```elixir
defmodule Daisy.Acumatica.ShipmentDetail do
  use Ash.Resource, domain: Daisy.Acumatica

  attributes do
    attribute :order_nbr, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :shipment_nbr, :string, public?: true
    attribute :customer_name, :string, public?: true
    attribute :status, :string, public?: true
    attribute :ship_date, :date, public?: true
    # ... more fields from the GI
  end

  actions do
    read :list do
      argument :status, :string
      manual Daisy.Acumatica.ShipmentDetail.ListAction
    end
  end
end
```

**5. Implement manual read action:**
```elixir
defmodule Daisy.Acumatica.ShipmentDetail.ListAction do
  use Ash.Resource.ManualRead

  @impl true
  def read(query, _data_layer_query, _opts, _context) do
    with {:ok, req} <- ReqAcumatica.ClientServer.get_client() do
      case ReqAcumatica.OData.query(req, "Shipment Labels with GI V7", top: 200) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &row_to_struct/1)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp row_to_struct(row) do
    %Daisy.Acumatica.ShipmentDetail{
      order_nbr: row["OrderNbr"],
      shipment_nbr: row["ShipmentNbr"],
      customer_name: row["CustomerName"],
      status: row["Status"],
      ship_date: parse_date(row["ShipDate"])
    }
  end

  defp parse_date(nil), do: nil
  defp parse_date(s), do: case Date.from_iso8601(s), do: ({:ok, d} -> d; _ -> nil)
end
```

**6. Domain with code interfaces:**
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

**7. Use from LiveView (LDAP user is the actor):**
```elixir
shipments = Daisy.Acumatica.list_shipment_details!(
  %{status: "Shipping"},
  actor: socket.assigns.current_user
)
```

## License

MIT

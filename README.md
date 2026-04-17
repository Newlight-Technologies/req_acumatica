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
  base_url: "https://example.acumatica.com",
  tenant: "MAIN",
  auth: {:basic, "api-user", "secret-password"}
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
        base_url: "https://example.acumatica.com",
        tenant: "MAIN",
        auth: {:oauth2, "client-id", "client-secret", "user", "pass"}
      )

# Or use the convenience function
req = ReqAcumatica.new(
  base_url: "https://example.acumatica.com",
  tenant: "MAIN",
  auth: {:basic, "api-user", "secret-password"},
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
  |> and_filter(contains("CustomerName", "Acme"))

ReqAcumatica.OData.query(req, "Sales Orders", filter: to_string(filter))
```

## Authentication

Three auth methods are supported.

### Basic Auth

```elixir
ReqAcumatica.new(
  base_url: "https://example.acumatica.com",
  tenant: "MAIN",
  auth: {:basic, "username", "password"}
)
```

### OAuth2 Bearer Token (pre-obtained)

```elixir
ReqAcumatica.new(
  base_url: "https://example.acumatica.com",
  tenant: "MAIN",
  auth: {:bearer, "eyJhbGciOi..."}
)
```

### OAuth2 Resource Owner (automatic token management)

Uses `/identity/connect/token` with `grant_type=password`. Requires a Connected
Application (SM303010) with Flow Type = "Resource Owner Password Credentials".

```elixir
req = ReqAcumatica.new(
  base_url: "https://example.acumatica.com",
  tenant: "MAIN",
  auth: {:oauth2, "client-id", "client-secret", "api-user", "password"},
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

## Using with Ash Framework

This library works well with [Ash](https://hexdocs.pm/ash/) manual actions when
you want to expose Acumatica data as read models or wrap Acumatica writes in
domain APIs. A common pattern is:

- start `ReqAcumatica.ClientServer` under supervision
- call `ReqAcumatica.OData` or `ReqAcumatica.REST` from an Ash manual action
- map Acumatica responses into your resource structs or action results

That same pattern also works outside Ash in GenServers, background jobs, and
plain application services.

## License

MIT

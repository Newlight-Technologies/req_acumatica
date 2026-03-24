# ReqAcumatica

[Req](https://hex.pm/packages/req) plugin for the [Acumatica](https://www.acumatica.com/) OData API.

Query Generic Inquiries exposed via OData from Elixir with a clean, composable API.

## Installation

```elixir
def deps do
  [
    {:req_acumatica, "~> 0.1.0"}
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

### Basic Auth

```elixir
ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:basic, "username", "password"}
)
```

### OAuth2 Bearer Token

Obtain a token via Acumatica's Connected Applications (SM303010 screen),
then pass it directly:

```elixir
ReqAcumatica.new(
  base_url: "https://mycompany.acumatica.com",
  tenant: "MY TENANT",
  auth: {:bearer, "eyJhbGciOi..."}
)
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

## Using with Ash Framework

This library pairs well with Ash's manual actions pattern for wrapping
external APIs. See the [Ash guide on wrapping external APIs](https://hexdocs.pm/ash/wrap-external-apis.html).

```elixir
defmodule MyApp.Acumatica.SalesOrder do
  use Ash.Resource, domain: MyApp.Acumatica

  attributes do
    attribute :order_nbr, :string, primary_key?: true, allow_nil?: false
    attribute :status, :string
    attribute :order_total, :decimal
    attribute :customer_name, :string
  end

  actions do
    read :list do
      argument :status, :string
      manual MyApp.Acumatica.SalesOrder.ListAction
    end
  end
end
```

## License

MIT

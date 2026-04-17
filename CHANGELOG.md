# Changelog

## v0.2.0

- Refactor to Dashbit Req SDK plugin pattern (`attach/2` + `new/1`)
- Add `ReqAcumatica.OData` module for Generic Inquiry operations
- Add `ReqAcumatica.REST` module for Contract-Based REST API (CRUD + actions)
- Add `unwrap_values/1` for flattening Acumatica's value wrapper format
- Add `operation_status/2` for polling long-running actions
- Configurable `api_version` for REST API contract version
- Low-level `request/2` and `request!/2` wrappers

## v0.1.0

- Initial release
- Req plugin for Acumatica OData API (Generic Inquiries)
- Basic Auth and Bearer token authentication
- OAuth2 Resource Owner Password Credentials grant with auto-refresh
- ClientServer GenServer for shared token-cached clients
- OData filter builder DSL
- Automatic pagination and lazy streaming

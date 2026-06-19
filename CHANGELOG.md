# Changelog

## v0.3.0

REST file/attachment, pagination, and schema fidelity (validated 1:1 against a live
Acumatica 24.200.001 tenant).

- **Fix `REST.list_files/2`**: now uses `$expand=files` and returns the `files` array
  (`%{"filename", "href", "id"}` per entry). Previously read a `FileURLs` field the
  contract endpoint never returns, so it always returned `[]`. **Breaking**: return type
  is now `[map()]` instead of `[String.t()]`.
- **Add `REST.download_file_by_id/2`**: `GET files/{FileID}` — the preferred download path
  (FileID comes from `list_files/2`), avoiding the fragile folder-prefixed filename.
- **Add `REST.list_all/3`**: bounded `$top`/`$skip` pagination with `:page_size` and
  `:max_results`, mirroring `OData.query_all/3`. Prevents `top: 500` browse adapters.
- **Add `REST.ad_hoc_schema/2`**: `GET {Entity}/$adHocSchema` — the live per-tenant schema.
  `describe/2` reads static `swagger.json`, which can diverge from the live endpoint.
- **Add `:custom_fields` option** to `list/3`/`get/3` → `$custom=` (first-class Usr-field
  selection; the old `:custom` raw-append escape hatch is retained).
- Docs: clarify `download_file/3` is by-filename (prefer by-id); document that `create/3`
  and `update/3` are both `PUT` upserts; document `$expand=files` usage.

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

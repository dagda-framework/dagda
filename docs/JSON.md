# Typed JSON requests and responses

Handlers can decode a request into an Odin struct and serialize a typed response.
Both APIs operate on the HTTP thread. The application reads the body asynchronously
before middleware and handlers run, under the transport's absolute read deadline.
There is no blocking socket read inside `decode_json`.

```odin
Create_Input :: struct {
    name: string,
    quantity: i32,
    labels: []string,
    note: union {string}, // nil or a string
}
Create_Response :: struct {
    accepted: bool,
    name: string,
}

create :: proc(c: ^http.Context) {
    input: Create_Input
    if !http.decode_json(c, &input) { return }
    // Required fields and business rules are checked explicitly by the handler.
    if input.name == "" || input.quantity <= 0 {
        http.json_text(c, 422, `{"error":{"code":"invalid_input"}}`)
        return
    }
    http.respond_json(c, 200, Create_Response{accepted=true, name=input.name})
}
```

The example registers `POST /echo` to round-trip an input struct without database
side effects. Its existing `GET /` now uses a typed response.

```sh
curl http://127.0.0.1:8080/echo \
  -H 'Content-Type: application/json' \
  -d '{"name":"Dagda","count":2,"enabled":true,"labels":["odin"],"note":null}'
```

## Input contract

- Bodies are limited to **8192 bytes**, with a maximum JSON nesting depth of **32**.
- Send `Content-Length` and `Content-Type: application/json`. An optional UTF-8
  charset parameter is accepted; media types and charset names are case-insensitive.
- Syntax is strict JSON: no comments, trailing commas, single quotes, unquoted
  keys, NaN, Infinity, or trailing values. Input must be valid UTF-8.
- Duplicate keys, unknown fields, empty object keys, incompatible types, and
  numeric overflow are rejected. Integer fields require integer JSON tokens;
  `1.0` is not accepted for an integer field. Integer input is limited to the
  signed 64-bit range, including when the destination is unsigned.
- Supported destinations are structs, strings, booleans, integers up to 64 bits,
  `f32`/`f64`, nested structs, slices, fixed arrays of exactly the declared size,
  and nullable single-variant unions such as `union {string}`. Raw pointers,
  maps, dynamic arrays, enums, multi-variant unions, and embedded `using` fields
  are outside this initial decoding contract.
- Struct fields may use Odin's `json:"wire_name"` tags. `json:"-"` fields cannot
  be supplied by clients. Missing fields are zero-valued; nullable unions accept
  `null`, while ordinary scalar/collection fields reject it. The decoded value alone does not
  distinguish missing from explicit null. `http.json_field_state` exposes that
  distinction for top-level fields after successful object decoding. See
  [field validation](VALIDATION.md) for required-value checks and 422 responses.
- Call `decode_json` once per request. It returns false and sends a JSON error on
  failure; the handler must return. Failed decoding leaves the destination
  unchanged. A repeated decode or nil destination returns 500 as a handler error.
- Decoded strings/slices use the request arena and must not outlive the response.
  Do not retain them in application state or worker jobs. `query_text` continues
  to copy SQL parameters into worker-owned storage before returning.

The app buffers bodies for all routes, not just JSON endpoints. Middleware runs
once the body is complete, so it cannot currently reject an upload before it is
read. Bytes remain bounded even for unauthenticated or unmatched requests.
`Context.body` exposes the request-owned bytes for handlers that need them.

Chunked transfer encoding remains unsupported and is rejected. Content encodings
(including gzip) and `Expect` are also rejected before reading a body. HTTP
connections still close after each response; streaming and multipart uploads are
not implemented.

## Responses and errors

`respond_json(context, status, value)` accepts a typed Odin value. Odin's JSON
encoder handles escaping and field tags. Encoding uses a fixed **8192-byte**
writer; no partial successful response is sent if encoding fails or exceeds the
limit. Such failures produce 500 with `invalid_response`. Non-finite floats are
not serializable. Application-created values must be finite, acyclic structures;
custom serializer callbacks must obey the event-loop rules.

The existing `json_text` API remains available for already-encoded JSON, including
PostgreSQL results. Both response APIs preserve HEAD behavior, request IDs,
completion logs, and exactly-once finalization. They cannot finalize a context
while a database operation owns it.

| Condition | Status/code |
| --- | --- |
| Missing/unsupported JSON media type or charset | 415 `unsupported_media_type` |
| Invalid JSON, type mismatch, unknown/duplicate field, range/depth error | 400 `invalid_json` |
| Malformed Content-Length | 400 `invalid_content_length` |
| Body exceeds 8192 bytes | 413 `body_too_large` |
| Body interrupted or read deadline expires | 400 `incomplete_body`, if a response can be delivered |
| Transfer-Encoding | 400 `body_not_supported` |
| Content-Encoding | 415 `unsupported_content_encoding` |
| Expect | 417 `expectation_failed` |
| Encoding failure or response too large | 500 `invalid_response` |

Transport-level framing failures may precede application errors. Error responses
never echo input values or parser diagnostics. Access logs omit body contents.

## Verification

`./scripts/test.sh` includes the typed JSON unit cases and `tests/json_api.py`.
The latter tests wire-level round trips, size boundaries, framing, fragmented
uploads, disconnects, read deadlines, concurrent requests, resource reuse, and
shutdown with an incomplete body. It uses its own temporary PostgreSQL database.

Verification passed on November 6, 2026 (America/Chicago): the build, all 9 HTTP
unit tests (including 5 typed JSON tests), and the complete JSON network suite.
Both M0 integration/failure suites and the M1 lifecycle/routing suite also passed
with this runtime build. The JSON suite passed on a targeted rerun after fixing
its reader to accept empty transport-level rejection bodies; no runtime rebuild
was needed for that fix.

Across interrupted uploads and concurrent requests, sampled RSS stayed at
7172 KiB, with 3 threads and 6 descriptors before and after. See the
[validation record](validation/2026-11-06-json.json). These are bounded integration
checks, not a repeat of the historical M0 30-minute stability run.

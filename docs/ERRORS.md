# Common application errors

Dagda's application-layer errors share this JSON envelope:

```json
{
  "error": {
    "code": "not_found",
    "message": "Resource not found"
  },
  "request_id": "same-generated-id-as-X-Request-ID"
}
```

`http.Error_Response` and `http.Error_Detail` are the public Odin types. Validation
uses the same types, adding `error.fields` and, only when needed,
`error.truncated`. `Validation_Response`/`Validation_Error` remain aliases.

Applications can use a predefined error or define a public application error:

```odin
http.fail(c, .Not_Found)
http.respond_error(c, 409, "revision_conflict", "The record has changed")
```

Only call one for a given response. Both respect exactly-once finalization and
refuse to finish a request while a database operation owns it. `respond_error`
accepts statuses 400–599, an application-authored code of at most 32 ASCII bytes
(letters, digits, underscores), and a nonempty UTF-8 message of at most 256 bytes.
Invalid metadata becomes 500 `internal_error` with a generic message. Do not pass
raw SQL errors, exceptions, credentials, or submitted values as messages/codes.

## Framework mappings

| Source | Status | Code |
| --- | --- | --- |
| Unknown route or missing database row | 404 | `not_found` |
| Unsupported method on a known route | 405, plus `Allow` | `method_not_allowed` |
| Rejected path | 400 | `invalid_path` |
| Invalid JSON syntax, shape, or field types | 400 | `invalid_json` |
| Unsupported JSON media type/charset | 415 | `unsupported_media_type` |
| Invalid field values | 422 | `validation_failed`, with fields |
| Invalid body length / oversized body | 400 / 413 | `invalid_content_length` / `body_too_large` |
| Incomplete body, including read deadline | 400 when deliverable | `incomplete_body` |
| Unsupported transfer/content encoding | 400 / 415 | `body_not_supported` / `unsupported_content_encoding` |
| Unsupported Expect header | 417 | `expectation_failed` |
| Admission full | 503, plus `Retry-After: 1` | `overloaded` |
| Database operation deadline | 503 | `deadline_exceeded` |
| Database unavailable | 503 | `database_unavailable` |
| Readiness failure | 503 | `not_ready` |
| Shutdown drain | 503 | `draining` |
| SQL execution failure | 500 | `query_failed` |
| Invalid response encoding/size/status | 500 | `invalid_response` |
| Invalid handler/validation/database API use | 500 | `handler_did_not_respond`, `invalid_validation`, `invalid_json_destination`, or `invalid_database_work` |

Framework-generated 500 messages say **Internal server error**. Codes remain
useful to clients without exposing low-level diagnostics. Error encoding uses a
bounded representation independent of the failing typed-response encoder, so an
oversized/unserializable application response can still receive an error.

Worker results carry a typed database error discriminator to the HTTP loop.
Dagda builds the public envelope after completion, using that request's ID; it
does not infer errors from or expose database result text. Custom query completion
callbacks receive the normalized error body too. Successful query results remain
unchanged. A callback can deliberately map an error to an application response.

## Compatibility and transport boundary

Application errors that previously contained only `error.code` now also contain
`error.message` and `request_id`. Readiness failure changes from
`{"status":"not_ready"}` to the common `not_ready` envelope; successful readiness
and liveness bodies are unchanged. Validation's existing envelope is preserved.
Update clients that compare entire old error bodies literally.

The new format covers the reusable Dagda application layer and example handlers.
It does not rewrite arbitrary error bodies passed to `json_text`, and the M0
proof binary retains its historical adapter responses. Low-level transport
parser rejections may still have an empty body, and disconnected clients may
receive no response. Tests for malformed HTTP must accept those transport
outcomes. The in-process Odin client does not replace those wire tests.

## Verification

Odin tests exercise every built-in envelope, safe internal messages, custom
errors, database completion mapping, and real example routes through the test
client. Network regressions also assert request-ID correlation for routing,
JSON, missing database rows, SQL errors, operation deadlines, and database
outages. Local build/unit checks and all five terminal integration suites passed.
The application suite correlated 147 request IDs with completion records,
including the new database failure checks. See the
[validation record](validation/2026-11-06-testing-errors.json).

# Field validation and structured errors

`dagda/validation` provides explicit checks over decoded input. It is independent
of HTTP and can be tested directly with Odin's test runner. There is no reflection
rule language or automatic database lookup: handlers declare the applicable
rules, including custom predicates and cross-field checks.

```odin
import validation "path/to/dagda/validation"
import http "path/to/dagda/http"

Input :: struct {
    title: string,
    quantity: i32,
    enabled: bool,
}

create :: proc(c: ^http.Context) {
    input: Input
    if !http.decode_json(c, &input) { return }

    errors: validation.Errors // zero-initialized; no init/destroy required
    if validation.required_text(&errors, "title", input.title) {
        validation.text_length(&errors, "title", input.title, 1, 80)
    }
    validation.integer_range(&errors, "quantity", i64(input.quantity), 1, 100)
    validation.required(&errors, "enabled",
        http.json_field_state(c, "enabled") == .Value)
    if !http.validate(c, &errors) { return }

    // Apply business side effects only after validation succeeds.
    http.respond_json(c, 200, input)
}
```

`POST /validate` in `examples/api` demonstrates this pattern, plus an allowed
priority choice. It validates and echoes the input without persisting anything.
The `/echo` endpoint remains an unrestricted typed-JSON round-trip example.

```sh
curl http://127.0.0.1:8080/validate \
  -H 'Content-Type: application/json' \
  -d '{"title":"","quantity":0,"priority":"normal","enabled":false}'
```

The response has status 422 and this shape:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "Request validation failed",
    "fields": {
      "title": ["required"],
      "quantity": ["out_of_range"]
    }
  },
  "request_id": "same-generated-id-as-X-Request-ID"
}
```

The boolean `false` is present and valid. Field names and codes are stable
application-defined metadata, never submitted values. Field-object order is not
guaranteed; codes within each field preserve the order of checks.

## Rules

Each helper returns a boolean and adds an error when the rule fails. This lets
handlers avoid redundant checks, such as checking length only after required text
passes. Calling several checks without branching collects all their errors.

| Helper | Behavior | Failure code |
| --- | --- | --- |
| `required(errors, field, has_value)` | Checks an explicit presence predicate; false/zero may be valid values | `required` |
| `required_text(errors, field, value)` | Rejects empty or whitespace-only text | `required` |
| `text_length(errors, field, value, min, max)` | Inclusive Unicode code-point count | `too_short`, `too_long`; `invalid` for invalid UTF-8 |
| `integer_range(errors, field, value, min, max)` | Inclusive signed 64-bit range | `out_of_range` |
| `number_range(errors, field, value, min, max)` | Inclusive finite floating-point range | `out_of_range` |
| `one_of(errors, field, value, choices)` | Exact, case-sensitive string membership | `invalid_choice` |
| `check(errors, field, condition, code)` | Custom predicate; default code is `invalid` | Caller-supplied code |
| `add(errors, field, code)` | Records an application-computed failure | Caller-supplied code |
| `valid(errors)` | True if there are no failures, truncation, or invalid rules | No mutation |

Text validation does not trim, normalize, or modify input. Code-point length is
not byte length or grapheme-cluster length. Float checks reject NaN and infinity;
use an exact application representation for monetary values.

For nested or collection fields, the application may use labels such as
`address.city` or `items[0].sku`. These are diagnostic labels, not expressions
that the validator evaluates. Custom checks must obey the HTTP event-loop rule:
no blocking I/O inside a handler. Database constraints and authorization remain
separate responsibilities.

## Presence and null

After successful object decoding, `http.json_field_state(context, wire_name)`
returns `.Missing`, `.Null`, or `.Value`. Before successful object decoding, or
for a non-object root, it returns `.Unavailable`. Names are exact top-level JSON
names, including `json:"wire_name"` tags; dotted paths and JSON Pointer are not
interpreted.

A required boolean uses `.Value`, so an explicitly supplied `false` is accepted
while omission is rejected. Nullable single-variant unions preserve JSON null;
ordinary non-nullable fields still reject null during decoding. For partial
updates, inspect field state before applying zero-valued fields. Nested presence
tracking and a general patch/update API remain future work.

## Bounds and failure behavior

The collector owns its metadata in fixed storage and can be copied by value.
Create a fresh zero-valued `Errors` for each validation pass and use its helpers
rather than modifying its internal counters/entries.

- At most **16 distinct field/code pairs** are retained. Duplicate pairs are
  suppressed. Further distinct failures set `error.truncated: true` on the 422
  response; the request still fails validation.
- Field labels are at most **64 ASCII bytes**; codes are at most **32 ASCII
  bytes**. Letters, digits, and underscores are accepted; field labels also
  accept dots, brackets, and hyphens. Use application-authored labels/codes.
- Invalid metadata, reversed ranges, negative text-length limits, non-finite
  range limits, and empty choice lists mark the collector invalid. HTTP returns
  500 `invalid_validation` with a generic message and request ID, never the
  invalid metadata.
- `http.validate` returns true only for a valid collector on an open request.
  Otherwise return from the handler. Pending database operations and already-sent
  responses are untouched, preserving the existing ownership/finalization rules.
- Encoding uses the same bounded typed response writer as other JSON responses.
  No submitted values or validation diagnostics are added to access logs.

Malformed JSON, type mismatches, unknown fields, and unsupported media types keep
their existing 400/415 responses. They do not run business validation. This slice
standardizes validation responses; it does not migrate every existing framework
error to the richer envelope.

## Tests

The Odin tests cover the rule helpers, Unicode boundaries, metadata ownership,
deduplication, truncation, invalid rules, grouped responses, request IDs, pending
request ownership, and field presence. `tests/validation_api.py` is an external
HTTP integration test for successful/invalid input, format separation, value
redaction, concurrency, resource reuse, and access-log correlation.

`./scripts/test.sh` runs both kinds of tests alongside the existing regression
suites. Verification passed on November 6, 2026 (America/Chicago): 26 Odin unit tests
(including 7 new validation/presence tests), 7 Python harness tests, and all five
network integration suites. The validation run correlated 123 response IDs with
exactly one access record each. Sampled RSS changed from 7248 to 7256 KiB, with
3 threads and 6 descriptors before and after. See the
[validation record](validation/2026-11-06-validation.json). The historical M0
30-minute stability test was not repeated for this slice.

# Odin application tests

Use `dagda/testing` with Odin's `core:testing` to exercise a configured application
without opening a socket, starting PostgreSQL, or acquiring an io_uring event
loop. It uses the application's actual routes and middleware, JSON/validation
helpers, body-header checks, response formatting, and completion-record code.

The example keeps route registration in `configure`, shared by its executable
and [Odin request tests](../examples/api/main_test.odin). This is the intended
pattern for applications and future generated projects.

```odin
import "core:testing"
import app "path/to/dagda/app"
import config "path/to/dagda/config"
import dt "path/to/dagda/testing"

@(test)
validates_input :: proc(t: ^testing.T) {
    settings, error := config.parse(config.Values{
        database_url="host=/tmp/dagda-test-only dbname=unused",
    })
    testing.expect_value(t, error.field, "")
    defer config.destroy(&settings)

    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    configure(application) // your application's ordinary route registration

    response, request_error := dt.request(application, {
        method=.Post,
        target="/validate",
        headers={{"Content-Type", "application/json"}},
        body=`{"title":"Dagda","quantity":1,"priority":"normal","enabled":false}`,
    })
    testing.expect_value(t, request_error, .None)
    if request_error != .None { return }
    defer dt.destroy(&response)
    testing.expect_value(t, response.status, 200)
    testing.expect_value(t, dt.header(&response, "Content-Type"), "application/json")
    testing.expect_value(t, response.completions, 1)
}
```

The database setting above is validated but never connected to. The pinned
compiler, native shim, and libpq are still build/link dependencies. In this repo,
run `./scripts/build.sh` once, then:

```sh
./scripts/odin.sh test dagda/testing -out:build/testing-tests -debug
./scripts/odin.sh test examples/api -out:build/api-tests -debug
```

Both run inside the restricted workspace; they do not require the privileges
needed by the socket integration tests.

## Request and response ownership

`dt.request(app, Request)` returns a `Response` and an `Error`; always inspect the
error before asserting the HTTP response. The app must be in `.Configured`
state. The call does not run lifecycle hooks, freeze registration, mutate the app
into `.Running`, or attach a worker pool. Use a separate app per parallel test,
and keep injected route/middleware state alive until the request returns.

`target` is an origin-form path with optional query string. Request headers are
pairs of name/value strings. The helper supplies `Host: localhost` and the body
length when absent. Supply content type explicitly. Header names are normalized;
invalid headers, conflicting framing, malformed test targets, and a supplied
length that disagrees with the complete body can produce `.Invalid_Request`.
These are test-input errors, not simulated wire-level responses.

Each request gets a generated UUID request ID. Incoming request-ID headers do not
replace it. Do not assert an exact randomly generated value: compare the response
header with the body/record instead.

The response owns its body, headers, completion metadata, and values decoded via
`dt.decode_json(&response, &value)`. They survive subsequent requests and app
destruction, and remain valid until `dt.destroy(&response)`. Destroy each response
exactly once; copying the struct does not transfer or duplicate ownership.
Request-context storage is destroyed before `dt.request` returns, so the client
also exercises copying responses out of request storage.

`dt.header` is case-insensitive and returns an empty string for a missing header.
Use the response's lowercase-keyed `headers` map if you need to distinguish a
missing header from an empty value. HEAD bodies are empty while content length
matches the corresponding representation. `dt.decode_json` requires a JSON body,
rejects trailing/duplicate data, uses Dagda's 32-level syntax bound, and leaves
the destination unchanged on failure. It otherwise uses Odin's typed response
decoder; request field validation is exercised through the actual handler.

`response.completion` captures the normal `http.Access_Record` shape, including
the matched route template and status. The client captures one completion
without invoking configured external log sinks. Its duration is in-process
execution time, not network latency.

## Dependency boundary

Synchronous application services can be injected using ordinary route and
middleware data pointers. The test client does not fabricate SQL results or
pretend a database operation succeeded:

- Calling `http.query_text` returns `.Database_Not_Supported` from `dt.request`.
  Response storage is cleaned up on this error.
- Unsupported pending handlers return `.Async_Not_Supported`. Do not schedule
  external work that retains a test request or modify internal context fields.
- Readiness returns `503 not_ready` because a configured test app has not started.
  This is not a database-health simulation.

Real PostgreSQL queries, worker handoffs, startup/shutdown hooks, partial uploads,
malformed wire framing, socket disconnects, and resource/soak measurements remain
external integration tests. The current Python harness owns those disposable
services. Application assertions and framework behavior belong in Odin; wire and
process failure tests complement them.

## Verification

Verification passed on November 6, 2026 (America/Chicago). The full terminal
script passed 34 Odin tests, 7 Python harness tests, and all five network suites.
A final unsigned-64 response-decoding case passed locally with the HTTP suite,
bringing the current Odin total to 35. Memory tracking is enabled for Odin tests.
See the [validation record](validation/2026-11-06-testing-errors.json).
`./scripts/test.sh` includes the new Odin packages and existing network suites.

package main

import "core:testing"
import app "../../dagda/app"
import config "../../dagda/config"
import dt "../../dagda/testing"
import http "../../dagda/http"

@(test)
application_requests_validate_and_short_circuit :: proc(t: ^testing.T) {
    settings, error := config.parse(config.Values{database_url="host=/tmp/dagda-test-only dbname=unused"})
    testing.expect_value(t, error.field, "")
    defer config.destroy(&settings)
    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    configure(application)
    invalid, invalid_error := dt.request(application, {method=.Post, target="/validate", headers={{"content-type", "application/json"}}, body=`{}`})
    testing.expect_value(t, invalid_error, .None)
    defer dt.destroy(&invalid)
    testing.expect_value(t, invalid.status, 422)
    errors: http.Validation_Response
    testing.expect(t, dt.decode_json(&invalid, &errors) == nil)
    testing.expect_value(t, errors.error.fields["enabled"][0], "required")
    testing.expect_value(t, errors.request_id, dt.header(&invalid, "x-request-id"))
    valid, valid_error := dt.request(application, {method=.Post, target="/validate", headers={{"content-type", "application/json"}},
        body=`{"title":"Dagda","quantity":1,"priority":"normal","enabled":false}`})
    testing.expect_value(t, valid_error, .None)
    defer dt.destroy(&valid)
    testing.expect_value(t, valid.status, 200)
    input: Validated_Input
    testing.expect(t, dt.decode_json(&valid, &input) == nil)
    testing.expect_value(t, input.title, "Dagda")
    testing.expect(t, !input.enabled)
    denied, denied_error := dt.request(application, {method=.Get, target="/private"})
    testing.expect_value(t, denied_error, .None)
    defer dt.destroy(&denied)
    testing.expect_value(t, denied.status, 401)
    allowed, allowed_error := dt.request(application, {method=.Get, target="/private", headers={{"X-Demo-Key", "example"}}})
    testing.expect_value(t, allowed_error, .None)
    defer dt.destroy(&allowed)
    testing.expect_value(t, allowed.status, 200)
    testing.expect_value(t, dt.header(&allowed, "x-powered-by"), "Dagda")
}

@(test)
application_error_envelopes :: proc(t: ^testing.T) {
    settings, error := config.parse(config.Values{database_url="host=/tmp/dagda-test-only dbname=unused"})
    testing.expect_value(t, error.field, "")
    defer config.destroy(&settings)
    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    configure(application)
    Case :: struct { method: http.Method, target, body, code: string, status: int }
    cases := []Case{
        {.Get, "/missing", "", "not_found", 404},
        {.Delete, "/", "", "method_not_allowed", 405},
        {.Get, "/items/%zz", "", "invalid_path", 400},
        {.Get, "/private", "", "demo_key_required", 401},
        {.Get, "/items/invalid", "", "invalid_id", 400},
        {.Post, "/echo", "{", "invalid_json", 400},
        {.Post, "/items", "", "not_implemented", 501},
        {.Get, "/health/ready", "", "not_ready", 503},
    }
    for item in cases {
        response, request_error := dt.request(application, {method=item.method, target=item.target,
            body=item.body, headers={{"content-type", "application/json"}}})
        testing.expect_value(t, request_error, .None)
        defer dt.destroy(&response)
        testing.expect_value(t, response.status, item.status)
        envelope: http.Error_Response
        testing.expect(t, dt.decode_json(&response, &envelope) == nil)
        testing.expect_value(t, envelope.error.code, item.code)
        testing.expect(t, len(envelope.error.message) > 0)
        testing.expect_value(t, envelope.request_id, dt.header(&response, "X-Request-ID"))
        testing.expect_value(t, response.completion.status, item.status)
        testing.expect_value(t, response.completions, 1)
    }
}

package main

import "core:testing"
import app "../vendor/dagda/dagda/app"
import config "../vendor/dagda/dagda/config"
import http "../vendor/dagda/dagda/http"
import dt "../vendor/dagda/dagda/testing"

@(test)
request_contract :: proc(t: ^testing.T) {
    settings, error := config.parse(config.Values{database_url="host=/tmp/dagda-test-only dbname=unused"})
    testing.expect_value(t, error.field, "")
    defer config.destroy(&settings)
    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    configure(application)
    response, request_error := dt.request(application, {method=.Get, target="/"})
    testing.expect_value(t, request_error, .None)
    if request_error != .None { return }
    defer dt.destroy(&response)
    testing.expect_value(t, response.status, 200)
    body: struct {name, status: string}
    testing.expect(t, dt.decode_json(&response, &body) == nil)
    testing.expect_value(t, body.name, "__APP_NAME__")
    testing.expect_value(t, body.status, "ok")
}

@(test)
validation_contract :: proc(t: ^testing.T) {
    settings, error := config.parse(config.Values{database_url="host=/tmp/dagda-test-only dbname=unused"})
    testing.expect_value(t, error.field, "")
    defer config.destroy(&settings)
    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    configure(application)
    invalid, request_error := dt.request(application, {method=.Post, target="/echo", headers={{"Content-Type", "application/json"}}, body=`{}`})
    testing.expect_value(t, request_error, .None)
    if request_error != .None { return }
    defer dt.destroy(&invalid)
    testing.expect_value(t, invalid.status, 422)
    body: http.Error_Response
    testing.expect(t, dt.decode_json(&invalid, &body) == nil)
    testing.expect_value(t, body.error.fields["message"][0], "required")
    testing.expect_value(t, body.request_id, dt.header(&invalid, "x-request-id"))
    valid, valid_error := dt.request(application, {method=.Post, target="/echo", headers={{"Content-Type", "application/json"}}, body=`{"message":"hello"}`})
    testing.expect_value(t, valid_error, .None)
    if valid_error != .None { return }
    defer dt.destroy(&valid)
    testing.expect_value(t, valid.status, 200)
    input: Echo_Input
    testing.expect(t, dt.decode_json(&valid, &input) == nil)
    testing.expect_value(t, input.message, "hello")
}

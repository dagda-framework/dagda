package main

import app "../vendor/dagda/dagda/app"
import http "../vendor/dagda/dagda/http"
import validation "../vendor/dagda/dagda/validation"

configure :: proc(application: ^app.App) {
    assert(app.route(application, .Get, "/", index) == .None)
    assert(app.route(application, .Post, "/echo", echo) == .None)
}
index :: proc(c: ^http.Context) {
    http.respond_json(c, 200, struct {name, status: string}{"__APP_NAME__", "ok"})
}
Echo_Input :: struct { message: string }
echo :: proc(c: ^http.Context) {
    input: Echo_Input
    if !http.decode_json(c, &input) { return }
    errors: validation.Errors
    if validation.required_text(&errors, "message", input.message) {
        validation.text_length(&errors, "message", input.message, 1, 120)
    }
    if !http.validate(c, &errors) { return }
    http.respond_json(c, 200, input)
}

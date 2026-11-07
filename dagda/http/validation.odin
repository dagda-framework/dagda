package dagda_http

import validation "../validation"

Validation_Error :: struct {
    code: string,
    message: string,
    fields: map[string][]string,
    truncated: union {bool} `json:",omitempty"`,
}
Validation_Response :: struct {
    error: Validation_Error,
    request_id: string,
}

// Returns true only when validation succeeds and the request is still open.
// On false, return from the handler. Pending/already-sent requests are untouched.
validate :: proc(c: ^Context, errors: ^validation.Errors) -> bool {
    if c._state != .Open { return false }
    if errors == nil || errors.invalid || errors.count < 0 || errors.count > validation.MAX_ERRORS {
        respond_json(c, 500, struct {error: struct {code, message: string}, request_id: string}{
            error={code="invalid_validation", message="Internal server error"}, request_id=c.request_id,
        })
        return false
    }
    if validation.valid(errors) { return true }
    fields := make(map[string][]string, c.allocator)
    for &issue in errors.items[:errors.count] {
        name := validation.field_name(&issue)
        if name in fields { continue }
        count := 0
        for &other in errors.items[:errors.count] {
            if validation.field_name(&other) == name { count += 1 }
        }
        codes := make([]string, count, c.allocator)
        index := 0
        for &other in errors.items[:errors.count] {
            if validation.field_name(&other) == name {
                codes[index] = validation.error_code(&other)
                index += 1
            }
        }
        fields[name] = codes
    }
    response := Validation_Response{
        error={code="validation_failed", message="Request validation failed", fields=fields},
        request_id=c.request_id,
    }
    if errors.truncated { response.error.truncated = true }
    respond_json(c, 422, response)
    return false
}

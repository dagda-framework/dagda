package dagda_http

import validation "../validation"

// Compatibility names for the now-shared application error envelope.
Validation_Error :: Error_Detail
Validation_Response :: Error_Response

// Returns true only when validation succeeds and the request is still open.
// On false, return from the handler. Pending/already-sent requests are untouched.
validate :: proc(c: ^Context, errors: ^validation.Errors) -> bool {
    if c._state != .Open { return false }
    if errors == nil || errors.invalid || errors.count < 0 || errors.count > validation.MAX_ERRORS {
        fail(c, .Invalid_Validation)
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

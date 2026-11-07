package dagda_http

import json "core:encoding/json"
import "core:io"
import "core:strings"
import "core:unicode/utf8"
import db "../db"
import validation "../validation"

Error_Detail :: struct {
    code: string,
    message: string,
    fields: map[string][]string `json:",omitempty"`,
    truncated: union {bool} `json:",omitempty"`,
}
Error_Response :: struct { error: Error_Detail, request_id: string }
Error_Kind :: enum {
    Invalid_Response, Invalid_Validation, Invalid_JSON_Destination,
    Unsupported_Media_Type, Invalid_JSON, Handler_Did_Not_Respond,
    Invalid_Database_Work, Overloaded, Draining, Body_Not_Supported,
    Expectation_Failed, Unsupported_Content_Encoding, Invalid_Content_Length,
    Body_Too_Large, Incomplete_Body, Not_Found, Method_Not_Allowed, Invalid_Path,
    Not_Ready, Deadline_Exceeded, Database_Unavailable, Query_Failed,
}
error_info :: proc(kind: Error_Kind) -> (status: int, code, message: string) {
    switch kind {
    case .Invalid_Response:             return 500, "invalid_response", "Internal server error"
    case .Invalid_Validation:           return 500, "invalid_validation", "Internal server error"
    case .Invalid_JSON_Destination:     return 500, "invalid_json_destination", "Internal server error"
    case .Unsupported_Media_Type:       return 415, "unsupported_media_type", "Expected application/json with UTF-8 encoding"
    case .Invalid_JSON:                 return 400, "invalid_json", "Invalid JSON request"
    case .Handler_Did_Not_Respond:      return 500, "handler_did_not_respond", "Internal server error"
    case .Invalid_Database_Work:        return 500, "invalid_database_work", "Internal server error"
    case .Overloaded:                   return 503, "overloaded", "Service temporarily at capacity"
    case .Draining:                     return 503, "draining", "Service is shutting down"
    case .Body_Not_Supported:           return 400, "body_not_supported", "Transfer encoding is not supported"
    case .Expectation_Failed:           return 417, "expectation_failed", "Request expectation is not supported"
    case .Unsupported_Content_Encoding: return 415, "unsupported_content_encoding", "Content encoding is not supported"
    case .Invalid_Content_Length:      return 400, "invalid_content_length", "Invalid content length"
    case .Body_Too_Large:               return 413, "body_too_large", "Request body exceeds the size limit"
    case .Incomplete_Body:             return 400, "incomplete_body", "Request body was not completely received"
    case .Not_Found:                   return 404, "not_found", "Resource not found"
    case .Method_Not_Allowed:          return 405, "method_not_allowed", "Method not allowed"
    case .Invalid_Path:                return 400, "invalid_path", "Invalid request path"
    case .Not_Ready:                   return 503, "not_ready", "Service is not ready"
    case .Deadline_Exceeded:           return 503, "deadline_exceeded", "Request deadline exceeded"
    case .Database_Unavailable:        return 503, "database_unavailable", "Database unavailable"
    case .Query_Failed:                return 500, "query_failed", "Internal server error"
    }
    unreachable()
}
fail :: proc(c: ^Context, kind: Error_Kind) -> bool {
    status, code, message := error_info(kind)
    return respond_error(c, status, code, message)
}

// Use application-authored public codes/messages, never raw exception/SQL/input
// text. Bound metadata before encoding so even encoder failures have a safe path.
respond_error :: proc(c: ^Context, status: int, code, message: string) -> bool {
    if c._state != .Open { return false }
    status, code, message := status, code, message
    if status < 400 || status > 599 || !validation.metadata_valid(code, false) ||
       len(message) == 0 || len(message) > 256 || !utf8.valid_string(message) {
        status, code, message = 500, "internal_error", "Internal server error"
    }
    writer: JSON_Writer
    encode_error(c, code, message, &writer)
    return json_text(c, status, string(writer.bytes[:writer.count]))
}
encode_error :: proc(c: ^Context, code, message: string, writer: ^JSON_Writer) {
    id := c.request_id
    if len(id) > 128 || !utf8.valid_string(id) { id = "" }
    // This fixed, bounded representation fits without allocating. It must not
    // call respond_json, whose own error path comes through respond_error.
    value := Error_Response{error={code=code, message=message}, request_id=id}
    error := json.marshal_to_writer(io.Writer{procedure=json_write, data=writer}, value, {spec=.JSON})
    assert(error == nil)
}
database_error_kind :: proc(error: db.Error) -> Error_Kind {
    switch error {
    case .Deadline: return .Deadline_Exceeded
    case .Unavailable: return .Database_Unavailable
    case .Unexpected_Result: return .Not_Found
    case .Query: return .Query_Failed
    case .None: return .Invalid_Database_Work
    }
    unreachable()
}
// Completion callbacks receive the same public body as the default response.
// The caller has already copied successful result bytes and released its slot.
query_result :: proc(c: ^Context, status: int, body: string, error: db.Error) {
    status, body := status, body
    c._state = .Open
    result := c._result
    c._result = nil
    if error != .None {
        code, message: string
        status, code, message = error_info(database_error_kind(error))
        writer: JSON_Writer
        encode_error(c, code, message, &writer)
        body = strings.clone(string(writer.bytes[:writer.count]), c.allocator)
    }
    if result != nil { result(c, status, body) } else { json_text(c, status, body) }
    if c._state == .Open { fail(c, .Handler_Did_Not_Respond) }
}

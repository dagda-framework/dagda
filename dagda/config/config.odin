package dagda_config

import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import db "../db"

Environment :: enum { Development, Test, Production }
Config :: struct {
    environment: Environment,
    listen: string,
    endpoint: net.Endpoint,
    database_url: cstring,
    deadline_ms: i64,
    read_timeout_ms, write_timeout_ms: i64,
    max_connections: int,
    access_log: bool,
    log_level: log.Level,
    allocator: mem.Allocator,
}

// Strings from the process environment or an explicit configuration source.
Values :: struct {
    environment, listen, database_url, deadline_ms: string,
    read_timeout_ms, write_timeout_ms, max_connections: string,
    access_log, log_level: string,
    pgservice, pghost, pghostaddr: string,
}
Error :: struct { field, message: string }

load :: proc(allocator := context.allocator) -> (config: Config, error: Error) {
    get :: proc(name: string) -> string { return os.get_env(name, context.temp_allocator) }
    return parse(Values{
        environment = get("DAGDA_ENV"), listen = get("DAGDA_LISTEN"), database_url = get("DAGDA_DATABASE_URL"),
        deadline_ms = get("DAGDA_DEADLINE_MS"), read_timeout_ms = get("DAGDA_READ_TIMEOUT_MS"),
        write_timeout_ms = get("DAGDA_WRITE_TIMEOUT_MS"), max_connections = get("DAGDA_MAX_CONNECTIONS"),
        access_log = get("DAGDA_ACCESS_LOG"), log_level = get("DAGDA_LOG_LEVEL"),
        pgservice = get("PGSERVICE"), pghost = get("PGHOST"), pghostaddr = get("PGHOSTADDR"),
    }, allocator)
}

parse :: proc(v: Values, allocator := context.allocator) -> (c: Config, error: Error) {
    c.allocator = allocator
    c.access_log = true
    c.log_level = .Warning
    switch v.environment {
    case "", "development": c.environment = .Development
    case "test": c.environment = .Test
    case "production": c.environment = .Production
    case: return {}, {"DAGDA_ENV", "expected development, test, or production"}
    }
    switch v.log_level {
    case "", "warn": c.log_level = .Warning
    case "error": c.log_level = .Error
    case "info": c.log_level = .Info
    case "debug": c.log_level = .Debug
    case: return {}, {"DAGDA_LOG_LEVEL", "expected error, warn, info, or debug"}
    }
    switch v.access_log {
    case "", "true", "1": c.access_log = true
    case "false", "0": c.access_log = false
    case: return {}, {"DAGDA_ACCESS_LOG", "expected true or false"}
    }
    listen := v.listen
    if listen == "" { listen = "127.0.0.1:8080" }
    endpoint, ok := net.parse_endpoint(listen)
    if !ok { return {}, {"DAGDA_LISTEN", "expected a numeric IP address and port"} }
    c.endpoint = endpoint
    fields := []struct {name, value: string, fallback, low, high: i64, target: ^i64}{
        {"DAGDA_DEADLINE_MS", v.deadline_ms, 2000, 50, 30000, &c.deadline_ms},
        {"DAGDA_READ_TIMEOUT_MS", v.read_timeout_ms, 2000, 50, 30000, &c.read_timeout_ms},
        {"DAGDA_WRITE_TIMEOUT_MS", v.write_timeout_ms, 1000, 50, 30000, &c.write_timeout_ms},
    }
    for field in fields {
        value := field.fallback
        if field.value != "" {
            parsed, valid := strconv.parse_i64(field.value)
            if !valid || parsed < field.low || parsed > field.high { return {}, {field.name, "expected milliseconds in 50..30000"} }
            value = parsed
        }
        field.target^ = value
    }
    c.max_connections = 64
    if v.max_connections != "" {
        value, valid := strconv.parse_int(v.max_connections)
        if !valid || value < 1 || value > 4096 { return {}, {"DAGDA_MAX_CONNECTIONS", "expected an integer in 1..4096"} }
        c.max_connections = value
    }
    if v.pgservice != "" || v.pghost != "" || v.pghostaddr != "" {
        return {}, {"PGSERVICE/PGHOST/PGHOSTADDR", "unset inherited target overrides; use DAGDA_DATABASE_URL"}
    }
    if v.database_url == "" || strings.contains(v.database_url, "\x00") {
        return {}, {"DAGDA_DATABASE_URL", "a local PostgreSQL connection string is required"}
    }
    url := strings.clone_to_cstring(v.database_url, allocator)
    if !db.valid_local_conninfo(url) {
        delete(url, allocator)
        return {}, {"DAGDA_DATABASE_URL", "expected one Unix socket directory or numeric loopback hostaddr; services are unsupported"}
    }
    c.database_url = url
    c.listen = strings.clone(listen, allocator)
    return
}

destroy :: proc(c: ^Config) {
    delete(c.database_url, c.allocator)
    delete(c.listen, c.allocator)
    c^ = {}
}

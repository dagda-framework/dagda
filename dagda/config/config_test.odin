package dagda_config

import "core:testing"
import "core:strings"

@(test)
defaults_and_owned_configuration :: proc(t: ^testing.T) {
    c, error := parse(Values{database_url = "host=/tmp dbname=dagda"})
    if !testing.expect_value(t, error.field, "") { return }
    defer destroy(&c)
    testing.expect_value(t, c.listen, "127.0.0.1:8080")
    testing.expect_value(t, c.deadline_ms, 2000)
    testing.expect_value(t, c.max_connections, 64)
    testing.expect(t, c.access_log)
    testing.expect_value(t, c.environment, .Development)
    testing.expect_value(t, string(c.database_url), "host=/tmp dbname=dagda")
}

@(test)
invalid_configuration_never_echoes_secrets :: proc(t: ^testing.T) {
    cases := []struct { values: Values, field: string }{
        {Values{}, "DAGDA_DATABASE_URL"},
        {Values{database_url="host=remote password=DO_NOT_LOG"}, "DAGDA_DATABASE_URL"},
        {Values{environment="staging"}, "DAGDA_ENV"},
        {Values{listen="localhost:8080"}, "DAGDA_LISTEN"},
        {Values{deadline_ms="0"}, "DAGDA_DEADLINE_MS"},
        {Values{deadline_ms="30001"}, "DAGDA_DEADLINE_MS"},
        {Values{read_timeout_ms="infinity"}, "DAGDA_READ_TIMEOUT_MS"},
        {Values{write_timeout_ms="-1"}, "DAGDA_WRITE_TIMEOUT_MS"},
        {Values{max_connections="0"}, "DAGDA_MAX_CONNECTIONS"},
        {Values{access_log="maybe"}, "DAGDA_ACCESS_LOG"},
        {Values{log_level="trace"}, "DAGDA_LOG_LEVEL"},
        {Values{pghost="remote"}, "PGSERVICE/PGHOST/PGHOSTADDR"},
    }
    for entry in cases {
        _, error := parse(entry.values)
        testing.expect_value(t, error.field, entry.field)
        testing.expect(t, error.message != "")
        testing.expect(t, !strings.contains(error.message, "DO_NOT_LOG"))
    }
}

@(test)
explicit_environment_settings :: proc(t: ^testing.T) {
    c, error := parse(Values{database_url="hostaddr=127.0.0.1 dbname=dagda", environment="production",
                            listen="127.0.0.1:9000", deadline_ms="500", read_timeout_ms="600",
                            write_timeout_ms="700", max_connections="32", access_log="false", log_level="error"})
    if !testing.expect_value(t, error.field, "") { return }
    defer destroy(&c)
    testing.expect_value(t, c.environment, .Production)
    testing.expect_value(t, c.deadline_ms, 500)
    testing.expect_value(t, c.read_timeout_ms, 600)
    testing.expect_value(t, c.write_timeout_ms, 700)
    testing.expect_value(t, c.max_connections, 32)
    testing.expect(t, !c.access_log)
}

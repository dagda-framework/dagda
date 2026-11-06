package dagda_db

import "core:testing"

@(test)
local_connection_targets :: proc(t: ^testing.T) {
    accepted := []cstring{
        "host=/tmp/dagda dbname=postgres",
        "dbname=postgres host='/tmp/dagda test'",
        "hostaddr=127.0.0.1 dbname=postgres",
        "hostaddr=::1 dbname=postgres",
    }
    for value in accepted {
        testing.expect(t, valid_local_conninfo(value))
    }
    rejected := []cstring{
        "", "host=localhost", "host=/tmp host=example.com",
        "host=/tmp,/other", "host=/tmp service=external",
        "hostaddr=192.0.2.1", "hostaddr=127.0.0.1,192.0.2.1",
        "host='/unterminated", "not_a_libpq_option=value",
    }
    for value in rejected {
        testing.expect(t, !valid_local_conninfo(value))
    }
}

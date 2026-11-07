package main

import "core:fmt"
import "core:os"
import app "../vendor/dagda/dagda/app"
import config "../vendor/dagda/dagda/config"
import db "../vendor/dagda/dagda/db"
import platform "../vendor/dagda/dagda/platform"

main :: proc() { os.exit(run()) }
run :: proc() -> int {
    command := "serve"
    if len(os.args) > 1 { command = os.args[1] }
    database_check := command == "check" && len(os.args) == 3 && os.args[2] == "--database"
    if (command != "serve" && command != "check") || (len(os.args) > 2 && !database_check) {
        fmt.eprintln("Usage: __APP_NAME__ [serve | check [--database]]")
        return 2
    }
    settings, error := config.load()
    if error.field != "" { fmt.eprintf("Invalid %s: %s\n", error.field, error.message); return 1 }
    defer config.destroy(&settings)
    if command == "check" {
        if database_check {
            deadline := platform.monotonic_ms() + settings.deadline_ms
            connection, connect_error := db.connect(settings.database_url, deadline)
            if connect_error != .None { fmt.eprintln("Database connectivity check failed"); return 1 }
            defer db.close(&connection)
            _, query_error := db.query_text(&connection, "SELECT 'ready'", nil, deadline, context.temp_allocator)
            if query_error != .None { fmt.eprintln("Database query check failed"); return 1 }
            fmt.println("Database connectivity: OK")
        }
        fmt.println("Configuration: OK")
        return 0
    }
    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    configure(application)
    if app.run(application) != .None { return 1 }
    return 0
}

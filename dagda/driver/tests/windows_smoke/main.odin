package main

import "core:fmt"
import "core:os"
import driver "dagda:dagda/driver"

// Diagnostic: exercise listen/connect/accept/write/read at
// the transport layer only, printing each stage.
main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: windows-smoke <socket-path>")
		os.exit(2)
	}
	path := os.args[1]
	fmt.println("stage: listen")
	fd, identity, ok := driver.listen_unix(path)
	fmt.printf("listen ok=%v identity_valid=%v\n", ok, identity.valid)
	if !ok {
		os.exit(1)
	}
	fmt.println("stage: connect")
	cfd, cok := driver.connect_unix(path)
	fmt.printf("connect ok=%v\n", cok)
	if !cok {
		os.exit(1)
	}
	fmt.println("stage: accept-poll skipped (listener is blocking in this smoke)")
	fmt.println("stage: write via client socket")
	if !driver.write_all(cfd, "ping\n") {
		fmt.println("write failed")
		os.exit(1)
	}
	fmt.println("stage: done (no accept in smoke)")
	driver.close_socket(cfd)
	driver.close_socket(fd)
}

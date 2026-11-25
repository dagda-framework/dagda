package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda/driver"

usage :: proc() {
	fmt.eprintln("usage: dagda-client <socket-path> inspect [role]")
	fmt.eprintln("       dagda-client <socket-path> invoke  <id> <action>")
}

run_client :: proc() -> int {
	if len(os.args) < 3 {
		usage()
		return 2
	}
	path, cmd := os.args[1], os.args[2]

	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	switch cmd {
	case "inspect":
		if len(os.args) == 3 {
			strings.write_string(&b, "{\"op\":\"inspect\"}")
		} else if len(os.args) == 4 {
			strings.write_string(&b, "{\"op\":\"inspect\",\"role\":")
			driver.write_json_string(&b, os.args[3])
			strings.write_byte(&b, '}')
		} else {
			usage()
			return 2
		}
	case "invoke":
		if len(os.args) != 5 {
			usage()
			return 2
		}
		id, ok_id := strconv.parse_i64(os.args[3])
		if !ok_id || id < 0 {
			usage()
			return 2
		}
		fmt.sbprintf(&b, "{{\"op\":\"invoke\",\"id\":%d,\"action\":", id)
		driver.write_json_string(&b, os.args[4])
		strings.write_byte(&b, '}')
	case:
		usage()
		return 2
	}

	fd, ok := driver.connect_unix(path)
	if !ok {
		fmt.eprintf("could not connect to %s\n", path)
		return 1
	}
	defer posix.close(fd)

	request := strings.to_string(b)
	if !driver.write_all(fd, request) || !driver.write_all(fd, "\n") {
		fmt.eprintln("could not send request")
		return 1
	}

	reader := driver.Line_Reader{fd = fd}
	reply, has_reply := driver.read_line(&reader)
	if !has_reply {
		fmt.eprintln("no reply from host")
		return 1
	}
	defer delete(reply)
	fmt.println(reply)
	return strings.contains(reply, "\"ok\":true") ? 0 : 1
}

main :: proc() {
	if code := run_client(); code != 0 {
		os.exit(code)
	}
}

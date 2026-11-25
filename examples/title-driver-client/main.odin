package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import driver "dagda:examples/title-driver"

usage :: proc() {
	fmt.eprintln("usage: title-client <socket-path> inspect <role>")
	fmt.eprintln("       title-client <socket-path> watch   <role>")
	fmt.eprintln("       title-client <socket-path> preview <id> <base_revision> <text>")
	fmt.eprintln("       title-client <socket-path> commit  <id> <base_revision> <text>")
	fmt.eprintln("       title-client <socket-path> undo    <id> <base_revision>")
}

// parse_target accepts only the non-negative i64 range the wire
// decoder accepts, so CLI and wire validation stay consistent.
parse_target :: proc(id_s, rev_s: string) -> (i64, i64, bool) {
	id, id_ok := strconv.parse_i64(id_s)
	rev, rev_ok := strconv.parse_i64(rev_s)
	if !id_ok || !rev_ok || id < 0 || rev < 0 {
		return 0, 0, false
	}
	return id, rev, true
}

main :: proc() {
	if len(os.args) < 3 {
		usage()
		os.exit(2)
	}
	path, cmd := os.args[1], os.args[2]

	b: strings.Builder
	strings.builder_init(&b)

	is_watch := false
	switch cmd {
	case "inspect":
		if len(os.args) != 4 {
			usage()
			os.exit(2)
		}
		strings.write_string(&b, "{\"op\":\"inspect\",\"role\":")
		driver.write_json_string(&b, os.args[3])
		strings.write_byte(&b, '}')
	case "watch":
		if len(os.args) != 4 {
			usage()
			os.exit(2)
		}
		is_watch = true
		strings.write_string(&b, "{\"op\":\"watch\",\"role\":")
		driver.write_json_string(&b, os.args[3])
		strings.write_byte(&b, '}')
	case "preview", "commit":
		if len(os.args) != 6 {
			usage()
			os.exit(2)
		}
		id, rev, nums_ok := parse_target(os.args[3], os.args[4])
		if !nums_ok {
			usage()
			os.exit(2)
		}
		fmt.sbprintf(&b, "{{\"op\":%q,\"id\":%d,\"base_revision\":%d,\"text\":", cmd, id, rev)
		driver.write_json_string(&b, os.args[5])
		strings.write_byte(&b, '}')
	case "undo":
		if len(os.args) != 5 {
			usage()
			os.exit(2)
		}
		id, rev, nums_ok := parse_target(os.args[3], os.args[4])
		if !nums_ok {
			usage()
			os.exit(2)
		}
		fmt.sbprintf(&b, "{{\"op\":\"undo\",\"id\":%d,\"base_revision\":%d}}", id, rev)
	case:
		usage()
		os.exit(2)
	}

	fd, ok := driver.connect_unix(path)
	if !ok {
		fmt.eprintf("could not connect to %s\n", path)
		os.exit(1)
	}

	request := strings.to_string(b)
	if !driver.write_all(fd, request) || !driver.write_all(fd, "\n") {
		fmt.eprintln("could not send request")
		os.exit(1)
	}
	reader := driver.Line_Reader{fd = fd}
	reply, has_reply := driver.read_line(&reader)
	if !has_reply {
		fmt.eprintln("no reply from host")
		os.exit(1)
	}
	fmt.println(reply)
	_ = os.flush(os.stdout)
	code := strings.contains(reply, "\"ok\":true") ? 0 : 1
	delete(reply)
	if !is_watch || code != 0 {
		posix.close(fd)
		os.exit(code)
	}

	for {
		ev, has_ev := driver.read_line(&reader)
		if !has_ev {
			break
		}
		fmt.println(ev)
		_ = os.flush(os.stdout)
		delete(ev)
	}
	posix.close(fd)
	os.exit(0)
}

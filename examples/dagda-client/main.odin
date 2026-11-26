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
	fmt.eprintln("       dagda-client <socket-path> hit-test <x> <y>  (logical window coordinates, as in inspect bounds)")
	fmt.eprintln("       dagda-client <socket-path> edits   <id>")
	fmt.eprintln("       dagda-client <socket-path> preview <id> <edit> <base_revision> text <text>")
	fmt.eprintln("       dagda-client <socket-path> preview <id> <edit> <base_revision> none")
	fmt.eprintln("       dagda-client <socket-path> preview <id> <edit> <base_revision> rect <x> <y> <width> <height>")
	fmt.eprintln("       dagda-client <socket-path> commit  <id> <edit> <base_revision> text <text>")
	fmt.eprintln("       dagda-client <socket-path> commit  <id> <edit> <base_revision> rect <x> <y> <width> <height>")
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
		id, ok_id := strconv.parse_u64(os.args[3])
		if !ok_id {
			usage()
			return 2
		}
		fmt.sbprintf(&b, "{{\"op\":\"invoke\",\"id\":%d,\"action\":", id)
		driver.write_json_string(&b, os.args[4])
		strings.write_byte(&b, '}')
	case "edits":
		if len(os.args) != 4 {
			usage()
			return 2
		}
		id, ok_id := strconv.parse_u64(os.args[3])
		if !ok_id {
			usage()
			return 2
		}
		fmt.sbprintf(&b, "{{\"op\":\"edits\",\"id\":%d}}", id)
	case "preview", "commit":
		// dagda-client <sock> preview|commit <id> <edit> <base_revision> text <text>
		// dagda-client <sock> preview|commit <id> <edit> <base_revision> rect <x> <y> <w> <h>
		if len(os.args) < 7 {
			usage()
			return 2
		}
		id, ok_id := strconv.parse_u64(os.args[3])
		rev, ok_rev := strconv.parse_u64(os.args[5])
		if !ok_id || !ok_rev {
			usage()
			return 2
		}
		fmt.sbprintf(&b, "{{\"op\":%q,\"id\":%d,\"edit\":", cmd, id)
		driver.write_json_string(&b, os.args[4])
		fmt.sbprintf(&b, ",\"base_revision\":%d,\"argument\":", rev)
		switch os.args[6] {
		case "none":
			if len(os.args) != 7 {
				usage()
				return 2
			}
			strings.write_string(&b, "{\"kind\":\"none\"}")
		case "text":
			if len(os.args) != 8 {
				usage()
				return 2
			}
			strings.write_string(&b, "{\"kind\":\"text\",\"text\":")
			driver.write_json_string(&b, os.args[7])
			strings.write_byte(&b, '}')
		case "rect":
			if len(os.args) != 11 {
				usage()
				return 2
			}
			nums: [4]f64
			for i in 0 ..< 4 {
				v, ok_num := strconv.parse_f64(os.args[7 + i])
				if !ok_num {
					usage()
					return 2
				}
				nums[i] = v
			}
			fmt.sbprintf(&b, "{{\"kind\":\"rect\",\"rect\":{{\"x\":%g,\"y\":%g,\"width\":%g,\"height\":%g}}}}", nums[0], nums[1], nums[2], nums[3])
		case:
			usage()
			return 2
		}
		strings.write_byte(&b, '}')
	case "hit-test":
		if len(os.args) != 5 {
			usage()
			return 2
		}
		x, ok_x := strconv.parse_f64(os.args[3])
		y, ok_y := strconv.parse_f64(os.args[4])
		// Coordinates must be finite f32 window coordinates,
		// matching the wire decoder's range.
		max_coord := f64(transmute(f32)u32(0x7F7FFFFF)) // exact f32 maximum, widened
		if !ok_x || !ok_y || x != x || y != y || x > max_coord || x < -max_coord || y > max_coord || y < -max_coord {
			usage()
			return 2
		}
		fmt.sbprintf(&b, "{{\"op\":\"hit-test\",\"x\":%g,\"y\":%g}}", x, y)
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

package sdlhost

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "dagda:dagda"
import "dagda:dagda/driver"

@(test)
test_host_exits_nonzero_and_removes_socket_on_duplicate_id_rebuild :: proc(t: ^testing.T) {
	Dup_State :: struct {
		triggered: bool,
		elements:  [2]dagda.Element,
	}
	dup_view :: proc(user_data: rawptr) -> dagda.View {
		s := (^Dup_State)(user_data)
		if !s.triggered {
			s.elements = {
				{info = {id = 1, role = "dup.value"}, kind = .Label, text = "ok"},
				{info = {id = 2, role = "dup.trigger"}, kind = .Button, text = "Trigger"},
			}
		} else {
			s.elements = {
				{info = {id = 1, role = "dup.value"}, kind = .Label, text = "bad"},
				{info = {id = 1, role = "dup.trigger"}, kind = .Button, text = "bad"},
			}
		}
		return {elements = s.elements[:]}
	}
	dup_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Dup_State)(user_data)
		if id == 2 && action == .Activate {
			s.triggered = true
			return true
		}
		return false
	}

	Client_Probe :: struct {
		sock_path:      string,
		connected:      bool,
		first_buf:      [256]u8,
		first_len:      int,
		got_second:     bool,
	}
	probe_proc :: proc(th: ^thread.Thread) {
		p := (^Client_Probe)(th.data)
		fd: posix.FD = -1
		for _ in 0 ..< 200 {
			if cfd, ok := driver.connect_unix(p.sock_path); ok {
				fd = cfd
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		if fd < 0 {
			return
		}
		defer posix.close(fd)
		p.connected = true
		_ = driver.write_all(fd, "{\"op\":\"invoke\",\"id\":2,\"action\":\"activate\"}\n{\"op\":\"inspect\"}\n")
		r := driver.Line_Reader{fd = fd}
		if line1, ok1 := driver.read_line(&r); ok1 {
			n := min(len(line1), len(p.first_buf))
			copy(p.first_buf[:n], line1[:n])
			p.first_len = n
			delete(line1)
		}
		if line2, ok2 := driver.read_line(&r); ok2 {
			p.got_second = true
			delete(line2)
		}
	}

	sock_dir := fmt.tprintf("/tmp/dagda-sdlhost-dup-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	sock_path := fmt.tprintf("%s/dup.sock", sock_dir)

	probe := Client_Probe{sock_path = sock_path}

	th := thread.create(probe_proc)
	th.data = &probe
	thread.start(th)

	state: Dup_State
	app := App{
		title     = "Dagda — Duplicate ID Test",
		width     = 320,
		height    = 160,
		user_data = &state,
		view      = dup_view,
		handle    = dup_handle,
	}
	code := run(app, {socket_path = sock_path})
	thread.join(th)
	thread.destroy(th)

	testing.expect_value(t, probe.connected, true)
	testing.expect_value(t, code, 1)
	testing.expect_value(t, string(probe.first_buf[:probe.first_len]), `{"ok":false,"error":"Frame_Invalid"}`)
	testing.expect_value(t, probe.got_second, false)
	testing.expect_value(t, os.exists(sock_path), false)
}

package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import driver "dagda:examples/title-driver"
import title_model "dagda:examples/title-model"

stopped: bool

on_signal :: proc "c" (_: posix.Signal) {
	stopped = true
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: title-host <socket-path>")
		os.exit(2)
	}
	path := os.args[1]
	if os.exists(path) {
		fmt.eprintf("socket path already exists: %s\n", path)
		os.exit(1)
	}

	act: posix.sigaction_t
	act.sa_handler = on_signal
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)

	listen_fd, ok := driver.listen_unix(path)
	if !ok {
		fmt.eprintf("could not listen on %s\n", path)
		os.exit(1)
	}
	defer {
		posix.close(listen_fd)
		driver.remove_unix(path)
	}

	model: title_model.Model
	if err := title_model.init(&model, {id = 1, role = "slide.title"}, "Quarterly results"); err != .None {
		fmt.eprintln("could not initialise title model")
		os.exit(1)
	}
	defer title_model.destroy(&model)

	fmt.printf("Listening %s\n", path)

	for !stopped {
		pfd := posix.pollfd{fd = listen_fd, events = {.IN}}
		if posix.poll(&pfd, 1, 200) <= 0 {
			continue
		}
		conn := posix.accept(listen_fd, nil, nil)
		if conn < 0 {
			continue
		}
		reader := driver.Line_Reader{fd = conn}
		for !stopped {
			line, has_line := driver.read_line(&reader)
			if !has_line {
				break
			}
			if len(line) == 0 {
				delete(line)
				continue
			}
			reply := driver.dispatch(&model, line)
			delete(line)
			driver.write_all(conn, reply)
			driver.write_all(conn, "\n")
			delete(reply)
		}
		posix.close(conn)
	}
}

package main

import "callbacks"
import "core:sys/linux"

Callback :: #type proc(_: int) -> int
Handler :: struct {
	callback: Callback,
}

install :: proc(callback: Callback) -> Handler {
	return Handler{callback = callback}
}

main :: proc() {
	handler := install(callbacks.increment)
	linux.exit_group(i32(handler.callback(41)))
}

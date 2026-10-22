package main

import "core:sys/linux"

Id :: distinct u32
Value :: union {
	Id,
	int,
}
Info :: struct {
	id: Id,
}

consume :: proc(value: Value) -> bool {
	id, ok := value.(Id)
	return ok && id == 2
}

main :: proc() {
	info := Info{2}
	if !consume(Value(info.id)) { linux.exit_group(1) }
	linux.exit_group(42)
}

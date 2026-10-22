package main

import "core:sys/linux"

Failure :: enum u8 {
	None,
	Failed,
}
Error :: union #shared_nil {
	Failure,
	^int,
}

value :: proc(fail: bool) -> (int, Error) {
	if fail { return 0, Failure.Failed }
	return 7, nil
}

propagate :: proc(fail: bool) -> (number: int, error: Error) {
	number = value(fail) or_return
	return number + 1, nil
}

main :: proc() {
	number, error := propagate(false)
	if number != 8 || error != nil { linux.exit_group(1) }
	number, error = propagate(true)
	if number != 0 || error == nil || error.(Failure) != .Failed { linux.exit_group(2) }
	if (value(false) or_else 9) != 7 { linux.exit_group(3) }
	if (value(true) or_else 9) != 9 { linux.exit_group(4) }
	count := 0
	for index in 0 ..< 3 {
		number := value(index == 1) or_break
		count += number
	}
	if count != 7 { linux.exit_group(5) }
	for index in 0 ..< 3 {
		number := value(index == 1) or_continue
		count += number
	}
	if count != 21 { linux.exit_group(6) }
	linux.exit_group(42)
}

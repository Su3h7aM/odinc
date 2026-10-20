package main

import "base:intrinsics"

Error :: enum {
	None,
	Failure,
}

main :: proc() {
	code := 0
	if declaration() == .None { code += 1 }
	first, second, err := assignment()
	if err == .None { code += first + second }
	if unnamed_single() == .None { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

declaration :: proc() -> Error {
	first, second := pair() or_return
	if first + second == 30 { return .None }
	return .Failure
}

assignment :: proc() -> (first: int, second: int, err: Error) {
	first, second = pair() or_return
	return
}

unnamed_single :: proc() -> Error {
	status() or_return
	return .None
}

pair :: proc() -> (int, int, Error) { return 10, 20, .None }
status :: proc() -> Error { return .None }

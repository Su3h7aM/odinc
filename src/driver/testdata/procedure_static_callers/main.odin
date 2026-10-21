package main

import "base:intrinsics"
import "base:runtime"

Callback :: proc(
	value: int,
	text: string = #caller_expression(value),
	site: runtime.Source_Code_Location = #caller_location,
) -> (
	int,
	string,
	runtime.Source_Code_Location,
)
Record :: struct {
	callback: Callback,
}
target :: proc(number: int, expression: string, location: runtime.Source_Code_Location) -> (int, string, runtime.Source_Code_Location) {return number,
		expression,
		location}
evaluations: int
returned :: proc() -> Callback { evaluations += 1; return target }

main :: proc() {
	callback: Callback = target
	record := Record{target}
	value, text, location := callback(value = 41 + 1)
	if value != 42 || text != "41 + 1" || location.line != 27 { intrinsics.syscall(60, 1) }
	if location.file_path[len(location.file_path) - 9:] != "main.odin" { intrinsics.syscall(60, 2) }
	second, second_text, second_location := record.callback(value = 6 * 7)
	if second != 42 || second_text != "6 * 7" || second_location.line != 30 { intrinsics.syscall(60, 3) }
	third, third_text, third_location := returned()(value = 40 + 2)
	if third != 42 || third_text != "40 + 2" || third_location.line != 32 || evaluations != 1 { intrinsics.syscall(60, 4) }
}

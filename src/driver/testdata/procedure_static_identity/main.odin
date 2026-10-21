package main

import "base:intrinsics"
import "base:runtime"

one :: proc(x := 1) -> int { return x }
two :: proc(x := 2) -> int { return x }
invoke :: proc(callback: $T) -> int { return callback() }
reverse :: proc(callback: $T) -> int { return callback() }
anonymous :: proc(callback: $T) -> int { return callback() }
Box :: struct($T: typeid) {
	callback: T,
}
Value :: union {
	proc(value := 4) -> int,
	int,
}

main :: proc() {
	if invoke(one) != 1 || invoke(two) != 1 { intrinsics.syscall(60, 1) }
	if reverse(two) != 2 || reverse(one) != 2 { intrinsics.syscall(60, 2) }
	a: proc(x := 3) -> int = one
	b: proc(x := 7) -> int = one
	c: proc(y := 9) -> int = one
	if anonymous(a) != 3 || anonymous(b) != 3 || anonymous(c) != 9 { intrinsics.syscall(60, 3) }
	if type_of(a) != type_of(b) || type_of(a) != type_of(c) { intrinsics.syscall(60, 4) }
	if typeid_of(type_of(a)) != typeid_of(type_of(b)) { intrinsics.syscall(60, 5) }
	if typeid_of(type_of(a)) == typeid_of(type_of(c)) { intrinsics.syscall(60, 6) }
	if type_info_of(type_of(a)) != type_info_of(type_of(b)) { intrinsics.syscall(60, 7) }
	first := Box(type_of(a)){a}
	second := Box(type_of(b)){b}
	if first.callback() != 3 || second.callback() != 3 { intrinsics.syscall(60, 8) }
	value: Value = c
	callback, ok := value.(proc(other := 6) -> int)
	if !ok || callback() != 6 { intrinsics.syscall(60, 9) }
	#partial switch entry in value {
	case proc(different := 8) -> int:
		if entry() != 8 { intrinsics.syscall(60, 10) }
	case int:
		intrinsics.syscall(60, 11)
	}
	boxed: any = a
	extracted, extracted_ok := boxed.(proc(x := 11) -> int)
	if !extracted_ok || extracted() != 11 { intrinsics.syscall(60, 12) }
	switch entry in boxed {
	case proc(x := 13) -> int:
		if entry() != 13 { intrinsics.syscall(60, 13) }
	case:
		intrinsics.syscall(60, 14)
	}
	named: proc(input := 3) -> (output: int) = one
	procedure_info := type_info_of(type_of(named)).variant.(runtime.Type_Info_Procedure)
	parameters := procedure_info.params.variant.(runtime.Type_Info_Parameters)
	results := procedure_info.results.variant.(runtime.Type_Info_Parameters)
	if len(parameters.names) != 1 || len(results.names) != 1 || len(parameters.types) != 1 || len(results.types) != 1 { intrinsics.syscall(60, 16) }
	if parameters.names[0] != "input" || results.names[0] != "output" { intrinsics.syscall(60, 15) }
	if parameters.types[0] != type_info_of(int) || results.types[0] != type_info_of(int) { intrinsics.syscall(60, 17) }
}

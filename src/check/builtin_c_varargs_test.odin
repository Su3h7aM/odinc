package check

import "core:testing"

@(test)
c_varargs_validate_list_identity_and_type_arguments :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
c_va_list :: struct {}
read :: proc(list: ^c_va_list) -> i32 { return c_va_arg(list, i32) }
copy_list :: proc(dst, src: ^c_va_list) { c_va_copy(dst, src); c_va_end(dst) }
start :: proc "c" (list: ^c_va_list, #c_vararg args: ..i32) { c_va_start(list, args) }
bad :: proc(list: ^int) { c_va_end(list) }
bad_type :: proc(list: ^c_va_list) { c_va_arg(list, 42) }
bad_start :: proc(list: ^c_va_list, args: []i32) { c_va_start(list, args) }
`,
	)
	names := []string{"c_va_arg", "c_va_copy", "c_va_end", "c_va_start"}
	for name in ([?]string{"read", "copy_list", "start", "bad", "bad_type", "bad_start"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = names, package_kind = .Intrinsics)
		if ok { testing.expect(t, (procedure.body_state == .Complete) == (name == "read" || name == "copy_list" || name == "start")) }
	}
}

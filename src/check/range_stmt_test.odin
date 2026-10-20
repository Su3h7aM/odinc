package check

import "core:testing"

@(test)
range_statements_check_containers_intervals_and_break_targets :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample

main :: proc() {
	values := [3]u8{1, 2, 3}
	for &value in values { value *= 2 }
	total := u8(0)
	for value in values { total += value }
	for i in 0 ..< 3 { break }
	for i in 0 ..= 2 { if i == 1 { break } }
	#unroll for k in 0 ..< 2 { total += u8(k) }
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	testing.expect(t, ok && procedure.body_state == .Complete, "range statements --- containers, intervals and unlabeled break must check")
}

@(test)
unroll_body_rejects_unlabeled_break :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample

main :: proc() {
	for i in 0 ..< 3 {
		#unroll for k in 0 ..< 2 { if k == 1 { break } }
	}
}
`)
	procedure, ok := check_last_procedure_source(t, source)
	testing.expect(t, ok && procedure.body_state != .Complete, "unlabeled break inside #unroll must be rejected")
}

@(test)
double_dot_range_operator_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample

main :: proc() {
	for i in 0 .. 2 {}
}
`)
	procedure, ok := check_last_procedure_source(t, source)
	testing.expect(t, ok && procedure.body_state != .Complete, "'..' must be rejected as a range operator")
}
@(test)
reverse_and_enum_range_forms_check :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample

Color :: enum { Red, Green }
Flags :: bit_set[Color]

main :: proc() {
	values := [2]int{1, 2}
	counts := [Color]int{.Red = 1, .Green = 2}
	flags := Flags{.Red}
	#reverse for value in values {}
	for count, color in counts {}
	for color in Color {}
	#reverse for flag in flags {}
}
`,
	)
	procedure, ok := check_last_procedure_source(t, source)
	testing.expect(t, ok && procedure.body_state == .Complete, "reverse, enum and bit_set range forms must check")
}

@(test)
reverse_interval_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample

main :: proc() {
	#reverse for i in 0 ..< 3 {}
}
`)
	procedure, ok := check_last_procedure_source(t, source)
	testing.expect(t, ok && procedure.body_state != .Complete, "#reverse over an interval must be rejected")
}

@(test)
map_range_rejects_reverse_and_key_references :: proc(t: ^testing.T) {
	reverse := transmute([]byte)string(`package sample
main :: proc() {
	values: map[int]int
	#reverse for key in values {}
}
`)
	_, reverse_ok := check_procedure_source(t, reverse, expected_kind = .Invalid_Reverse_Range)
	if !reverse_ok { return }
	key_reference := transmute([]byte)string(`package sample
main :: proc() {
	values: map[int]int
	for &key in values {}
}
`)
	_, key_reference_ok := check_procedure_source(t, key_reference, expected_kind = .Unsupported, expected_reason = "Range_Reference")
	testing.expect(t, key_reference_ok, "map key references must be rejected")
}

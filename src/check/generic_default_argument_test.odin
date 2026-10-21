package check

import "core:testing"

// An explicitly passed argument converts against the default inferred with the parameters
// bound so far. Official Odin builds `get(&a, 9)` and prints 9.
@(test)
explicit_argument_converts_against_bound_default_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
get :: proc(b: ^Box($T), x := size_of(T)) -> int { return x }
main :: proc() {
	a := Box(int){value = 1}
	b := Box(u8){value = 2}
	_ = get(&a)
	_ = get(&b, 9)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

// A default naming a parameter bound only later is rejected. Official Odin reports
// "Undeclared name: T" at the definition.
@(test)
forward_reference_default_still_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
get :: proc(x := size_of(T), b: ^Box($T)) -> int { return x }
main :: proc() {
	a := Box(u8){value = 2}
	_ = get(b = &a)
}
`,
	)
	_, ok := check_procedure_source(t, source, .Undeclared_Name)
	testing.expect(t, ok)
}

// A generic call used as a default is not a constant. Official Odin reports
// "Default parameter must be a constant, got pick(T)".
@(test)
generic_call_default_must_be_constant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
pick :: proc($T: typeid) -> int { return 8 }
get :: proc(b: ^Box($T), x := pick(T)) -> int { return x }
main :: proc() {
	a := Box(int){value = 1}
	_ = get(&a)
}
`,
	)
	_, ok := check_procedure_source(t, source, .Unsupported, "Default_Constant")
	testing.expect(t, ok)
}

// A compound literal over a polymorphic type is not a valid default, with or without an
// explicit parameter type. Official Odin reports "Cannot use a polymorphic type for a
// compound literal, got '$T'".
@(test)
polymorphic_compound_literal_default_rejected :: proc(t: ^testing.T) {
	untyped := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
get :: proc(b: ^Box($T), x := T{}) -> T { return x }
main :: proc() {
	a := Box(int){value = 1}
	_ = get(&a)
}
`,
	)
	_, untyped_ok := check_procedure_source(t, untyped, .Unsupported, "Default_Polymorphic_Compound")
	testing.expect(t, untyped_ok)
	typed := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
get :: proc(b: ^Box($T), x: T = T{}) -> T { return x }
main :: proc() {
	a := Box(int){value = 1}
	_ = get(&a)
}
`,
	)
	_, typed_ok := check_procedure_source(t, typed, .Unsupported, "Default_Polymorphic_Compound")
	testing.expect(t, typed_ok)
}

// A bare polymorphic parameter is not a valid default. Official Odin reports "A default value
// for a parameter must not be a polymorphic constant type, got $D".
@(test)
bare_polymorphic_default_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid, $D: int) { value: T }
get :: proc(b: ^Box($T, $D), x := D) -> int { return x }
main :: proc() {
	a := Box(int, 1){value = 1}
	_ = get(&a)
}
`,
	)
	_, ok := check_procedure_source(t, source, .Unsupported, "Default_Polymorphic_Constant")
	testing.expect(t, ok)
}

// A procedure literal over a polymorphic type is not a valid default, even though a literal
// with a concrete signature is accepted and its body belongs to the instances.
@(test)
polymorphic_procedure_literal_default_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
get :: proc(b: ^Box($T), f := proc(v: T) -> T { return v }) -> T { return f(b.value) }
main :: proc() {
	a := Box(int){value = 1}
	_ = get(&a)
}
`,
	)
	_, ok := check_procedure_source(t, source, .Unsupported, "Default_Polymorphic_Procedure")
	testing.expect(t, ok)
}

// A computed non-constant default is rejected even outside generics. Official Odin reports
// "Default parameter must be a constant, got marker + 1".
@(test)
computed_default_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
marker := 10
plain :: proc(x := marker + 1) -> int { return x }
main :: proc() {
	_ = plain()
}
`)
	_, ok := check_procedure_source(t, source, .Unsupported, "Default_Constant")
	testing.expect(t, ok)
}

// A bare global stays a valid non-constant default, re-evaluated at each call.
@(test)
global_default_still_accepted :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
marker := 10
get :: proc($T: typeid, x := marker) -> int { return x }
main :: proc() {
	_ = get(int)
}
`)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

// A procedure literal with a concrete signature stays valid, even when its body names a
// polymorphic type: the body belongs to the instances.
@(test)
clean_literal_default_still_accepted :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
get :: proc(b: ^Box($T), f := proc(v: int) -> int { return v + size_of(T) }) -> int { return f(1) }
main :: proc() {
	a := Box(int){value = 1}
	_ = get(&a)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

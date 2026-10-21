package check

import "core:testing"

@(test)
auto_cast_rejects_unrepresentable_constant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
    value: u8 = auto_cast 300
    _ = value
}
`)
	_, ok := check_procedure_source(t, source, .Conversion, diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
length_argument_hint_does_not_retype_a_bound_variable :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
consume :: proc(value: uint) {}
main :: proc() {
    values: []u8
    count := len(values)
    consume(count)
}
`,
	)
	_, ok := check_procedure_source(t, source, .Conversion, diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
procedure_directive_requires_a_procedure_scope :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
NAME :: #procedure
main :: proc() {}
`)
	_, ok := check_procedure_source(t, source, .Unsupported, "Procedure_Directive_Scope", diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
local_generic_record_checks_its_where_clause :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc() {
    Buffer :: struct($N: int) where N > 1 { values: [N]int }
    buffer: Buffer(0)
    _ = buffer
}
`,
	)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 1)
	testing.expect(t, ok)
}

@(private = "file")
CALL_CONTEXT_REASON :: "'context' has not been defined within this scope, but is required for this procedure call"

@(private = "file")
DYNAMIC_LITERAL_CONTEXT_REASON :: "Compound literals of dynamic types require a 'context' to defined"

// Official: Compound literals of dynamic types require a 'context' to defined.
@(test)
dynamic_array_literal_requires_a_context :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`#+feature dynamic-literals
package sample
f :: proc "contextless" () {
    values := [dynamic]int{1, 4, 9}
    _ = values
}
`,
	)
	_, ok := check_procedure_source(t, source, .Undefined_Context, DYNAMIC_LITERAL_CONTEXT_REASON, diagnostic_count = 1, procedure_name = "f")
	testing.expect(t, ok)
}

// Official: Compound literals of dynamic types require a 'context' to defined.
@(test)
map_literal_requires_a_context :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`#+feature dynamic-literals
package sample
f :: proc "contextless" () {
    table := map[string]int{"a" = 1}
    _ = table
}
`,
	)
	_, ok := check_procedure_source(t, source, .Undefined_Context, DYNAMIC_LITERAL_CONTEXT_REASON, diagnostic_count = 1, procedure_name = "f")
	testing.expect(t, ok)
}

// Official: 'context' has not been defined within this scope, but is required for this procedure call.
@(test)
contextless_procedure_cannot_call_an_odin_procedure :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
g :: proc() {}
f :: proc "contextless" () {
    g()
}
`)
	_, ok := check_procedure_source(t, source, .Undefined_Context, CALL_CONTEXT_REASON, diagnostic_count = 1, procedure_name = "f")
	testing.expect(t, ok)
}

// Official: a `proc "c"` caller defines no context either.
@(test)
c_procedure_cannot_call_an_odin_procedure :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
g :: proc() {}
f :: proc "c" () {
    g()
}
`)
	_, ok := check_procedure_source(t, source, .Undefined_Context, CALL_CONTEXT_REASON, diagnostic_count = 1, procedure_name = "f")
	testing.expect(t, ok)
}

// Official: the call through an odin-convention procedure value needs the context too.
@(test)
contextless_procedure_cannot_call_an_odin_procedure_value :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
g :: proc() {}
f :: proc "contextless" () {
    operation := g
    operation()
}
`)
	_, ok := check_procedure_source(t, source, .Undefined_Context, CALL_CONTEXT_REASON, diagnostic_count = 1, procedure_name = "f")
	testing.expect(t, ok)
}

// Official: a deferred odin-convention call needs the context at the defer site.
@(test)
contextless_procedure_cannot_defer_an_odin_call :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
g :: proc() {}
f :: proc "contextless" () {
    defer g()
}
`)
	_, ok := check_procedure_source(t, source, .Undefined_Context, CALL_CONTEXT_REASON, diagnostic_count = 1, procedure_name = "f")
	testing.expect(t, ok)
}

// Official: a contextless callee takes no context, so the call checks.
@(test)
contextless_procedure_can_call_a_contextless_procedure :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
g :: proc "contextless" () {}
f :: proc "contextless" () {
    g()
}
`)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0, procedure_name = "f")
	testing.expect(t, ok)
}

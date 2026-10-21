package check

import "core:strings"
import "core:testing"

// A by-value range variable is immutable: official rejects assignment to it
// with `Cannot assign to 'x'` (check_stmt.cpp:613). Uses of the checker-wide
// `.Immutable` mechanism surface that verdict as Assign_Destination_Mode.
@(test)
range_by_value_assignment_is_rejected :: proc(t: ^testing.T) {
	header :=
		"package sample\nS :: struct { x: int }\nColor :: enum { Red, Green }\nFlags :: bit_set[Color]\n" +
		"take_ptr :: proc \"contextless\" (p: ^int) { p^ += 1 }\n" +
		"produce :: proc \"contextless\" () -> (int, bool) { return 1, true }\n"
	cases := [?]struct {
		body:   string,
		kind:   Expression_Diagnostic_Kind,
		reason: string,
	} {


		// Official: Cannot assign to 'x'.
		{"a := [3]int{1, 2, 3}\nfor x in a { x = 9 }", .Unsupported, "Assign_Destination_Mode"},
		{"s: []int\nfor x in s { x = 9 }", .Unsupported, "Assign_Destination_Mode"},
		{"d: [dynamic]int\nfor x in d { x = 9 }", .Unsupported, "Assign_Destination_Mode"},
		{"for c in Color { c = .Green }", .Unsupported, "Assign_Destination_Mode"},
		{"f: Flags\nfor e in f { e = .Green }", .Unsupported, "Assign_Destination_Mode"},
		{"for i in 0 ..< 3 { i = 9 }", .Unsupported, "Assign_Destination_Mode"},
		{"for v in produce() { v = 9 }", .Unsupported, "Assign_Destination_Mode"},
		// Official: Cannot assign to 'i'. The index is a value too.
		{"a := [3]int{1, 2, 3}\nfor v, i in a { i = 9 }", .Unsupported, "Assign_Destination_Mode"},
		// Official: Cannot assign to 'e.x'. A field of a by-value variable is not assignable.
		{"a: [3]S\nfor e in a { e.x = 9 }", .Unsupported, "Assign_Destination_Mode"},
		// Official: Cannot take the pointer address of 'x'. Passing it to a pointer parameter is the same rule.
		{"a := [3]int{1, 2, 3}\nfor x in a { _ = &x }", .Unsupported, "Address_Mode"},
		{"a := [3]int{1, 2, 3}\nfor x in a { take_ptr(&x) }", .Unsupported, "Address_Mode"},
	}
	for entry in cases {
		source := strings.concatenate({header, "main :: proc \"contextless\" () {\n", entry.body, "\n}\n"}, context.temp_allocator)
		_, ok := check_procedure_source(t, transmute([]byte)source, entry.kind, entry.reason)
		testing.expectf(t, ok, "must reject: %s", entry.body)
	}
}

// Writing through a pointer the variable already holds, and assigning through
// a `&x` by-reference binding, stay valid. So do reads of every form,
// including #soa values whose write diagnostic belongs to the checker core.
@(test)
range_reference_and_pointer_writes_check :: proc(t: ^testing.T) {
	header := "package sample\nS :: struct { x: int }\n"
	cases := [?]string {
		"a := [3]int{1, 2, 3}\nptrs: [3]^int\nfor v, i in a { ptrs[i] = &a[i] }\nfor p in ptrs { p^ = 1 }",
		"a := [3]int{1, 2, 3}\nfor &x in a { x = 9 }",
		"s: []int\nfor &x in s { x = 9 }",
		"d: [dynamic]int\nfor &x in d { x = 9 }",
		"a := [3]int{1, 2, 3}\nfor x in a { _ = x }",
		"for i in 0 ..< 3 { _ = i }",
		"c: #soa[4]S\nfor v in c { _ = v.x }",
		"c: #soa[4]S\nfor v, i in c { _ = i }",
	}
	for body in cases {
		source := strings.concatenate({header, "main :: proc \"contextless\" () {\n", body, "\n}\n"}, context.temp_allocator)
		procedure, ok := check_procedure_source(t, transmute([]byte)source)
		if !testing.expectf(t, ok, "must check: %s", body) { continue }
		testing.expectf(t, procedure.body_state == .Complete, "must complete: %s", body)
	}
}

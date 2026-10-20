package check

import "core:strings"
import "core:testing"

@(test)
using_parameters_reject_invalid_roots_collisions_and_value_mutation :: proc(t: ^testing.T) {
	// Official rejects blank/nonstruct roots and namespace collisions, including result names and immediate body declarations.
	cases := [?]struct {
		procedure: string,
		kind:      Expression_Diagnostic_Kind,
		reason:    string,
	} {
		{"f :: proc(using _: Point) {}", .Invalid_Operand, "Using_Parameter_Name"},
		{"f :: proc(using value: int) {}", .Invalid_Operand, "Using_Struct_Variable"},
		{"f :: proc(using values: ..Point) {}", .Invalid_Operand, "Using_Struct_Variable"},
		{"f :: proc(using value: Point, x: int) {}", .Invalid_Operand, "Using_Collision"},
		{"f :: proc(x: int, using value: Point) {}", .Invalid_Operand, "Using_Collision"},
		{"f :: proc(using value: Point) -> (x: int) { return }", .Invalid_Operand, "Using_Collision"},
		{"f :: proc(using value: Point) { x := 2; _ = x }", .Unsupported, "Local_Duplicate"},
		// Official: Cannot assign to 'x'. Pointer-valued embedded fields do not make value-root aliases writable.
		{"f :: proc(using value: Point) { x = 2 }", .Unsupported, "Assign_Destination_Mode"},
		{"f :: proc(using value: Embedded) { x = 2 }", .Unsupported, "Assign_Destination_Mode"},
		// Official: Cannot assign to 'value' which is from a 'using' procedure parameter.
		{"f :: proc(using value: ^Point) { value = nil }", .Unsupported, "Assign_Destination_Mode"},
		// Official: Cannot take the pointer address of 'value' which is a procedure parameter.
		{"f :: proc(using value: Point) { _ = &value }", .Unsupported, "Address_Mode"},
	}
	for entry in cases {
		source := strings.concatenate(
			{"#+feature using-stmt\npackage sample\nPoint :: struct { x, y: int }\nEmbedded :: struct { using inner: ^Point }\n", entry.procedure, "\n"},
			context.temp_allocator,
		)
		_, ok := check_procedure_source(t, transmute([]byte)source, entry.kind, entry.reason, procedure_name = "f")
		testing.expectf(t, ok, "must reject: %s", entry.procedure)
	}
	// Official requires the same opt-in for using statements and parameters.
	source := "package sample\nPoint :: struct { x: int }\nf :: proc(using value: Point) {}\n"
	_, ok := check_procedure_source(t, transmute([]byte)source, .Invalid_Operand, "Using_Disallowed", procedure_name = "f")
	testing.expect(t, ok)
}

package check

import "core:strings"
import "core:testing"
import "oc:syntax"

@(test)
using_statements_reject_nonentities_collisions_and_missing_opt_in :: proc(t: ^testing.T) {
	// Official rejects calls, scalar variables, struct type names, constants, and same-scope collisions.
	cases := [?]struct {
		body, reason: string,
	} {
		{"using get()", "Using_Entity"},
		{"value := 1; using value", "Using_Struct_Variable"},
		{"using Point", "Using_Struct_Variable"},
		{"value :: 1; using value", "Using_Struct_Variable"},
		{"value := Point{1}; x := 2; using value; _ = x", "Using_Collision"},
	}
	for entry in cases {
		source := strings.concatenate(
			{
				"#+feature using-stmt\npackage sample\nPoint :: struct { x: int }\nget :: proc() -> Point { return Point{1} }\nf :: proc() { ",
				entry.body,
				" }\n",
			},
			context.temp_allocator,
		)
		_, ok := check_procedure_source(t, transmute([]byte)source, .Invalid_Operand, entry.reason, procedure_name = "f")
		testing.expectf(t, ok, "must reject: %s", entry.body)
	}
	source := "package sample\nPoint :: struct { x: int }\nf :: proc() { point := Point{1}; using point }\n"
	_, ok := check_procedure_source(t, transmute([]byte)source, .Invalid_Operand, "Using_Disallowed", procedure_name = "f")
	testing.expect(t, ok)
	escaped := "#+feature using-stmt\npackage sample\nPoint :: struct { x: int }\nf :: proc() { point := Point{1}; { using point; x = 2 }; _ = x }\n"
	_, escaped_ok := check_procedure_source(t, transmute([]byte)escaped, .Undeclared_Name, procedure_name = "f")
	testing.expect(t, escaped_ok)
}

@(test)
promoted_field_collisions_are_rejected_at_the_struct_declaration :: proc(t: ^testing.T) {
	// Official: 'x' is already declared in the struct, through 'using'. None of these types is used.
	declarations := [?]string {
		"S :: struct { using a: A, using b: B }",
		"S :: struct { x: int, using a: A }",
		"S :: struct { using a: A, using b: A }",
		"S :: struct { using a: ^A, using b: B }",
		"Inner :: struct { using a: A }; S :: struct { using inner: Inner, using b: B }",
		"Recursive :: struct { using next: ^Recursive }; S :: struct { using value: Recursive }",
	}
	for declaration in declarations {
		source := strings.concatenate(
			{"package sample\nA :: struct { x: int }\nB :: struct { x: int }\n", declaration, "\nf :: proc() {}\n"},
			context.temp_allocator,
		)
		_, ok := check_procedure_source(t, transmute([]byte)source, procedure_name = "f", type_diagnostic_count = 1)
		testing.expectf(t, ok, "must reject unused declaration: %s", declaration)
	}
}

@(test)
using_vets_only_report_same_type_shadowing_from_using :: proc(t: ^testing.T) {
	for options in ([]syntax.Vet_Flags{{.Using_Stmt}, {.Using_Param}}) {
		_, ok := check_procedure_source(
			t,
			transmute([]byte)string(
				"#+feature using-stmt\npackage sample\nPoint :: struct { x: int }\nf :: proc() { x := 1; point := Point{}; { using point }; _ = x }\n",
			),
			.Shadowing,
			"Declaration of 'x' from 'using' shadows declaration at line 4",
			diagnostic_count = 1,
			procedure_name = "f",
			vet = options,
		)
		testing.expect(t, ok)
		_, clean := check_procedure_source(
			t,
			transmute([]byte)string(
				"#+feature using-stmt\npackage sample\nPoint :: struct { x: int }\nx: int\ng :: proc(using point: Point) { _ = x }\nf :: proc() { x := f32(1); point := Point{}; { using point }; _ = x }\n",
			),
			diagnostic_count = 0,
			procedure_name = "f",
			vet = options,
		)
		testing.expect(t, clean)
	}
}

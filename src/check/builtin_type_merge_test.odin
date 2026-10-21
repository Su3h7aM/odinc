package check

import "core:testing"

@(test)
type_merge_combines_union_variants :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
A :: enum i32 { None, One }
B :: enum i32 { None, Two }
C :: enum i32 { None, Three }
Merged :: type_merge(union #shared_nil { A, B }, union #shared_nil { B, C })
Aligned :: type_merge(union #align(16) { int }, union { bool })
Pointer :: type_merge(union { ^int }, union { ^int })
main :: proc() {
	#assert(size_of(Merged) == 8)
	#assert(align_of(Aligned) == 16)
	#assert(size_of(Pointer) == size_of(^int))
	a: Merged = A.One
	b: Merged = B.Two
	c: Merged = C.Three
}
`,
	)
	procedure, ok := check_procedure_source(t, source, intrinsic_names = {"type_merge"}, diagnostic_count = 0, type_diagnostic_count = 0)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
type_merge_rejects_non_unions_and_mismatched_kinds :: proc(t: ^testing.T) {
	for source in ([]string{"package sample\nmain :: proc() { T :: type_merge(int, union { bool }) }\n", "package sample\nmain :: proc() { T :: type_merge(union { int }, union #no_nil { bool }) }\n"}) {
		_, ok := check_procedure_source(t, transmute([]byte)source, intrinsic_names = {"type_merge"}, expected_kind = .Invalid_Operand, diagnostic_count = 1)
		testing.expect(t, ok)
	}
}

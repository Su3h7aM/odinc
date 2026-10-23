package check

import "core:testing"

// A `$C: typeid/Box($T)` constraint matches `Box(u8)`: the missing argument equals the record's
// default, as in `chan.create_buffered(Update_Channel, ...)` where `Chan` defaults `$D`.
@(test)
generic_typeid_constraint_matches_record_with_defaulted_trailing_parameter :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid, $N: int = 4) { value: T }
take_box :: proc "contextless" ($C: typeid/Box($T)) -> int { return 4 }
main :: proc "contextless" () {
	size := take_box(Box(u8))
	_ = size
}
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0)
	testing.expect(t, ok)
}

// A `$C: typeid/Box($T)` constraint rejects an instance whose trailing argument differs from the default.
@(test)
generic_typeid_constraint_rejects_non_default_record_argument :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid, $N: int = 4) { value: T }
take_box :: proc "contextless" ($C: typeid/Box($T)) -> int { return 4 }
main :: proc "contextless" () {
	size := take_box(Box(u8, 8))
	_ = size
}
`,
	)
	_, ok := check_procedure_source(t, source, .Unsupported, "Generic_Call_Type_Conflict")
	testing.expect(t, ok)
}

// Parameters sharing `$T` bind it from the first argument; a union variant for the second still
// matches, as in `testing.expect_value(t, dest_union, My_Distinct(...))`.
@(test)
generic_shared_poly_parameter_accepts_union_variant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
My_Int :: distinct int
My_Union :: union { int, My_Int }
same_type :: proc "contextless" (value, expected: $T) -> bool { return true }
main :: proc "contextless" () {
	slot: My_Union = My_Int(3)
	ok := same_type(slot, My_Int(3))
	_ = ok
}
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0)
	testing.expect(t, ok)
}

// Same shape with an enum variant, as in `testing.expect_value(t, err, io.Error.Unexpected_EOF)`
// where the error union holds the enum.
@(test)
generic_shared_poly_parameter_accepts_enum_variant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Code :: enum { Ok, Unexpected_EOF }
Outcome :: union { Code, int }
check_code :: proc "contextless" (value, expected: $T) -> bool { return true }
main :: proc "contextless" () {
	result: Outcome = Code.Unexpected_EOF
	ok := check_code(result, Code.Unexpected_EOF)
	_ = ok
}
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0)
	testing.expect(t, ok)
}

// Same shape when the variant comes from an outer generic parameter, as in the `expect_value(t, res, expected)`
// calls inside `when T == f16` branches where `res` is a union and `expected` is the outer `T`.
@(test)
generic_shared_poly_parameter_accepts_outer_parameter_as_variant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Slot :: union { u8, int }
inner :: proc "contextless" (value, expected: $T) -> bool { return true }
outer :: proc "contextless" (x: $T) -> bool {
	slot: Slot = x
	return inner(slot, x)
}
main :: proc "contextless" () {
	ok := outer(u8(1))
	_ = ok
}
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0)
	testing.expect(t, ok)
}

// Parameters sharing `$T` still reject an argument that does not convert to the bound type.
@(test)
generic_shared_poly_parameter_rejects_incompatible_types :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
same_type :: proc "contextless" (value, expected: $T) -> bool { return true }
main :: proc "contextless" () {
	a: i32 = 1
	b: i64 = 2
	ok := same_type(a, b)
	_ = ok
}
`,
	)
	_, ok := check_procedure_source(t, source, .Unsupported, "Generic_Call_Pattern")
	testing.expect(t, ok)
}

// A procedure binds a constant parameter by identity.
// A disabled generic procedure is neither instantiated with a body nor called.
// Matrix patterns bind dimensions, matrices index by any integer and transpose, and `$T/^Base` accepts a subtype pointer.
// A `#simd[$N]$E` pattern matches a vector and binds its lane count; constant arrays compare, untyped constants convert to
// `any`, and a procedure taking a pointer to an offset-zero subtype is assignable to one taking the pointer to the base.
@(test)
generic_simd_pattern_constant_aggregates_any_and_subtype_procedures_check :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
IFoo :: struct { foo: proc(self: ^IFoo) -> int }
Foo :: struct { using vt: IFoo }
Pair :: [2]int
Id :: struct { type: typeid }
#assert(Pair{0 = 1, 1 = 2} == {1 = 2, 0 = 1})
apply :: proc "contextless" (how: proc "contextless" (a: []int), what: []int) { how(what) }
gen :: proc "contextless" (a: $T/[]$E) {}
#assert(#hash("a", "crc32") == 3904355907)
lanes :: proc "contextless" (v: #simd[$N]$E) -> [N]E { return transmute([N]E)v }
Node :: struct { id: int }
Expr :: struct { using node: Node, e: int }
Index :: distinct i32
double :: proc "contextless" (value: int) -> int { return value * 2 }
call_with :: proc "contextless" ($f: proc "contextless" (int) -> int) -> int { return f(1) }
@(disabled = true)
disabled_generic :: proc "contextless" (value: $T) { undeclared_name(value) }
matrix_dimension :: proc "contextless" (m: matrix[$N, N]$E) -> int { return N }
pointer_of :: proc "contextless" (node: $T/^Node) -> typeid { return T }
entry :: proc "contextless" (v: #simd[4]f32, w: []int) {
	a := lanes(v)
	apply(gen, w)
	data :: Id{int}
	_ = data.type
	b, c := any(1), cast(any)2.5
	d: proc(self: ^IFoo) -> int = proc(self: ^Foo) -> int { return 0 }
	_, _, _, _ = a, b, c, d
	m := matrix[2, 2]f32{}
	k := Index(1)
	e: ^Expr
	disabled_generic(1)
	_ = call_with(double)
	row := [2]int{1, 2}
	grid: [2][2]int = row
	constant_grid: [2]Pair : Pair{3, 4}
	_, _ = cast([2][2]i64)grid, constant_grid
	_, _, _, _ = matrix_dimension(m), m[k, k], transpose(m), pointer_of(e)
}
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0, procedure_name = "entry", intrinsic_names = {"transpose"})
	testing.expect(t, ok)
}

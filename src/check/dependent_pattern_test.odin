package check

import "core:testing"

@(test)
dependent_array_patterns_bind_earlier_parameters :: proc(t: ^testing.T) {
	// Official accepts each of these shapes: later dimensions and element patterns name earlier bindings.
	source := transmute([]byte)string(
		`package sample
echo :: proc "contextless" (a: [$N]$T, b: [N]T) -> T { return b[0] }
combine :: proc "contextless" (a: [$N]int, b: [N][$P]int) -> int { return N + P }
deep :: proc "contextless" (a: [$N]int, b: [N][$P][2]int) -> int { return N + P }
shared :: proc "contextless" (a: [$N]$T, b: [N]T, c: T) -> T { return c }
constant_dimension :: proc "contextless" (a: [$N]int, b: [N][2 + 1]int) -> int { return N }
matrix_mul :: proc "contextless" (a: [$M][$N]$T, b: [N][$P]T) -> (c: [M][P]T) {
	for i in 0 ..< M {
		for j in 0 ..< P {
			for k in 0 ..< N {
				c[i][j] += a[i][k] * b[k][j]
			}
		}
	}
	return
}
Table :: struct($K, $V: typeid) { n: int }
expand :: proc "contextless" (table: ^$T/Table) -> int { return table.n }
main :: proc "contextless" () {
	a := [2]int{1, 2}
	_ = echo(a, [2]int{3, 4})
	_ = combine(a, [2][3]int{})
	_ = deep(a, [2][3][2]int{})
	_ = shared(a, [2]int{3, 4}, 9)
	_ = constant_dimension(a, [2][3]int{})
	_ = matrix_mul([2][3]f32{}, [3][2]f32{})
	table := Table(int, int){n = 7}
	_ = expand(&table)
	_ = combine([2]int{}, [2][3]int{})
	_ = combine([3]int{}, [3][4]int{})
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
constant_parameter_names_its_own_type :: proc(t: ^testing.T) {
	// Official binds both `$N` and the type name `$I` it declares.
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	foo :: proc "contextless" ($N: $I, $T: typeid) -> (res: [N]T) {
		for i in 0 ..< N {
			res[i] = T(i * i)
		}
		return
	}
	array := foo(4, int)
	_ = array
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
dependent_array_pattern_rejects_conflicting_dimension :: proc(t: ^testing.T) {
	// Official: the second argument has length 3 but the earlier binding fixes the dimension at 2.
	source := transmute([]byte)string(
		`package sample
f :: proc "contextless" (a: [$N]int, b: [N]int) -> int { return N }
main :: proc "contextless" () {
	a := [2]int{}
	b := [3]int{}
	_ = f(a, b)
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}

@(test)
dependent_array_pattern_rejects_unbound_later_name :: proc(t: ^testing.T) {
	// Official: `M` is undeclared, so the later parameter's shape cannot be bound.
	source := transmute([]byte)string(
		`package sample
f :: proc "contextless" (a: [$N]int, b: [M]int) -> int { return 0 }
main :: proc "contextless" () {
	_ = f([2]int{}, [3]int{})
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}

@(test)
dependent_array_pattern_rejects_forward_reference :: proc(t: ^testing.T) {
	// Official: `N` is undeclared in the earlier parameter; bindings reach later parameters only.
	source := transmute([]byte)string(
		`package sample
f :: proc "contextless" (a: [N]int, b: [$N]int) -> int { return N }
main :: proc "contextless" () {
	_ = f([2]int{}, [2]int{})
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}

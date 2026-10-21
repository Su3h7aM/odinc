package check

import "core:testing"

@(test)
selector_call_rejects_invalid_receiver_calls :: proc(t: ^testing.T) {
	too_many := transmute([]byte)string(
		`package sample
Impl :: struct { id: int, f: proc "contextless" (p: ^Impl, n: int) }
g :: proc "contextless" (p: ^Impl, n: int) {}
main :: proc "contextless" () { i := Impl{f = g}; i->f(1, 2) }
`,
	)
	_, ok := check_procedure_source(t, too_many, .Unsupported, "Selector_Call_Arguments", procedure_name = "main")
	testing.expect(t, ok)

	rvalue := transmute([]byte)string(
		`package sample
Impl :: struct { id: int, f: proc "contextless" (p: ^Impl, n: int) }
g :: proc "contextless" (p: ^Impl, n: int) {}
mk :: proc "contextless" () -> Impl { return Impl{f = g} }
main :: proc "contextless" () { mk()->f(1) }
`,
	)
	_, ok = check_procedure_source(t, rvalue, .Conversion, procedure_name = "main")
	testing.expect(t, ok)

	non_proc := transmute([]byte)string(
		`package sample
Impl :: struct { id: int, f: proc "contextless" (p: ^Impl, n: int) }
main :: proc "contextless" () { i := Impl{}; i->id(1) }
`,
	)
	_, ok = check_procedure_source(t, non_proc, .Unsupported, "Selector_Call_Callee", procedure_name = "main")
	testing.expect(t, ok)

	package_procedure := transmute([]byte)string(
		`package sample
Impl :: struct { id: int, f: proc "contextless" (p: ^Impl, n: int) }
g :: proc "contextless" (p: ^Impl, n: int) {}
main :: proc "contextless" () { i := Impl{}; i->g(1) }
`,
	)
	_, ok = check_procedure_source(t, package_procedure, .Undeclared_Name, procedure_name = "main")
	testing.expect(t, ok)
}

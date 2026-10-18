package check

import "core:testing"

@(test)
procedure_where_clauses_require_true_constant_booleans :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		kind:   Expression_Diagnostic_Kind,
		reason: string,
	} {
		{`package sample
main :: proc "contextless" () where true, 1 == 1 {}
`, .None, ""},
		{`package sample
main :: proc "contextless" () where false { undeclared = 1 }
`, .Invalid_Operand, "'where' clause evaluated to false:\n\tfalse"},
		{`package sample
main :: proc "contextless" () where 1 {}
`, .Expected_Boolean_Constant, "'where' clauses expect a constant boolean evaluation"},
		{
			`package sample
main :: proc "contextless" (value: bool) where value {}
`,
			.Expected_Boolean_Constant,
			"'where' clauses expect a constant boolean evaluation",
		},
		{
			`package sample
main :: proc "contextless" () { local :: proc "contextless" () where false { undeclared = 1 } }
`,
			.Invalid_Operand,
			"'where' clause evaluated to false:\n\tfalse",
		},
	}
	for test in cases {
		count := 1 if test.kind != .None else 0
		procedure, ok := check_procedure_source(t, transmute([]byte)test.source, test.kind, test.reason, count)
		if ok { testing.expect(t, procedure.body_state == (.Complete if test.kind == .None else .Invalid)) }
	}
}

@(test)
polymorphic_procedure_where_clauses_check_each_instance :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		kind:   Expression_Diagnostic_Kind,
		reason: string,
	} {
		{
			`package sample
pick :: proc "contextless" (value: $T) -> T where T == u8 { return value }
unused :: proc "contextless" (value: $T) where false { undeclared = 1 }
main :: proc "contextless" () { value := pick(u8(1)); _ = pick(value) }
`,
			.None,
			"",
		},
		{
			`package sample
pick :: proc "contextless" (value: $T) -> T where T == u8 { return value }
main :: proc "contextless" () { _ = pick(u8(1)); _ = pick(1) }
`,
			.Invalid_Operand,
			"'where' clause evaluated to false:\n\tT == u8",
		},
		{
			`package sample
pick :: proc "contextless" ($N: int) where N > 0 {}
main :: proc "contextless" () { pick(1); pick(0) }
`,
			.Invalid_Operand,
			"'where' clause evaluated to false:\n\tN > 0",
		},
		{
			`package sample
pick :: proc "contextless" ($N: int) where N {}
main :: proc "contextless" () { pick(1) }
`,
			.Expected_Boolean_Constant,
			"'where' clauses expect a constant boolean evaluation",
		},
		{
			`package sample
pick :: proc "contextless" (value: $T) where value {}
main :: proc "contextless" () { pick(true) }
`,
			.Expected_Boolean_Constant,
			"'where' clauses expect a constant boolean evaluation",
		},
	}
	for test in cases {
		count := 1 if test.kind != .None else 0
		procedure, ok := check_procedure_source(t, transmute([]byte)test.source, test.kind, test.reason, count * 2, "main")
		if ok { testing.expect(t, procedure.body_state == (.Complete if test.kind == .None else .Invalid)) }
	}
}

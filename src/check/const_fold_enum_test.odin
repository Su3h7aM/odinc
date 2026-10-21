package check

import "core:testing"

@(test)
unsigned_enum_constants_keep_their_full_range :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Unsigned :: enum uint { Zero, High = 1 << 63, Last = ~uint(0) }
Signed :: enum i64 { Low = -9223372036854775808, High = 9223372036854775807 }
main :: proc "contextless" () {
	#assert(uint(Unsigned.Last) == 18446744073709551615)
	#assert(min(Unsigned) == .Zero)
	#assert(max(Unsigned) == .Last)
	#assert(i64(Signed.Low) == -9223372036854775808)
	#assert(i64(Signed.High) == 9223372036854775807)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
enum_initializers_accept_integer_backed_constants :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Source :: enum { First = 11, Last = 19 }
Target :: enum { First = auto_cast Source.First, Last = auto_cast Source.Last }
main :: proc() {
	#assert(int(Target.First) == 11)
	#assert(int(Target.Last) == 19)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
enum_backing_ranges_reject_overflow :: proc(t: ^testing.T) {
	for source in ([]string{`package sample
E :: enum u64 { Last = 18446744073709551616 }
main :: proc() {}
`, `package sample
E :: enum i64 { Last = 9223372036854775808 }
main :: proc() {}
`, `package sample
E :: enum i64 { First = -9223372036854775809 }
main :: proc() {}
`, `package sample
E :: enum u64 { First = -1 }
main :: proc() {}
`, `package sample
E :: enum u64 { Last = 18446744073709551615, Overflow }
main :: proc() {}
`}) {
		_, ok := check_procedure_source(t, transmute([]byte)source, diagnostic_count = 0, type_diagnostic_count = 1)
		testing.expect(t, ok)
	}
}

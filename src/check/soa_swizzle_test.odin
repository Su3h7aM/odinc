package check

import "core:testing"

// Selectors over an array-element #soa gather the named lanes. Every direct
// form the runtime suite uses must check with no diagnostics.
@(test)
soa_array_element_swizzle_checks :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	fixed: #soa[3][4]u16
	fixed.x[1] = 1
	fixed.y[1] = 2
	fixed.z[1] = 3
	fixed.w[1] = 4
	plain: [2]u16 = fixed[1].xy
	permuted: [2]u16 = fixed[1].yx
	repeated: [2]u16 = fixed[1].xx
	three: [3]u16 = fixed[1].xyz
	four: [4]u16 = fixed[1].xyzw
	reversed: [4]u16 = fixed[1].wzyx
	i := 1
	runtime_index: [2]u16 = fixed[i].xy
	fixed[1].xy = [2]u16{10, 11}
	fixed[1].yx = [2]u16{20, 21}
	fixed[1].xy += [2]u16{9, 10}
	fixed[1].xx += [2]u16{5, 100}
	fixed[1].xy = fixed[1].yx
	_, _, _, _, _, _, _ = plain, permuted, repeated, three, four, reversed, runtime_index
	sum: u16
	for c in fixed[1].wz {
		sum += c
	}
	s := fixed[:]
	slice_read: [2]u16 = s[0].zw
	s[0].zw = [2]u16{50, 51}
	_ = slice_read
}
read_dynamic :: proc "contextless" (dyn: #soa[dynamic][4]u16) {
	pair: [2]u16 = dyn[0].xy
	dyn[1].xy = [2]u16{40, 41}
	_ = pair
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

// Rules the swizzle shares with plain arrays still reject: mixed xyzw/rgba
// kinds, lanes past the element length, names past four letters, and the
// address of a multi-lane swizzle. Struct elements keep field selection, so a
// lane name there is an undeclared field.
@(test)
soa_array_element_swizzle_rejects :: proc(t: ^testing.T) {
	cases := []struct {
		name:   string,
		source: string,
		reason: string,
	} {
		{
			"mixture",
			`package sample
main :: proc "contextless" () { fixed: #soa[3][4]u16; _ = fixed[1].xry }
`,
			"Mixture of swizzle kinds for field index, got fixed[1]",
		},
		{
			"out_of_bounds",
			`package sample
main :: proc "contextless" () { two: #soa[2][2]u16; _ = two[0].wz }
`,
			"Swizzle value is out of bounds, got w, max count 2",
		},
		{"too_long", `package sample
main :: proc "contextless" () { fixed: #soa[3][4]u16; _ = fixed[1].xyzwx }
`, ""},
		{
			"address",
			`package sample
main :: proc "contextless" () { fixed: #soa[3][4]u16; _ = &fixed[1].xy }
`,
			"Cannot take the pointer address of 'fixed[1].xy' which is a swizzle intermediate array value",
		},
		{"struct_element", `package sample
Vec :: struct { x, y: u16 }
main :: proc "contextless" () { s: #soa[2]Vec; _ = s[0].xy }
`, ""},
	}
	for entry in cases {
		_, ok := check_procedure_source(
			t,
			transmute([]byte)entry.source,
			expected_kind = .Invalid_Operand if entry.name != "too_long" && entry.name != "struct_element" else .Undeclared_Name,
			expected_reason = entry.reason,
			diagnostic_count = 1,
		)
		if !ok { testing.expectf(t, false, "%s failed", entry.name) }
	}
}

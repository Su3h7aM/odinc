package check

import "core:testing"

@(test)
array_selectors_check_lane_types_and_writable_storage :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	value: [4]u8
	pointer := &value
	x: u8 = value.x
	y: u8 = value.y
	z: u8 = pointer.z
	w: u8 = pointer.w
	r: u8 = value.r
	g: u8 = value.g
	b: u8 = pointer.b
	a: u8 = pointer.a
	lanes: [2]u8 = value.yx
	four: [4]u8 = pointer.abgr
	value.xy = lanes
	pointer.ba = lanes
	value.xx = lanes
	value.x = 1
	address := &pointer.r
	nested: [2]u8 = value.wzy.yx
	Named :: distinct [4]u8
	named: Named
	same: Named = named.wzyx
	hinted: Named = value.abgr
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if ok { testing.expect(t, procedure.body_state == .Complete) }

	cases := []struct {
		source, reason: string,
	} {
		{`package sample
main :: proc "contextless" () { value: [4]u8; _ = value.xr }
`, "Mixture of swizzle kinds for field index, got value"},
		{`package sample
main :: proc "contextless" () { value: [2]u8; _ = value.xz }
`, "Swizzle value is out of bounds, got z, max count 2"},
		{
			`package sample
main :: proc "contextless" () { value: [4]u8; _ = &value.xy }
`,
			"Cannot take the pointer address of 'value.xy' which is a swizzle intermediate array value",
		},
	}
	for invalid in cases {
		rejected_procedure, rejected_ok := check_procedure_source(t, transmute([]byte)invalid.source, .Invalid_Operand, invalid.reason, 1)
		if rejected_ok { testing.expect(t, rejected_procedure.body_state == .Invalid) }
	}
	_, rejected := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
make_value :: proc "contextless" () -> [4]u8 { return {} }
main :: proc "contextless" () { make_value().xy = [2]u8{} }
`,
		),
		.Message,
		"Cannot assign to 'make_value().xy'",
		1,
	)
	testing.expect(t, rejected)
}

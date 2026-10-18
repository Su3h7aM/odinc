package check

import "core:testing"

@(test)
numeric_builtin_types_f16_and_complex_declare :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	half: f16
	pair: complex64
	quad: quaternion64
	unsigned_16_little: u16le
	unsigned_32_little: u32le
	unsigned_64_little: u64le
	unsigned_128_little: u128le
	signed_16_little: i16le
	signed_32_little: i32le
	signed_64_little: i64le
	signed_128_little: i128le
	unsigned_16_big: u16be
	unsigned_32_big: u32be
	unsigned_64_big: u64be
	unsigned_128_big: u128be
	signed_16_big: i16be
	signed_32_big: i32be
	signed_64_big: i64be
	signed_128_big: i128be
	return 0
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

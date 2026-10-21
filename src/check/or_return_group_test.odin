package check

import "core:testing"

// Official accepts a multi-value `or_return` as the tuple arguments of a procedure group member and of a concrete call.
@(test)
or_return_multi_value_expands_into_group_and_concrete_calls :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Major :: enum { Unsigned, Negative }
Encode_Data_Error :: enum { None, Int_Too_Big }
_i128_to_uint :: proc "contextless" (v: i128) -> (u: u64, m: Major, err: Encode_Data_Error) {
	return u64(v), .Unsigned, nil
}
_encode_u64 :: proc "contextless" (w: int, v: u64, major: Major = .Unsigned) -> int { return int(v) }
_encode_u32 :: proc "contextless" (w: int, v: u32, major: Major = .Unsigned) -> int { return 32 }
_encode_uint :: proc {
	_encode_u64,
	_encode_u32,
}
grouped :: proc "contextless" (e: int, i: i128) -> (r: int, err: Encode_Data_Error) {
	r = _encode_uint(e, _i128_to_uint(i) or_return)
	return
}
concrete :: proc "contextless" (e: int, i: i128) -> (r: int, err: Encode_Data_Error) {
	r = _encode_u64(e, _i128_to_uint(i) or_return)
	return
}
main :: proc "contextless" () {
	_, _ = grouped(0, 5)
	_, _ = concrete(0, 5)
}
`,
	)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

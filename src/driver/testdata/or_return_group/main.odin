package main

import "core:fmt"

Major :: enum {
	Unsigned,
	Negative,
}
Encode_Data_Error :: enum {
	None,
	Int_Too_Big,
}

_i128_to_uint :: proc(v: i128) -> (u: u64, m: Major, err: Encode_Data_Error) {
	if v > i128(max(u64)) { return 0, .Unsigned, .Int_Too_Big }
	return u64(v), .Unsigned, nil
}
_int_to_uint :: proc {
	_i128_to_uint,
}
_encode_u64 :: proc(w: int, v: u64, major: Major = .Unsigned) -> int { return int(v) + 1000 * int(major) }
_encode_u32 :: proc(w: int, v: u32, major: Major = .Unsigned) -> int { return 32 }
_encode_uint :: proc {
	_encode_u64,
	_encode_u32,
}

grouped :: proc(e: int, i: i128) -> (r: int, err: Encode_Data_Error) {
	r = _encode_uint(e, _int_to_uint(i) or_return)
	return
}

concrete :: proc(e: int, i: i128) -> (r: int, err: Encode_Data_Error) {
	r = _encode_u64(e, _i128_to_uint(i) or_return)
	return
}

main :: proc() {
	r, err := grouped(0, 5)
	fmt.println("group", r, err)
	r, err = grouped(0, 1 << 70)
	fmt.println("group_overflow", r, err)
	r, err = concrete(0, 5)
	fmt.println("concrete", r, err)
	r, err = concrete(0, 1 << 70)
	fmt.println("concrete_overflow", r, err)
}

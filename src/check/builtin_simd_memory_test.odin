package check

import "core:testing"

@(test)
simd_memory_operations_validate_addresses_masks_and_result_modes :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
load :: proc(p: ^i32, v: #simd[4]i32, m: #simd[4]bool) -> #simd[4]i32 { return simd_masked_load(p, v, m) }
store :: proc(p: rawptr, v: #simd[4]i32, m: #simd[4]u8) { simd_masked_store(p, v, m) }
expand :: proc(p: rawptr, v: #simd[4]i32, m: #simd[4]bool) -> #simd[4]i32 { return simd_masked_expand_load(p, v, m) }
compress :: proc(p: rawptr, v: #simd[4]i32, m: #simd[4]bool) { simd_masked_compress_store(p, v, m) }
gather :: proc(p: #simd[4]rawptr, v: #simd[4]i32, m: #simd[4]bool) -> #simd[4]i32 { return simd_gather(p, v, m) }
scatter :: proc(p: #simd[4]rawptr, v: #simd[4]i32, m: #simd[4]bool) { simd_scatter(p, v, m) }
bad_mask :: proc(p: rawptr, v: #simd[4]i32, m: #simd[2]bool) { simd_masked_store(p, v, m) }
bad_address :: proc(p: int, v: #simd[4]i32, m: #simd[4]bool) { simd_masked_load(p, v, m) }
bad_store_result :: proc(p: rawptr, v: #simd[4]i32, m: #simd[4]bool) -> #simd[4]i32 { return simd_masked_store(p, v, m) }
`,
	)
	names := []string{"simd_masked_load", "simd_masked_store", "simd_masked_expand_load", "simd_masked_compress_store", "simd_gather", "simd_scatter"}
	for name, index in ([?]string{"load", "store", "expand", "compress", "gather", "scatter", "bad_mask", "bad_address", "bad_store_result"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = names)
		if ok { testing.expect(t, (procedure.body_state == .Complete) == (index < 6)) }
	}
}

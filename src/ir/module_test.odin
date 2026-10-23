package ir

import "core:slice"
import "core:testing"

@(test)
blob_merge_is_deterministic_and_merges_only_equal_blobs :: proc(t: ^testing.T) {
	hello := transmute([]byte)string("hello")
	zeros := []byte{0, 0, 0, 0, 0, 0, 0, 0}
	expected_global_of_blob := [][]u32{{1, 1, 2}, {1, 3, 2, 4}}

	merged: [2]Module
	merged_symbols: [2][][]Symbol_Ref
	addresses: [2]Node_Id
	for &module, run in merged {
		init_err := module_init(&module)
		testing.expect(t, init_err == nil, "module_init failed")
		append(&module.globals, Global{name = "target"})

		function_0, make_err_0 := function_make(context.allocator, 0, "f0", 0)
		function_1, make_err_1 := function_make(context.allocator, 1, "f1", 0)
		testing.expect(t, make_err_0 == nil && make_err_1 == nil, "function_make failed")
		append(&module.functions, function_0, function_1)

		append(
			&function_0.blobs,
			Data_Blob{bytes = hello, align = 1},
			Data_Blob{bytes = hello, align = 1},
			Data_Blob{bytes = zeros, align = 8, relocs = {{target = {.Global, 0}}}},
		)
		append(
			&function_1.blobs,
			Data_Blob{bytes = hello, align = 1},
			Data_Blob{bytes = zeros, align = 8, relocs = {{target = {.Global, 0}, addend = 8}}},
			Data_Blob{bytes = zeros, align = 8, relocs = {{target = {.Global, 0}}}},
			Data_Blob{bytes = zeros, align = 8, relocs = {{target = {.Local_Blob, 0}}}},
		)
		addresses[run] = symbol_addr(function_0, Symbol_Ref{space = .Local_Blob, index = 0})

		symbols, err := blob_merge(&module)
		testing.expect(t, err == nil, "blob_merge failed")
		merged_symbols[run] = symbols
	}
	defer module_destroy(&merged[0])
	defer module_destroy(&merged[1])

	testing.expect_value(t, merged[0].functions[0].nodes.data[addresses[0]].symbol, Symbol_Ref{.Global, 1})
	testing.expect_value(t, len(merged[0].functions[0].blobs), 0)
	for blobs, function_index in merged_symbols[0] {
		for symbol, blob_index in blobs {
			testing.expect_value(t, symbol.space, Symbol_Space.Global)
			testing.expect_value(t, symbol.index, expected_global_of_blob[function_index][blob_index])
		}
	}
	testing.expect_value(t, len(merged[0].globals), 5)
	testing.expect_value(t, merged[0].globals[4].relocs[0].target, Symbol_Ref{.Global, 1})

	testing.expect_value(t, len(merged[1].globals), len(merged[0].globals))
	for global, index in merged[0].globals {
		other := merged[1].globals[index]
		testing.expect(t, global.size == other.size && global.align == other.align, "global size or align differs")
		testing.expect(t, slice.equal(global.bytes, other.bytes), "global bytes differ")
		testing.expect(t, slice.equal(global.relocs, other.relocs), "global relocs differ")
	}
	for blobs, function_index in merged_symbols[0] {
		testing.expect(t, slice.equal(blobs, merged_symbols[1][function_index]), "symbols differ")
	}
}

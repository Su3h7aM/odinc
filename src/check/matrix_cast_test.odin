package check

import "core:testing"
import "oc:types"

@(test)
matrix_casts_follow_element_count_and_square_rules :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	f32_type := types.intern(&store, types.Type{kind = .Float, count = 4})
	f64_type := types.intern(&store, types.Type{kind = .Float, count = 8})
	i32_type := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	complex_type := types.intern(&store, types.Type{kind = .Complex, count = 8})
	mat2 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 2, upper_bound = 2})
	mat3 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 3, upper_bound = 3})
	mat4 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 4, upper_bound = 4})
	mat2x4 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 2, upper_bound = 4})
	mat4x2 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 4, upper_bound = 2})
	mat1x4 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 1, upper_bound = 4})
	rmat2x4 := types.intern(&store, types.Type{kind = .Matrix, elem = f32_type, count = 2, upper_bound = 4, row_major = true})
	mat2f64 := types.intern(&store, types.Type{kind = .Matrix, elem = f64_type, count = 2, upper_bound = 2})
	mat4x2f64 := types.intern(&store, types.Type{kind = .Matrix, elem = f64_type, count = 4, upper_bound = 2})
	mat2i := types.intern(&store, types.Type{kind = .Matrix, elem = i32_type, count = 2, upper_bound = 2})
	mat2c := types.intern(&store, types.Type{kind = .Matrix, elem = complex_type, count = 2, upper_bound = 2})
	named_mat2 := types.reserve_nominal(&store, .Named, "Mat2")
	named_mat4 := types.reserve_nominal(&store, .Named, "Mat4")
	types.complete_nominal(&store, named_mat2, types.Type{kind = .Named, name = "Mat2", elem = mat2})
	types.complete_nominal(&store, named_mat4, types.Type{kind = .Named, name = "Mat4", elem = mat4})
	config := Conversion_Config {
		uintptr = word,
		layout  = types.DEFAULT_LAYOUT,
	}
	source := Operand(Expression_Ref{view = 1, node = 2})
	entries := []struct {
		source, target: types.Type_Id,
		ok:             bool,
	} {
		{mat2, mat4, true},
		{mat4, mat2, true},
		{mat2, mat3, true},
		{mat2x4, mat4x2, true},
		{mat1x4, mat2, true},
		{rmat2x4, mat4x2, true},
		{mat2, mat2f64, true},
		{mat2x4, mat4x2f64, true},
		{mat2, mat2i, true},
		{mat2i, mat2, true},
		{mat2, mat2c, true},
		{named_mat2, named_mat4, true},
		{mat2, mat1x4, false},
		{mat2x4, mat2, false},
		{mat2x4, mat3, false},
		{mat2, mat4x2, false},
		{mat2c, mat2, false},
		{mat2c, mat2f64, false},
	}
	for entry in entries {
		info := Expression_Info {
			type  = entry.source,
			mode  = .Value,
			state = .Checked,
		}
		converted, diagnostic, err := check_conversion(&pool, &store, source, info, entry.target, .Cast, config)
		if !testing.expect(t, err == nil) { continue }
		if !testing.expectf(t, (diagnostic == .None) == entry.ok, "%v -> %v: %v", entry.source, entry.target, diagnostic) { continue }
		if entry.ok {
			testing.expect(t, converted.info.type == entry.target && converted.info.mode == .Value && converted.plan.kind == .Cast)
		}
	}
}

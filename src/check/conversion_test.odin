package check

import "core:testing"
import "oc:types"

@(test)
conversions_preserve_identity_range_and_source :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	unsigned := types.intern(&store, types.Type{kind = .Integer, count = 8})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = byte_type})
	config := Conversion_Config {
		uintptr = word,
		layout  = types.DEFAULT_LAYOUT,
	}
	literal, literal_error := literal_constant(&pool, .Integer, "256")
	if !testing.expect(t, literal_error == nil) { return }
	info := Expression_Info {
		type     = types.TYPE_UNTYPED_INTEGER,
		constant = literal,
		mode     = .Constant,
		state    = .Checked,
	}
	value := Operand(Expression_Ref{view = 1, node = 2})
	_, diagnostic, err := check_conversion(&pool, &store, value, info, byte_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Representable)
	converted: Conversion_Result
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, integer, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Constant)
	testing.expect(t, converted.plan.source == value && converted.plan.target == integer && info.type == types.TYPE_UNTYPED_INTEGER)
	info = Expression_Info {
		type  = integer,
		mode  = .Variable,
		state = .Checked,
	}
	_, diagnostic, err = check_conversion(&pool, &store, value, info, byte_type, .Assignment, config)
	testing.expect(t, err == nil && diagnostic == .Not_Assignable)
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, byte_type, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.info.mode == .Value)
	_, diagnostic, err = check_conversion(&pool, &store, value, info, byte_type, .Transmute, config)
	testing.expect(t, err == nil && diagnostic == .Size_Mismatch)
	info.type = unsigned
	_, diagnostic, err = check_conversion(&pool, &store, value, info, pointer, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .Not_Castable)
	info.type = word
	converted, diagnostic, err = check_conversion(&pool, &store, value, info, pointer, .Cast, config)
	testing.expect(t, err == nil && diagnostic == .None && converted.plan.source == value)
	info.type = types.TYPE_UNTYPED_INTEGER
	_, diagnostic, err = check_conversion(&pool, &store, value, info, integer, .Transmute, config)
	testing.expect(t, err == nil && diagnostic == .Untyped_Transmute)
}

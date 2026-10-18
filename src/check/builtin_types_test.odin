package check

import "core:testing"
import "oc:types"

@(test)
builtin_integers_of_equal_size_stay_distinct :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	builtins := seed_builtin_types(&store)
	testing.expect(t, builtins.int != builtins.i64 && builtins.uint != builtins.u64 && builtins.uintptr != builtins.u64)
	testing.expect(t, types.sized_integer(&store, 8, true) == builtins.i64 && types.sized_integer(&store, 8, false) == builtins.u64)
	testing.expect(t, record_type_name(&store, builtins.int, context.allocator) == "int" && record_type_name(&store, builtins.i64, context.allocator) == "i64")
	testing.expect(t, record_type_name(&store, builtins.rune, context.allocator) == "rune")
}

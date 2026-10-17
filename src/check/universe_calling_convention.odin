package check

import "core:math/big"
import "oc:types"

// Member order of the official `ProcCC` enumeration, as checker.cpp registers `Odin_Calling_Convention`.
@(private = "file")
calling_convention_names := [?]string {
	"Invalid",
	"Odin",
	"Contextless",
	"CDecl",
	"Std_Call",
	"Fast_Call",
	"None",
	"Naked",
	"_",
	"Win64",
	"SysV",
	"PreserveNone",
	"PreserveMost",
	"PreserveAll",
}

// The official default on the Linux x86-64 target is `Odin`.
@(private = "file")
DEFAULT_CALLING_CONVENTION :: 1

// Publishes the `Odin_Calling_Convention` enum and `ODIN_DEFAULT_CALLING_CONVENTION`, which the runtime reads through `type_of`.
bind_universe_calling_convention :: proc(checker: ^Type_Checker, universe: Scope_Id, pool: ^Constant_Pool) -> bool {
	names := calling_convention_names
	members, members_error := make([]Enum_Member, len(names), checker.arena_allocator)
	if members_error != nil { return false }
	for name, index in names {
		members[index] = Enum_Member {
			name  = name,
			value = i64(index),
		}
	}
	backing := types.intern(checker.store, types.Type{kind = .Integer, count = 1, signed = false})
	enum_type := types.intern(
		checker.store,
		types.Type {
			kind = .Enum,
			name = "Odin_Calling_Convention",
			backing = backing,
			count = i64(len(names)),
			lower_bound = 0,
			upper_bound = i64(len(names) - 1),
		},
	)
	_, stored, inserted, map_error := map_entry(&checker.enum_members, enum_type)
	if map_error != nil { return false }
	if inserted { stored^ = members }
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, i64(DEFAULT_CALLING_CONVENTION)); set_error != nil { return false }
	constant, constant_error := constant_pool_intern_integer(pool, &value, enum_type)
	if constant_error != nil { return false }
	return publish_universe_constant(checker, universe, "ODIN_DEFAULT_CALLING_CONVENTION", enum_type, constant)
}

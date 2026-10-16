package ir

import "core:reflect"
import "core:strings"
import "core:testing"

@(test)
kind_info_rules_hold_for_every_kind :: proc(t: ^testing.T) {
	for kind in Node_Kind {
		info := kind_info[kind]

		lowercase_name := strings.to_lower(reflect.enum_string(kind), context.temp_allocator)
		testing.expectf(t, lowercase_name == info.name, "%v: name %q", kind, info.name)
		testing.expectf(t, info.min_inputs <= info.max_inputs, "%v: arity range", kind)
		testing.expectf(t, info.result != {}, "%v: empty result set", kind)
		testing.expectf(t, (.Tuple in info.result) == (info.tuple != .None), "%v: tuple shape", kind)
		testing.expectf(t, int(info.member_count) <= MAX_TUPLE_PREFIX, "%v: member count", kind)

		if info.max_inputs == INPUTS_UNBOUNDED {
			testing.expectf(t, info.tail != {}, "%v: variadic without tail", kind)
		} else {
			for slot in 0 ..< int(info.max_inputs) {
				testing.expectf(t, input_types(kind, slot) != {}, "%v: slot %d has no types", kind, slot)
			}
		}

		if is_pinned(kind) {
			testing.expectf(t, input_types(kind, 0) == {.Control}, "%v: pinned needs control in slot 0", kind)
		}
		if is_pure(kind) {
			testing.expectf(t, .Control not_in input_types(kind, 0), "%v: pure has control input", kind)
		}
		if .Commutative in info.flags {
			testing.expectf(t, info.min_inputs == 2 && info.max_inputs == 2, "%v: commutative needs two inputs", kind)
		}
	}
}

package driver

import "core:testing"

@(test)
range_over_pointer_to_container_exits_with_value :: proc(t: ^testing.T) {
	expect_exit(t, "range_container_pointer", 42)
}

@(test)
type_name_as_value_operand_exits_with_value :: proc(t: ^testing.T) {
	expect_exit(t, "typeid_value_operand", 42)
}

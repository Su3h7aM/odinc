package main

import "core:fmt"
import "core:reflect"

Vector3 :: struct {
	x, y, z: int,
}
Tagged :: struct {
	x: int `json:"x"`,
	y: int,
}

main :: proc() {
	fmt.printf("%q\n", reflect.struct_field_tags(Tagged))
	fmt.printf("%q\n", reflect.struct_field_tags(struct {
				x, y: int "shared:\"yes\"",
			}))
	first: struct {
		x: int `first`,
	}
	second: struct {
		x: int `second`,
	}
	fmt.println(typeid_of(type_of(first)) == typeid_of(type_of(second)))
	fmt.println(typeid_of(bit_set[0 ..= 8;u16]), typeid_of(bit_set[0 ..= 8]))
	fixed: #soa[2]Vector3
	fixed[0] = {1, 4, 9}
	fixed[1] = {2, 3, 4}
	fmt.println(fixed)
	fmt.println(fixed[:])
	dynamic_values := make(#soa[dynamic]Vector3, 2)
	defer delete_soa(dynamic_values)
	dynamic_values[0] = {1, 4, 9}
	dynamic_values[1] = {2, 3, 4}
	fmt.println(dynamic_values)
}

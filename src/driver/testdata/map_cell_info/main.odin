package main

import "base:intrinsics"

Name :: distinct string
Byte_Value :: distinct u8
Big :: struct {
	data: [80]u8,
}
Zero :: struct {}

main :: proc "contextless" () {
	code := 0
	name := intrinsics.type_map_cell_info(Name)
	if name.size_of_type == 16 && name.align_of_type == 8 && name.size_of_cell == 64 && name.elements_per_cell == 4 { code += 1 }
	value := intrinsics.type_map_cell_info(Byte_Value)
	if value.size_of_type == 1 && value.size_of_cell == 64 && value.elements_per_cell == 64 { code += 2 }
	big := intrinsics.type_map_cell_info(Big)
	if big.size_of_type == 80 && big.size_of_cell == 128 && big.elements_per_cell == 1 { code += 4 }
	zero := intrinsics.type_map_cell_info(Zero)
	if zero.size_of_type == 0 && zero.size_of_cell == 0 && zero.elements_per_cell == 1 { code += 8 }
	intrinsics.syscall(60, uintptr(code))
}

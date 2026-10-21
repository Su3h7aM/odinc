#+feature dynamic-literals
package main

import "base:intrinsics"
import "base:runtime"

Color :: enum {
	Red,
	Green,
	Blue,
}

Point :: struct {
	x, y: int,
}

empty_global: map[string]int

check_rtti_only :: proc(m: map[string]int) -> int {
	info := type_info_of(map[string]int).variant.(runtime.Type_Info_Map)
	if info.map_info == nil { return 1 }
	if len(m) != 1 || m["a"] != 12 { return 2 }
	return 0
}

literal_in_call :: proc() -> int {
	m := map[string]int {
		"a" = 1,
	}
	return m["a"]
}

main :: proc() {
	code := 0

	strings := map[string]int {
		"a" = 12,
	}
	if len(strings) != 1 || strings["a"] != 12 { code += 1 }
	if type_info_of(map[string]int).variant.(runtime.Type_Info_Map).map_info == nil { code += 2 }

	duplicates := map[int]string {
		1 = "one",
		2 = "two",
		2 = "TWO",
	}
	if len(duplicates) != 2 || duplicates[2] != "TWO" { code += 4 }

	colors := map[Color]int {
		.Red  = 1,
		.Blue = 3,
	}
	if len(colors) != 2 || colors[.Red] + colors[.Blue] != 4 { code += 8 }

	points := map[Point]int {
		{1, 2} = 5,
		{3, 4} = 6,
	}
	if len(points) != 2 || points[{1, 2}] != 5 { code += 16 }
	sum := 0
	for _, value in points { sum += value }
	if sum != 11 { code += 32 }

	struct_values := map[string]Point {
		"p" = {7, 8},
	}
	if len(struct_values) != 1 || struct_values["p"] != {7, 8} { code += 64 }

	array_values := map[string][2]u8 {
		"k" = {9, 10},
	}
	if len(array_values) != 1 || array_values["k"] != {9, 10} { code += 128 }

	nothing := map[string]int{}
	if len(nothing) != 0 { code += 256 }

	erased_key, erased_value := delete_key(&strings, "a")
	if erased_key != "a" || erased_value != 12 || len(strings) != 0 { code += 512 }

	zero: map[int]int
	if len(zero) != 0 || zero[3] != 0 { code += 1024 }

	if len(empty_global) != 0 { code += 2048 }
	if literal_in_call() != 1 { code += 4096 }
	if check_rtti_only(map[string]int{"a" = 12}) != 0 { code += 8192 }
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"
import "core:fmt"
import "core:reflect"

Default :: enum {
	Zero,
	One,
	Two,
}
Small :: enum u8 {
	Low  = 2,
	High = 19,
}
Wide :: enum i64 {
	Neg = -3,
	Pos = 70000,
}
Huge :: enum u64 {
	Last = ~u64(0),
}

main :: proc() {
	code := 0
	one := Default.One
	default_any: any = Default.Two
	small_any: any = Small.High
	wide_any: any = Wide.Neg
	huge_any: any = Huge.Last

	fmt.println(reflect.enum_string(Default.One))
	fmt.println(reflect.enum_string(one))
	fmt.println(reflect.enum_string(default_any))
	fmt.println(reflect.enum_string(Small.High))
	fmt.println(reflect.enum_string(small_any))
	fmt.println(reflect.enum_string(Wide.Neg))
	fmt.println(reflect.enum_string(wide_any))
	fmt.println(reflect.enum_string(Huge.Last))
	fmt.println(reflect.enum_string(huge_any))

	from_default, ok_default := reflect.enum_from_name(Default, "Zero")
	fmt.println(ok_default)
	fmt.println(reflect.enum_string(from_default))
	from_small, ok_small := reflect.enum_from_name(Small, "Low")
	fmt.println(ok_small)
	fmt.println(reflect.enum_string(from_small))
	from_wide, ok_wide := reflect.enum_from_name(Wide, "Pos")
	fmt.println(ok_wide)
	fmt.println(reflect.enum_string(from_wide))
	from_huge, ok_huge := reflect.enum_from_name(Huge, "Last")
	fmt.println(ok_huge)
	fmt.println(reflect.enum_string(from_huge))

	name_default, ok_name_default := reflect.enum_name_from_value(Default.Two)
	fmt.println(ok_name_default)
	fmt.println(name_default)
	name_small, ok_name_small := reflect.enum_name_from_value(Small.Low)
	fmt.println(ok_name_small)
	fmt.println(name_small)
	name_wide, ok_name_wide := reflect.enum_name_from_value(Wide.Pos)
	fmt.println(ok_name_wide)
	fmt.println(name_wide)
	name_huge, ok_name_huge := reflect.enum_name_from_value(Huge.Last)
	fmt.println(ok_name_huge)
	fmt.println(name_huge)

	if reflect.enum_string(Default.One) != "One" { code += 1 }
	if reflect.enum_string(one) != "One" { code += 1 }
	if reflect.enum_string(default_any) != "Two" { code += 1 }
	if reflect.enum_string(Small.High) != "High" { code += 1 }
	if reflect.enum_string(small_any) != "High" { code += 1 }
	if reflect.enum_string(Wide.Neg) != "Neg" { code += 1 }
	if reflect.enum_string(wide_any) != "Neg" { code += 1 }
	if reflect.enum_string(Huge.Last) != "Last" { code += 1 }
	if reflect.enum_string(huge_any) != "Last" { code += 1 }
	if !ok_default || from_default != .Zero { code += 1 }
	if !ok_small || from_small != .Low { code += 1 }
	if !ok_wide || from_wide != .Pos { code += 1 }
	if !ok_huge || from_huge != .Last { code += 1 }
	if !ok_name_default || name_default != "Two" { code += 1 }
	if !ok_name_small || name_small != "Low" { code += 1 }
	if !ok_name_wide || name_wide != "Pos" { code += 1 }
	if !ok_name_huge || name_huge != "Last" { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

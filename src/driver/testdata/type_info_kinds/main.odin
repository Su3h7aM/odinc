package main

import "base:intrinsics"
import "base:runtime"

main :: proc() {
	code := 0
	complex_info := type_info_of(complex64)
	code += complex_info.size + complex_info.align
	#partial switch _ in complex_info.variant {
	case runtime.Type_Info_Complex:
		code += 1
	}
	quaternion_info := type_info_of(quaternion128)
	code += quaternion_info.size + quaternion_info.align
	#partial switch _ in quaternion_info.variant {
	case runtime.Type_Info_Quaternion:
		code += 2
	}
	value: complex64
	boxed := any{&value, typeid_of(complex64)}
	code += type_info_of(boxed.id).size
	intrinsics.syscall(60, uintptr(code))
}

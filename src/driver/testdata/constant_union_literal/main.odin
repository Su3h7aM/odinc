package main

import "base:intrinsics"

Rune_Info :: struct {}

Other_Info :: struct {
	size: int,
}

Info :: struct {
	variant: Variant,
	boxed:   any,
}

Variant :: union {
	Rune_Info,
	Other_Info,
}

main :: proc() {
	info := Info {
		variant = Rune_Info{},
		boxed   = 42,
	}
	code := 0
	_, variant_ok := info.variant.(Rune_Info)
	value, value_ok := info.boxed.(int)
	if variant_ok && value_ok && value == 42 { code = 42 }
	intrinsics.syscall(60, uintptr(code))
}

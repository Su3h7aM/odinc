package sample

import "base:intrinsics"

Rune_Info :: struct {}

Value :: union {
	int,
	string,
	Rune_Info,
}

Holder :: struct {
	variant: Value,
	boxed:   any,
}

make_holder :: proc(v: Value, b: any) -> Holder {
	return Holder{variant = v, boxed = b}
}

main :: proc() {
	code := 0
	value: Value = 5
	text: Value = "x"
	rune_value: Value = Rune_Info{}
	boxed: any = 9

	_, ok := value.(Rune_Info)
	if ok { code += 1 }
	number, ok2 := value.(int)
	if !ok2 || number != 5 { code += 2 }
	_, ok3 := rune_value.(Rune_Info)
	if !ok3 { code += 4 }
	flag: bool
	_, flag = text.(int)
	if flag { code += 8 }
	_, flag = text.(string)
	if !flag { code += 16 }
	_, ok4 := boxed.(int)
	if !ok4 { code += 32 }
	_, ok5 := make_holder(text, boxed).variant.(string)
	if !ok5 { code += 64 }
	h := make_holder(value, boxed)
	if n, ok6 := h.boxed.(int); !ok6 || n != 9 { code += 128 }
	intrinsics.syscall(60, uintptr(code))
}

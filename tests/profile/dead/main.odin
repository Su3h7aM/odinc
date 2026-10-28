package main
import "core:fmt"
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
unused :: proc() { _ = puts("hello") }
main :: proc() {
	when ODIN_NO_CRT { fmt.println("NO_CRT") } else { fmt.println("MANAGED") }
}

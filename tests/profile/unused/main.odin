package main
import "core:fmt"
foreign import c "system:c"
foreign c { puts :: proc "c" (s: cstring) -> i32 --- }
main :: proc() {
	when ODIN_NO_CRT { fmt.println("NO_CRT") } else { fmt.println("MANAGED") }
}

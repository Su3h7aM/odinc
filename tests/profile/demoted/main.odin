package main
import "core:fmt"
foreign import c "system:c"
foreign c { strlen :: proc "c" (s: cstring) -> u64 --- }
value :: [1]u64{strlen("hello")}
main :: proc() {
	fmt.println(value[0])
	when ODIN_NO_CRT { fmt.println("NO_CRT") } else { fmt.println("MANAGED") }
}

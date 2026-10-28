package main
import "core:fmt"
foreign import c "system:c"
foreign c { strlen :: proc "c" (s: cstring) -> u64 --- }
unused_alias :: strlen
main :: proc() {
	when ODIN_NO_CRT { fmt.println("NO_CRT") } else { fmt.println("MANAGED") }
}

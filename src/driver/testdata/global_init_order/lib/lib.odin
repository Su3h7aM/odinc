package lib

x := helper()
base := 3

helper :: proc "contextless" () -> int { return base * 2 }

ticks: int

tick :: proc "contextless" () -> int {
	ticks += 1
	return ticks
}

lib_stamp := tick()

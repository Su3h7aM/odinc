package main

import "core:fmt"

FLAG :: #config(FLAG, false)
COUNT :: #config(COUNT, 2)
RATIO :: #config(RATIO, 0.5)
NAME :: #config(NAME, "default")
NEGATIVE :: #config(NEGATIVE, 0)
MASK :: #config(MASK, 1)
LENGTH :: #config(LENGTH, 3)
MISSING :: #config(MISSING, 7)

Level :: enum {
	Low = #config(LOW, 1),
	High,
}

Buffer :: [LENGTH]int

main :: proc() {
	buffer: Buffer
	fmt.println(FLAG, COUNT, RATIO, NAME, NEGATIVE, MASK, MISSING, len(buffer), Level.High, int(Level.High))
	when FLAG {
		fmt.println("flag on")
	} else {
		fmt.println("flag off")
	}
}

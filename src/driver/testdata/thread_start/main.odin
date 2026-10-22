package main

import "core:fmt"
import "core:thread"
import "core:time"

@(thread_local)
worker_value: int

@(thread_local)
worker_zero: int

worker :: proc(t: ^thread.Thread) {
	assert(worker_value == 0 && worker_zero == 0)
	worker_value = 37
	assert(worker_value == 37)
	worker_value = t.user_index
	worker_zero = t.user_index + 1
	for i in 1 ..= 3 {
		assert(worker_value == t.user_index && worker_zero == t.user_index + 1)
		fmt.printf("Thread %d iteration %d\n", t.user_index, i)
		time.sleep(1 * time.Millisecond)
	}
}

main :: proc() {
	threads := make([dynamic]^thread.Thread, 0, 3)
	defer delete(threads)
	for _ in 0 ..< 3 {
		if t := thread.create(worker); t != nil {
			t.user_index = len(threads)
			append(&threads, t)
			thread.start(t)
		}
	}
	for len(threads) > 0 {
		for i := 0; i < len(threads); {
			if t := threads[i]; thread.is_done(t) {
				fmt.printf("Thread %d done\n", t.user_index)
				thread.destroy(t)
				ordered_remove(&threads, i)
			} else {
				i += 1
			}
		}
		time.sleep(1 * time.Millisecond)
	}
}

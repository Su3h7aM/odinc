package main

import "core:sync"
import "core:thread"

trace: [64]int
trace_count: int

record :: proc(value: int) {
	trace[trace_count] = value
	trace_count += 1
}

@(deferred_in = record)
capture_input :: proc(value: int) {  }

@(deferred_out = record)
capture_output :: proc(value: int) -> int { return value + 10 }

record_pair :: proc(input, output: int) {
	record(input)
	record(output)
}

@(deferred_in_out = record_pair)
capture_both :: proc(value: int) -> int { return value + 20 }

record_none :: proc() { record(99) }

@(deferred_none = record_none)
capture_none :: proc() {  }

early_return :: proc() {
	capture_input(8)
	defer record(9)
	return
}

work :: proc(task: thread.Task) {
	completed := cast(^int)task.data
	sync.atomic_add(completed, 1)
}

main :: proc() {
	{
		value := 1
		capture_input(value)
		value = 7
		defer record(value)
		_ = capture_output(2)
		_ = capture_both(3)
		capture_none()
	}
	early_return()
	for index in 0 ..< 4 {
		capture_input(index + 30)
		if index == 0 { continue }
		if index == 2 { break }
	}
	expected := [?]int{99, 3, 23, 12, 7, 1, 9, 8, 30, 31, 32}
	assert(trace_count == len(expected))
	for value, index in expected { assert(trace[index] == value) }

	mutex: sync.Mutex
	for _ in 0 ..< 2 {
		sync.guard(&mutex)
	}

	pool: thread.Pool
	completed: int
	thread.pool_init(&pool, context.allocator, 2)
	defer thread.pool_destroy(&pool)
	for index in 0 ..< 16 {
		thread.pool_add_task(&pool, context.allocator, work, &completed, index)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)
	assert(completed == 16)
	assert(thread.pool_num_done(&pool) == 16)
}

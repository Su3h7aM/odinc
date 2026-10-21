package main

events: [128]int
event_count: int

record :: proc(event: int) {
	events[event_count] = event
	event_count += 1
}

expect :: proc(expected: []int) {
	assert(event_count == len(expected))
	for event, index in expected { assert(events[index] == event) }
	event_count = 0
}

@(deferred_out = finish)
condition :: proc(event: int, result: bool) -> bool {
	record(event)
	return result
}

finish :: proc(result: bool) { record(100 if result else 200) }

early_return :: proc() {
	@(deferred_out = finish)
	local_condition :: proc() -> bool { record(1); return true }
	if local_condition() {
		record(2)
		return
	}
}

loop_return :: proc() {
	for condition(1, true) { record(2); return }
}

switch_return :: proc() {
	switch condition(1, true) {
	case true:
		record(2)
		return
	}
}

main :: proc() {
	@(deferred_out = local_finish)
	local_condition :: proc(result: bool) -> bool {
		record(1)
		return result
	}
	local_finish :: proc(result: bool) { record(100 if result else 200) }

	if local_condition(true) { record(2) }
	record(3)
	expect({1, 2, 100, 3})
	if local_condition(false) { record(2) }
	expect({1, 200})
	if local_condition(false) { record(2) } else { record(3) }
	record(4)
	expect({1, 3, 200, 4})
	if value := local_condition(true); value { record(2) }
	expect({1, 2, 100})
	if value := local_condition(false); condition(2, !value) { record(3) }
	expect({1, 2, 3, 100, 200})

	if condition(1, true) {
		if local_condition(false) { record(2) } else { record(3) }
		record(4)
	}
	expect({1, 1, 3, 200, 4, 100})
	early_return()
	expect({1, 2, 100})
	loop_return()
	expect({1, 2, 100})
	switch_return()
	expect({1, 2, 100})

	for index := 0; condition(1, index < 2); index += 1 { record(2) }
	record(3)
	expect({1, 2, 1, 2, 1, 200, 3})
	for condition(1, true) {
		record(2)
		break
	}
	expect({1, 2, 100})
	for index := 0; condition(1, index < 2); index += 1 {
		record(2)
		continue
	}
	expect({1, 2, 1, 2, 1, 200})
	for value := condition(1, true); value; {
		if local_condition(true) { break }
	}
	expect({1, 1, 100, 100})

	switch local_condition(true) {
	case true:
		record(2)
	}
	record(3)
	expect({1, 2, 100, 3})
	switch value := condition(1, false); condition(2, !value) {
	case true:
		record(3)
		break
	}
	expect({1, 2, 3, 100, 200})
}

package main

import "base:intrinsics"

main :: proc() {
	Slot :: struct($T: typeid) {
		value: T,
	}
	Table :: struct($T: typeid) {
		slots: [2]Slot(T),
	}
	Buffer :: struct($T: typeid, $N: int) where N > 1 {
		values: [N]T,
	}
	Number :: union($T: typeid) {
		T,
		string,
	}
	table: Table(int)
	table.slots[1].value = 17
	buffer: Buffer(int, 3)
	buffer.values[2] = 19
	number: Number(int) = 7
	value, ok := number.(int)
	result := table.slots[1].value + buffer.values[2] + value
	if !ok { result = 99 }
	intrinsics.syscall(60, uintptr(result))
}

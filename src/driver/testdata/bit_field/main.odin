package main

import "base:intrinsics"

Tagged :: bit_field u64 {
	pointer: i64 | 57,
	version: u8  | 7,
}

Flags :: bit_field u16 {
	low:    u8   | 4,
	signed: i8   | 4,
	ok:     bool | 1,
}

main :: proc "contextless" () {
	code := 0
	tagged := Tagged {
		pointer = -2,
		version = 5,
	}
	if tagged.pointer == -2 && tagged.version == 5 { code += 1 }
	tagged.version += 3
	tagged.pointer = 0x1234_5678_9abc
	if tagged.pointer == 0x1234_5678_9abc && tagged.version == 8 { code += 2 }
	raw := (^u64)(&tagged)^
	if raw == u64(0x1234_5678_9abc) | u64(8) << 57 { code += 4 }
	fresh := Tagged {
		version = 3,
	}
	if fresh.pointer == 0 && (^u64)(&fresh)^ == u64(3) << 57 { code += 8 }
	flags := Flags {
		low    = 9,
		signed = -3,
	}
	if flags.low == 9 && flags.signed == -3 && !flags.ok { code += 16 }
	flags.ok = true
	flags.low = 15
	if flags.ok && flags.low == 15 && flags.signed == -3 { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

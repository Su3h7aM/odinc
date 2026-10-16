// abi_matrix generates C-ABI signatures and compares the System V x86-64 plan of
// package types with what clang and the official Odin compiler emit for them.
//
//	abi_matrix emit <dir>      write <dir>/cases.c and <dir>/cases.odin
//	abi_matrix compare <dir>   read <dir>/clang.ll and <dir>/fork.ll/main.ll, print mismatches
package main

import "core:fmt"
import "core:os"
import "core:strings"
import types "oc:types"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: abi_matrix emit|compare <dir>")
		os.exit(2)
	}
	build_cases()
	directory := os.args[2]
	switch os.args[1] {
	case "emit":
		write(directory, "cases.c", emit_c())
		write(directory, "cases.odin", emit_odin())
	case "compare":
		compare(directory)
	case:
		fmt.eprintln("unknown mode", os.args[1])
		os.exit(2)
	}
}

write :: proc(directory, name, text: string) {
	path := fmt.tprintf("%s/%s", directory, name)
	if err := os.write_entire_file(path, text); err != nil {
		fmt.eprintln("cannot write", path, err)
		os.exit(1)
	}
}

read_module :: proc(path: string) -> Module {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path, err)
		os.exit(1)
	}
	return parse_module(string(data))
}

// Agreement is which of the three signatures are equal, as a short key.
agreement :: proc(ours, clang, fork: string) -> string {
	switch {
	case ours == clang && clang == fork:
		return "all agree"
	case clang == fork:
		return "clang == fork != ours"
	case ours == clang:
		return "ours == clang != fork"
	case ours == fork:
		return "ours == fork != clang"
	}
	return "all differ"
}

compare :: proc(directory: string) {
	clang := read_module(fmt.tprintf("%s/clang.ll", directory))
	fork := read_module(fmt.tprintf("%s/fork.ll/main.ll", directory))
	store := types.init()
	ids := build_store(&store)

	categories: map[string][dynamic]string
	clang_extensions, fork_extensions, our_extensions, small_results := 0, 0, 0, 0
	for _, index in signatures {
		name := function_name(index)
		ours, ours_extension, plan_err := plan_for(&store, ids, index)
		if plan_err != .None { ours = fmt.tprintf("<plan error %v>", plan_err) }
		clang_text, clang_extension, _ := signature_of(clang, name)
		fork_text, fork_extension, _ := signature_of(fork, name)
		if clang_extension { clang_extensions += 1 }
		if fork_extension { fork_extensions += 1 }
		if ours_extension { our_extensions += 1 }
		if clang_extension || fork_extension || ours_extension { small_results += 1 }

		key := agreement(ours, clang_text, fork_text)
		list := categories[key]
		append(&list, name)
		categories[key] = list
		if key == "all agree" { continue }
		fmt.printfln("%s", c_prototype(index))
		fmt.printfln("  ours : %s", ours)
		fmt.printfln("  clang: %s", clang_text)
		fmt.printfln("  fork : %s", fork_text)
	}

	fmt.printfln("\n%d signatures", len(signatures))
	for key, names in categories {
		fmt.printfln("%-24s %d", key, len(names))
		if key != "all agree" { fmt.printfln("  %s", strings.join(names[:], " ")) }
	}
	fmt.printfln("result extension attribute: clang %d, fork %d, ours %d (of %d with any)", clang_extensions, fork_extensions, our_extensions, small_results)
}

# Upstream bugs found

Three suspected bugs were checked against upstream Odin (`/home/su3h7am/Projects/refs/compilers_linkers/Odin-upstream`, master `f9f544ec4`, 2026-10-22), the official docs, the Linux man pages and the Intel SDM. All three are confirmed: the upstream source and a run of the official compiler show the behaviour, and the docs or the specification contradict it. The imm8-size half of suspicion 3 is not a bug and is listed at the end, with the other non-bugs, so nobody re-investigates it.

## 1. `#soa[]V{}` is typed as a plain `[]V`, not as `#soa[]V`

Minimal reproduction:

```odin
package main

V :: struct { a: int, b: f32 }

main :: proc() {
	values := #soa[]V{}
	_ = values.a
}
```

Expected: `values` has type `#soa[]V` and `values.a` selects the field slice, because `{}` is the zero value of any type and `#soa[]V` is a type. Actual (upstream master, and reproduced with `odin check`):

```
Error: 'values' of type '[]V' has no field 'a'
```

The explicit form is worse than mis-typed: `s: #soa[]V = #soa[]V{}` is rejected with `Cannot assign value '#soa[]V{}' of type '[]V' to '#soa[]V'`. `s: #soa[]V = {}` (contextual) and `w := #soa[dynamic]V{}` both work, and non-empty `#soa[]V{{1, 2}}` is rejected on purpose with `#soa slices are not supported for compound literals`, so only the explicit empty literal is affected.

Evidence:

- `src/check_expr.cpp:11717-11719` — in the `Ast_ArrayType` branch of `check_compound_literal`, when `ArrayType.count == nullptr` the type is unconditionally `alloc_type_slice(check_type(c, type_expr->ArrayType.elem))`; the `#soa` tag is never consulted.
- `src/check_expr.cpp:11720-11736` — the `#soa` handling is inside `if (cl->elems.count > 0)`, so it never runs for `{}`. `is_soa` (declared at `:11675`) is then dead for the empty case.
- By contrast `check_type` builds a real SoA type for the same syntax: `src/check_type.cpp:5024-5025` (`make_soa_struct_slice`) for `#soa[]T`, and `:4979-4980` for `#soa[N]T`.
- The tag was introduced for compound literals by `42ff71111` ("Fix #3515", gingerBill, 2024-07-01); that commit added the `count == nullptr` slice branch and wrapped the tag check in `cl->elems.count > 0`, which is where the empty case was lost.
- Docs, "Zero values" (https://odin-lang.org/docs/overview/#zero-values): "The expression `{}` can be used as the zero value of any type." Docs, "SOA struct slices and dynamic arrays" (https://odin-lang.org/docs/overview/#soa-struct-slices-and-dynamic-arrays): `#soa[]Vector3` is a slice type that supports `.x`/field selection.

Upstream report: none. Searched issues and PRs for "soa compound literal", "soa slice literal", "soa typed as slice", "soa empty literal" — the closest, #3515 (`Bad error message in SOA slice compound literals`, closed by `42ff71111`) and #5692 (`SOA compound literal issues`, closed by #7259), are about non-empty literals. #5419 (`Failed cpp assertion when passing empty slice into function that expects #soa slice`) was about contextual `{}`, which works now.

## 2. `core:os` `Process_State` cannot report termination by a signal, and its `success` doc contradicts the code

Minimal reproduction:

```odin
package main

import "core:fmt"
import "core:os"

run :: proc(script: string) {
	p, _ := os.process_start({command = {"/bin/sh", "-c", script}})
	state, _ := os.process_wait(p)
	fmt.printf("%-16q exited=%v exit_code=%d success=%v\n", script, state.exited, state.exit_code, state.success)
}

main :: proc() {
	run("exit 0")
	run("exit 4")
	run("kill -ILL $$") // SIGILL is 4
}
```

Expected: the state distinguishes a normal exit from a signal, and `success` means what its comment says. Actual (upstream master, reproduced):

```
"exit 0"         exited=true exit_code=0 success=true
"exit 4"         exited=true exit_code=4 success=false
"kill -ILL $$"   exited=true exit_code=4 success=false
```

Two defects, one of them a plain doc/code contradiction:

1. `exit 4` and death by `SIGILL` (signal 4) produce identical states, so no caller can tell a controlled failure from a crash. `waitid` hands upstream both facts and the code discards the one that distinguishes them.
2. The `success` comment says "whether the termination of the process was successful or not, i.e. whether it has crashed or not", but `success` is simply `exit_code == 0` (or `false` for any signal), so `exit 4` — which is not a crash — reports `success == false`.

Evidence:

- `core/os/process.odin:492-510` — `Process_State` has only `pid`, `exited`, `exit_code`, `success`, `system_time`, `user_time`. No signal field. The `exit_code` comment (`:497-500`) does say it "will also store the number of the exception or signal that has crashed the process", but nothing at run time separates the two readings.
- `core/os/process_linux.odin:664-676` (`_reap_terminated`) and `:753-765` (`_timed_wait_on_handle`) — for `.KILLED, .DUMPED, .TRAPPED` they set `exit_code = int(info.status)`, `success = false`, and drop `info.code`; the `.EXITED` branch sets `success = exit_code == 0`.
- `core/os/process_posix.odin:319-325` — same conflation on the other POSIX targets.
- `man 2 wait` (local copy `/home/su3h7am/Projects/refs/man-pages/man2/wait.2:302-323`): `si_status` is "Either the exit status of the child ... or the signal that caused the child to terminate", and "The `si_code` field can be used to determine how to interpret this field"; `WIFEXITED`/`WIFSIGNALED` and `WEXITSTATUS`/`WTERMSIG` are the pair to use. The Linux behaviour upstream relies on is correct; it is the API that loses the distinction.

Upstream report: open issue #7775, `os: Process_State cannot distinguish "exited with code N" from "killed by signal N", and its success doc does not match the implementation` (2026-10-06, no comments). Open PR #7914, `Add Process_State.signal` (2026-10-13, by wintermi, fixes #7775): adds `signal` on Linux and POSIX, fixes the `success` doc, adds a test; the author's question in the PR about also clearing `exit_code` on a signal is unanswered, so the shape of the fix is not settled.

## 3. `core:rexcode/isa/x86` encoder omits the `0x66` operand-size prefix for 16-bit memory operands

Minimal reproduction:

```odin
package main

import "core:fmt"
import x86 "core:rexcode/isa/x86"

main :: proc() {
	mem := x86.mem_make(x86.RBP, x86.RDX, 4, -0x54c, x86.NONE)
	code: [16]u8
	relocs: [dynamic]x86.Relocation
	errs: [dynamic]x86.Error
	inst := x86.inst_m_i(.MOV, mem, 2, 4, 2) // `mov word ptr [rbp + rdx*4 - 0x54c], 4`
	n, ok := x86.encode([]x86.Instruction{inst}, nil, code[:], &relocs, &errs)
	fmt.printf("ok=%v %x\n", ok, code[:n])
}
```

Expected (llvm-mc ground truth, `movw $4, -1356(%rbp,%rdx,4)`): `66 c7 84 95 b4 fa ff ff 04 00`. Actual (upstream master, reproduced): `c7 84 95 b4 fa ff ff 04 00`, no `66`. Disassembling those bytes gives `movl $4, -1356(%rbp,%rdx,4)` — a 32-bit store, not the 16-bit store requested. Same for `inc word ptr [...]` (`66 ff 84 ...` expected, `ff 84 ...` emitted), `mul m16` (`66 f7 ...`), `test m16, imm16` (`66 f7 ...`), and the other 16-bit memory forms.

The cause is that the prefix decision keys off registers only: `has_gpr16` is set solely when `uop.kind == .REGISTER` and the class is `REG_GPR16`, and it is the only thing (besides the operand-less `opsize_16` flag) that can request `66h`. A memory operand never satisfies that check, so every form whose operand list has a 16-bit memory slot and no 16-bit register uses the 32-bit operand size.

Evidence:

- `core/rexcode/isa/x86/encoder.odin:242` (`has_gpr16`), `:277-283` (set only for `.REGISTER` operands), `:305-308` (the MOVSX/MOVZX/MOVSXD widening exception, which is correct and unrelated), `:511-523` (`needs_66 := (has_gpr16 || enc.flags.opsize_16) && ...`).
- Scope in the encoding table: counts over `core/rexcode/isa/x86/tablegen/generated/encode_tables.odin` give 184 `.MR` forms whose first operand is `.RM16`/`.M16`; 122 of them have no 16-bit register operand to trigger the prefix (73 mnemonics: MOV, ADD, ADC, SUB, SBB, MUL, IMUL, DIV, IDIV, INC, DEC, NEG, CMP, AND, OR, XOR, NOT, TEST, SHL/SHR/SAR/SAL/ROL/ROR/RCL/RCR, BT/BTS/BTR/BTC, POP, PUSH, JMP, CALL, NOP, KMOVW, VPEXTRW, LGDT/…/VERW, and the x87 integer forms FILD/FIST/…). Forms that do carry a 16-bit register (`mov word [mem], ax`, `add ax, 4`) are already correct, which is why the existing tests miss it: `tests/test_narrow_widths.odin:103-105` is the only memory case and it is a widening move, correctly excluded.
- Intel SDM, ADD and the general 64-bit-mode rule (https://www.felixcloutier.com/x86/add): "In 64-bit mode, the instruction's default operation size is 32 bits", and `81 /0 iw`/`83 /0 ib` `ADD r/m16, imm16/imm8` require the 16-bit operand size, i.e. the `66` prefix. `mov r/m16, imm16` (`C7 /0 iw`) is the same.
- The package's own tests state their expected bytes are llvm-mc ground truth (`tests/test_narrow_widths.odin:19-21`, "Every expected byte string below is llvm-mc ground truth"), so the intent is byte-exact agreement with the SDM encodings.

Upstream report: none. Searched issues and PRs for "rexcode", "operand-size prefix", "encoder 66h", "x86 encoder prefix", "16-bit encoder", "mem16", "has_gpr16" — the only rexcode encoder issue is #7586 (wasm text output), and the encoder PRs since #6839 (`core:rexcode`) touch other areas. The nearest prior art is the narrow-width work that produced `test_narrow_widths.odin` and the `opsize_16` flag (CBW/CWD/MOVSW/…), which fixed the register and operand-less cases but not the memory-only ones.

## 4. The store/load reversal warning picks its reported site by heap address

The atomics analysis warns `'%s' is stored and then '%s' loaded, while the reverse is done at %s, so both loads may read what was there before` once per pair of locations. Which of the two directions is reported, and so which line the warning points at, is chosen by comparing the addresses of the two location entities in the compiler's heap.

Evidence:

- `src/check_atomics.cpp:728-748`: `check_atomic_store_load_cmp` orders the store/load pairs by `cast(uintptr)x->store->location` and then `cast(uintptr)x->load->location`, i.e. by `Entity *` value.
- `src/check_atomics.cpp:1753`: `if (cast(uintptr)x.store->location > cast(uintptr)x.load->location) continue;` drops one direction of each pair by the same pointer order, so the kept direction depends on allocation order.
- The final report sort (`check_atomic_report_cmp`, `:750-758`) orders by source position, but it runs after the direction was chosen and cannot restore a stable site.

Entity addresses depend on allocation order, which changes with the checker's parallel scheduling and the allocator, so the same program can report the warning at either site. The warning count is stable; only its position is not. This is from the source; a varying run was not observed.

Our compiler: the pair and its direction are ordered by the declaration's source position (file, offset), then the entity, and for struct fields the type and field index (`atomic_location_key` in `src/analysis/atomic_model.odin`). The report can therefore name the other site of the pair than a given upstream run.

Upstream report: not searched yet.

## Not bugs (recorded so nobody re-investigates)


- **`ADD`/`CMP` `m16, imm8` picking `81 /0 iw` over `83 /0 ib`** (`encoder.odin` form-match order, `encode_tables.odin:112` before `:115`, and the same for `CMP`): INTENDED. The SDM lists both `81 /0 iw` and `83 /0 ib` as valid `ADD r/m16, imm8` encodings, so the emitted bytes are architecturally correct, only 3 bytes longer than the shortest form. It is a code-size opportunity, not a wrong encoding; our compiler should prefer `83` but must not call upstream's output incorrect.
- **`Process_State.exit_code` holding the signal number**: INTENDED as documented (`core/os/process.odin:497-500` says so explicitly). Only the missing signal field and the `success` comment are wrong, as covered in section 2.

# Design of package `x64` and the first `link` stage

Status: draft 1. Scope: instruction selection, frame and call lowering, emission and relocations for Linux x86-64 (System V), process startup (ticket H8), and the minimal `link` package (stage 1 of `docs/research/08-linker-options.md`). Inputs are `docs/02-ir-design.md` (sections 4, 6, 12-15 and the open-question rulings), `src/regalloc/program.odin`, `src/types/abi_plan.odin`, `core/rexcode/isa/x86`, `src/elf`, and `docs/research/07`, `08`, `09`, `12`. The IR names (`Node_Kind`) are those of `src/ir/kinds.odin`.

`src/sched` does not exist yet. This document uses the interface of `docs/02-ir-design.md` section 12 (`Schedule { blocks: []Block }`, each `{head, nodes, preds, succs, depth, cold}`, with `Const_*`, `Undef`, `Symbol_Addr`, `Tls_Addr` marked `Rematerialize` and left unscheduled). The regalloc interface is the one in `src/regalloc/program.odin`; open questions 1 and 2 concern its gaps.

## 1. Prior art and what is reused

| Question | Finding | Consequence |
|---|---|---|
| Encoder in `core`? | `core/rexcode/isa/x86` (`encode`, `Instruction`, generic `inst_*` shape builders, about 7,500 typed `inst_<mnemonic>_<operands>` builders, labels, `Relocation`, `clobber_forms`). API summary: `core/rexcode/docs/x86_api.md` (the task named `docs/x86_api.md`; the file is in `core/rexcode/docs/`). | No encoder is written. Fixed sequences (prologue, startup, expansions) use the typed builders. The table-driven core uses the shape-generic builders (`inst_r_r`, `inst_r_m`, `inst_r_i`, `inst_m_r`, `inst_m_i`, `inst_rel`), because the operand width is data there and four typed builders per mnemonic would multiply the tables by four. |
| Operand read/write facts | `x86.clobber_forms(mnemonic)` gives per form the written and read operand sets, implicit registers, and flags. | The per-opcode operand-role table is generated from it, not typed by hand (section 4). A test checks that all forms of every mnemonic `x64` uses agree on the operand roles it takes from them. |
| ELF output | `src/elf`: `Builder` (ET_REL), `Executable_Builder` (ET_EXEC with `PT_LOAD` and `PT_GNU_STACK`), `R_X86_64` constants. | `link` writes the executable through `executable_add_segment`. Missing: `PT_TLS` and `R_X86_64_TPOFF32` (section 12, ticket H1 prerequisite). |
| Allocator | `src/regalloc`: `Program`, `Instruction`, `Operand`, `Result` (agent-279). | `x64` builds a `regalloc.Program` and applies the `Result`. |
| Lowering lessons | `docs/research/07` sections 3, 7, 8: stack-first/registers-second call setup, `AL` rule, explicit scratch contract, flag fusion, cold blocks last, table-driven ALU core instead of an 800-line switch, errors instead of asserts on user input. | Adopted as stated below. Rejected: always-frame without a reason (here the frame pointer is a stated contract), Win64-order spills, `R11` RIP normalization. |
| Startup | `docs/research/12` and the rulings: the compiler emits entry, TLS and stack-protector sequences. Reference behaviour: `base/runtime/entry_unix_no_crt_linux_amd64.asm`, `tls_linux_no_crt_amd64.asm`, `stack_protector_linux_no_crt_amd64.asm`. | `x64.startup` re-creates these three with `rexcode` builders (section 11). |
| Linker | `docs/research/08` stage 1: fused static non-PIE executable, small code model, fail loudly beyond ±2 GiB. | Section 12. |
| Official behaviour | The fork lowers through LLVM and has no code to copy. ABI reference: `llvm_abi.cpp` through `types.plan_abi`. Numerics: `docs/02-ir-design.md` section 8. | Every sequence below is checked against the interpreter and the fork's native output (section 15). |

## 2. Decisions

1. **Always framed.** Every function runs `push rbp; mov rbp, rsp`. Reason: `docs/research/09` stage 0 (`lldb bt`, `perf` call graphs), a fixed-shape `.eh_frame` entry, `Stack_Alloc` without a second base register. A frameless leaf mode is a later optimization.
2. **No red zone.** Generated code never uses memory below `rsp`.
3. **Narrow values have undefined upper bits.** `I8`, `I16`, `I32` values in a 64-bit register carry no promise about bits above their width, except that `Bool` is 0 or 1 in its low byte. An operation that depends on the upper bits (compare, shift right, divide, convert, store, return of an extended result) widens or uses the exact width itself. `Zext`/`Sext` nodes are explicit. Arithmetic on `I8`/`I16` (`Add Sub Mul And Or Xor Shl`) uses 32-bit forms.
4. **Callers extend arguments, callees extend results, nobody trusts either.** The caller extends a `Direct` piece with `ext` ≠ `None` to 32 bits (as clang does). The callee extends a result with `ext` ≠ `None` to 32 bits before `ret` (the plan carries the intended `ext`; the fork never attaches it, clang does: `docs/02-ir-design.md` section 6, "Known ABI differences"). A caller never reads upper bits of a result, and a callee never reads upper bits of a parameter, so both clang-built and fork-built code interoperate.
5. **Stage order.** `select` (ideal nodes in schedule order → machine instructions on virtual registers, all control expansion done) → `verify_machine` → `regalloc.allocate` → `emit` (apply locations, frame, spills, relaxation, encoding, relocations).
6. **Expansions that need control flow create blocks before liveness**; nothing creates blocks after allocation. Where a branch-free sequence exists it is preferred (this removes float `Select` from the control expansions listed in `docs/02-ir-design.md` section 12: it moves through a general register and uses `cmov`).
7. **Scratch registers are not allocatable**: `r10`, `r11`, `xmm14`, `xmm15`. They serve spill reloads, memory-to-memory moves, `Syscall` argument 4, and cycle breaking (section 6).
8. **Errors are values.** `select` returns `Select_Error{node, kind}` for unsupported or malformed input (`Unsupported_Node`, `Unsupported_Alignment`, `Unsupported_Signature`, `Out_Of_Memory`); no assert fires on user input.
9. **The IR is not changed.** Mismatches with `src/ir/module.odin` or the IR document are listed in section 16 and are not patched here.

## 3. Package layout and data

`src/x64` (imports `oc:ir`, `oc:sched`, `oc:regalloc`, `oc:types` for `Abi_Piece`/`Abi_Plan` only if the driver passes plans, `oc:link` for the output types, `core:rexcode/isa/x86`):

| File | Content |
|---|---|
| `machine.odin` | `Machine_Function`, `Machine_Block`, `Machine_Instruction`, operand types, register tables, printer |
| `op_info.odin` | per-mnemonic operand roles and constraints; generation of `regalloc.Program` |
| `abi.odin` | register and stack assignment of pieces (F1) |
| `select.odin`, `select_int.odin`, `select_float.odin`, `select_memory.odin`, `select_control.odin` | one procedure per node group |
| `frame.odin` | frame layout, prologue, epilogue |
| `emit.odin` | applying `regalloc.Result`, relaxation, encoding, relocation collection |
| `startup.odin` | `_start`, `_odin_linux_tls_layout`, `__stack_chk_fail` |
| `verify.odin` | `verify_machine` |

```odin
Machine_Operand :: union { Vreg, Physical, Immediate, Memory_Ref, Block_Ref, Symbol_Ref_Offset }
Memory_Ref :: struct { base: Memory_Base, index: Vreg, has_index: bool, scale: u8, displacement: i32, segment_fs: bool }
Memory_Base :: union { Vreg, Frame_Object, Rip_Symbol }       // Frame_Object: slot, spill, incoming argument, outgoing argument
Machine_Instruction :: struct {
	mnemonic: x86.Mnemonic, width: u8, operand_count: u8, operands: [4]Machine_Operand,
	pseudo: Pseudo, condition: Condition, location: u32,       // location: index into the function's debug table, 0 = none
}
Pseudo :: enum u8 { None, Call, Return, Copy, Parallel_Copy, Syscall, Jump_Table, Tls_Address, Spill_Probe }
```

`Physical` names a fixed machine register inside a fixed-register sequence. `Pseudo` instructions expand in `emit`. `Copy` is a `regalloc` `is_move` (class-matching `mov`/`movaps`).

**Register numbering** (the `regalloc.Register` number is the hardware number; `x86.gpr64_from_num` / `x86.xmm_from_num` convert):

| Set | Int bank | Float bank |
|---|---|---|
| allocatable | `rax rcx rdx rbx rsi rdi r8 r9 r12 r13 r14 r15` (0,1,2,3,6,7,8,9,12,13,14,15) | `xmm0`-`xmm13` |
| scratch (reserved) | `r10 r11` | `xmm14 xmm15` |
| never | `rsp rbp` | – |
| callee-saved | `rbx r12 r13 r14 r15` | none |
| call clobbers | `rax rcx rdx rsi rdi r8 r9` | `xmm0`-`xmm13` |

`x64.build_program(machine_function) -> regalloc.Program` fills `blocks` (instructions with operand lists from `op_info`), `classes`, `allocatable`, `callee_saved`; `depth` comes from `sched`. Edge copies are `Block.edge_moves`.

## 4. Operand constraint generation

`op_info(mnemonic, form) -> Operand_Info [4]{role, position, constraint, memory_ok, immediate_ok}` plus `implicit_uses`, `implicit_defs`, `clobbers`, `writes_flags`. The roles come from `x86.clobber_forms` (`written`, `read`, `implicit_wr`, `implicit_rd`); the table adds what the encoder metadata cannot say:

| Rule | Constraint produced |
|---|---|
| Two-address ALU (`add sub and or xor imul shl sar cmov*`, SSE `addsd`…`sqrtsd` when destructive, `neg not inc`) | destination `Use_Def`; selection gives it a fresh vreg with `Reuse_Input` on the first source (`Operand.reuse` = index of the source use). A source with later uses is therefore copied by the allocator. |
| Non-destructive forms (`lea`, `movzx`, `movsx`, `mov`, 3-operand `imul`, `cvt*`) | `Def` at `Late`, no reuse. |
| Source that may be memory | `memory_ok`: if its vreg is spilled, `emit` uses the slot as the memory operand. At most one such operand per instruction. |
| Shifts by a variable | count: `Use`, `Fixed rcx`. |
| `div idiv` | dividend `rax`, remainder/high `rdx`: `Fixed` uses at `Early`; quotient `rax` and remainder `rdx`: `Fixed` defs at `Late`; divisor `Any`, which cannot share `rax`/`rdx` because they are live at its position. |
| `mul` / one-operand `imul` | `rax` `Use_Def` fixed, `rdx` `Def` fixed, source `Any`. |
| `cmpxchg` | `rax` `Use_Def` fixed (expected in, old out), new value `Use`, address `Use`. |
| `cpuid xgetbv rdtsc` | the architectural registers as `Fixed` defs/uses; `cpuid` also defines `rbx`, which makes it a callee-saved register used by the function. |
| `rep movsb` / `rep stosb` | `rsi rdi rcx` (and `al` for `stosb`) `Use_Def` fixed. |
| `setcc`, sequences that write a result before reading all sources | the result `Def` is at `Early` so it cannot share a register with a source. |
| `call` | `is_call`, `clobbers` = the call-clobber set; argument vregs `Use` with `Fixed` at the argument register; results `Def` with `Fixed`; the `AL` count is a `Fixed rax` use. |
| `syscall` | uses `rax rdi rsi rdx r8 r9` (fixed), defines `rax`, clobbers `rcx r11` and flags. Argument 4 is an `Any` use that `emit` moves to `r10` immediately before the instruction. |

Flags are not a register class. `select` emits a compare and its single consumer (`jcc`, `setcc`, `cmovcc`) adjacent in one machine block; `verify_machine` rejects any instruction that writes flags between them. Constants materialized with `xor r, r` are therefore always created before the compare.

## 5. Instruction selection

Selection walks each `sched` block in order, greedily and top-down on use counts, and produces machine instructions with fresh vregs for non-folded values. Every node result that is not a pure `Rematerialize` node gets one vreg: class `Int` for `Bool I8..I64 Ptr`, `Float` for `F16 F32 F64 V128`. A rematerialized node is created at each use.

**Folding rules** (all of them also applied by the verifier's matcher test): (a) a single-use `Load` folds into the consumer's memory operand only if no pinned node lies between them in the final order (`docs/02-ir-design.md` section 12) and the load is `Plain`; (b) `Ptr_Offset`/`Ptr_Index` chains and `Stack_Slot`/`Symbol_Addr` bases fold into one `[base + index*scale + disp32]`, scale ∈ {1,2,4,8}, otherwise a `shl`/`imul` first; (c) `Const_Int` folds as `imm32` (sign-extended; 8-bit form when it fits) if the form takes an immediate, otherwise it is materialized (below); (d) a compare whose only user is the block's `If`, a `Select` or a single `Zext` fuses with its consumer; (e) `Zext`/`Sext` of a single-use `Load` becomes `movzx`/`movsx`/`movsxd` from memory.

**Materialization of constants and addresses** (each use, `Rematerialize`):

| Node | Sequence |
|---|---|
| `Const_Int` 0 | `xor r32, r32` (flags dead by construction) |
| `Const_Int` in `0..2^32-1`, `Bool` | `mov r32, imm32` |
| `Const_Int` in `-2^31..-1` (64-bit) | `mov r64, simm32` |
| other 64-bit | `movabs r64, imm64` |
| `Const_Float` 0.0 | `xorps x, x` |
| other `F32`/`F64` | `movss`/`movsd x, [rip + pool]`, pool entry in `.rodata` (deduplicated by bits and width, in first-use order, 4-byte or 8-byte aligned; relocation `R_X86_64_PC32`) |
| `Const_Float` `F16` | `mov r32, bits` then `movd x, r32` |
| `Undef` | no instruction: a fresh vreg with no def (the verifier allows exactly this) |
| `Symbol_Addr` | `lea r, [rip + sym]` (`R_X86_64_PC32`, addend −4); folded into memory operands when used as a base |
| `Tls_Addr` | `mov r, fs:[0]`, then `lea r, [r + tpoff]` with `R_X86_64_TPOFF32` on the `lea` displacement; later `mov r, fs:[tpoff]` folds loads and stores (section 9) |
| `Stack_Slot` | folded into memory operands as `Frame_Object`; stand-alone `lea r, [rbp - offset]` |

**Integer and bit operations** (`w` is the node width; `*` marks a 32-bit form used for `I8`/`I16`):

| IR kind | Machine sequence | Constraints |
|---|---|---|
| `Add` | I32/I64 with two registers or register + `imm32`: `lea r, [a + b]` / `[a + imm]`; otherwise `add d, s` | `lea`: `Def`, no reuse; `add`: reuse of the first source |
| `Sub And Or Xor` | `op d, s` (`s` register, memory, or `imm`) | reuse of the first source; `Xor`/`And`/`Or` on `Bool` use the 32-bit form |
| `Mul` | `imul d, s` or `imul d, s, imm32` | reuse (2-operand form) |
| `Shl Shr Sar`, count constant `< w` | `shl/shr/sar d, imm8` | reuse |
| `Shl Shr`, other count | zero-extend the count to 32 or 64 bits (its own width); `shl/shr d, cl`; `cmp c, w; sbb t, t; and d, t` (`t = -1` iff `c < w`) | `c` fixed `rcx`; `t` fresh, early def |
| `Sar`, other count | zero-extend the count; `mov t, w-1; cmp c, t; cmova c, t`; `sar d, cl` | `c` fixed `rcx` |
| `Shr`/`Sar` on `I8`/`I16` | `movzx`/`movsx` of the operand to 32 bits first | – |
| `SDiv SRem` | `I64`: `mov rax, a; cqo; idiv b`; `I32`: `cdq`; `I8`/`I16`: `movsx` both to 32 bits, then the 32-bit form. Result `rax` (quotient) or `rdx` (remainder) copied out | fixed `rax`/`rdx` (section 4) |
| `UDiv URem` | as above with `xor edx, edx; div b`, `movzx` for narrow widths | same |
| `Eq Ne SLt SLe ULt ULe` | `cmp a, b` (width `w`; memory or immediate for `b`) → flags; consumers: `jcc` / `setcc` + `movzx` / `cmovcc` | conditions `e ne l le b be`; `>` and `>=` were swapped by canonicalization |
| `Select` (int) | `mov d, b; test c, c; cmovne d, a` (or fused compare); `I8`/`I16` use 32-bit `cmov` | `d` reuse of `b` |
| `Trunc` | none (a `Copy`); to `Bool`: `and r32, 1` | – |
| `Zext` | `movzx r32, r8/r16`; `I32→I64`: `mov r32, r32`; `Bool→I*`: `movzx r32, r8` | – |
| `Sext` | `movsx r32/r64, r8/r16`; `movsxd r64, r32` | – |
| `Popcnt` | SWAR on the zero-extended 32 or 64-bit value, straight line (`shr`/`and`/`sub`/`add`/`imul` by `0x0101..`), no `popcnt` instruction | fresh temporaries |
| `Clz` | `mov t, -1; bsr r, x; cmovz r, t; neg r; add r, w-1` (the value is `w` for 0), narrow widths on the zero-extended 32-bit value with `w` adjusted | `r` early def |
| `Ctz` | `mov t, w; bsf r, x; cmovz r, t` | `r` early def |
| `Bswap` | `bswap r32/r64`; `I16`: `rol r16, 8` | reuse |
| `Mul_Hi_U` / `Mul_Hi_S` | `mov rax, a; mul b` / `imul b`; result `rdx` | section 4 |
| `Ptr_Offset Ptr_Index` | folded; stand-alone `lea r, [base + index*scale + disp]` | – |
| `Bitcast` | same bank: `Copy`; `I32↔F32`: `movd`; `I64↔F64`: `movq`; `I16↔F16`: `movd` on the zero-extended value | – |

**Floating point** (`F32` uses the `ss` forms, `F64` the `sd` forms):

| IR kind | Machine sequence |
|---|---|
| `FAdd FSub FMul FDiv` | `addss/subss/mulss/divss d, s` (memory or register source), reuse of the first source |
| `FNeg` | `xorps d, [rip + sign_mask]` (16-byte pool entry, `0x80000000` or `0x8000000000000000` in the low lane) |
| `FSqrt` | `sqrtss/sqrtsd d, s` (`Def`, no reuse) |
| `FLt a<b`, `FLe a<=b` | `ucomis b, a`; conditions `a` (above) and `ae`; NaN gives CF=1, so false |
| `FEq` | `ucomis a, b; sete t1; setnp t2; and t1, t2`, then `movzx` |
| `FNe` | `ucomis a, b; setne t1; setp t2; or t1, t2`, then `movzx` |
| `Select` (float) | `movd/movq` both float operands to general registers, `cmov`, move back. Branch-free; no block is created |
| `Sint_To_Float` | `cvtsi2ss/sd x, r32/r64` after `xorps x, x` (dependency break); `I8`/`I16` are sign-extended to 32 bits first |
| `Uint_To_Float` | `U8..U32`: zero-extend, then `cvtsi2*` with `r64`. `U64`: blocks `entry: test r, r; js big`, `small: cvtsi2* x, r; jmp done`, `big: mov t, r; shr t, 1; mov u, r; and u, 1; or t, u; cvtsi2* x, t; add* x, x`, `done` (phi of `x`) |
| `Float_To_Sint` | `cvtts*2si r32/r64, x` (`I8`/`I16` through `r32`); out-of-range gives the hardware "integer indefinite" value; the fork's `fptosi` is poison there, so no source-visible behaviour is promised (to confirm against the fork's output) |
| `Float_To_Uint` | `U8..U32`: `cvtts*2si r64` and truncate. `U64`: blocks comparing with `2^63` (`ucomis` against a pool constant), subtracting it, converting, and `xor`ing the top bit back |
| `Float_Ext` / `Float_Trunc` | `F32↔F64`: `cvtss2sd` / `cvtsd2ss`. `F16` ends: call to the runtime software routine (ticket H5); the symbols come from the driver (`Config.runtime_f16_to_f32`, `runtime_f32_to_f16`, section 16) |

**Memory** (loads use the exact width into a fresh register; narrow results are zero-extended by `movzx` so no partial-register write occurs):

| IR kind | Machine sequence |
|---|---|
| `Load I8/I16` | `movzx r32, byte/word [m]` |
| `Load I32 / I64 / Ptr` | `mov r32/r64, [m]` |
| `Load F32 / F64` | `movss` / `movsd x, [m]` |
| `Load F16` | `pxor x, x; pinsrw x, word [m], 0` |
| `Load V128` | `movups x, [m]` |
| `Store` | `mov [m], r8/r16/r32/r64`; immediate: `mov m32, imm32`, `mov m64, simm32`, wider constants through a register; `movss/movsd/movups [m], x`; `F16`: `pextrw r32, x, 0; mov word [m], r16` |
| `Mem_Copy` constant size ≤ 128 | load all chunks into fresh `Float` vregs (`movups` 16 bytes, then 8, 4, 2, 1 through general registers; the tail overlaps the previous chunk when size ≥ 16), then store all: `memmove` semantics, no overlap hazard |
| `Mem_Copy` other | blocks: `cmp rdi, rsi; jbe forward`; `backward: lea rsi,[rsi+rcx-1]; lea rdi,[rdi+rcx-1]; std; rep movsb; cld; jmp done`; `forward: rep movsb`. `rsi rdi rcx` fixed |
| `Mem_Set` constant size ≤ 128 | stores of the byte broadcast to 8 bytes (`imul r, 0x0101010101010101` when the byte is not constant), overlapping tail |
| `Mem_Set` other | `rep stosb` (`rdi`, `rcx`, `al` fixed) |
| `Stack_Alloc` | `sub rsp, round_up(size, 16)`; realign for `data.index` > 16 (`and rsp, -a`); result `lea r, [rsp + outgoing_size]` (the block lies above the outgoing area; old outgoing contents are dead). Addresses of frame objects stay `rbp`-relative |

Atomic and ordered nodes follow `docs/02-ir-design.md` section 4 and are ticket H2:

| IR kind | Machine sequence |
|---|---|
| `Load_Ordered` | `mov` (any order); volatile: same, never folded, never removed |
| `Store` `Seq_Cst` | `xchg [m], r` (result register unused); other atomic or volatile orders: `mov` |
| `Atomic_Rmw` add/sub with the old value | `lock xadd [m], r` (sub: `neg` the value first); xchg: `xchg [m], r` |
| `Atomic_Rmw` add/sub/and/or/xor without the old value | `lock add/sub/and/or/xor [m], r` |
| `Atomic_Rmw` and/or/xor/nand with the old value | loop in blocks: `mov rax, [m]`; `loop: mov t, rax; op t, v; (not t for nand); lock cmpxchg [m], t; jne loop` (`rax` fixed, result `rax`) |
| `Atomic_Cas` | `mov rax, expected; lock cmpxchg [m], desired; sete flag`; old value in `rax`; widths 1, 2, 4, 8; 16 is `Unsupported_Node` |
| `Fence` | `Seq_Cst` thread fence: `mfence`; others and all signal fences: no instruction, but a compiler barrier (the node stays in the order) |

**Control** (`select_control.odin`, ticket F5):

| IR kind | Machine sequence |
|---|---|
| block heads | one `Machine_Block` per `sched` block, in `sched` order (entry first, `Cold` blocks last); `Region`/`Loop` heads need no instruction |
| `If` | `jcc taken; jmp other` with the fall-through successor omitted at layout time; a `Cold` projection is placed in the cold tail, so the branch to it is a forward `jcc` |
| `Switch` | ≤ 3 cases: compare chain. Else if `max − min + 1 ≤ 4 × cases`: bias and range check (`sub`, `cmp`, `ja default`), `lea t, [rip + table]`, `movsxd u, dword [t + idx*4]`, `add u, t`, `jmp u`; table in `.rodata`, entries `R_X86_64_PC32` against the function symbol with addend `label_offset + 4*i`. Else a sorted binary search of compares |
| `Phi` | parallel copies at the end of each predecessor (an edge block exists for every edge by the no-critical-edge rule); the copies are `Block.edge_moves` |
| `Return` | results to `rax rdx xmm0 xmm1` through `Fixed` copies; callee extension (decision 4); `Struct_Return`: `rax` = the incoming `rdi` pointer; then the epilogue and `ret` (duplicated per return; at most about ten instructions) |
| `Trap`, `Unreachable` | `ud2` |
| `Call` | section 7 |
| `Syscall` | six `Fixed` copies (`rax rdi rsi rdx r8 r9`), argument 4 for `r10`, `syscall`, result `rax` |
| `Target_Op` | `Cpuid`: `eax`, `ecx` in; `cpuid`; `eax ebx ecx edx` out. `Xgetbv`: `ecx` in, `eax edx` out. `Pause`: `pause`. `Rdtsc`: `rdtsc; shl rdx, 32; or rax, rdx` |

A bounds-check failure is not special to `x64`: the IR contains an `If` whose `Cold` projection leads to a handler `Call` and `Unreachable`. The cold tail therefore holds argument setup, `call handler`, `ud2`. Cold blocks are not merged in v0.

## 6. Applying the allocation (`emit`)

`regalloc.Result` gives one `Location` (register or spill slot) per vreg and `inserted_moves` positioned by block and instruction. `emit` goes through each block:

1. Apply `inserted_moves` that precede the instruction: register to register `mov` (`movaps` for `Float`), register to or from a slot `mov [rbp - off], r` / `movsd`/`movups`, slot to slot through `r11` or `xmm15`. Cycle breaking is the allocator's (E3); a remaining swap uses `xchg` (general) or `xmm15` (float).
2. Operands in registers are used directly. An operand in a spill slot is used as a memory operand if `op_info.memory_ok` allows (the encoder takes `Mem64` etc. in the same builder shape); otherwise it is loaded into `r10`/`r11` (`xmm14`/`xmm15`) first, and a spilled `Def` is stored back after the instruction. An address with a spilled base and index and a spilled stored value is collapsed with `lea r10, [r10 + r11*s + d]` so that two scratch registers always suffice.
3. Encode into `[]x86.Instruction`. Branch targets are labels (section 8).

`select` guarantees that at most two vregs of one instruction need registers at the same time after memory folding; `verify_machine` enforces it.

## 7. Calls and ABI (F1)

**Assignment** reproduces LLVM's `CC_X86_64_C` over the `ir.Signature` pieces (the pieces already carry the fork's decisions; `x64` assigns sequentially, as `docs/02-ir-design.md` section 6 requires):

| Piece | Placement |
|---|---|
| `I8..I64`, `Bool`, `Ptr`, `Direct` | next of `rdi rsi rdx rcx r8 r9`, else the next 8-byte stack slot |
| `F16 F32 F64`, `V128` | next of `xmm0`-`xmm7`, else the next stack slot (8 bytes; `V128`: 16 bytes, 16-aligned) |
| `Direct` piece with `align = 16` (low half of an `i128`) | register if one is free, else a stack slot aligned to 16; its partner follows sequentially. The straddle case is reproduced, not corrected |
| `Indirect` | an `Int` register or slot holding the address; no copy by `x64` |
| `By_Value` | no register; the object is copied into the outgoing area at the next stack offset aligned to `max(8, align)`, size rounded to 8 |
| `Struct_Return` | first `Int` register (`rdi`) |
| `Context` | an ordinary `Int` piece, last in the list |
| Result pieces | `Int`: `rax`, `rdx`; `Float`: `xmm0`, `xmm1`; a piece pair mixes by class (`rax` and `xmm0`, in that order) |

**Caller sequence** for `Call` (a `Pseudo.Call` plus fixed copies, so the allocator sees all constraints): stack arguments are stored first into `[rsp + offset]` (floats through `xmm14`, general values directly or through `r11`; `By_Value` objects use the `Mem_Copy` sequences with `rsi`/`rdi`/`rcx` only when larger than 128 bytes); register arguments are `Fixed`-constrained copies; for a variadic signature `eax` receives the number of `xmm` registers used (`Fixed rax` use); `call rel32` to a function or extern symbol (`R_X86_64_PLT32`, addend −4, resolved at link time to the final address) or `call r`/`call [m]` for an indirect callee (the callee vreg `Any`); then results are `Fixed` defs copied to fresh vregs. `rsp` is 16-aligned at every `call` because the frame is (section 8). The outgoing area is `max` over all calls of the stack argument bytes, rounded to 16, reserved once in the frame; nothing is pushed.

**Callee side** (`Start`): incoming `Direct` pieces are `Fixed` defs at the entry (copied out of the argument registers immediately, so their vregs can live elsewhere); stack pieces are `Frame_Object` incoming arguments at `[rbp + 16 + offset]` (loaded on use); `By_Value` and `Indirect` parameters are the address of the incoming memory or the incoming pointer. Callee-side C variadics (`va_start` register save area) are `Unsupported_Signature` in v0; call-side variadics are supported (`AL` rule).

## 8. Frame, prologue and epilogue (F6)

```
high   [rbp + 16 + k]   incoming stack arguments (By_Value objects, spilled pieces)
       [rbp + 8]        return address
       [rbp]            saved rbp
       [rbp - 8 * n]    callee-saved registers actually used (pushed in order rbx r12 r13 r14 r15)
       ...              Stack_Slot objects (fixed offsets, descending, by node id, each aligned)
       ...              spill slots (8 bytes each, regalloc numbering)
       [rsp .. rsp+out) outgoing argument area
low    rsp              16-byte aligned
```

Prologue: `push rbp; mov rbp, rsp; push <used callee-saved>; sub rsp, F`, where `F` makes `rsp` 16-aligned (entry `rsp` ≡ 8 mod 16, so after `push rbp` it is aligned and each push adds 8). Epilogue: `lea rsp, [rbp - 8*n]; pop <reverse>; pop rbp; ret` (`mov rsp, rbp; pop rbp; ret` when `n = 0`). A frame of 4096 bytes or more probes each page in descending order (`or qword [rsp], 0`) before the final `sub`. `Stack_Slot` alignment above 16 is `Unsupported_Alignment` in v0 (open question 6). The frame is a pure function of the machine function and the allocation: object order is node-id order, then spill slot order, then the outgoing area.

**Unwind data** (`.eh_frame`, produced by `link` from per-function facts the emitter records): `Unwind_Info { code_start, code_size, push_rbp_end, set_rbp_end, saved: [](register, cfa_offset) }`. The shape is uniform: CFA = `rsp+8` at entry; after `push rbp` (`push_rbp_end`) CFA = `rsp+16`, `rbp` at CFA−16; after `mov rbp, rsp` (`set_rbp_end`) CFA = `rbp+16`; callee-saved registers at CFA−24, −32, …. Only call sites are described precisely (no asynchronous unwinding inside the epilogue). CIE as in `docs/research/07` section 4: version 1, `"zR"`, code alignment 1, data alignment −8, return address column 16, FDE encoding `pcrel|sdata4`.

## 9. TLS (local-exec) and `Tls_Addr`

The thread pointer `fs:0` holds its own address (the startup stub and `linux_no_crt_tls_init` write it). `Tls_Addr` for a `tls` global at TLS offset `s` (offset of the symbol from the start of the TLS segment) is `fs:0 + tpoff(s)` where, with `vaddr`, `memsz`, `align` from `PT_TLS`:

`tpoff(s) = s − (memsz + ((−vaddr − memsz) & (align − 1)))`

(the formula the runtime itself uses for `block_offset`: the `.alignment` block of `tls_linux_no_crt_amd64.asm`; it is negative or zero). `link` computes it; `x64` emits `lea r, [r + 0]` with a `R_X86_64_TPOFF32` relocation on the displacement, or, when the address is only used by one load or store, the folded form `mov r, fs:[disp32]` with the relocation on `disp32`. The encoder emits relocations only for labels, so these two forms are recorded by the emitter: it defines a label before and after the instruction, and for `lea` with no immediate or a segmented `mov` with no immediate the displacement is the last four bytes of the instruction (`end − 4`). The same rule holds for RIP-relative operands: **no RIP-relative operand is combined with an immediate**, so the `REL32` field is always the last four bytes and ELF addend = encoder addend − 4. `select` materializes the immediate in a register in that case; `verify_machine` checks it.

## 10. Relocations and the object seam

`x64` and the data emission produce `link.Input` (section 12). Relocation kinds, all from `elf.R_X86_64` plus one addition:

| Source | Field | ELF type | Addend |
|---|---|---|---|
| `call sym` | rel32 | `R_X86_64_PLT32` (4) | −4 |
| `lea r, [rip + sym]`, `[rip + sym + d]` memory operands, constant pool, jump-table base | rel32 | `R_X86_64_PC32` (2) | −4 + d |
| jump-table entry | 32-bit | `R_X86_64_PC32` against the function symbol | `label_offset + 4*i` |
| `Data_Reloc` in a global | 64-bit absolute | `R_X86_64_64` (1) | `reloc.addend` |
| `Tls_Addr` | disp32 | `R_X86_64_TPOFF32` (23, **not yet in `src/elf/types.odin`**) | 0 |
| absolute 32 (`mov r32, imm32` of an address) | – | not used: non-PIE would allow `R_X86_64_32S`, but RIP-relative keeps the output position-independent-ready | – |

Symbols: one `link.Symbol` per `ir.Function` (defined in `.text`, size = code size), per `Global` (section by kind), per `Extern` (undefined), plus startup symbols (section 11). `Local_Blob` ids never reach the object: the driver's `blob_merge` has already assigned each blob a `Global` (`src/ir/module.odin`), and `x64` maps `Symbol_Addr(Local_Blob)` through `blob_symbols[function][blob]`.

## 11. Process startup (H8)

`x64.startup` builds three fixed code sequences with typed `rexcode` builders (no encoder written) and defines them as symbols the runtime expects:

| Symbol | Behaviour (reference) |
|---|---|
| `_start` | `entry_unix_no_crt_linux_amd64.asm`: clear `rbp`, `cld`, read `argc`/`argv`, skip `envp`, scan auxv for `AT_PHDR`(3) `AT_PHENT`(4) `AT_PHNUM`(5) `AT_RANDOM`(25), seed `_odin_linux_stack_guard` from the 16 random bytes with the low byte cleared, find `PT_TLS` (7) in the program headers, call `_odin_linux_tls_layout`, `mmap` the TLS block, copy the `.tdata` image, store the thread pointer at `[tp]` and the guard at `[tp+0x28]`, `arch_prctl(ARCH_SET_FS)`, align the stack, call `_start_odin(argc, argv)`, `exit_group(127)` on any failure |
| `_odin_linux_tls_layout(phdr, out) -> bool` | `tls_linux_no_crt_amd64.asm`, same six-word layout |
| `__stack_chk_fail` | `stack_protector_linux_no_crt_amd64.asm`: write the message to fd 2 (retry on `EINTR`), `exit_group(134)`, string in `.rodata` |

The startup is a subset-first ticket: **H8a** (`_start` that loads `argc/argv`, calls the entry symbol and `exit_group`s with its result; no TLS) is enough for milestones M0/M1; **H8b** is the full sequence above (M2). The stubs are tested by running executables and by decoding the emitted bytes with `rexcode`'s decoder against the reference listing (one round-trip test per symbol). Undefined `_start_odin`, `_odin_linux_stack_guard` and `_odin_linux_tls_header` are ordinary runtime symbols resolved by name in `link`. No stack protector is inserted into generated code in v0 (`__stack_chk_fail` exists only because the runtime references it).

## 12. Package `link`, stage 1

Input types (the seam of `docs/research/08` stage 0; `x64` imports `link` for these types only):

```odin
Section_Kind :: enum u8 { Text, Rodata, Data, Bss, Tdata, Tbss }
Atom :: struct { section: Section_Kind, align: u32, bytes: []byte, size: u64, relocs: []Relocation, unwind: Unwind_Info, lines: []Line_Row }   // size > len(bytes) only for Bss/Tbss
Symbol :: struct { name: string, atom: u32, offset: u64, size: u64, binding: Binding, kind: Symbol_Kind }   // atom = ATOM_UNDEFINED for externs
Relocation :: struct { offset: u32, symbol: u32, kind: elf.R_X86_64, addend: i64 }
Input :: struct { atoms: []Atom, symbols: []Symbol, entry: string }
link :: proc(input: Input, allocator: mem.Allocator) -> (image: []byte, err: Link_Error)
```

**What a `Module` lowers to** (`x64.compile_module(module, schedules, config) -> (link.Input, Error)`):

| Source | Atom |
|---|---|
| each `Function`, in function-index order | one `Text` atom, align 16, with its relocations, `Unwind_Info`, line rows |
| startup stubs | `Text` atoms placed first, so `_start` is the first code in the image |
| each `Global` with `bytes`, not `mutable` | `Rodata` atom (data relocations as `R_X86_64_64`) |
| each `Global` with `bytes`, `mutable` | `Data` atom |
| each `Global` without `bytes` and `mutable` | `Bss` atom (size, align only); non-mutable zero data goes to `Rodata` |
| each `tls` `Global` | `Tdata` (with bytes) or `Tbss` atom |
| float constant pool, jump tables | `Rodata` atoms, one per function, in function-index order |

**Layout** (all deterministic; sorted by atom order inside a section): image base `0x400000`; the ELF header and program headers occupy the first file page and are not part of any mapped section; `.text` at `0x401000` (R+X), `.rodata` at the next page boundary (R), then the writable segment (R+W) starting on a page boundary with `.tdata`, `.data`, `.bss` in that order (`.tbss` takes no address space; it extends only the TLS segment). `PT_LOAD` per non-empty segment through `elf.executable_add_segment`; `.bss` is `memsz > filesz` in the writable segment. `PT_TLS`: `p_vaddr` = start of `.tdata`, `p_filesz` = `.tdata` size, `p_memsz` = `.tdata + .tbss` (each atom aligned), `p_align` = max atom alignment, `p_offset` the file offset of the image. `PT_GNU_STACK` is added by `executable_write`. Entry = address of `_start`.

**Steps:** (1) place atoms; (2) build the name table (a duplicate defined name is `Duplicate_Symbol`); (3) resolve each relocation (`Undefined_Symbol` if the target has no atom); (4) apply: `R_X86_64_64`: `S + A`; `PC32`/`PLT32`: `S + A − P`; `TPOFF32`: `tpoff(S) + A`; 32-bit results must fit `i32` (`Relocation_Overflow{symbol, atom, offset, value}`), which is the "fail loudly beyond ±2 GiB" rule; (5) `executable_write`. No dynamic section, no GOT/PLT (PLT32 resolves directly), no `gc-sections` in this stage (the checker already lowers only reachable procedures; per-function atoms make the later pass a reachability walk).

`elf` additions this needs (owner of `src/elf`, not this document): `PT_TLS` support in `Executable_Builder` (`executable_set_tls(vaddr, file_data, memsz, align)`, the header emitted before `PT_GNU_STACK`) and `R_X86_64_TPOFF32 = 23`.

## 13. Debug-info hooks (stage 1: line table, `docs/research/09`)

`ir.Node` has no source location (open question 2). The hook: an optional `ir.Function.locations: []Source_Location` parallel to `nodes` (`{file: u32, line: u32, column: u32}`), filled by `lower` when `-debug` is on. `select` copies the location of the node that produced an instruction to `Machine_Instruction.location`. `emit` records `Line_Row {address, file, line, column, is_stmt, prologue_end}` when the location changes between consecutive encoded instructions, suppressing zero-length rows; `prologue_end` is set on the first instruction after the prologue; rows follow address order, so cold blocks (laid out last) form their own rows. The frame pointer, symbol sizes and `Unwind_Info` already give stage 0 (`lldb bt`, `perf`). The DWARF writers (`.debug_info`, `.debug_abbrev`, `.debug_line`, DWARF 5 header) are a separate package after this one; they consume `Atom.lines` and `Symbol` records and do not touch `x64`.

## 14. Determinism rules

1. Iterate `module.functions`, `globals`, `externs`, `sched` blocks and `regalloc` vregs by index; never iterate a `map` whose order reaches the output (lookup-only maps are allowed).
2. Vreg numbers are assigned in schedule order, instruction order, operand order.
3. The constant pool and jump tables are appended in function-index order, then first-use order; deduplication keys are bytes and alignment.
4. Relaxation is a monotone fixed point: all short branches first; a `LABEL_OUT_OF_RANGE` error from the encoder (`Error.inst_idx`) widens exactly that branch; repeat until no error. The result does not depend on iteration order.
5. Symbols and atoms are numbered in input order; the ELF writer already serializes in insertion order, with no timestamps.
6. Parallelism is per function (`select` → `regalloc` → `emit` in one worker, as `docs/02-ir-design.md` section 14); the join appends atoms in function-index order. A test compares the image bytes at 1 and 8 threads.
7. No pointer values, hashes of addresses, or allocation addresses enter any key.

## 15. Verification

- `verify_machine`: predecessor/successor symmetry; every use has a def on all paths; fixed-register constraints are consistent with `op_info`; flags are not written between a compare and its consumer; no RIP-relative operand with an immediate; at most two register-needing operands per instruction after folding; no critical edge.
- Per-sequence tests (few, table-driven): encode the sequence of one node kind, decode it with `rexcode`, compare mnemonics (selection test); run tiny functions natively through the interpreter-versus-native harness (the interpreter is the oracle for scalar semantics; the official compiler's native output is the oracle for ABI and source-visible effects). Division, shift totality, `Clz/Ctz` of 0, `u64↔float` boundaries, `MIN % -1`, atomics and TLS each get one table of boundary values.
- ABI: the `mise run abi-matrix` signatures are compiled by our backend and called from clang-built C and the reverse (milestone M1).
- Link: `llvm-readelf --program-headers`, `llvm-objdump -d` and running the file are the oracles; `llvm-readelf --debug-dump=frames` checks `.eh_frame` when that part lands.

## 16. Open questions

1. **Spill and reload contract with regalloc.** `Result.location` is per program vreg and `inserted_moves` are vreg moves; this document reloads spilled operands itself through the scratch registers (section 6) and applies `inserted_moves` as plain moves. Confirm with the regalloc owner that (a) `edge_moves` and cycle breaking are resolved inside `inserted_moves` (the document assumes yes, so `emit` never resolves a parallel copy), (b) the allocator never needs a scratch register of its own, (c) a vreg used by a `Fixed`-constrained operand may be assigned a register outside that fixed register and the allocator then inserts the copy.
2. **Source locations on IR nodes.** Needed by section 13; not in `ir.Node`. Proposal: a parallel `locations` array on `Function` (no node growth). Needs a ruling by the `ir` owner.
3. **`elf` additions** (`PT_TLS`, `R_X86_64_TPOFF32`) and who writes them; H1 depends on them.
4. **Package edge.** The architecture table lists `x64` as depending on `ir, sched`. This design adds `regalloc`, `link` (types only) and `types` (ABI plan, only in the driver glue). The table needs the new edges, or the atom types move to `elf`.
5. **`Float_Ext`/`Float_Trunc` on `F16`.** The runtime routines are Odin procedures reached by name. Who declares them as externs: `lower` (as ordinary `Call`s, which would remove these from `x64`) or `x64` through `Config`? Recommendation: `lower`, so `x64` never sees an `F16` conversion; H5 shrinks to the `lower` side plus `movd` moves.
6. **Over-aligned frame objects.** `#simd` and `align(32)` aggregates reach alignment above 16 (`DEFAULT_LAYOUT.max_simd_align` is 512). v0 reports `Unsupported_Alignment`. A later step realigns `rsp` and addresses locals through a second base register.
7. **Float `Select` without control flow.** This design uses `movd/movq` + `cmov`; `docs/02-ir-design.md` section 12 lists float `Select` among the control-flow expansions. Confirm the deviation (it is a strict simplification, the result is bitwise the same).
8. **Callee-side C variadics** (`#c_vararg` procedures defined in Odin) are not supported in v0; no known program in the default runtime defines one.
9. **Frame pointer always.** Decision 1 trades about one instruction and one register per function for debuggability; revisit with a measurement at M4.
10. **`src/sched` is absent.** If its final `Block`/`Schedule` shape differs from `docs/02-ir-design.md` section 12, only `select.odin`'s entry and `Cold`/depth reads change.

## 17. Staged ticket plan

Sizes include tests and error paths. "After" lists hard dependencies. `link` and `startup` have no dependency on `select`.

| Ticket | Deliverable | Lines | After | Test |
|---|---|---|---|---|
| X0 | `machine.odin`, `op_info.odin` (generated from `clobber_forms`), register tables, `build_program`, `verify.odin`, machine printer | ~550 | regalloc `program.odin`, ir A1 | op_info agreement test, hand-built programs |
| F1 | `abi.odin`: assignment, `Start` parameters, `Call`, `Return`, sret, result extension, `AL`, stack arguments and `By_Value` copies | ~600 | X0, types B3, sched D2 | signatures from the B4 matrix, selection golden |
| F2 | `select_int.odin`: constants, ALU, shifts (total), div/rem, compares, `Select`, ext/trunc, address folding | ~600 | X0 | per-kind selection tests |
| F3 | `select_float.odin`: float ops, compares, conversions with `u64` blocks, constant pool, `Bitcast`, float `Select` | ~600 | X0 | boundary-value tests |
| F4 | `select_memory.odin`: `Load`/`Store` widths, `Stack_Slot`, `Stack_Alloc`, `Mem_Copy`/`Mem_Set` | ~600 | X0 | copy sizes 0..130 |
| F5 | `select_control.odin`: layout, `If`/`Switch`/`Phi` copies, edge blocks, jump tables, `Trap`/`Unreachable` | ~600 | X0, sched D1 | CFG shape tests |
| F6 | `frame.odin`, `emit.odin`: `Result` application, scratch use, prologue/epilogue, relaxation, encoding, relocations, `Unwind_Info`, line rows | ~600 | X0, regalloc E2, F1 | decode round-trip, relaxation fixed point |
| L1 | `link`: types, layout, symbol table, relocation application, `Relocation_Overflow`, ET_EXEC through `elf` | ~550 | elf | hand-built atoms run natively |
| H8a | `startup.odin`: minimal `_start` | ~150 | L1 | runs, exit code |
| H1 | TLS end to end: `tpoff`, `Tls_Addr` forms, `link` `.tdata/.tbss` and `PT_TLS`, `elf` additions | ~600 | F4, L1, elf additions | thread-local test |
| H2 | atomics, fences, ordered accesses | ~500 | F4, ir C4 | per-op tests |
| H3 | `Popcnt Clz Ctz Bswap Mul_Hi`, `FSqrt` | ~500 | F2 | per-op tables |
| H5 | `f16` handling (`movd` moves, runtime conversion calls if open question 5 goes to `x64`) | ~300 | F3 | rounding cases |
| H7 | `Target_Op`, `Stack_Alloc` realignment | ~300 | F1 | per-op |
| H8b | full startup: auxv scan, `PT_TLS` lookup, TLS block, guard, layout function, `__stack_chk_fail` | ~500 | H1 | M2 |
| L2 | `.eh_frame` synthesis in `link` | ~350 | F6 | `llvm-readelf --debug-dump=frames` |
| L3 | line table rows to `.debug_line` (separate package) | later | F6 | `lldb` break at `file:line` |

**Critical path:** X0 → F1/F2/F4/F5 → F6, with L1 and H8a in parallel → M0 (`syscall`-and-exit program as a native executable) → M1 (F1 plus the ABI matrix) → H1, H8b → M2.

**Parallel start:** after X0, four agents on disjoint files: **A** F1 (`abi.odin`), **B** F2 then H3, **C** F3 then H5, **D** F4 then H2. **E** (`link` L1, then H8a, then L2) starts immediately and does not wait for X0. F5 and F6 start when F1, F2 and sched D1/D2 are available; F6 is last because it needs the allocator result and F1's frame facts.

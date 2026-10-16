# PR #7850 (`-backend:fast`) — lowering, SysV ABI, ELF, DWARF: case study

Source: checkout at `/home/su3h7am/Projects/refs/odin-pr7850-fast-backend`
(`src/x64_lower.cpp`, `src/x64_abi.cpp`, `src/x64_elf.cpp`, `src/xb_dwarf.cpp`,
`src/linker.cpp`). PR: https://github.com/odin-lang/Odin/pull/7850 —
title "Add `-backend:fast`, a non-LLVM debug backend for x86-64 and arm64"
(by bbodi, 140 commits, +32526/−111, 54 files, state closed, not merged).
The only comment on the PR is Ginger Bill's (2026-10-09):
"No. This is not maintainable."
(api.github.com/repos/odin-lang/Odin/issues/7850/comments).
Scope here: SysV x86-64 on Linux only. arm64, COFF, Mach-O, CodeView,
Objective-C are skipped. IDEAS ONLY — no copied code, no design baggage
(our project is pure Odin; see `docs/01-architecture.md`).

All `file:line` citations below refer to the checkout, e.g.
`src/x64_lower.cpp:31` means
`/home/su3h7am/Projects/refs/odin-pr7850-fast-backend/src/x64_lower.cpp:31`.
Spot-checked against the checkout; treat sub-10-line ranges as approximate.

## Prior-art check (per AGENTS.md)

1. **Our tree first.** `src/elf/` already has an ELF writer in progress
   (`writer.odin`, `types.odin`, `doc.odin`, `writer_test.odin`: a `Builder`
   with `Section_Handle`/`Symbol_Handle`, structured `Error` return).
   Encoding is settled: `core:rexcode/isa/x86` exists and per AGENTS.md must
   be used — we do NOT write an encoder. `core/debug/` has only `pe` and
   `trace`: no DWARF, no `.eh_frame` helper anywhere in `src/` or `core`.
   No SysV classifier exists in our tree (only syscall stubs matched a
   case-insensitive "sysv" grep). So: reuse `src/elf` + `rexcode/isa/x86`;
   write fresh: SysV classification, frame/prologue lowering, `.eh_frame`,
   DWARF.
2. **Official repos.** The PR itself is the prior art (closed, unmerged).
   Its test evidence is real but does not imply mergeability:
   `tests/internal` 213/213, `tests/core/normal.odin` 641/641,
   `tests/abi` (Odin vs clang) 229/229 on Linux, byte-identical objects at
   1 vs 10 threads (PR description). Correctness testing was strong;
   the rejection was about maintainability, not behavior.
3. **Refs.** The SysV classification ports `lbAbiAmd64SysV` + LLVM's
   `CC_X86_64_C`; the spec ground truth is the System V AMD64 ABI §3.2.3,
   and LLVM's `X86CallingConv.td`/`CC_X86_64_C` for assignment. Check those,
   not just this port.
4. **Vision check.** Ginger Bill's "not maintainable" verdict is consistent
   with `docs/research/01-gingerbill-vision.md` (simplest efficient solution,
   idiomatic code, nothing that changes the language): the PR optimizes for
   backend-author throughput (one contributor, C++ idioms, duplicated
   per-target paths) over reviewer throughput.

## 1. `src/x64_lower.cpp` (2111 lines) — xb IR → x86-64 machine code

What it does: consumes procedures whose registers were already assigned by
`xb_alloc_regs` and emits bytes plus relocations through a byte-emitter
helper family (`xb_enc`, `xb_mov_r_rm`, `xb_alu_r_rm`, …). Central context
is `struct xbLower` (`:31`). Operands are abstracted by a `x64_src / x64_dst /
x64_put` family (`:233–:333`) covering const-rematerialization, register,
and stack-slot sources, with float↔GPR shuffles via `movd`. Memory operands
funnel through `xb_mem_opnd` (`:347`), which maps `xbMem{Local, Incoming,
Reg, Sym}` to emitter operands and handles TLS/GOT/RIP normalization.
Odd-size (3/5/6/7-byte) traffic has dedicated `xb_load/store_xmm` and
`xb_load/store_bytes_gpr` paths (`:416–:501`). Copies ≤64 B inline as
overlapping loads-then-stores (`x64_copy_small`, `:540`); larger or dynamic
sizes call `__xb_memmove`/`__xb_memset` helpers that preserve only scratch
regs (`:582–:799`). Calls are lowered by `xb_lower_call` (`:810`): stack
args first (so arg regs stay free as scratch), then register args, then the
`call`, then return-value stores. The ~800-line `xb_lower_instr` switch
(`:1061`) covers arithmetic, compares, converts, atomics, vectors, TLS,
syscalls and intrinsics. Flag fusion (`x64_can_fuse`, `:1860`) keeps a
compare that feeds only the next branch/select/test in the flags, and the
per-procedure driver `x64_lower_proc` (`:1884`) lays out cold-blocks-last
with fallthrough-`jmp` elision and deferred `rel32` patching.

Good ideas worth adapting: the explicit scratch contract (documented at the
top of file: `rax, rcx, rdx, r10, r11` + `xmm0–3`) is the kind of invariant
our `x64` package should state once and enforce; one-deep store→load
forwarding with a `fresh/valid/volatile` guard is a cheap, sound peephole
that fits a non-optimizing backend; cold-blocks-last plus `rel32` fixup
patching is simple and deterministic; the frame-layout comment (`:13–:19`)
is exactly the documentation our lowering should carry.

Poor design (likely what hurt maintainability): the 800-line lowering
switch hand-encodes each case with slightly different scratch choices
(`Add` LEA-3-op special case vs `Mul`-imm vs shifts) instead of a
table-driven ALU core — every new op is a new snowflake; raw opcode bytes
sit inline (`fs:[0]` prologue, `cpuid`/`xgetbv`, a Valgrind `rol` chain,
`punpcklqdq`) instead of going through assembler helpers; C++ lambdas
capturing the emitter and a templated `wants/pins<F>` allocator policy
(`:90–:106`) have no direct Odin equivalent and would need redesign, not
translation; `GB_ASSERT`/`GB_PANIC` guard codegen invariants that can fire
on user input (bad xmm load size, bad mem operand, "cannot lower op") with
no error return; load/store paths are duplicated (`xmm` vs `bytes_gpr`,
inline-small vs helper-small); float `Select` via integer `cmov` is
bitwise-correct but unexplained. Prologue shape also pessimizes leaf code:
always `push rbp; mov rbp, rsp`, never uses the red zone, always reserves
the outgoing area.

Odin translation: `xbLower` becomes a struct of `distinct` handles and
slices, no methods-on-emitter; the `x64_src/dst/put` family becomes plain
procedures returning an `Operand` tagged union; the giant switch becomes
one procedure per op group (arith, cmp/branch, convert, mem, atomic,
vector, misc) dispatching on `Node_Kind`-style enum; scratch discipline
becomes a `bit_set` + verifier assertion, not a comment; every failure
returns an `Error`, never asserts. Encoding itself is `rexcode/isa/x86` —
the PR's emitter helpers have no equivalent in our design. Per
`docs/01-architecture.md`, scheduling/GCM is a separate package; the PR's
cold-layout trick belongs in `sched`, not in lowering.

## 2. `src/x64_abi.cpp` (1401 lines) — SysV classification + assignment

What it does: a self-contained port of `lbAbiAmd64SysV` classification plus
LLVM `CC_X86_64_C` register/stack assignment. A lowered-type layer
(`xbLTypeKind`/`xbLType`: `Void, Int, Half, Float, Double, Ptr, Struct,
Array, Vector` + size/align/packed, `:8–:29`) is computed from Odin types
(`xb_ltype`, `:394–:415`, with layout, padding, union and packing rules at
`:46–:392`), then classified into eightbyte classes by a 14-case `RegClass`
lattice (`NoClass, Int, SSEHs/SSEHv, SSEFs/SSEFv, SSEDs/SSEDv,
SSEInt8/16/32/64/128, SSEUp, X87, X87Up, ComplexX87, Memory`, `:423–:443`).
`classify_with` (`:500–:590`) recurses over the lowered type;
`classify_source` (`:635–:694`) classifies directly from the Odin type for
layout-quirk cases; `unify` (`:469–:498`) merges classes per eightbyte and
`fixup` (`:696–:736`) runs the spec's post-merger cleanup. `amd64_type`
(`:977–:1076`) turns classes into `Direct/ByVal/Indirect/Ignore` decisions
with register-exhaustion and wide-aggregate rules; `xb_abi_assign_piece /
assign_arg / assign_ret` (`:1103–:1198`) place pieces into the 6 GPR / 8 XMM
argument and 2 GPR / 4 XMM return registers (`RDI, RSI, RDX, RCX, R8, R9`
at `:1103+`); `xb_abi_compute` (`:1225–:1401`) builds the full signature
including hidden `sret` pointer, stack slots, and context.

Good ideas worth adapting: the lowered-type layer before classification
forces padding/union/packing decisions once so the classifier stays
spec-clean — copy that layering; `unify` + `fixup` are small, testable, and
spec-critical — port the logic, not the code; `byval_align = max(8, align)`,
empty-struct `Ignore`, trailing-`NoClass` trim, and the slice-like
`{ptr, i64} → 2×GPR direct` shortcut (Odin slices/strings/`any` hit this
constantly) are all worth taking; sign/zero-extension by signedness
(`ext_for`, `:925–:933`) belongs in one place.

Poor design: two parallel classifiers (`classify_with` vs
`classify_source`) with an allowlist (`source_is_classifiable`, `:592–:633`)
doubles maintenance and risks silent divergence — one classifier over the
canonical layout is enough; per-call heap-allocated `Array<RegClass>` plus
a global + thread-local cache with mutex for what is a pure function over
≤4 eightbytes is overkill — a fixed `[8]RegClass` stack buffer (the max is
tiny) and a caller-owned memo table suffice; `llreg` (`:810–:923`) emulates
LLVM's cast-to-register-pieces including AVX/AVX512 lane splitting — the
most intricate, bug-prone code in the file — while our backend can emit
pieces directly from `(class, offset)`; X87/ComplexX87 enum members are
carried but never produced (Odin has no `f80`), and `is_sse` omits
`SSEInt128`/`SSEUp`, so the lattice is neither fully generic nor honestly
Odin-minimal. This file also owns no red-zone/stack-alignment/`AL` logic —
correct layering, but a reader expecting "the ABI file" to cover it will
look in the wrong place.

Odin translation: `RegClass` enum + `[8]RegClass` + count on the stack;
pure procedures `(type_handle, layout) -> classification`, no cache, no
mutex; `unify`/`fixup` as tiny unit-testable procedures — these are ideal
`types`-package material per `docs/01-architecture.md` (SysV layout lives
in `types`); assignment results as a small struct of slices owned by an
arena. Table-test against clang's decisions (`tests/abi`-style) rather than
against this port.

## 3. Prologue, varargs, calls (lowering + ABI together)

Prologue (SysV path, `x64_lower.cpp:1932–:1962`): always framed —
`push rbp; mov rbp, rsp; sub rsp, frame_size`, then callee-saved spills at
negative offsets; `incoming_base = 16` (`:1924`);
`frame_size = align16(slots + locals) + align16(max_call_stack)` (`:179`).
Only `RBX, R12–R15` are considered (`:139–:142`); restore + `leave; ret`
at `:1007–:1011`. `naked` procedures skip everything (`:120, :999–:1002,
:1928`). Over-16-aligned locals use a `raw_offset` plus runtime
`lea/and/mov` realignment (`:167–:173, :1963–:1969`). `alloca` carves above
the outgoing area with `lea/sub/and` (`:1755–:1764`). Dwarf register numbers
come from a small table (`:69–:72`) and feed both debug info and
`.eh_frame`.

Varargs: the callee spills the SysV register-save area (`RDI…R9` order via
`xb_sysv_int_regs` plus `xmm0–7` with `movups`) into the frame
(`va_save_local`, `:1953–:1962`); callers set `AL = sse_count` (`mov rax,
count` before the call, `:888–:890`). `c_va_arg` walks the register area
then the stack like clang (per the PR description; implementation lives in
the IR builders, out of scope here). Note a smell: a adjacent `va_home`
spill uses `RCX, RDX, R8, R9` order (`:1948`) — Win64 order, not SysV —
so the two vararg paths demand careful reading before any adaptation.

Calls: `xb_lower_call` places stack args first, then register args, emits
direct (`sym`) or indirect (`R11`) calls (`:891–:895`); float stack args go
through `XMM0` (`:817–:819`); by-value `StackMem` wider than 8 B copies via
`lea/copy_fwd`, `V128` via `movups` (`:827–:841`); single return values take
a store-forwarding shortcut (`:910–:914`); tail calls only place args and
return without emitting the call (`:885–:887`); syscalls reuse arg placement
then trap with the result in `RAX` (`:1788–:1793`).

Adapt: the frame-layout contract, the `AL` rule, the int+XMM save-area
shape, and the stack-first/regs-second call ordering (keeps arg regs free
as scratch). Reject: always-frame + no-red-zone as the only mode (fine for
a debug backend, wasteful as our only backend); the Win64-order spill next
to the SysV save area; `R11`-clobbering RIP normalization where `rel32`
addressing would do.

## 4. `src/x64_elf.cpp` (511 lines) — ELF64 writer + `.eh_frame`

What it does: single entry `xb_write_object` (`:132`) copies the lowered
`Text/Rodata/Data/TData` bytes into output buffers, synthesizes
`.eh_frame`, calls `xb_dwarf_build` for `.debug_*`, appends
`odin_debugger.py` as `.debug_gdb_scripts`, builds `symtab`/`strtab`,
translates internal relocations to `Elf64_Rela`, lays out header + data +
section headers, and writes the file (`:461–:510`). 24 sections are
emitted unconditionally (`:72–:98` enum, `:412–:459` names/flags:
`Text ALLOC|EXEC`, `Rodata ALLOC`, `Data/Bss ALLOC|WRITE`,
`TData/TBss +TLS`, `EhFrame`, `DebugAbbrev/Info/Line/Ranges`,
`DebugGdbScripts` with `MERGE|STRINGS`, `NoteStack`, six `Rela*` with
`INFO_LINK`, `Symtab` linked to `Strtab`, `Strtab`, `Shstrtab`;
`Bss/TBss` are `NOBITS` sized without bytes, `:470–:471`). Relocation kinds
map to `ABS64/ABS32/PREL32` plus `GOTPCRELX/REX_GOTPCRELX`, `GOTTPOFF`,
`TPOFF32`, `TLSGD` (`:351–:373`); globals become real symbols
(`Weak→2`, `Func→2`, `Tls→6`, `Hidden→st_other=2`, `:309–:318`) while
locals are elided into section symbols with folded addends (`:343–:349`).
`.eh_frame` (`:152–:214`): CIE with `version=1, "zR", code_align=1,
data_align=-8 (sleb), RA=16, augmentation 0x1b` (FDE pointers are
PC-relative `sdata4`); initial CFA `rsp+8` with return address at `cfa-8`;
per-procedure FDEs (`PC_BEGIN` as section-based `R_PC32` extra reloc,
size, `auglen=0`), `naked` procedures get no CFA ops, framed procedures
get `advance/def_cfa_offset/offset rbp/def_cfa_register rbp` sequences,
then per-saved-register `offset` records; short-form `advance/offset`
vs `advance_loc2/offset_extended` encodings at `:34–:51`.

Good ideas worth adapting: local-symbol elision via section symbols keeps
`symtab` small and is easy to verify; separate `Rela*` sections with
correct `link/info`, `NOBITS` size-without-bytes handling, and the
`MERGE|STRINGS` gdb-script section (merges cleanly with LLVM objects) are
all correct ELF citizenship; per-procedure FDEs with a `naked` fast path
match our needs exactly; the `zR` augmentation choice is standard.

Poor design: all 24 sections are emitted even when empty (a hello-world
object carries debug/relocation sections it does not need); FDE
`pc/size` fields are 32-bit, so a single procedure over 4 GB is
unsupported; no `COMDAT`/`SHF_GROUP` support. For our `src/elf` writer
these are scope decisions, not blockers: emit only non-empty sections and
keep the address-size limitation documented or fixed.

Odin translation: this maps almost 1:1 onto our `elf` package's `Builder`
model — sections as handles, relocations as data, layout as a pure
procedure returning `Error`. The `.eh_frame` synthesizer wants to be its
own small file with a byte-level test (CIE bytes + one FDE, decoded by
`llvm-readelf --debug-dump=frames` as oracle).

## 5. `src/xb_dwarf.cpp` (1378 lines) — DWARF 4

What it does: `xb_dwarf_build` (`:1115`) fills abbrev/info/line/ranges
buffers. One fixed abbrev table (`:175–:361`) keeps DIEs small with
variants: `CompileUnit` (producer/lang/name/comp_dir/low_pc addr/high_pc
`data8` len/stmt_list), `Subprogram[NoChildren][Ret]` (name + linkage,
`low_pc` addr, `high_pc` `data4` len, `frame_base` exprloc, decl file/line,
`external`, optional type `ref4`), `Param`/`Var` (name, location exprloc,
decl line, type `ref4`), `BaseType`, `Pointer/NamedPointer`,
`Struct/Member`, `Array/Subrange` (count, no upper bound), `Typedef`,
`Enum/Enumerator` (+`Enumerator64`), `Union`, `EmptyStruct`,
`BitMember`, `SubroutineType` (empty — no signatures), `GlobalVar`,
`Constant`, `LexicalBlock` (low+high or ranges form), `AbstractSubprogram`
+ `InlinedSubroutine` (origin + low/high or ranges + call site). Types are
encoded to mirror the LLVM backend's descriptions (`:479–:784`): integers
as `Typedef→BaseType` pairs (so the debugger shows the Odin name),
`cstring` via `char` pointer, `string` as `{data, len}` struct,
`typeid` as a sorted `u64` enum of type-table hashes, slices as
`{data, len}`, `dynamic` arrays as `{data, len, cap, allocator}`,
enums with `sleb` values, unions with tag + variants from 0/1, bit-sets as
flag enums or unions of 1-bit bools, matrices as nested arrays, bit-fields
as accumulated `BitMember`s. Deduplication is by canonical type hash with
`ref4` placeholders patched CU-relative after procedures are written.
Procedures are built in 64-proc parallel chunks with per-thread arenas and
merged in order (`:1326–:1361`); the line program (`:1141–:1259`) is DWARF 4
with short-name file tables, zero-length-row suppression, and
`prologue_end` marking. Locations: globals via `OP_addr` (+ TLS op
sequence with `realign` rounding, `:919–:943`); params/locals via
`breg/reg/regx/fbreg` with `deref` for by-ref (`:971–:1003`); `frame_base`
is one byte (`rbp` register 6, `:1095–:1096, :1123`); multi-range blocks
use `.debug_ranges` (`:1006–:1048`).

Good ideas worth adapting: canonical-hash type dedup (deterministic under
threads) is the right call for parallel DWARF; mirroring the LLVM
backend's type descriptions keeps existing pretty printers working — we
should do the same against whatever our debugger story needs; short-name
file tables, zero-row suppression, `prologue_end`, and sorted-`typeid`
enums are all small wins worth copying; the fixed abbrev table is a
reasonable simplicity-vs-size trade for a debug backend.

Poor design: `FORM_string` everywhere (no `.debug_str`) bloats objects;
`high_pc` mixes `data4` (subprograms) and `data8` (CU) — DWARF-4-legal but
debugger-sensitive; one expression per variable (no location lists), so
register-allocated values going stale across the procedure is inherent;
ranges keyed to unit `low_pc` = text start couples DWARF to object layout.
1378 lines for "DWARF 4, debug subset" is itself the maintainability
signal: it covers everything (matrices, bit-fields, endianness-tagged
bit-sets, `string16`, inlined subroutines) in one file with threading
baked in.

Odin translation: split by section (abbrev table as data, info writer,
line-program writer, location writer) with each writer taking simple
inputs and returning `Error`; canonical-hash dedup via a map owned by the
debug context, no threads initially (our pipeline is serial until proven
otherwise); `ref4`/`sec_offset`/`addr` relocations expressed through the
`elf` package's relocation model, not a parallel `ExtraReloc` scheme.
Defer: location lists, `.debug_str`, split-DWARF — none are needed for
"breakpoints, stepping, backtraces, `info locals`".

## 6. `src/linker.cpp` changes (1260 lines — effectively unchanged)

What it does: `linker_stage` turns emitted object paths plus foreign
libraries into executables/shared/static objects by shelling out per
platform. Verified by grep: **zero `xb_` references** in `linker.cpp` —
the PR's only link-side change is producing one more object path
(`xb_object_path`/`xb_write_object` in `xb_backend.cpp:814–824`); link
invocation is stock. On Unix it drives `clang` (`ODIN_CLANG_PATH` or
`PATH`, `:623–:629`) precisely so `libgcc_s`/interpreter/unwind ordering
and `crt*.o` come from clang's specs — Odin passes no explicit
`crt*.o`, `-dynamic-linker`, or search paths (`:946–:952`).
Linux-relevant flags: `-pie` by default (`:980–:984`), `-Wl,-z,now
-Wl,-z,relro` (`:1105–:1108`), `-rpath,$ORIGIN` unless `no_rpath`
(`:1132–:1144`), `-lm -lc` unless `no_crt` (`:1146–:1154`), `.a/.o/.so`
via `-l:path` with dedup (`:788–:830`), `-fuse-ld=` passthrough
(`:1196–:1204`), `-nostdlib` and early `ar rcs` return for static libs
(`:924–:944`).

Lesson for us: nothing to adapt — this confirms the fast backend
deliberately stayed a *compiler* change, not a toolchain change, and our
built-in static linker (`link` package per `docs/01-architecture.md`) will
need to reproduce exactly the behaviors currently delegated to clang:
default-PIE, RELRO+now, `$ORIGIN` rpath, `-lc`/`-nostdlib` mutual
exclusion, `-l:path` path links, init/fini for shared libs. That list is a
useful acceptance checklist for the next backend milestone, nothing more.

## 7. Tricky SysV/ELF/DWARF details it got right — must not forget

ABI: eightbyte classification with misaligned-field → `MEMORY`
(`x64_abi.cpp:503–:510`); `>4 eightbytes → MEMORY` (`:742–:743`);
post-merger `fixup` including `SSEUp → SSEDv` rewrite (`:721–:722`);
`>2-eightbyte aggregate starting with SSE → indirect`
(`:1015–:1024`); `i128` needs 2 consecutive GPRs or a 16 B stack slot
(`:1157–:1169`); hidden `sret` for `MEMORY`-class returns, including the
wide-vector demotion (`:1323–:1364`); `byval` alignment `max(8, align)`
(`:1010–:1013`); zero-size/empty-struct `Ignore` (`:1062–:1065`); `AL =
number of vector registers` at vararg call sites
(`x64_lower.cpp:888–:890`); callee-side int+XMM register-save area
(`x64_lower.cpp:1953–:1962`); 16 B `rsp` alignment before `call`
(`frame_size` padding, `x64_lower.cpp:179`); `RDX:RAX` for `div`/`mul`,
shift-count-in-`CL`, `RBX` preserved across `cpuid`
(`x64_lower.cpp:1261–:1272, :1285–:1288, :1664–:1674`); `u64 ↔ float`
via branch-and-halve / `2^63` compare (`:1416–:1471`); `ucomis` + parity
for float equality, operand swap for ordered compares (`:1368–:1398`);
`lock xchg/xadd/cmpxchg` + `mfence` (`:1173–:1178, :1582–:1583,
:1610–:1655`); `bsf/bsr` zero-guard (`:1830–:1848`); `memcpy`-backward
via `std + rep movsb + cld` with `RSI/RDI` parked (`:682–:706`).

TLS/PIC: initial-exec `fs:0 + GOTTPOFF`, global-dynamic via
`__tls_get_addr` (`x64_lower.cpp:378–:390, :1734–:1741`); `GOTPCREL` for
foreign-undefined/preemptible symbols (`:392–:397`); ELF `DTPOFF64` for
debug symbol references, `GOTTPOFF/TPOFF32/TLSGD` relocation selection
(`x64_elf.cpp:240–:243, :351–:373`).

Unwind: CIE `zR + 0x1b`, `code_align=1`, `data_align=-8`, `RA=16`;
entry CFA is `rsp+8` (return address still on the stack) with `rip` at
`cfa-8`; per-push `advance/def_cfa_offset/offset rbp/def_cfa_register`
sequences; short vs extended `advance/offset` forms
(`x64_elf.cpp:34–:51, :155–:213`).

DWARF: `ref4` is CU-relative; `abbrev/stmt_list/ranges` need section
relocs (`ABS32`), code addresses `ABS64`; member offsets must respect
alignment; union variant base 0/1 with tag omission for maybe-pointer;
`call_file ≥ 1` clamping; `realign` TLS op sequence
(`xb_dwarf.cpp:928–:943, :1019, :1315, :1344–:1349`).

ELF/link: `STV_HIDDEN = 2`, weak bind = 2, TLS symbol type = 6;
`NOBITS` size-without-bytes; `Rela` entity size 24, align 8; never `-lc`
under `-no-crt`; shared-lib init/fini wiring.

## 8. Verdict: good ideas vs poor design (why "not maintainable" rings true)

Take: lowered-type → classify → assign layering; `unify`/`fixup` logic;
slice fast path; explicit scratch + frame contracts; store-forwarding and
flag-fusion as bounded peepholes; section-symbol elision; `zR` eh_frame;
canonical-hash DWARF dedup; clang-driver delegation (until our linker
lands); the bisect switches (`NO_FALLBACK`/`SERIAL`/`ONLY`/`SKIP`) as a
testing pattern.

Leave: the 800-line lowering switch; inline raw opcodes; emitter-capturing
lambdas and templated allocator policy; assert-on-user-input codegen;
dual classifiers; heap-per-call classification with mutexed caches;
LLVM-cast-emulating `llreg`; emit-everything-24-sections; `FORM_string`
everywhere; one-file 1378-line DWARF with threading baked in; ~32.5k added
lines across two architectures and three object formats in one PR with
fallback-to-LLVM as the safety net. Each piece is defensible; together
they ask every future maintainer to hold the whole backend in their head.
A pure-Odin port that keeps the layering but replaces the snowflakes with
tables, the asserts with errors, and the parallelism with determinism-first
serial code gets the 2× debug-build win without the maintenance bill.

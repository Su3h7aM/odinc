# 04 — Reuse Survey

Read-only survey of what already exists that each planned package can adapt, and
what it must write. Backends and paths below were read directly; every claim is
tied to a path, and line ranges refer to the files as checked out now.

Roots:

- `OC` = `/home/su3h7am/Projects/odin-compiler` (this workspace).
- `FORK` = `/home/su3h7am/Projects/Odin` (our Odin fork; `core`, `base`).
- `REFS` = `/home/su3h7am/Projects/refs` (reference checkouts).

Per `AGENTS.md`, the rule is "do not reinvent the wheel": reuse `FORK` first,
then `REFS`, and record which reference informed the work.

---

## 0. What the reference set actually contains (read this first)

The task assumes several references that are **not present**. The clones are
sparse (confirmed by `REFS/README-tls-clones.md`):

| Reference assumed | Present? | Reality |
|---|---|---|
| Go `src/cmd/compile`, `src/cmd/asm`, `src/internal/obj/x86`, `internal/obj/link` | **No** | Only `REFS/go/src/cmd/link/internal/ld` is cloned, plus `runtime`, `syscall`, `internal/runtime`. There is **no Go x86 encoder, no Go regalloc, no `cmd/compile`**. |
| LLVM `lib/MC`, `lib/CodeGen/RegAlloc*`, `FastISel` | **No** | `REFS/alloc/llvm-project` contains **only `compiler-rt/`**. No `llvm/lib` at all. No MC ELF writer, no linear-scan/Greedy regalloc, no FastISel source. |
| Zig self-hosted x86_64 backend | **No** | `REFS/zig` is sparse: **`lib/std` only**. The compiler (`src/`) is absent. `lib/std/Target/x86.zig` and `lib/std/os/linux/*` are present (ABI + syscalls only). |
| A Sea of Nodes implementation | **No** | Case-insensitive grep for `sea of nodes`/`seaofnodes` across `REFS` (excluding the unrelated `harness/goose` Rust tree) returns nothing. The SoN references are the external `SeaOfNodes/Simple` and the V8 post-mortem, both already summarised in `OC/docs/research/02-backend-ir-landscape.md`. |

Two large `REFS` trees are noise for this work: `REFS/harness/goose` (a Rust
agent project) and `REFS/terminal_tui_gui`, `REFS/file_search`. Exclude them
from searches.

The consequence is a sharp shift of weight onto the fork: **`FORK/core/rexcode`
is the single most valuable reference in the whole set**, and it is the thing our
already-written `src/x64/encode.odin` duplicates.

### 0.1 The `REFS/rfcs` corpus (corrected)

`REFS/rfcs` is **not only Linux syscall material** — it is a broad protocol
reference set (`REFS/rfcs/README.md`: "417 documents from manifest.tsv, plus
3989 kernel documentation files and 208 Linux man pages"), indexed by
`REFS/rfcs/manifest.tsv` (418 lines) and `REFS/rfcs/fetch.sh`. Most of it
(HTTP, TLS, DNS, MCP, OpenAI, …) is irrelevant to a compiler. The
**compiler-relevant subset** is the Linux tree plus a few encoding/grammar RFCs
(RFC 3629, 4648, 5234, 2119). The
`refs/rfcs/linux` tree sits inside `refs/rfcs` (which explains the path noted in
`OC/docs/research/03-existing-compiler-map.md:393`); its `VERSION` is Linux
**7.2.8**.

The corpus is grep-able directly. Useful when working on `syntax`, `elf`, `link`
and the runtime:

| Topic | Documents (exact paths under `REFS/`) |
|---|---|
| ELF-specific behaviour | `rfcs/linux/kernel-docs/Documentation/userspace-api/ELF.rst` (`PT_INTERP`/`PT_GNU_STACK`/`PT_GNU_PROPERTY` rules) |
| x86 ELF auxv | `rfcs/linux/kernel-docs/Documentation/arch/x86/elf_auxvec.rst` (`AT_SYSINFO_EHDR`, `AT_MINSIGSTKSZ`, …) — what our `_start` reads |
| x86-64 address space | `rfcs/linux/kernel-docs/Documentation/arch/x86/x86_64/mm.rst.md` (user space ends `0x00007fffffffffff`, guard hole, non-canonical region) and `.../x86_64/5level-paging.rst` (47-bit vs 56-bit) |
| syscall interface | `rfcs/linux/kernel-docs/Documentation/ABI/stable/syscalls.md` (+ `.../ABI/stable/syscalls/`) and `.../Documentation/process/adding-syscalls.rst` |
| x86-64 entry/ABI | `rfcs/linux/kernel-docs/Documentation/arch/x86/entry_64.rst` (syscall/entry calling conventions) |
| per-syscall semantics | `rfcs/linux/man-pages/{2-mmap,2-mprotect,2-mremap,2-madvise,2-brk,2-arch_prctl,2-read,2-write,2-openat,2-close,2-exit,2-exit_group,2-getrandom,2-sched_yield,2-uname,2-prctl,2-rt_sigaction,2-rt_sigprocmask,2-nanosleep,2-futex,2-futex_waitv,2-clone,2-clone3,2-memfd_create,2-userfaultfd}.md` |
| futex / rseq / exec | `rfcs/linux/kernel-docs/Documentation/locking/robust-futex-ABI.rst`, `.../Documentation/userspace-api/{futex2,rseq,check_exec}.rst` |
| UTF-8 | `rfcs/encoding/rfc3629-utf-8-a-transformation-format-of-iso-10646.md` (cross-check against `FORK/core:unicode/utf8`) |
| Base16/32/64 | `rfcs/encoding/rfc4648-the-base16-base32-and-base64-data-encodings.md` (dumps, build-ids) |
| Grammar notation | `rfcs/foundations/rfc5234-augmented-bnf-for-syntax-specifications-abnf.md` (ABNF; pairs with `FORK/odin.ebnf`) |
| Requirement keywords | `rfcs/foundations/{rfc2119-...,rfc8174-...}.md` (for spec/doc wording) |

**Not in the corpus** (still external if needed): the x86-64 **System V psABI**,
the ELF gABI/psABI **format spec**, and the **DWARF** standard. The corpus has
only fragmentary mentions of "System V" and DWARF (e.g.
`.../Documentation/arch/x86/entry_64.rst:45`, `.../Documentation/locking/robust-futex-ABI.rst`),
and `.../Documentation/kbuild/gendwarfksyms.rst` is *kernel* DWARF symbol
generation, not a user-space DWARF reference.

---

## 1. Per-package reuse survey

### 1.1 `syntax` — tokenizer, AST, parser

**Best references (all in `FORK`):**

- `FORK/core/odin/tokenizer/token.odin` (350 lines): `Token` (`token.odin:5`),
  `Token_Kind` enum (`token.odin:31`), `to_string` (`:311`), `is_literal` /
  `is_operator` / `is_assignment_operator` / `is_keyword` (`:325`–`:342`). This is
  the reference token vocabulary, including the `B_Custom_Keyword_*` range our
  `Token_Kind` currently omits (`OC/src/syntax/token.odin:11`).
- `FORK/core/odin/tokenizer/tokenizer.odin` (939 lines): `init` (`:100`),
  `offset_to_pos` (`:128`), the per-token `Error_Handler` model (`:100`, `:140`),
  `scan` (`:660`), `scan_number` (`:541`), `scan_string` (`:332`),
  `scan_raw_string` (`:412`), and a **hash-based keyword LUT** (`keyword_hash`,
  `keyword_lut_init`, `:64`–`:99`).
- `FORK/core/odin/ast/ast.odin` (1157 lines): the full Odin AST. `Node`
  (`ast.odin:41`), `File` (`:70`), `Expr`/`Stmt`/`Decl` bases (`:98`–`:108`),
  `Any_Expr`/`Any_Stmt` tagged-union payloads. Note it is a **pointer-based**
  tree (`^File`, `^Stmt`, `^Expr`, `using node: ...`).
- `FORK/core/odin/parser/parser.odin` (4502 lines): `Parser` struct (`:19`),
  `parse_file` (`:135`), then the full recursive-descent grammar — `parse_operand`
  (`:2445`), `parse_expr` (`:3658`), `parse_binary_expr` (`:3726`),
  `parse_stmt` (`:1459`), `parse_body` (`:1750`), `parse_proc_type` (`:2364`),
  `parse_type` (`:1741`), `parse_field_list` (`:2063`). `parse_files.odin`
  holds `collect_package` (`:11`), `parse_package` (`:58`),
  `parse_package_from_path` (`:89`).
- `FORK/core/odin/doc-format/doc_format.odin` (356 lines): the doc-comment format,
  if we support `odin doc`.
- `FORK/core/odin/printer`, `FORK/core/odin/format`, `FORK/core/odin/tool-format`:
  AST-to-text; a reference for a canonical printer and for parser round-trip tests.
- Grammar/encoding cross-checks in `REFS`: ABNF notation
  (`rfcs/foundations/rfc5234-augmented-bnf-for-syntax-specifications-abnf.md`,
  pairs with `FORK/odin.ebnf`) and UTF-8
  (`rfcs/encoding/rfc3629-utf-8-a-transformation-format-of-iso-10646.md`).

**Adapt vs rewrite.** Adapt heavily; do not write Odin's grammar from memory. The
parser is the authoritative encoding of Odin's syntax, and `AGENTS.md` requires
the same program to parse identically under both compilers.

- **Token kinds and the tokenizer:** adapt `token.odin`'s vocabulary wholesale,
  and adopt the **keyword LUT** idea. Our `keyword_kind`
  (`OC/src/syntax/tokenizer.odin:549`) is a linear `switch` over `string(name)`;
  the fork's `keyword_hash`/`keyword_lut_init` is the same information in the
  form they ship. Either keep our `switch` (Odin compiles string switches well)
  or adopt the LUT; do not invent a third scheme.
- **AST:** adapt the **node kinds and field semantics** but **rewrite the storage
  model** to index-based, as `OC/docs/01-architecture.md:24` and `:15` require
  ("AST (index based)", "`distinct u32` node and type handles, not pointers").
  The fork's pointer/`using`/`Any_Expr` design is exactly what the architecture
  rejects. Treat `ast.odin` as the *shape* spec, not the implementation.
- **Parser:** port the **procedure structure and precedence climbing** one-to-one
  (same procedure names, same order), swapping `^ast.Expr` for an
  index handle. Keep `parse_binary_expr`'s precedence table and the
  `parse_operand`/`parse_atom_expr` split — these encode Odin's actual grammar
  and are the parts most likely to be got subtly wrong if rewritten.

**Most important design lesson:** the fork's AST is a pointer graph because a
batch compiler "parses then consumes"; our architecture is data-oriented
(`docs/01-architecture.md:15`) because we interleave and schedule. Copy the
*tree of node kinds*, but make the container an arena of structs addressed by
`distinct u32` from the first commit; retrofitting indexes onto a pointer AST
later is a rewrite.

---

### 1.2 `types` — semantic type store, interning, layout

**Best references:**

- No Odin package exists for this. The fork deliberately ships `core:odin/ast`
  and `core:odin/parser` but **no checker or type store** (confirmed:
  `FORK/core/odin/` contains only `ast doc-format format parser printer
  tokenizer tool-format`).
- The semantics reference is the C++ compiler, already mapped in
  `OC/docs/research/03-existing-compiler-map.md`:
  - `FORK/src/types.cpp` (5970 lines): `TYPE_KIND` set incl. `BitSet` (`:289`),
    `BitField` (`:310`), `Matrix`; type construction/canonicalization and
    size/align/hash.
  - `FORK/src/check_type.cpp` (5574 lines): `determine_type_from_polymorphic`
    (`:2`), polymorphic-record gen-types (`:307`–`:395`).

**Adapt vs rewrite.** Rewrite in Odin; the C++ is the **specification**, not a
porting source (per `AGENTS.md`). Interning and layout are pure data structures
and should follow the architecture's `distinct u32` + arena rules directly.

**Reusable substrate (see §3):** `FORK/core:strings` `intern` for type/ident
interning, `FORK/core:container/*` for the interning table, and
`FORK/base/intrinsics` (`type_is_*`, `size_of`, `align_of`) for self-describing
layout queries.

**Most important design lesson:** Odin's type identity is *canonicalization*, not
name. Two structurally identical types are one type. Make the type store an
interner keyed by structure (size, align, kind, children) with a deterministic
hash, and assign ids in a deterministic order — this is the same determinism
requirement as the IR (`docs/01-architecture.md:13`).

---

### 1.3 `ir` — Sea of Nodes graph, builder, verifier, printer

**Best references:**

- `FORK/core/rexcode/ir/` — a **shared SSA/IR structural model**, 592 lines:
  `module.odin` (158, `Module`/`Function`/`Block`/`Operation`/`Operand`/
  `Result`/`Dataflow`), `refs.odin` (99, `Id`/`Ref`/`Ref_Space`/`Symbol_Table`),
  `types.odin` (74, `Type`/`Type_Ref`/`Type_Kind`), `status.odin` (42,
  `Error`/`Error_Code`), `print.odin` (130, token kinds + `Print_Options`).
- `FORK/core/rexcode/docs/ir_design.md` — the rationale for the shared IR core,
  including the `Module → Function → Block → Operation` spine borrowed from MLIR
  (`ir_design.md:171`), the "three concessions" of an IR vs an ISA (`:84`–`:105`),
  and the pluggable-codec split (`:238`).
- `FORK/core/rexcode/docs/cross_arch_design.md` — "share the bookkeeping,
  specialize the bytes" (`:14`); the universal nine-item shape (`:35`); the
  divergence table (`:87`).
- **Sea of Nodes itself has no implementation in the reference set.** The design
  evidence is `OC/docs/research/02-backend-ir-landscape.md`: Click's original
  (`:11`–`:28`), the V8 post-mortem's 14 problems (`:55`–`:74`), and the
  Cranelift "CFG for effects, float only pure ops" hybrid (`:145`–`:166`).

**Adapt vs rewrite.** Adapt the *vocabulary* (`ir/`: ids, ref spaces, type refs,
module/function/block/operation, a printable status type). Do **not** expect
`rexcode/ir` to be a Sea of Nodes: it is a flat SSA/structured IR contract, not a
scheduler-based node graph, and it has no effect/control chains. Use it for the
pieces that are genuinely the same (`refs.odin`, `types.odin`, `status.odin`,
`print.odin` shapes) and write the SoN-specific parts ourselves.

**Most important design lesson.** Take `docs/01-architecture.md:9`–`:13`
literally and treat it as the Go/No-Go for SoN:

- Model memory and side effects as **explicit state edges** (Click's tutorial
  style), and ship the **verifier** that checks effect/control chains in the same
  commit as the graph builder — V8's #4 bug class (`docs/research/02:60`) is
  exactly an unverifiable chain.
- **Deterministic ids in creation order; nodes in SOA arrays by `distinct u32`;
  never iterate a map where order matters** (`:13`). `rexcode`'s label model
  (`FORK/core/rexcode/isa/labels.odin`: `Label_Definition :: distinct u32`,
  forward/backward labels) is a small, concrete precedent for index-based
  bookkeeping.
- Because SoN has no reference implementation here, the **interpreter + `-dump-ir`
  round trip** (`docs/research/02:220`–`:227`) is the correctness lever, not a
  nice-to-have.

---

### 1.4 `check` — name resolution, type checking, constants, polymorphism

**Best references:**

- The C++ checker, mapped in `OC/docs/research/03-existing-compiler-map.md:86`–`:103`:
  `FORK/src/checker.cpp` (8574; `check_parsed_files` `:8220`),
  `FORK/src/check_expr.cpp` (14933), `FORK/src/check_type.cpp` (5574),
  `FORK/src/check_builtin.cpp` (9173 + `checker_builtin_procs.hpp` 826),
  `FORK/src/check_stmt.cpp` (3129), `FORK/src/check_decl.cpp` (2668),
  `FORK/src/check_escape.cpp` (5564), `FORK/src/checker_global.cpp` (2558).
- No Odin checker exists (`FORK/core/odin` has none), so the C++ is the only
  behavioural reference.

**Adapt vs rewrite.** Rewrite in Odin; the C++ semantics are the contract.
Port **in the C++'s own order** (collect entities → add imports → directives →
global ordering → scope usage; `checker.cpp:8220`), because Odin's semantics
depend on that staging (notably global-entity initialization order,
`checker_global.cpp:1703`, which `docs/research/02` does not cover).

**Most important design lesson:** the checker is where the language *is*; the
backend is downstream. Do not let the SoN/IR decision leak into checking. Keep
`check` pure over `syntax` + `types` (as `docs/01-architecture.md:26` says) and
reuse the C++ file-by-file split as the porting checklist so no Odin feature
(implicit `context`, `defer`, `or_return`, monomorphization) is silently dropped.

---

### 1.5 `x64` — encoder, instruction selection, register allocation

**Encoder — best reference: `FORK/core/rexcode/isa/x86` (17,566 lines).**

- `encoder.odin` (1253): `encode` (`:59`), `encode_max_code_size` (`:1154`),
  `encode_max_relocation_count` (`:1160`), `encode_reserve` (`:1170`), plus
  dynamic-array `emit_*` helpers (`:1187`+).
- `mnemonic_builders.odin` (10,345): typed `inst_*`/`emit_*` builders, ~7,477
  procs / ~2,338 overload groups (`docs/x86_api.md:515`).
- `mnemonics.odin` (1392): `Mnemonic` enum, ~1176 mnemonics (`x86_api.md:257`).
- `operands.odin` (374): packed `Operand` + `Memory` bit-field (`x86_api.md:114`).
- `registers.odin` (417): `Register :: distinct u16` with class/bits
  (`x86_api.md:47`).
- `reloc.odin` (82): `Relocation` `#packed` 16 bytes mirroring ELF `rela`, with
  `REL8/REL32/ABS32/ABS64` (`reloc.odin:15`–`:31`) and patch primitives
  (`:44`+).
- `encoding_types.odin` (386), `tables.odin` (123), `decoder.odin` (1530),
  `printer.odin` (731), plus `tablegen/` (the `ENCODING_TABLE` source of truth).
- Design: table-driven, zero-allocation, caller-owned buffers
  (`docs/x86_api.md:10`–`:14`); labels are architecture-independent bookkeeping
  in `FORK/core/rexcode/isa/labels.odin` (parametric over `$T`), with branch-label
  inference in `isa/label_infer.odin:36`.

**Instruction selection & register allocation — no usable reference in the
cloned set.** Go's and LLVM's selectors/allocators are absent (§0). The
available guidance is `OC/docs/research/02-backend-ir-landscape.md`: Pipeline
§7.2 step 2 (trivial lowering / FastISel-equivalent, `:228`), step 3 (linear
scan, Poletto & Sarkar, `:229`), the x86-64 constraint list (early/late positions,
reuse-input, fixed `rax`/`rdx`/`cl`, caller-saved clobbers, 16-byte alignment,
`:230`), and the regalloc2 liverange/bundle/parallel-move model (`:169`–`:172`).
Also `OC/docs/research/02:191`–`:201` for the effort comparison, and QBE's
fixed-size C ABI (`:131`) — the SysV ABI we need.

**Adapt vs rewrite.**

- **Encoder: adapt, do not rewrite.** `rexcode/isa/x86` already covers REX/VEX/EVEX,
  ModRM/SIB, relocations, labels and a printer, and it is verified against LLVM-mc
  (`x86_api.md:531`–`:538`). For a correctness-first compiler that only needs a
  subset, select a subset of the *table* — the engine stays. If the whole package
  is too heavy to vendor, copy `registers/operands/encoding_types/tables/encoder`
  and drop decoder/printer/tablegen.
- **Instruction selection: rewrite.** Pattern-match the IR against the typed
  `inst_*` builders; keep it direct and unoptimized (FastISel-like).
- **Register allocation: rewrite**, starting from linear scan over live intervals,
  with the x86-64 constraints modelled from day one.

**Most important design lesson:** the encoder must remain a **pure, deterministic
function of explicit operands** (`OC/src/x64/doc.odin:5`) with **no selection or
allocation inside it**. rexcode's separation — ISA does "the bytes", labels/
relocations are architecture-independent bookkeeping (`cross_arch_design.md:104`),
selection/regalloc live above — is exactly the layering to copy.

---

### 1.6 `elf` — relocatable and executable writer

**Best references:**

- **Relocatable (ET_REL):** `OC/src/elf` already writes this (see §2). The spec
  structs are mirrored in `OC/src/elf/types.odin`; the suggestion-for-reuse list
  is `FORK/core/rexcode/isa/x86/reloc.odin` (ELF-rela-shaped relocations) and the
  spec constants.
- **Executable (ET_EXEC):** the only real reference in the set is
  `REFS/go/src/cmd/link/internal/ld/elf.go` (2398 lines): `Elfinit` (`:173`),
  `elf64writehdr` (`:502`), `elf64phdr` (`:251`), `elf64shdr` (`:338`),
  `elfSortShdrs` (`:382`), `elfwritephdrs` (`:458`), program-header fixup
  (`fixElfPhdr` `:241`). It writes both `ET_REL` and `ET_EXEC`/`ET_DYN`.
- **Reader / spec cross-check:** `REFS/zig/lib/std/debug/ElfFile.zig` (538 lines)
  and `REFS/zig/lib/std/debug/SelfInfo/Elf.zig`. Locally we also have the
  Linux-specific ELF behaviour in
  `REFS/rfcs/linux/kernel-docs/Documentation/userspace-api/ELF.rst` and the x86
  auxv in `REFS/rfcs/linux/kernel-docs/Documentation/arch/x86/elf_auxvec.rst`.
  The ELF **format** specification (gABI/psABI) and `elf(5)` are **not** in the
  local corpus (`REFS/rfcs/linux/man-pages` is 208 section-2/3 syscall pages,
  not `elf.5`).
- Startup/entry shape: `FORK/base/runtime/entry_unix_no_crt_linux_amd64.asm`
  (`_start`, parses `argc/argv/envp/auxv`), and `REFS/musl/arch/x86_64/crt_arch.h`,
  `REFS/musl/crt/crt1.c`, `REFS/relibc/src/crt0` as syscall-ABI/startup references
  (not to be linked — see the new `AGENTS.md` "No third-party dependencies").

**Adapt vs rewrite.** Keep the REL writer we have (no Odin equivalent exists; see
§2) but **extend it to ET_EXEC** as a separate, self-contained path, following
Go's `elf.go` ordering (headers, program headers, section-to-segment mapping).
Do not shell out and do not import libc (new `AGENTS.md` rule).

**Most important design lesson:** REL and EXEC are different products. REL is
"a bag of sections + symbols + relocations for someone else to place"; EXEC is
"a placement + program headers + entry point". Go keeps them in one writer but
with clearly separate header/phdr emission and a `fixElfPhdr` pass (`elf.go:241`)
that patches addresses after layout. Mirror that split; the current `src/elf`
explicitly scopes `ET_EXEC` out (`OC/src/elf/types.odin:11`,
`OC/src/elf/doc.odin:12`).

---

### 1.7 `link` — built-in static linker

**Best reference:** `REFS/go/src/cmd/link/internal/ld` is the only static linker
source in the set (29,576 lines total in `ld/`):

- `lib.go` (3247): the linker driver, host-object/library loading.
- `data.go` (3510): address assignment (`dodata`), section layout, symbol
  resolution, relocation application.
- `symtab.go` (864): symbol table emission.
- `deadcode.go` (555): reachability-based dead code elimination.
- `dwarf.go` (2651) + `dwarf_test.go` (2273): DWARF emission.
- `elf.go` (2398): ELF output (shared with §1.6).

Note: Go's **loader package** (the object-file reader that `ld/` consumes) is
**not cloned** — only `ld/`. So Go gives us the *linker structure* and the ELF
writer, not the input reader.

**Startup/syscall references:** `FORK/base/runtime/virtual_memory_linux.odin`
(`vm_map` `:95`, `vm_unmap` `:119`), `FORK/base/runtime/entry_unix.odin`
(`_start_odin` `:53`), `FORK/core/sys/linux/syscall_amd64.odin` (the `SYS_*`
table), and `REFS/musl/arch/x86_64/syscall_arch.h` for the raw `syscall`
convention (`rax` = number, `rdi/rsi/rdx/r10/r8/r9` = args, `rcx`/`r11` clobbered).
Per-syscall semantics (flags, struct layouts, error returns) are in
`REFS/rfcs/linux/man-pages` (208 section-2 pages, e.g. `2-mmap.md`,
`2-openat.md`, `2-read.md`, `2-arch_prctl.md` for TLS, `2-futex.md`),
backed by the kernel ABI docs
`REFS/rfcs/linux/kernel-docs/Documentation/ABI/stable/syscalls.md` and
`.../Documentation/process/adding-syscalls.rst`; the x86-64 entry/ABI
conventions are in `.../Documentation/arch/x86/entry_64.rst`; the x86-64
address-space limits for link layout are in
`.../Documentation/arch/x86/x86_64/mm.rst.md` and
`.../x86_64/5level-paging.rst`; the futex ABI is in
`.../Documentation/locking/robust-futex-ABI.rst`.

**Adapt vs rewrite.** Rewrite, but structure it like Go's `ld`: a symbol table +
`data.go`-style layout + `elf.go`-style emission + `deadcode.go`-style
reachability. Our input is our own `elf` package (not Go's loader), so the reader
is ours.

**Most important design lesson:** a static linker is **symbol resolution + layout
+ relocation application**, and layout (assigning every section a final VA and
computing PC-relative distances) is the hard, testable core. Go's `data.go` is the
model: resolve all symbols first, then assign addresses top-down
(segments → sections → symbols), then apply relocations in a final pass — never
interleave resolution with address assignment.

---

### 1.8 `driver` — CLI, package loading, pipeline

**Best references:**

- The C++ driver, mapped in `OC/docs/research/03-existing-compiler-map.md:36`–`:50`
  and `:169`–`:199`: `FORK/src/main.cpp` (5065; pipeline at `:4198`),
  `FORK/src/build_settings.cpp` (2776; `CommandKind` `:212`, output modes
  `:202`), `FORK/src/path.cpp` (580; collection resolution `core:`/`base:`).
- Odin-language reuse: `FORK/core:flags` (CLI parsing), `FORK/core:path`
  (collections, normalization), `FORK/core:os` (files/dirs — libc-free on Linux,
  see §3).
- Package loading: `FORK/core/odin/parser/parse_files.odin` (`collect_package`
  `:11`, `parse_package` `:58`) and `OC/docs/research/03:215`–`:260` for how the
  C++ driver overlapped parse/check with a thread pool.

**Adapt vs rewrite.** Rewrite the CLI/pipeline in Odin; adapt the C++
`BuildContext`/flag surface so `odin build`/`odin run`/`odin check` accept the
same flags. Reuse `core:flags`, `core:path`, `core:os` rather than re-deriving
argument and path handling.

**Most important design lesson:** determinism is a driver responsibility
(`docs/01-architecture.md:46`). The C++ driver's parallel parse/check
(`docs/research/03:222`–`:260`) is attractive but must not leak nondeterminism
into output; keep ordering explicit at the joins (Go and rexcode both do
this — merge results in index order, never in completion order).

---

## 2. Already-written packages: duplication flags

### 2.1 `OC/src/syntax` tokenizer vs `FORK/core/odin/tokenizer` — **DUPLICATE; recommend KEEP, documented**

`OC/src/syntax/tokenizer.odin` (977 lines) and `token.odin` (175 lines)
reimplement `FORK/core/odin/tokenizer/{tokenizer,token}.odin` (939 + 350 lines).
Function-for-function they track: `advance_rune`, `peek_rune`, `peek_byte`,
`skip_whitespace`, `is_letter`, `is_digit`, `scan_comment`, `scan_escape`,
`scan_rune`, `scan_string`, `scan_number`, `scan_identifier`, and
automatic-semicolon insertion. Differences that are deliberate:

- Ours is **zero-allocation with byte-range tokens** (`Token{kind,start,end}`,
  `OC/src/syntax/token.odin:74`) and optional error/comment sinks
  (`OC/src/syntax/tokenizer.odin:12`).
- The fork's returns owned `string`s and reports through a `Pos`-based
  `Error_Handler` (`FORK/core/odin/tokenizer/tokenizer.odin:100`,`:140`).

**Recommendation: keep ours**, because the byte-range/no-alloc contract is what
the architecture wants, and it already has the lossless-offset property the fork's
model does not. But record the fork as the informing reference, and **align the
token kinds** (`B_Custom_Keyword_*` range, `token.odin:31`+) and adopt the
keyword-LUT approach rather than a long `switch`. This is the one case where a
"duplicate" is a justified adaptation, and it must be documented as such per
`AGENTS.md`.

### 2.2 `OC/src/x64/encode.odin` vs `FORK/core/rexcode/isa/x86` — **DUPLICATE; recommend REPLACE**

`OC/src/x64/encode.odin` (1194 lines) is a hand-written subset encoder:
`emit_reg_reg`/`emit_reg_mem`/`encode_mem` and per-mnemonic procs for a few dozen
instructions. `FORK/core/rexcode/isa/x86` (17,566 lines) is a **table-driven
full x86-64 encoder/decoder** covering REX/VEX/EVEX, ~1176 mnemonics, verified
against LLVM-mc. Our file is the textbook case of the wheel the rule tells us not
to reinvent.

**Recommendation: replace.** Adapt `rexcode/isa/x86` (vendor the needed subset:
`registers`, `operands`, `encoding_types`, `tables`, `mnemonics`, `encoder`,
`encoder_match`, `reloc`, plus the chosen `mnemonic_builders`, and the shared
`isa/labels.odin`). Keep, at most, the current `Emitter` label/fixup convenience
only if it earns its place over rexcode's `Label_Map`/`Label_Definition`
(`FORK/core/rexcode/isa/labels.odin`). The typed `inst_*` builders double as the
instruction-selection target, so adapting the encoder also gives the selector a
compile-checked instruction vocabulary.

### 2.3 `OC/src/elf` writer vs `REFS/go/.../ld/elf.go` — **NOT an Odin duplicate; recommend KEEP**

There is **no Odin ELF writer to adapt**: `FORK/core/encoding` has no ELF and
`FORK/core/debug` has only `pe` and `trace`. So `OC/src/elf/writer.odin` +
`types.odin` (REL-only) is new work, not a duplicate of anything in-language. It
overlaps Go's `elf.go` conceptually (both emit ELF), but Go is not an Odin
reference we can import.

**Recommendation: keep and extend.** Cross-check the constants and layout against
`REFS/go/src/cmd/link/internal/ld/elf.go` and the `elf.5` man page; add the
`ET_EXEC` path (§1.6) as new code. This is the one "already-written" package that
is not a wheel re-invention.

---

## 3. Core packages from the fork: use directly vs copy

The new `AGENTS.md` rule (no third-party dependencies, no libc, talk to the
kernel through `core:sys/linux`) changes which `core` packages are safe.

### Use directly (import `core:...` / `base:...`)

| Package | Why it is safe / useful |
|---|---|
| `FORK/core:strings` | `strings` helpers and `Intern` (`strings/intern.odin:37` `intern_init`, `:69` `intern_get`) for identifiers/type names. |
| `FORK/core:container/topological_sort` | `Sorter`/`Relations` (`topological_sort.odin:9`+): global-entity ordering and scheduling. |
| `FORK/core:container/{pool,priority_queue,queue,small_array,intrusive/list,rbtree,avl,lru}` | Worklist and lookup structures for the IR/scheduler/checker. |
| `FORK/core:mem` | Allocators (`allocators.odin`, `tracking_allocator.odin`). |
| `FORK/core:mem/virtual` | `Arena` (`virtual/arena.odin:49` `arena_init_growing`, `:66` static, `:78` buffer) — the per-phase IR/type arenas the architecture asks for. |
| `FORK/core:sync` | Futex primitives on Linux import `core:sys/linux` (`sync/primitives_linux.odin:5`) — **libc-free**, safe. |
| `FORK/core:os` | Linux backend imports `core:sys/linux` (`os/file_linux.odin:9`, `pipe_linux.odin:4`, `dir_linux.odin:4`) — **libc-free**, safe for reading source files. |
| `FORK/core:sys/linux` | The syscall surface (`syscall_amd64.odin`, `sys` constants, `wrappers.odin` futex `:137`). The required kernel interface. |
| `FORK/core:path` | Collection/path resolution (`core:`, `base:`), matching the C++ `path.cpp`. |
| `FORK/core:flags` | CLI parsing for `driver`. |
| `FORK/core:slice`, `FORK/core:sort` | Deterministic ordering; needed everywhere. |
| `FORK/core:strconv`, `FORK/core:unicode`, `FORK/core:unicode/utf8` | Number formatting and rune classification (tokenizer, diagnostics). |
| `FORK/core:encoding/hex` | Hex dumps for `-dump`/diagnostics. |
| `FORK/core:fmt`, `FORK/core:io`, `FORK/core:bufio`, `FORK/core:bytes` | Output and byte buffers. |
| `FORK/base:intrinsics` | `syscall`, `type_is_*`, `size_of`/`align_of` (note `base/runtime/virtual_memory_linux.odin` uses `intrinsics.syscall` directly for `mmap`). |
| `FORK/base:runtime` | `Allocator`/`Allocator_Error` interface the architecture's style depends on. |
| `FORK/core:odin/{tokenizer,ast,parser,doc-format,printer,format}` | Source references to adapt (§1.1), not to import blindly. |
| `FORK/core:rexcode/isa/x86`, `FORK/core:rexcode/isa`, `FORK/core:rexcode/ir` | To adapt/vendor for `x64` and to inform `ir` (§1.3, §1.5). |

### Do **not** use directly (libc); copy or route around

| Package | Problem | Action |
|---|---|---|
| `FORK/core:sys/posix/*` | `foreign import ... "system:c"` throughout (e.g. `posix/fcntl.odin:9`, `posix/dirent.odin:9`) — it is a **libc binding**. The new `AGENTS.md` forbids linking libc. | Avoid. Use `core:sys/linux` instead. |
| `FORK/core:thread` (default unix path) | `thread/thread_unix.odin:7` imports `core:sys/posix` (libc). | Use the fork's **no-CRT** path `core/thread/thread_linux_no_crt.odin` (imports `core:sys/linux`, `:8`), or copy that file's approach into the compiler. Verify which variant a given build selects before relying on it. |
| `FORK/core:os` on non-Linux | Other OS backends use posix/libc. | Linux-only target makes this moot; do not build the Windows/macOS paths. |
| Any package pulling `base/runtime`'s **managed** allocator/libc startup | The compiler must be owned/no-CRT. | Use the no-CRT runtime path the fork already ships (`base/runtime/entry_unix_no_crt_linux_amd64.asm`, `entry_linux_no_crt_test.odin`) until our own `_start` exists. |

**What must be copied into the project rather than imported:** in principle,
nothing under `core:`/`base:` — import it. The things worth *vendoring into
`src/`* are the **fork sources we are adapting**, not `core` packages:

1. `FORK/core/rexcode/isa/x86` (+ `isa/labels.odin`, `label_infer.odin`) into the
   `x64` package area, trimmed to the subset we keep — vendored, not imported, so
   we can shape the public surface to the compiler's needs and pin it.
2. The token/ast/parser **shape** from `FORK/core/odin/*` into `syntax`, ported to
   index-based handles. Copying the file and changing the storage is the intended
   "adapt", per `AGENTS.md`.
3. If `core:thread`'s default path is libc-bound for our build, copy
   `thread_linux_no_crt.odin`'s syscall-based thread creation into the compiler
   runtime rather than depend on a libc path.

Everything else (`mem`, `container`, `strings`, `sync`, `os`, `sys/linux`,
`path`, `flags`, `slice`, `sort`, `strconv`, `unicode`, `fmt`) is imported
directly.

---

## 4. Reference map (one line per package)

| Package | Best reference(s) | Adapt vs rewrite | Single most important lesson |
|---|---|---|---|
| `syntax` | `FORK/core/odin/tokenizer/{token,tokenizer}.odin`, `ast/ast.odin`, `parser/parser.odin`, `doc-format/` | Adapt grammar/kinds; rewrite storage to index-based | Copy the *tree of node kinds*, not the pointer graph; make it arena+`distinct u32` now. |
| `types` | `FORK/src/types.cpp`, `check_type.cpp` (spec); `core:strings` intern; `core:container` | Rewrite; C++ is the spec | Type identity is canonicalization + deterministic ids, not names. |
| `ir` | `FORK/core/rexcode/ir/*`, `rexcode/docs/ir_design.md`; `docs/research/02` (§1,§4,§7) | Adapt vocabulary; write SoN + scheduler + verifier | Explicit effect/control edges + verifier + text dump in commit 1; ids deterministic; no map-order dependence. |
| `check` | `FORK/src/check_*.cpp`, `checker*.cpp/hpp` | Rewrite in the C++'s own order | The checker *is* the language; keep it pure over `syntax`+`types`; don't let IR decisions leak in. |
| `x64` (encoder) | `FORK/core/rexcode/isa/x86` | Adapt/vendor | Encoder stays pure/deterministic over explicit operands; selection and allocation live above it. |
| `x64` (isel/regalloc) | none in-clone; `docs/research/02:228`–`:230`, QBE §131 | Rewrite | Model early/late positions, fixed `rax`/`rdx`/`cl`, caller-saved clobbers, 16-byte alignment from the first interval. |
| `elf` | `OC/src/elf` (REL, keep); `REFS/go/.../ld/elf.go`; `zig ElfFile.zig`; ELF spec (external `elf(5)`) | Keep REL; rewrite/extend for EXEC | REL and EXEC are different products; layout-then-patch (Go `fixElfPhdr`). |
| `link` | `REFS/go/.../ld/{lib,data,symtab,deadcode,elf}.go`; `core:sys/linux` | Rewrite, structured like Go's `ld` | Resolve all symbols, assign all addresses, then apply relocations — never interleave. |
| `driver` | `FORK/src/{main,build_settings,path}.cpp`; `core:flags`, `core:path`, `core:os` | Rewrite; reuse core CLI/path | Determinism is a driver duty; merge parallel work in index order, not completion order. |

---

## 5. Explicit gaps (so nothing is silently assumed)

- **No Go x86 encoder / Go regalloc / `cmd/compile`** in `REFS` — only
  `cmd/link/internal/ld`, `runtime`, `syscall`, `internal/runtime`.
- **No LLVM `lib/`** (`MC`, `CodeGen/RegAlloc*`, `FastISel`) — only `compiler-rt/`.
- **No Zig compiler source** — only `lib/std` (`Target/x86.zig`, `os/linux/*`,
  `debug/ElfFile.zig`).
- **No Sea of Nodes implementation** anywhere in `REFS` or `FORK`.
- **No x86-64 System V psABI, no ELF gABI/psABI format spec, no DWARF standard**
  in `REFS/rfcs`; the corpus has Linux-specific ELF/auxv docs and syscall
  material only (§0.1).
- `REFS/go/src/cmd/link/internal/ld` gives the linker + ELF writer but **not** the
  object-file loader that feeds it; our loader is ours.
- `REFS/alloc/llvm-project/compiler-rt` is the only LLVM content and is relevant
  only to the runtime (128-bit division, etc.), not to codegen.

If any of the missing references are needed (e.g. for regalloc), they must be
fetched into `REFS` first; do not proceed on memory of their contents.

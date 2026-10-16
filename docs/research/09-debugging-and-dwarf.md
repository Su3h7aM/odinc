# Debugging and DWARF — research

Scope: debugging support for a pure-Odin Odin compiler on Linux x86-64.
Two directions: (a) debugging programs our compiler produces, (b) debugging
the compiler itself (an Odin program) during development.

Prior-art check (per `AGENTS.md`):

1. Our tree first: `core/debug/` has only `pe/` and `trace/` — no DWARF, no
   `.eh_frame` helper (`/home/su3h7am/Projects/odin-compiler/core/debug`,
   `/home/su3h7am/Projects/odin-compiler/src/elf/{writer,types}.odin` is the
   in-progress ELF writer). Reuse `src/elf` + `core:rexcode/isa/x86`.
   Source-location plumbing already exists: `base/runtime/core.odin:378-382`
   (`Source_Code_Location`), `core/mem/tracking_allocator.odin:12-35`,
   `core/debug/trace/*`. ptrace is already wrapped:
   `core/sys/linux/sys.odin:1602-1623`,
   `core/sys/linux/bits.odin:1764-1851`, `types.odin:1426-1489`.
2. Official repos: Odin emits DWARF today only via LLVM DIBuilder
   (`/home/su3h7am/Projects/Odin/src/llvm_backend_debug.cpp`,
   `llvm_backend_general.cpp:110-133`, `llvm_backend.cpp:3967-4018`); the
   closed PR #7850 (`https://github.com/odin-lang/Odin/pull/7850`) prototype
   emitted DWARF 4 + `.eh_frame` by hand — see
   `docs/research/07-pr7850-lowering-abi-elf-dwarf.md` §§4–5/§7, do not
   re-derive DIE shapes or CIE bytes here.
3. Refs: `/home/su3h7am/Projects/refs/go/src/cmd/link/internal/ld/dwarf.go`
   (linker-side DWARF emission reference) and
   `/home/su3h7am/Projects/refs/zig/lib/std/dwarf*.zig` +
   `lib/std/debug/Dwarf*.zig` (opcode constants, parser/unwinder only —
   this checkout has no Zig DWARF emitter). No local copies of the DWARF
   standard, psABI, or ELF gABI exist under `/home/su3h7am/Projects/refs`
   (verified by glob/grep; only unrelated PDFs) — cite by URL below.
4. Vision check (`docs/research/01-gingerbill-vision.md`): simplest efficient
   solution, idiomatic Odin, no language changes. Staged DWARF (symbols →
   lines → types) fits; a from-scratch symbolic debugger does not.

## 1. RAD Debugger (raddbg) — Linux status and Odin integration

Upstream: `https://github.com/EpicGames/raddebugger` (README, roadmap,
`src/{lib_rdi,rdi_from_dwarf,demon,ctrl,elf,dwarf,eh}` layer list).

### 1.1 What is supported today vs experimental

- Supported today: local-machine Windows x64 with PDBs only. README: "It
  currently only supports local-machine Windows x64 debugging with PDBs,
  with plans to expand and port in the future."
- Linux x64 debugging is an explicit *future phase* ("Local x64 Linux
  Debugging Phase"), not alpha-bullet-proofing. Work items listed upstream:
  port `src/demon` (process-control abstraction) to Linux, implement an
  x64 ELF Linux unwinder in `src/ctrl`, create a DWARF-to-RDI converter
  (partial implementation in `src/rdi_from_dwarf`), port `src/render`
  (D3D11 → Linux GPU API), `src/font_provider` (DirectWrite → e.g.
  FreeType), and `src/os` (core + gfx) layers.
- What builds on Linux today: the debugger *itself* builds on Linux x64
  (`build.sh`; needs GCC or Clang + `libfreetype6-dev libx11-dev
  libxext-dev libxfixes-dev libxrandr-dev libgl-dev libegl-dev` on
  Debian-likes). That is a build-host port (UI + libs), distinct from
  *debugging Linux targets* — do not conflate them. Build-mode note from
  README: default build is debug (unoptimized); `./build.sh release` for
  release; `./build.sh radlink|radbin [release]` for linker/converter.
- ptrace backend status: Uncertain — no Linux `demon` implementation to
  inspect was fetched for this doc. Expect `PTRACE_SEIZE` + `PTRACE_O_*`
  event stops + `waitpid(__WALL)` + `PTRACE_GETREGSET/SETREGSET`, per
  `https://man7.org/linux/man-pages/man2/ptrace.2.html`. Mark any claim
  about raddbg using a specific ptrace op as [uncertain] until
  `src/demon` Linux code lands.
- Issue tracker signal: `https://github.com/EpicGames/raddebugger/issues/23`
  ("Linux build support", closed) confirms Linux was roadmap-after-Windows
  from Jan 2024; maintainer reply points at stale `os/core/linux` backend.
- Community forks mentioning DWARF/RDI are experimental (e.g. source-map
  fork `jamesnolanverran/raddebugger`, `joelvaneenwyk/rad-debugger`
  "highly experimental" banner). Treat non-upstream DWARF claims as
  [uncertain].

### 1.2 RDI, radbin, and what our compiler must emit

- RDI (RAD Debug Info) is raddbg's *own* format: "specified in code" in
  `src/lib_rdi/{rdi.h,rdi.c}` (+ parse helpers `rdi_parse.{h,c}`), with an
  in-progress constructor library `src/lib_rdi_make`. The debugger parses
  RDI, never PDB/DWARF directly.
- Conversion is on-demand: PDB now, "eventually PE/ELF files with embedded
  DWARF". Converter layers: `rdi_from_pdb` (working), `rdi_from_dwarf`
  (in-progress, D2R_), `rdi_from_elf` / `rdi_from_coff` (container data).
  `radbin` (also `raddbg --bin`) converts native formats to RDI and dumps
  RDI textually.
- Consequence for us: **emit standard DWARF in ELF; do not emit RDI.**
  RDI conversion is the debugger's job (at load or via `radbin`). Our only
  raddbg-specific output is the additive `.raddbg` section below. If
  `rdi_from_dwarf` lags, our binaries still debug under gdb/lldb — raddbg
  support follows their converter, not our emitter.
- [Uncertain]: exact DWARF subset `rdi_from_dwarf` currently handles
  (which tags/forms/line-opcodes, DWARF 4 vs 5). Verify against
  `src/rdi_from_dwarf` before relying on raddbg for a given construct;
  prefer DWARF 5 with a DWARF-4-compatible subset (see §2) to maximize
  converter + gdb/lldb coverage.

### 1.3 How Odin integrates today (fork, LLVM path)

All paths under `/home/su3h7am/Projects/Odin/src`; all emission gated on
`-debug` (`build_context.ODIN_DEBUG`), and the `.raddbg` part additionally
Windows-only (verified by subagent read; re-check before quoting beyond
this doc):

- Flags (`main.cpp:713,694,834,722`): `-debug` sets `ODIN_DEBUG=true` and
  *defaults* `-o` to `none` unless `-o:` is explicit
  (`build_settings.cpp:2149-2157`); `-o:none|minimal|size|speed|aggressive`
  maps none→-1; `-sanitize:address|memory|thread`
  (`build_settings.cpp:439-443,556`); `-no-crt`. No `keep_debug` /
  `strip_debug` flags exist (only linker passthrough `--strip-debug` in
  `no_crt_selection.cpp:260`).
- DWARF version (`llvm_backend_general.cpp:110-133`): `Debug Info
  Version=3`, Windows `CodeView=1`, Linux/Darwin `Dwarf Version=5`
  (comment: other targets keep LLVM default DWARF 4). Compile unit
  (`llvm_backend.cpp:4004-4017`): `DWARFSourceLanguageC99`,
  `producer="odin"`, `EmissionFull`, `is_optimized = level>0`. File MD5
  checksums on LLVM ≥ 22 (`llvm_backend_debug.cpp:21-73`).
  `debug-info-assignment-tracking` pass only at `-o:minimal`+ 
  (`llvm_backend.cpp:3021-3026`) — default `-debug` (`-o:none`) lacks it.
- `.raddbg` section (`llvm_backend.cpp:4213-4231, 4283-4394`): each string
  becomes a `raddbg_data__N` global in section `.raddbg`, plus
  `raddbg_is_attached_byte_marker` and `entry_point: "<mangled>"`. Content:
  built-in `type_view:` rules (slices/strings/dynamic arrays, `bswap` for
  `be` ints, `columns()` for matrices, SOA-slice `rows()`, union
  `tag==N ? vN : …`) and per-user `@(raddbg_type_view)` rules.
- `@(raddbg_type_view)` (`checker.cpp:5160-5174`, `7696-7958`,
  `check_decl.cpp:609-614`, `checker.hpp:175-176,793-796,876-877`):
  on a type declaration, optional string value = display expression,
  emitted verbatim; empty value auto-generates `rows($, …)` only for
  structs whose fields carry `raddbg:"…"` / `raddbg:"-"` (skip) or
  `fmt:"<fmt>,<len>"` tags (translated to `bin/dec/hex/oct/digits/array`
  calls). User views sort before generated ones so "user wins"
  (`llvm_backend.cpp:4363-4375`). No `core/` or `base/` usage exists
  (grep hits only `src/` + `.gitignore:309` `*.raddbg`).
- gdb/lldb path stays primary on Linux: `.debug_gdb_scripts` embeds
  `base/runtime/odin_debugger.py` (`llvm_backend.cpp:4178-4211`), which
  pretty-prints strings/slices/dynamic/maps/unions/`any`/SOA by *field
  shape*, not names (`odin_debugger.py:94-111, 258-277`). See §4 quirks.

What this means for our backend: replicate (a) standard DWARF, (b) the
`.debug_gdb_scripts` + field layouts the Python printers key on, and
(c) optionally the `.raddbg` strings (cheap: NUL-terminated
`type_view:`/`entry_point:` text in a `PROGBITS` `.raddbg` section).
(a)+(b) give gdb/lldb now; (c) is forward-compat for raddbg-on-Linux and
harmless to other tools.

## 2. Official specs to follow

Fetch these; `refs/` has no local copies (§0, point 3).

- DWARF 5: `https://dwarfstd.org/dwarf5std.html`,
  `https://dwarfstd.org/download.html`,
  PDF `https://dwarfstd.org/doc/DWARF5.pdf` (+ DWARF 4 PDF on the same
  downloads page for the fallback subset). Major v5 changes relevant here:
  `.debug_types` merged into `.debug_info`; `.debug_loc`→`.debug_loclists`
  and `.debug_ranges`→`.debug_rnglists` (indexed `loclistx/rnglistx`,
  less relocation); `.debug_pubnames/.debug_pubtypes`→`.debug_names`;
  revised line-table header; new forms (`addrx/strx/strp_sup/…`,
  `implicit_const`); call-site tags. Sections to implement against:
  `.debug_info/.debug_abbrev/.debug_line/.debug_str` (+ v5
  `.debug_line_str/.debug_addr/.debug_str_offsets`), `.debug_aranges`
  (optional index), `.debug_frame` vs `.eh_frame` (below),
  `.debug_loclists/.debug_rnglists`.
- x86-64 psABI: `https://refspecs.linuxbase.org/elf/x86_64-SysV-psABI.pdf`
  (mirror `https://cs61.seas.harvard.edu/site/2025/pdf/x86-64-abi-20210928.pdf`,
  `https://github.com/rui314/psabi/blob/main/x86-64.pdf`).
  §3.6 DWARF register-number mapping (Figure 3.36; return address is a
  pseudo-register even though it lives at `0(%rsp)`), §3.7 stack-unwind
  algorithm, §4 object files incl. `EH_FRAME` sections. psABI requires
  unwind tables for *every* function
  (`https://github.com/llvm/llvm-project/issues/14121` discussion).
- `.eh_frame` vs `.debug_frame`: `.eh_frame` is loaded at runtime
  (`PT_GNU_EH_FRAME`, `zR` augmentation, synchronic, LSDA pointers) and
  drives unwinding; `.debug_frame` is debug-section-only with the same CIE/FDE
  machine but DWARF pointers/relocations. Assembler control:
  `.cfi_sections .eh_frame[,.debug_frame]`, default `.eh_frame`
  (`https://sourceware.org/binutils/docs/as/CFI-directives.html`).
  GDB consumes both (`gdb/dwarf2-frame.c`, `eh_frame_p` flag). Our stage 0
  emits `.eh_frame` (runtime-correct unwinding, `perf`/C++-unwind reuse);
  `.debug_frame` is optional duplication — prefer emitting only `.eh_frame`
  + DWARF CFI-less frame_base until a consumer needs both. Doc 07 §4 gives
  the exact CIE bytes our prototype used (`version=1,"zR",code_align=1,
  data_align=-8,RA=16,aug 0x1b`; CFA `rsp+8`); cite, don't re-derive.
- Line-number program: DWARF 5 §6 (or DWARF 4 §6 for the subset):
  per-CU program in `.debug_line` with revised v5 header
  (directory/file tables, `line_strp` forms), standard opcodes
  (`copy/advance_pc/advance_line/set_file/set_column/…`), extended opcodes
  (`end_sequence/set_address/define_file`), special opcodes, `prologue_end`
  / `epilogue_begin` / `is_stmt` flags. Minimum viable: one CU, one file
  entry per module, `set_address + advance_line/copy` rows, `end_sequence`.
- ELF gABI: generic ELF `https://refspecs.linuxbase.org/elf/` (gABI
  chapters 4–5: sections, `SHT_PROGBITS/NOBITS`, `SHF_ALLOC/EXECINSTR`,
  symbol table, relocations). Debug sections are non-`SHF_ALLOC`
  `PROGBITS` (except live `.eh_frame`); keep `sh_offset` 0-based
  section-relative DWARF with `REL`/`RELA` where the linker expects them.
- Linux tracing (no local `2-ptrace.md` — confirmed gap in
  `/home/su3h7am/Projects/refs/rfcs/linux/man-pages`, `2-*` jumps
  `prlimit64 → process_madvise`): use
  `https://man7.org/linux/man-pages/man2/ptrace.2.html` (ops
  `TRACEME/ATTACH/SEIZE/INTERRUPT/LISTEN/CONT/SYSCALL/SINGLESTEP/
  SYSEMU/GETREGSET/SETREGSET/PEEKTEXT/POKEDATA/GETSIGINFO/SETOPTIONS/
  GETEVENTMSG/GET_SYSCALL_INFO`, `PTRACE_O_TRACECLONE/FORK/VFORK/EXEC/
  EXIT/SECCOMP/TRACESYSGOOD`, `PTRACE_EVENT_*` stops, `__WALL` waitpid,
  signal-injection vs group-stop semantics). Local stand-ins that *do*
  exist: `refs/rfcs/linux/man-pages/2-process_vm_readv.md`
  (+ `2-process_vm_writev.md`), `2-waitid.md` (+ `2-wait4.md`),
  `2-rt_sigaction.md` (+ `2-rt_sigprocmask.md`, `7-signal.md`),
  plus `2-pidfd_open.md`, `2-clone.md`/`2-clone3.md` (`CLONE_PTRACE`),
  `2-tkill.md`/`2-tgkill.md`. In-tree wrappers: `core/sys/linux/sys.odin`,
  `bits.odin`, `types.odin`, `syscall_amd64.odin` (`SYS_ptrace = 101`).
- "GDB JIT-free basics" (assumption: standard AOT debugging, *not* the
  `__jit_debug_register_code` JIT interface — that interface,
  `https://sourceware.org/gdb/current/onlinedocs/gdb/JIT-Interface.html`
  (`Declarations`/`Registering-Code`), in-memory ELF + descriptor +
  breakpoint, is out of scope for an AOT compiler; no JIT hooks needed):
  `gdb --args ./prog`, `break file:line`, `run`, `bt`, pending breakpoints
  for not-yet-loaded objects; `.debug_gdb_scripts` auto-load needs
  `add-auto-load-safe-path`. Forum workflow confirms current Odin reality:
  `odin build -debug -o:none`, "might only give assembly, not Odin code"
  without it (`https://forum.odin-lang.org/t/debugging-odin-using-gdb/1119`,
  Jul 2025; also `https://odin-lang.org/docs/faq`, discussion
  `https://github.com/odin-lang/Odin/discussions/2325` for sanitizer/X-ray
  context).

## 3. Minimal staged plan (Linux x86-64)

Principle: each stage is usable with stock gdb/perf; raddbg rides along
once its DWARF→RDI converter lands (§1.2). IR/lowering must preserve the
inputs each stage consumes — columns are requirements, not wishes.

### Stage 0 — frame pointers + symbols (no DWARF)

Emit: `push rbp; mov rbp,rsp` prologue in every proc (matches PR #7850
`incoming_base=16` frame model; doc 07 §1/§3), full `symtab` + `strtab`
(function + global symbols, size + type), valid `.eh_frame` CIE+FDE per
proc (doc 07 §4 bytes). Result: `gdb bt`, `perf record/call-graph`,
`addr2line -e -f -C` work; no source lines yet.
IR/lowering must preserve: proc symbol names (mangled Odin canonical
names — the same strings `typeid`/pretty-printers hash), proc byte ranges
(start/size; FDE `initial_location/address_range` source), per-proc frame
size + callee-save layout (so FDE CFA/CFA-offset rules are exact, not
`rsp+8` guesswork), no red-zone use under the frame pointer contract.

### Stage 1 — line table only

Emit: `.debug_info` skeleton (one CU + one `DW_TAG_subprogram` per proc
with `low_pc/high_pc`) + `.debug_abbrev` + `.debug_line` program
(`set_address/advance_line/copy/end_sequence`, `prologue_end`, `is_stmt`);
`.debug_str` optional (else `FORM_string`, accepting doc-07 debt
knowingly). Result: `gdb step/list/break file:line`, `perf annotate`
source correlation.
IR/lowering must preserve: **source location on every IR node**
(`file,line,column`, CU-relative file index) from AST → IR → machine
instr; *do not* drop locations in peepholes/inlining (or mark
`is_stmt=0`); instruction→address mapping at emission time (address +
row delta per machine instr; suppress zero-length rows); cold-blocks-last
layout must still emit rows in *address* order per `end_sequence` ranges.
DWARF 5 line header (`directory/file` tables, MD5 per
`llvm_backend_debug.cpp:21-73` precedent) — keep v4-compatible opcode
subset so partial converters (raddbg D2R_) still parse.

### Stage 2 — variables/types (DWARF 5)

Emit: full DIEs per proc — `subprogram`, `formal_parameter`,
`variable`/`constant`, `lexical_block` (with ranges), base/pointer/
struct/member/array/typedef/enum/union/subroutine types in `.debug_info`
(+ `.debug_loclists`/`.debug_rnglists` with `loclistx/rnglistx` at v5;
fall back to `.debug_loc/.debug_ranges` only if a consumer demands v4),
`frame_base = DW_OP_fbreg 0` off single-`rbp` (doc-07 single-byte
`rbp` precedent), locations via `OP_addr/breg/reg/fbreg/deref`
(+ `DW_OP_GNU_entry_value` only where proven). Result: `gdb print/locals`,
lldb synthetic children, future raddbg eval.
IR/lowering must preserve, in addition to stages 0–1: **variable→value
mapping** per program point (which stack slot / register / `breg+offset`
holds each source variable; spill/reload updates; location lists over
ranges, not single addresses); **scope ranges** (lexical block
start/end PCs, shadowing generations, inlined-subroutine call sites if we
ever inline at `-o:none` — preferably never); type identity through
monomorphization (canonical type string per DIE, hashed dedup with
CU-relative `ref4` patching per doc 07 §5; `string`→`{data,len}`,
slices/dynamics/`any`/map-union layouts *identical* to what
`odin_debugger.py:94-111` keys on, else printers silently stop matching);
`is_optimized=false`, and defer `debug-info-assignment-tracking`
equivalents until an optimizer exists.

Explicit non-goals per stage: split-DWARF/`.dwp`, `.debug_names` index,
macro sections, call-site tags, LTO-aware locations — all deferrable
without breaking gdb `bt/step/print`.

## 4. Debugging the compiler itself during development

The compiler is an Odin program built today by the fork's LLVM path; all
of these work *now*, before our backend exists.

- `odin -debug` + gdb/lldb/raddbg: build with `odin build -debug -o:none`
  (forum-verified gdb recipe; §1.3 for what `-debug` enables). gdb:
  `source base/runtime/odin_debugger.py` or rely on auto-load from
  `.debug_gdb_scripts` (+ `add-auto-load-safe-path <dir>`);
  `set odin-map-hint off` for VS Code C/C++ front-ends that mishandle the
  `map` display hint (`odin_debugger.py:16-17`). lldb: `command script
  import base/runtime/odin_debugger.py`, needs
  `settings set target.load-script-from-symbol-file true` on macOS dSYM
  (`odin_debugger.py:3-8`); LLDB ≤ 14 matches by regex not recognizer fn
  (`__lldb_init_module`, `:974-998`). raddbg on Windows: open the `.pdb`
  + `.exe`; `.raddbg` views apply automatically; on Linux use gdb/lldb
  until the Linux-debug phase lands (§1.1).
- `-sanitize`: `-sanitize:address|memory|thread` (`main.cpp:834,1951-1968`);
  OS gates `build_settings.cpp:2693-2727` (address: Win/Linux/Darwin/
  FreeBSD; memory: Linux/FreeBSD; thread: Linux/Darwin/FreeBSD);
  incompatible with `-no-crt` (`:2730-2733`); per-proc LLVM attrs
  (`llvm_backend_proc.cpp:452-459`), opt-out `@(no_sanitize_address|memory|
  thread)` (`checker.cpp:4831-4847`). Use ASan/MSan/TSan builds of the
  compiler to catch memory/thread bugs that DWARF-level debugging only
  observes after the fact.
- `core:testing` + tracking allocator: default failure path prints
  `entry.location.file_path/line/procedure`
  (`core/testing/reporting.odin:308-335`, entries carry
  `runtime.Source_Code_Location` from `core/mem/tracking_allocator.odin`);
  run test binaries under gdb with `break __debugbreak` / `SIGTRAP` catch
  to land exactly on the failing assert.
- `core:debug/trace`: `trace.odin:9,15,49-80,99-156`, `doc.odin:1-49`.
  Linux default resolves via fork+exec `addr2line`
  (`trace_linux.odin:50-351`, `SYMBOLIZER_PROGRAM`, `trace.odin:28`) —
  needs stage-0 symbols, no DWARF; or opt into instrumentation mode
  (`-define:ODIN_TRACE_INSTRUMENTATION_MODE=true`,
  `trace_instrumentation.odin:17-28`, requires `-o:minimal`+ and
  single-module) where entries *are* `Source_Code_Location` and DWARF is
  irrelevant. `trace/allocator.odin` wires locations into allocation
  tracking — cheapest first heap-corruption evidence.
- Odin DWARF quirks that matter when reading compiler debug sessions:
  Linux gets DWARF 5, Windows CodeView (`llvm_backend_general.cpp:124-131`);
  CU language is C99 with `producer="odin"` (so C-oriented expression
  defaults; Odin semantics come from DIE shapes + printers, not language
  code); default `-debug` is `-o:none` *without* assignment tracking —
  variable locations vanish across calls; re-run with `-o:minimal` for
  better `print locals`; pretty-printers key on field *shapes*
  (`{data,len}`, `{data,len,cap,allocator}`, map-metadata
  `{key,value,hash,key_cell,value_cell}`, union `v<tag>+tag`,
  `any {data,id}`) — any backend layout drift breaks them with no error;
  `any`/`typeid` resolution hashes canonical names
  (`typeid_hash`, `:58-84`) so renamed/mangled symbols break `any` display;
  every target is little-endian (`:26`); lldb shortens some names, hence
  the hash-match fallback (`:593-643`); maps read live memory in 1 KiB
  chunks with tombstone/capacity guards (`:164-194`) — a corrupt map
  shows truncated, not crashed, which can mislead.

## Open questions / verification owed

1. [Uncertain] raddbg `rdi_from_dwarf` coverage (tags/forms/DWARF 5) —
   read `src/rdi_from_dwarf` upstream at implementation time.
2. [Uncertain] raddbg Linux `demon` ptrace op set — same, `src/demon`.
3. DWARF 5 vs 4 default for *our* emitter: recommend DWARF 5 with a
   v4-parseable subset (v5 headers + classic location/range encodings
   until stage 2 proves `loclists/rnglists` with gdb ≥ 8, lldb ≥ 10,
   and D2R_).
4. Whether to emit `.debug_aranges` / `.debug_names`: defer; gdb builds its
   own index, and both sections are optional.

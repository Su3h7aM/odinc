# Linker options for a pure-Odin Odin compiler (Linux x86-64)

Scope: how the pure-Odin compiler should turn its output into a runnable
Linux x86-64 program. Four families are evaluated: (A) our own general
static linker, (B) whole-program fused linking (no separate link step for
pure Odin), (C) shelling out to mold / lld / GNU ld, (D) other integrated
designs. This is a decision document with a staged path, not a full design.

Status of every claim: factual claims carry a URL or a local path. Where a
source could not be fetched or a term is not standard, it is marked
*uncertain*. Nothing here is invented; where I could not verify, I say so.

---

## 0. Recommendation in brief

- **Target the end state of option B implemented through the reusable core
  of option A.** Write one `link` package that consumes in-memory atoms
  (sections, symbols, relocations) handed over by code generation, performs
  symbol resolution, relocation, section merging/layout and `gc-sections`,
  and writes a **static non-PIE `ET_EXEC`** directly. This is the shape the
  fork's `no_crt` runtime already assumes and the shape `src/elf` already
  emits.
- **Keep option C (clang driver / mold) as an explicit fallback during the
  transition only.** It is the current status quo and is not the
  destination: the project rules require the compiler to be pure Odin and
  forbid external linkers "in the end state" (`docs/research/00-synthesis.md`).
- **Do not build a general-purpose linker now.** Archives, linker scripts,
  symbol versioning, LTO, IFUNC and large-code-model support are separate
  decisions with their own triggers.
- **Dynamic linking is the hard boundary.** Emitting an executable that the
  OS `ld.so` loads (`PT_INTERP`, `.dynamic`, `dynsym`, GOT/PLT,
  `GLOB_DAT`/`JUMP_SLOT`, RELRO+NOW, TLS models) is well specified but much
  larger than static linking, and is only needed when importing foreign
  `.so`s. That is a *decide later* trigger, not a v1 requirement.

---

## 1. What "linking" must accomplish here

### 1.1 The two distinct cases

Everything in this document is about one question: what must happen
between "we have machine code and data for every package" and "the kernel
can `exec` a file".

1. **Pure Odin program, no foreign libraries** — the fork's owned/
   `ODIN_NO_CRT` track. All packages are known to the compiler; there are
   no external objects. Today this is a **static non-PIE executable**
   (see §1.4).
2. **Anything with foreign imports, `-build-mode:obj`, `:lib`, `:shared`,
   or PIE** — the managed track. This is where dynamic linking, archives
   and relocatable output live.

Option B's question ("does the pure-Odin case need a linker at all?") is
answered by case 1: it needs *linking* — address assignment, relocation
resolution, section merging and layout — but it does not need a separate
linker *program* or an object-file interchange. The work is intrinsic; only
the boundary moves.

### 1.2 The concrete work items

From the ELF gABI object-file model and the x86-64 psABI relocation model
(§7 references), a static non-PIE x86-64 linker for our own objects needs:

- Symbol resolution: defined/undefined/weak, common, absolute, section
  symbols; local-before-global ordering.
- Relocation: at minimum what our own code generation emits. Our `elf`
  package already enumerates `R_X86_64_64`, `PC32`, `GOT32`, `PLT32`,
  `GOTPCREL`, `32`, `32S` (`src/elf/types.odin:96-105`). A pure static
  program additionally needs the TLS forms the backend already lowers:
  `TPOFF32`, `GOTTPOFF`, `TLSGD`, `DTPOFF64`
  (`docs/research/07-pr7850-lowering-abi-elf-dwarf.md:352-355`).
- Section merging and layout: `.text`, `.rodata`, `.data`, `.bss`, TLS
  (`.tdata`/`.tbss`), `.eh_frame`/`.eh_frame_hdr`, `.init_array`/
  `.fini_array`, DWARF sections; page-congruent file offsets.
- `gc-sections` / dead-code elimination at symbol granularity. In
  whole-program mode this is "reachability from entry", the same idea Go
  documents: mark from `main`, drop the rest
  (https://internals-for-interns.com/posts/the-go-linker/).
- Program headers: `PT_LOAD` with W^X separated permissions, `PT_GNU_STACK`
  non-executable, and — for dynamic output only — `PT_INTERP`,
  `PT_DYNAMIC`, `PT_TLS`, `PT_GNU_EH_FRAME` (gABI ch5; Linux's own ELF
  idiosyncrasies are in
  `/home/su3h7am/Projects/refs/rfcs/linux/kernel-docs/Documentation/userspace-api/ELF.rst`).
- Determinism: byte-identical output for the same input (project rule in
  `docs/01-architecture.md`).

`src/elf` already provides the ET_REL writer (`src/elf/writer.odin`), the
packed spec structs and relocation enum (`src/elf/types.odin`), and a
minimal static ET_EXEC writer with `PT_LOAD` + `PT_GNU_STACK`
(`src/elf/elf_exec.odin`). Its doc comment states the boundary: "Executable
output (`ET_EXEC`) is not in scope here" for the relocatable writer, and
the executable writer produces "No program interpreter, no dynamic
linking, no section headers" (`src/elf/doc.odin`, `src/elf/elf_exec.odin`).

### 1.3 What Odin on Linux currently needs from clang/ld

Verified in the Odin fork. `linker_stage` shells out; it does **not** link
in-process (`/home/su3h7am/Projects/Odin/src/linker.cpp:402+`,
`docs/research/03-existing-compiler-map.md:338-357`). The Linux-relevant
behaviours currently delegated to the `clang` driver are the acceptance
checklist for any replacement:

- Uses `clang` (`ODIN_CLANG_PATH` or `PATH`) as the front end precisely so
  `libgcc_s`, the dynamic linker path and unwind ordering come from clang's
  built-in specs; Odin passes **no explicit `crt*.o`, no
  `-dynamic-linker`, no search paths** (`linker.cpp:1144-1154`).
- `-pie` when `reloc_mode == PIC`; `-no-pie` otherwise
  (`linker.cpp:1180-1193`). Default Linux reloc mode is
  `linux_no_crt_tls() ? Static : PIC`
  (`/home/su3h7am/Projects/Odin/src/build_settings.cpp:2008-2009`), so the
  managed default is **PIE** and the owned/`no_crt` default is **static
  non-PIE**.
- `-nostdlib` under `no_crt`; `-static` for the `no_crt` TLS executable
  path (`linker.cpp:1119-1123`).
- `-lm -lc` unless `no_crt` (`linker.cpp:1344-1351`).
- `-Wl,-z,now -Wl,-z,relro` (hardened RELRO + immediate binding),
  `-rpath,$ORIGIN` unless `no_rpath`, `-l:path` for `.a/.o/.so` path links
  (`docs/research/07-...md:315-318`, `linker.cpp:1300-1355`).
- `-shared` + `-Wl,-init,_odin_entry_point -Wl,-fini,_odin_exit_point` for
  shared libraries (`linker.cpp:1152-1171`).
- `-fuse-ld=lld` / `-fuse-ld=mold` passthrough (`linker.cpp:1394-1399`).
- Static libraries are made with `ar rcs`, not the linker
  (`linker.cpp:1134-1143`).

`docs/research/07-...md:306-328` already distilled this into an acceptance
list; nothing there is new work for this document.

### 1.4 The owned/`no_crt` runtime fixes the v1 target

The fork's freestanding entry stub is the strongest constraint in this
whole question. `base/runtime/entry_unix_no_crt_linux_amd64.asm` documents
itself as "**Static non-PIE only: static PIE needs self-relocation, which
this stub does not do.**" It:

- reads `argc`/`argv`/`envp` from the initial stack,
- reads the auxiliary vector (`AT_PHDR`, `AT_PHENT`, `AT_PHNUM`,
  `AT_RANDOM`),
- scans program headers, and if a `PT_INTERP` is present it does **not**
  set up TLS (the dynamic loader already did),
- otherwise builds TLS itself via `PT_TLS` + `mmap` + `arch_prctl`
  (`ARCH_SET_FS` = `0x1002`), installing a self-pointer at `%fs:0` and LLVM's
  stack-protector canary at `%fs:0x28`,
- on failure calls `exit_group` (syscall 231) directly.

`base/runtime/tls_linux_no_crt_amd64.asm` implements the psABI Variant II
TLS layout, and `base/runtime/lifecycle_linux_amd64.odin` states it:
"**Static non-PIE executables only: the dynamic loader never runs here, so
nobody else will run these.**" This is the pure-Odin case, and it is a
*static executable with a self-installed TLS block and no libc*. The
minimum viable linker is therefore the static non-PIE one.

Relocations under this target can stay in the **small code model** (all of
text+data within ±2 GiB of a fixed base). That is a real constraint to
encode and verify, not an assumption to hide: `R_X86_64_PC32`/`PLT32`/
`32S` all overflow silently if the ±2 GiB window is exceeded. Go's linker
solves far branches with range-extension thunks
(`refs/go/src/cmd/link/internal/ld/...`); a v1 static linker can instead
**fail loudly on overflow** and grow later.

---

## 2. Prior art (what exists, what we reuse, what is greenfield)

This is the AGENTS.md prior-art pass, recorded before any design is chosen.

**In our own tree (reuse / adapt):**

- `src/elf/types.odin` — packed ELF64 spec structs and the `R_X86_64`
  enum; extend the enum, keep the layout.
- `src/elf/writer.odin` — ET_REL writer with `.symtab`/`.strtab`/
  `.rela.<name>`; the base for `-build-mode:obj`.
- `src/elf/elf_exec.odin` — static `ET_EXEC` writer (segments only); the
  base for the static link path.
- `core:rexcode/isa/x86` — the instruction encoder (already merged
  upstream); relevant to *code generation*, not to linking, but it is why
  our objects will have a small, known relocation set.

**In the Odin fork (adapt behaviour, do not port C++):**

- `src/linker.cpp` — the exact flag set to reproduce (§1.3).
- `src/no_crt_selection.cpp` — the owned/managed selection logic that
  decides when the pure-Odin track applies; its header comment calls the
  owned link plan a "known linker, **static non-PIE** executable"
  (`no_crt_selection.cpp:1-40`).
- `base/runtime/*no_crt*` — the runtime contract the linker must satisfy.

**External, ideas only (no code copy):**

- **Go internal linker** — the canonical "compiler ships its own linker"
  design: a `Loader` builds a global symbol index, dead code is marked from
  `main`, addresses are assigned, relocations patched, segments written.
  Go uses internal linking by default and falls back to external linking
  (clang/gcc) when cgo or arbitrary host objects are involved
  (https://internals-for-interns.com/posts/the-go-linker/,
  https://go.dev/src/cmd/cgo/doc.go §"Internal and External Linking",
  https://pkg.go.dev/cmd/link). This is the closest model to option B/D.
- **Zig's built-in ELF linker** (`src/link/Elf.zig`, the "Elf2"
  implementation) — a from-scratch ELF linker with position-independent
  reloading of already-emitted objects and offsets (`markDirty`,
  `growSection`, `findFreeSpace`, `allocateChunk`), designed for
  **incremental compilation** and shipping the full dynamic-linking
  machinery (`dynsym`, `versym`, `.verneed`, `got`, `plt`, `rela_dyn`,
  `rela_plt`, `copy_rel`, `hash`, `gnu_hash`, `interp` phdr, TLS phdr)
  (https://github.com/ziglang/zig/blob/master/src/link/Elf.zig;
  https://ziglang.org/download/0.17.0/release-notes.html). It is the best
  reference for the *incremental* endgame and for the dynamic section list.
- **lld** — the well-documented architectural reference: `Symbol` /
  `SymbolTable` / `InputSection` / `OutputSection` / `Writer` / `Driver`,
  "do nothing until you have to", and reported ~21k lines of C++ for
  LLD/ELF as of 2017 (https://lld.llvm.org/NewLLD.html,
  https://lld.llvm.org/). It is also embeddable as a library
  (`lld::lldMain`) — relevant to a *host* tool, not to pure Odin.
- **mold** — Rust, MIT, "drop-in replacement", benchmarked at ~4.9× lld and
  ~1.9× wild at the median in its Aug-2026 suite; x86-64 among its targets
  (https://github.com/rui314/mold). An *external program*, not a library.
- **wild** — Rust, Apache-2.0/MIT, x86-64 Linux; fast for iterative
  development, incremental linking not yet implemented
  (https://github.com/wild-linker/wild).
- **Tilde / Cuik (the former Odin "TB" backend)** — explicitly "early work
  on **directly outputting linked executables thus bypassing the need for a
  conventional linker**" (https://yasserarg.com/tb). This validates the
  option-B/D direction independently, but the code was removed from Odin
  (`docs/research/05-github-prior-art.md` §6, PR #6483).
- **radlink** — the only "linker for Odin" in the wild; it is **C**,
  PE/COFF, Windows-only, and is an external binary (not adaptable)
  (`docs/research/05-github-prior-art.md` §2).

**Greenfield:** an Odin-language linker of any kind. `docs/research/
05-github-prior-art.md` §2: "There is **no linker written in Odin** … A
built-in static linker in Odin (any platform) is greenfield."

**On "hard linker":** the term is **not standard** in this sense; the
sources use "internal linker" (Go), "self-hosted/new ELF linker" (Zig) and
"directly outputting linked executables" (Tilde). I treat "hard linker" as
*an in-process, hardwired linker step inside the compiler* and flag the
terminology as uncertain. No source was found that uses the exact phrase.

---

## 3. Option analysis

Each option is judged on: effort, correctness risk, compile speed,
debuggability, dynamic linking / foreign imports, and the non-executable
build modes (`-build-mode:obj/lib/shared`, incremental).

### 3.1 Option A — our own general static linker (`link` over ET_REL → ET_EXEC)

Write a standalone linker that reads our `elf` objects, resolves symbols,
applies relocations, merges/lays out sections, does `gc-sections`, and
writes `ET_EXEC`. This is `docs/01-architecture.md`'s stated plan (`link`
depends on `elf`).

- **Effort:** high *only if general*. A general linker means archives with
  member extraction, `--start-group`-like semantics, linker scripts, common
  symbols, `SHF_MERGE` string merging, COMDAT/`SHT_GROUP`, symbol
  versioning, `--gc-sections` from section roots, ICF, and every
  `R_X86_64_*`. lld/ELF alone was ~21k lines of C++ in 2017
  (https://lld.llvm.org/NewLLD.html), and that excludes archive/script
  completeness. *A linker restricted to our own objects and our own
  relocation set* is far smaller — a few thousand Odin lines — because
  there is no foreign object to parse and no linker script to interpret.
- **Correctness risk:** medium. The classic hazards are deterministic:
  relocation overflow (small code model, §1.4), `.eh_frame` / `.eh_frame_hdr`
  consistency, TLS layout miscount, and weak/common resolution order. All
  are testable against the LLVM-built `odin` as an oracle
  (`docs/01-architecture.md` proposes an IR interpreter for exactly this
  differential testing idea).
- **Compile speed:** excellent. In-process, no process spawn, no disk
  round-trip if codegen hands over in-memory atoms.
- **Debuggability:** best-in-class — our own code, our own diagnostics,
  deterministic, no external version drift.
- **Dynamic linking / foreign imports:** only if extended. Static-only
  first. Foreign `.o`/`.a` inputs require an ELF object reader; foreign
  `.so` imports require the whole dynamic path (§3.4).
- **Non-exec modes:** natural home for `-build-mode:obj` (already have the
  writer) and for incremental relinking.
- **Verdict:** the right *core*, wrong *scope* if attempted generally now.

### 3.2 Option B — whole-program fused linking, no separate link step

Because all packages are known, code generation can hand the linker
complete, final information and the driver can emit the executable with no
`.o` interchange and no separate program.

- **Does the pure case need a linker at all?** It needs *linking*
  (§1.1); the distinction is only whether that logic sits behind an object
  file. Remove the object file and you still must assign addresses, resolve
  symbols, apply relocations, merge sections and write segments. So B does
  not remove the linker — it removes the **ET_REL boundary** for the pure
  case.
- **Effort:** *lower* than A for the pure case (no object parser, no
  archive handling), and it shares the entire core with A. The marginal
  extra cost over A's core is near zero.
- **Correctness risk:** lower than A, because there are no third-party
  objects and no cross-invocation ABI to misinterpret. Same overflow/TLS
  hazards as A.
- **Compile speed:** best possible — no serialization to `.o`, no reparse,
  single pass over in-memory atoms.
- **Debuggability:** same as A; plus deterministic whole-program reachability
  makes `gc-sections` trivially testable.
- **What remains unimplemented / undone by B:**
  - **Foreign imports** (`foreign import` of `.so`) need dynamic structures;
    B does not help (§3.4).
  - **`-build-mode:obj/lib/shared`** — these *require* emitting ET_REL /
    archives / ET_DYN, i.e. option A's object path. B cannot replace them;
    it only means the *default executable* build never writes `.o`.
  - **Incremental builds** — without `.o`/atom caches you recompile and
    relink everything. B is fine for a first correctness milestone and bad
    for incremental; the Zig Elf2 model (§2) is the reference if this
    becomes a goal.
- **Verdict:** B is A's core with the object-file boundary removed for the
  default build; implement it as one `link` package whose first consumer is
  the fused driver, and whose second consumer (later) is an ET_REL reader.

### 3.3 Option C — call mold / lld / GNU ld as an external tool

This is the current status quo (via clang; `linker.cpp`).

- **Rule check — be honest.** The rules say: *"The compiler is written
  entirely in Odin"* and *"no third-party libc … On Linux there is no
  first-party C library, so Linux code talks to the kernel through
  syscalls."* mold/lld/ld are **programs**, not libraries linked into the
  Odin programs we produce, so using them does not break the "no third-party
  libc in our binaries" rule. But it does break *"the compiler is written
  entirely in Odin"* and `docs/research/00-synthesis.md`'s explicit
  *"No external assembler or linker in the end state."* The compiler would
  also gain a runtime dependency on a third-party program being installed,
  and `fork`/`exec` of one is only possible via raw syscalls here (the
  fork's syscall layer makes that possible but does not make it desirable).
  So: **acceptable as a temporary fallback, not as the destination.**
- **Effort:** near zero to keep; it is what exists.
- **Correctness risk:** lowest for arbitrary/foreign inputs — these are
  production linkers (mold has been in production since 2021;
  https://github.com/rui314/mold).
- **Compile speed:** good but externally bounded by process spawn + file
  I/O; mold/wild optimize exactly this (https://github.com/rui314/mold,
  https://github.com/wild-linker/wild). Still slower than in-process B.
- **Debuggability:** opaque to us; depends on external versions;
  non-deterministic across machines unless pinned.
- **Dynamic linking / foreign imports:** complete, today — its only real
  advantage.
- **Verdict:** keep as the managed-path fallback while A/B mature; do not
  make it the end state.

### 3.4 Dynamic linking, PIE, ld.so, TLS, IFUNC — the shared hard part

This applies to A and B equally, and it is what makes the pure case
*easy by comparison*.

For a dynamically linked executable the kernel does **not** run our code
first: it maps the interpreter named by `PT_INTERP` and hands control to
it; the interpreter (the system `ld.so`) loads `DT_NEEDED` objects,
performs relocations and transfers control (gABI ch5 "Dynamic Linking",
https://www.sco.com/developers/gabi/latest/ch5.dynamic.html). We would not
have to *write a loader* — `ld.so` is a platform component, like the
kernel — but we **must emit** everything it consumes:

- `.interp` + `PT_INTERP` (path e.g. `/lib64/ld-linux-x86-64.so.2`; search
  order and tokens like `$ORIGIN` are specified by
  `/home/su3h7am/Projects/refs/man-pages/man/man8/ld.so.8` and gABI ch5).
- `.dynamic` with the mandatory tags (`DT_NEEDED`, `DT_STRTAB`, `DT_SYMTAB`,
  `DT_STRSZ`, `DT_SYMENT`, `DT_HASH`/`DT_GNU_HASH`, `DT_RELA*`,
  `DT_JMPREL`/`DT_PLTRELSZ`/`DT_PLTREL`), `DT_RUNPATH`/`DT_RPATH`,
  `DT_FLAGS`/`DF_BIND_NOW`/`DF_ORIGIN`, plus `DT_INIT`/`DT_FINI` and
  `DT_INIT_ARRAY`/`DT_FINI_ARRAY` (gABI ch5).
- `.dynsym`/`.dynstr`, hash tables, GOT/`.got.plt`, `.plt`, and the
  relocation types ld.so applies: `GLOB_DAT`, `JUMP_SLOT`, `RELATIVE`,
  `COPY`, `IRELATIVE`, `TLS` variants (x86-64 psABI relocation table).
- **RELRO + immediate binding** (`-z now -z relro`) — currently the
  default (`linker.cpp:1305`), and the reason the GOT is placed before a
  read-only boundary after relocation.
- **TLS**: the psABI defines local-exec / initial-exec / global-dynamic
  models. Our backend already lowers initial-exec (`fs:0 + GOTTPOFF`) and
  global-dynamic (`__tls_get_addr`, `TLSGD`)
  (`docs/research/07-...md:352-355`). A dynamically linked executable must
  emit `PT_TLS`, `.tdata`/`.tbss` and the matching dynamic relocations.
- **IFUNC** (`STT_GNU_IFUNC`): glibc implements hot functions (e.g.
  `memcpy`) as IFUNCs; a static linker emitting the final image must
  recognise them and ld.so resolves them at load. **Not needed for pure
  Odin with no libc**; needed only when importing glibc-backed `.so`s.

So "dynamic linking" is a *second, larger* project gated on the foreign
import feature, and IFUNC is a corner of it that only appears with libc.

---

## 4. Comparison

| Criterion | A: own general static linker | B: whole-program fused | C: mold/lld/ld | D: integrated (Go/Zig/Tilde style) |
|---|---|---|---|---|
| Effort, pure static v1 | medium (core) | **medium-low** (core, no `.o` boundary) | ~0 | medium (≈B) |
| Effort, fully general | **very high** | n/a | ~0 | very high |
| Correctness risk | medium (overflow, TLS, eh_frame) | **lower** (own objects only) | **lowest** (mature) | medium |
| Compile speed | high (in-process) | **highest** | good (spawn + I/O) | highest (Zig incremental) |
| Debuggability | **best** (our code, deterministic) | **best** | opaque / version drift | good |
| Dynamic linking / foreign `.so` | needs the dynamic path | needs the dynamic path | **complete now** | complete (Zig has all of it) |
| `-build-mode:obj/lib/shared` | **native** | requires A's object path | complete | complete |
| Incremental | object-level possible | poor without caches | n/a | **target** (Zig Elf2) |
| Rule compliance | **yes** | **yes** | temporary only | **yes** |

---

## 5. Recommended staged path

Each stage is independently shippable and leaves the previous path working.

**Stage 0 — freeze the boundary (now).**
Keep the clang/mold fallback for the managed path (that is `linker.cpp`
today). Define the seam: code generation produces in-memory *atoms* —
named sections, symbols with binding/visibility/type, and relocation
requests in the small relocation set — plus the `elf` writers for when a
file is genuinely needed. Do **not** write a linker yet.

**Stage 1 — fused static non-PIE executable for pure Odin (option B core).**
Implement the `link` package over those atoms: symbol resolution, the
`R_X86_64_*` subset our backend emits, section merge/layout,
reachability `gc-sections`, `PT_LOAD`/`PT_GNU_STACK`, and `ET_EXEC` output.
Target exactly what `entry_unix_no_crt_linux_amd64.asm` /
`tls_linux_no_crt_amd64.asm` / `lifecycle_linux_amd64.odin` assume:
**static non-PIE, local-exec TLS, small code model, fail loudly on ±2 GiB
overflow.** This is the milestone where a pure-Odin hello-world runs with
no external tool at all. Validate by differential comparison against the
LLVM-built `odin` (`docs/01-architecture.md`).

**Stage 2 — the object/library modes via the same core (option A surface).**
`-build-mode:obj` uses the existing ET_REL writer; `:lib` uses `ar`
archives (write the archive format in Odin — it is trivial) or emit the
members for an external `ar`; the same `link` core gains an ET_REL reader
so objects round-trip. **Trigger:** the first user need for
`-build-mode:obj`/`:lib`, or the first incremental requirement.

**Stage 3 — dynamic linking (decide-later, biggest).**
Implement `.interp`, `.dynamic`, `.dynsym`/hash, GOT/PLT,
`GLOB_DAT`/`JUMP_SLOT`, RELRO+NOW, `PT_TLS` and dynamic TLS relocations
enough for **foreign `.so` imports**. Use Zig's `Elf.zig` synthetic-section
list as the checklist (`dynsym`, `versym`, `verneed`, `got`, `plt`,
`rela_dyn`, `rela_plt`, `copy_rel`, `hash`, `gnu_hash`, `interp`, TLS
phdr). **Trigger:** the first real `foreign import` of a `.so` that must
run without the external linker. Until then, keep Stage 0's fallback for
this path.

**Stage 4 — shared libraries, PIE, IFUNC, incremental.**
`-build-mode:shared` = ET_DYN + `DT_SONAME` + init/fini; PIE = position-
independent emission + dynamic `RELATIVE` relocations; IFUNC only if
importing glibc; incremental only if build latency becomes the priority
(Zig Elf2's `markDirty`/`growSection`/`findAllocCollision` design is the
reference). Each is its own trigger.

### 5.1 Decide-later triggers (explicit)

- **Build a general ET_REL/archive linker** only when a foreign `.o`/`.a`
  must be consumed, or `-build-mode:obj`/`:lib` is required. Until then the
  fused driver is enough.
- **Implement dynamic linking** only when a foreign `.so` import must be
  produced without the external linker (and never before `foreign import`
  support itself exists).
- **Implement IFUNC / symbol versioning** only when glibc-backed imports
  are exercised.
- **Implement incremental linking** only when rebuild latency is a stated
  goal; this changes the data model (atoms must be stable across edits,
  cf. Zig Elf2) and should not leak into Stage 1.
- **Adopt mold/wild as a supported fallback** (not the destination) is
  already true via `-fuse-ld`; no new work.

### 5.2 Non-negotiable invariants for every stage

- Same Odin program behaves identically under this compiler and the LLVM
  one (project rule; also means the linker must not silently "fix"
  semantics the official toolchain rejects).
- Deterministic, byte-identical output.
- No third-party libc in produced binaries on Linux; the compiler stays
  pure Odin in the end state.
- `mise run fmt` and `mise run check` before reporting work (AGENTS.md).

---

## 6. Uncertainties and open questions

1. **Term "hard linker"** — not standard; interpreted as an in-process,
   hardwired linker. No source uses the phrase. *Uncertain.*
2. **x86-64 psABI PDF** — I could reach the repo
   (https://gitlab.com/x86-psABIs/x86-64-ABI) but **not** fetch the built
   `x86-64-abi.pdf` (404 on the raw URL); the relocation/TLS details here
   are cross-checked against the gABI HTML, the Linux man pages and our
   own `src/elf/types.odin`. Before relying on a specific `R_X86_64_*`
   semantic, read the generated PDF from the repo's CI artifacts.
3. **"Directly outputting linked executables"** in Tilde/Cuik (TB) is
   described as *early work* (https://yasserarg.com/tb); it is a direction,
   not a proven design we can copy.
4. **mold/wild as libraries**: mold is written in Rust and built with a C
   compiler (https://github.com/rui314/mold), so it cannot become a pure-
   Odin in-process component; it can only ever be an external program.
5. **Default PIE vs static**: confirmed from `build_settings.cpp:2008-2009`
   + `linker.cpp:1180-1193`; the owned/`no_crt` track is *Static*, the
   managed default is *PIC/PIE*. If the pure-Odin compiler wants PIE by
   default later, Stage 4 is mandatory first.
6. **Whether `-rpath $ORIGIN` / RELRO+NOW defaults should still apply**
   once the linker is ours — a policy question, not covered here.

---

## 7. References

**Project-local (read):**
- `/home/su3h7am/Projects/odin-compiler/AGENTS.md`
- `/home/su3h7am/Projects/odin-compiler/docs/01-architecture.md`
- `/home/su3h7am/Projects/odin-compiler/docs/research/00-synthesis.md`
- `/home/su3h7am/Projects/odin-compiler/docs/research/03-existing-compiler-map.md`
- `/home/su3h7am/Projects/odin-compiler/docs/research/05-github-prior-art.md`
- `/home/su3h7am/Projects/odin-compiler/docs/research/07-pr7850-lowering-abi-elf-dwarf.md`
- `/home/su3h7am/Projects/odin-compiler/src/elf/{doc,types,writer,elf_exec}.odin`
- `/home/su3h7am/Projects/Odin/src/linker.cpp` (`linker_stage`, flags)
- `/home/su3h7am/Projects/Odin/src/no_crt_selection.cpp`
- `/home/su3h7am/Projects/Odin/src/build_settings.cpp` (`linux_no_crt_tls*`,
  default reloc mode)
- `/home/su3h7am/Projects/Odin/base/runtime/entry_unix_no_crt_linux_amd64.asm`
- `/home/su3h7am/Projects/Odin/base/runtime/tls_linux_no_crt_amd64.asm`
- `/home/su3h7am/Projects/Odin/base/runtime/lifecycle_linux_amd64.odin`
- `/home/su3h7am/Projects/refs/go/src/cmd/link/internal/ld/`
- `/home/su3h7am/Projects/refs/man-pages/man/man8/ld.so.8`
- `/home/su3h7am/Projects/refs/rfcs/linux/kernel-docs/Documentation/userspace-api/ELF.rst`

**Specifications:**
- ELF gABI (PDF): https://refspecs.linuxfoundation.org/elf/elf.pdf
- ELF gABI (HTML mirror, fetched):
  https://www.sco.com/developers/gabi/latest/contents.html and
  https://www.sco.com/developers/gabi/latest/ch5.dynamic.html
- System V x86-64 psABI: https://gitlab.com/x86-psABIs/x86-64-ABI
  (built PDF reached only via the project's CI artifacts)

**Linkers / prior art:**
- mold: https://github.com/rui314/mold
- wild: https://github.com/wild-linker/wild
- lld design: https://lld.llvm.org/NewLLD.html ; https://lld.llvm.org/
- Zig ELF linker: https://github.com/ziglang/zig/blob/master/src/link/Elf.zig
- Zig 0.17 release notes (ELF + incremental):
  https://ziglang.org/download/0.17.0/release-notes.html
- Go linker walkthrough:
  https://internals-for-interns.com/posts/the-go-linker/
- Go internal vs external linking: https://go.dev/src/cmd/cgo/doc.go
- `cmd/link` flags: https://pkg.go.dev/cmd/link
- Tilde / Cuik (TB): https://yasserarg.com/tb
- radlink / Odin Windows linker: https://github.com/EpicGames/raddebugger

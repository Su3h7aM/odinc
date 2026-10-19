# 05 — GitHub Prior Art (online survey)

Online prior-art check for a pure-Odin Odin compiler, done 2026-10-16 against
live GitHub. Every row is a real URL; nothing here is from memory. Where a
result is a *reader* vs a *writer*, or *merged* vs *rejected*, the table says so.

**Method.** Searches used the public GitHub REST API (`api.github.com`, no auth)
for repository and issue/PR search, plus `raw.githubusercontent.com` for file
contents and `pkg.odin-lang.org` for the shipped package list. Orgs/users
covered as required: `odin-lang/Odin`, `odin-lang/examples`,
`odin-lang/pkg.odin-lang.org`, `DanielGavin/*` (ols), `laytan/*`,
`RealNeGate/*`. No `gh` CLI, no `jj`/`git` mutation.

**Version pinned.** All "in dev-2026-10?" answers were confirmed by grepping our
fork `FORK = /home/su3h7am/Projects/Odin`, `git describe` =
`dev-2026-10-499-gea225db25`. `OC = /home/su3h7am/Projects/odin-compiler`.

> Search-engine caveat: GitHub repo *code* search needs auth and was not used, so
> "no X found" means "not surfaced by repository/issue search or by name/description".
> It does not prove a file does not exist somewhere.

---

## 0. Headline: what already exists, and what Ginger Bill said

- The single most relevant attempt is **PR #7850, "Add `-backend:fast`, a
  non-LLVM debug backend for x86-64 and arm64"** by `bbodi` (2026-10-09). It is a
  full from-scratch backend: its own IR, register allocation, machine-code
  encoding, and ELF/COFF/Mach-O object writing with DWARF 4 / CodeView. **It was
  closed unmerged**, and Ginger Bill's entire review was: *"No. This is not
  maintainable."* — https://github.com/odin-lang/Odin/pull/7850#issuecomment-6085338974
- `core:rexcode` (PR #6839, author **Brendan Punsky / `dotbmp@github`**, merged
  2026-07-17) is the only large piece of the target stack that is *already in the
  language and merged*: a table-driven, LLVM-verified multi-arch instruction
  encoder/decoder/printer, including x86-64. It **is** in dev-2026-10.
- **No Odin ELF writer, no Odin DWARF emitter, no Odin static linker, and no
  Odin Odin-checker exists** — in `core`, in `odin-lang/Odin`, or in any
  community repo found. Those parts are greenfield.
- The **Tilde backend was removed** (PR #6483, `-14714` lines, `+3`, merged
  2026-03-26, shipped dev-2026-04); it is *not* in dev-2026-10.

---

## 1. ELF object / executable writing or reading in Odin

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| `core:encoding` (asn1, base16/32/64, cbor, csv, hex, json, pem, uuid, varint, xml, …) | shipped | odin-lang | present | yes — **no `elf` subpackage** | https://pkg.odin-lang.org/core/ |
| `core:debug/pe`, `core:debug/trace` | shipped | odin-lang | present | yes — **no `dwarf`/`elf`** | https://pkg.odin-lang.org/core/debug/pe/ |
| Odin's compiled objects & executables | shipped | odin-lang | LLVM emits objects; external linker links them (C++ `linker.cpp`) | yes — no Odin ELF code | https://github.com/odin-lang/Odin/blob/master/src/linker.cpp |
| `colrdavidson/elflib` — "Odin ELF parsing library" | reader | colrdavidson | last push 2022-03-26, 0★ | no | https://github.com/colrdavidson/elflib |
| `colrdavidson/peel` — "DWARF/ELF debug dumper" | reader | colrdavidson | 2024-05-16, 1★ | no | https://github.com/colrdavidson/peel |
| `Koliras/odin-dwarf` — single `dwarf.odin` (~25 KB; parses ELF ident + DWARF sections) | reader | Koliras | 2025-06-09, 0★ | no | https://github.com/Koliras/odin-dwarf |
| `djnnvx/draugr` (ELF analysis tool), `meowgoo-me/elf-viewer`, `bradcypert/elfinspect` | readers/tools | various | tiny, 0★ | no | https://github.com/djnnvx/draugr |

**Finding.** Every in-language ELF artifact found is a **reader**. There is **no
Odin ELF *writer*** anywhere in the official tree or the community. Our own
`OC/src/elf` (REL-only) is therefore not a wheel re-invention (this matches
`OC/docs/research/04-reuse-survey.md` §2.3); the community readers are only
useful as format cross-checks.

---

## 2. Static linker / built-in linker in Odin

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| Odin's linking | shipped | odin-lang | **shells out** to `ld`/`lld`/`mold` (Linux), `lld-link`/`link.exe` (Win), `ld`/`wasm-ld`, `clang` | yes | https://github.com/odin-lang/Odin/blob/master/src/linker.cpp |
| **`radlink`** — "RAD Linker", x64 PE/COFF, MSVC-compatible CLI | external linker (**C**, not Odin) | Epic Games / `EpicGames/raddebugger` | merged as Odin's **default Windows linker** (PR #7739, 2026-10-04) | yes — `build_settings.cpp` `Linker_radlink`, `linker.cpp` invokes `bin\radlink` | https://github.com/EpicGames/raddebugger ; https://github.com/odin-lang/Odin/pull/7739 |
| Issue: "Can't build static binaries with non-msvc linkers" | issue | blob1807 | open, 2026-10-10 | n/a | https://github.com/odin-lang/Odin/issues/7858 |
| `-linker:radlink` rejection fix | PR | MatzeOGH | merged 2026-10-04 | yes | https://github.com/odin-lang/Odin/pull/7746 |

**Finding.** There is **no linker written in Odin**. `radlink` is a **C** PE/COFF
linker for Windows; it is an external binary Odin shells out to, is Windows-only,
and is not source we can adapt. A built-in static linker in Odin (any platform)
is greenfield. (Note `radlink` ≠ the medical company at `radlink.com`.)

---

## 3. x86-64 encoder/assembler (`core:rexcode`) and instruction selection / register allocation

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| **`core:rexcode`** (PR #6839) | encoder/decoder/printer + IR core | Brendan Punsky (`dotbmp`), merged by gingerBill | merged 2026-07-17 | **yes** | https://github.com/odin-lang/Odin/pull/6839 ; https://pkg.odin-lang.org/core/rexcode/ |
| `core:rexcode/isa/x86` — table-driven REX/VEX/EVEX, ~1176 mnemonics, LLVM-verified | encoder | dotbmp | shipped | yes (`encoder.odin` 1253, `mnemonic_builders.odin` 10345, `mnemonics.odin` 1392, `decoder.odin` 1530, `reloc.odin` 82) | https://github.com/odin-lang/Odin/tree/master/core/rexcode/isa/x86 |
| Upstream source of rexcode | repo | dotbmp | active, 32★ | (vendored into core) | https://github.com/dotbmp/rexcode |
| `rexcode/x86` label addressing (RIP-rel disp, movabs) | PR | gingerBill | merged 2026-07-30 | yes | https://github.com/odin-lang/Odin/pull/7168 |
| `core:rexcode` improvements / x86 merge tables | PRs | gingerBill | merged 2026-08 | yes | https://github.com/odin-lang/Odin/pull/7362 , /pull/7384 |
| 512-bit `vmovntdq`; `append_elem` perf | PRs | Einh06, MatzeOGH | merged 2026-09 | yes | https://github.com/odin-lang/Odin/pull/7627 , /pull/7684 |
| Instruction selection / register allocation **in Odin** | — | — | **none found** (repo search "register allocation language:Odin" = 0, "instruction selection language:Odin" = 0) | no | — |
| `core:rexcode/ir` | shared structural SSA/IR *model* only (`module/function/block/operation`, `refs`, `types`, `status`, `print`) — **no isel/regalloc** | dotbmp | shipped | yes | https://pkg.odin-lang.org/core/rexcode/ir/ |
| **PR #7850 `-backend:fast`** | full non-LLVM backend incl. its own regalloc + x86-64/arm64 encoder | bbodi | **closed unmerged** 2026-10-09 | no | https://github.com/odin-lang/Odin/pull/7850 |
| `kalsprite/ojitsu` — "Odin JIT Assembler" (independent x86 encoder using Intel XED/asmdb tables) | encoder | kalsprite | 2025-09, 1★ | no | https://github.com/kalsprite/ojitsu |
| `sheganinans/fasm-odin` — bindings to the Flat Assembler | FFI binding | sheganinans | 11★ | no | https://github.com/sheganinans/fasm-odin |
| `colrdavidson/xasm` — x86_64 assembler tinkering (**C**) | encoder | colrdavidson | 2024-05 | no | https://github.com/colrdavidson/xasm |

**Finding.** The encoder is solved and merged (`core:rexcode/isa/x86`); the two
things the survey specifically asked about — **instruction selection** and
**register allocation** — have **no Odin implementation in the open** other than
the rejected #7850. `rexcode/ir` is a *bookkeeping/model* layer (its own docs
call it a structural contract, not a scheduler/SoN), so isel and regalloc remain
ours to write.

---

## 4. DWARF emission / reading in Odin

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| Odin debug info today | shipped | odin-lang | DWARF/CodeView emitted via **LLVM** (C++ `llvm_backend_debug.cpp`); no Odin DWARF code | yes (via LLVM only) | https://github.com/odin-lang/Odin/blob/master/src/llvm_backend_debug.cpp |
| `Koliras/odin-dwarf` | DWARF **reader** | Koliras | 2025-06-09, 0★ | no | https://github.com/Koliras/odin-dwarf |
| `colrdavidson/peel` — DWARF/ELF debug dumper | **reader** | colrdavidson | 2024-05, 1★ | no | https://github.com/colrdavidson/peel |
| `laytan/pdb` — reads Microsoft PDB (CodeView) files | **reader** (Windows) | laytan | fork, Odin | no | https://github.com/laytan/pdb |
| PR #7850 would have emitted DWARF 4 + CodeView | emitter | bbodi | **rejected** | no | https://github.com/odin-lang/Odin/pull/7850 |
| #7681 "Odin uses DWARF2 on macOS"; debug-info printer PRs #7823/#7826/#7831 | issues/PRs | yuraiz, bbodi | closed (LLVM path) | yes (LLVM path) | https://github.com/odin-lang/Odin/issues/7681 |

**Finding.** No Odin **DWARF emitter** exists; the only Odin DWARF code is
**reading** (`odin-dwarf`, `peel`), and the only emitter attempt (#7850) was
rejected. DWARF emission for our backend is greenfield; the readers are weak
(small, unofficial) but can serve as a format cross-check.

---

## 5. Odin-written type checker / semantic analysis / self-hosted / alternative compiler

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| `core:odin/{ast,parser,tokenizer,doc-format,format,printer,tool-format}` | front end | odin-lang | shipped | yes — **no checker/type store** | https://pkg.odin-lang.org/core/odin/parser/ |
| `DanielGavin/ols` — Odin language server | partial semantic analyzer + LSP | DanielGavin | active, 1209★ | no (separate repo) | https://github.com/DanielGavin/ols |
| ols parsing | uses `core:odin/parser` (+ `core:odin/ast`, `core:odin/tokenizer`) | DanielGavin | — | — | https://github.com/DanielGavin/ols/blob/master/src/server/ast.odin |
| ols checker | own analyzer (`src/server/analysis.odin` ~146 KB, `types.odin`, `semantics.odin`, `type_definition.odin`, `collector.odin`); **full diagnostics delegated to `odin check` via overlay** (`src/server/check.odin`) | DanielGavin | — | — | https://github.com/DanielGavin/ols/blob/master/src/server/analysis.odin |
| `Spaceghost/Bor` — "Odin-to-C compiler written in Odin" | alt compiler (scalar subset) | Spaceghost | 2026-09, 1★ | no | https://github.com/Spaceghost/Bor |
| `lumixing/iris` — "intermediate representation" | IR, Odin | lumixing | 2025-10, 0★ | no | https://github.com/lumixing/iris |
| toy compilers in Odin (`monkey-odin`, `codin`, `odinlox`, `goc`, `oasm` VM, …) | toy | various | low★ | no | https://github.com/TESTMECS/monkey-odin , https://github.com/MarvinKatapult/codin |
| "odin-compiler-in-odin" / self-hosted | — | — | **no such repo found**; FAQ says self-host only *after* 1.0 | no | https://odin-lang.org/docs/faq/ |

**Finding.** The only Odin-language semantic analysis of note is **ols**, and it
is deliberately **not a full checker** — it has a partial analyzer for LSP
features and shells out to the real `odin check` for diagnostics. This is the
strongest practical precedent for "analyze Odin in Odin", but it is not a
reusable checker. `Spaceghost/Bor` is a useful precedent for *architecting* an
Odin-subset compiler in Odin (it reuses `core:odin/parser`, owns sema + MIR,
emits C). No full self-hosted Odin compiler exists.

---

## 6. IR / backend work (Sea of Nodes, SSA, `-bedrock`, alternative backend, Tilde #6483, rexcode #6839)

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| **PR #6483 "Remove Tilde Backend"** | backend removal | gingerBill | merged 2026-03-26 (`+3 / -14714`, 21 files) | **no** (shipped dev-2026-04) | https://github.com/odin-lang/Odin/pull/6483 |
| Tilde, continued (C) | Sea-of-Nodes backend | RealNeGate / c3lang | — | no | https://github.com/RealNeGate/Cuik , https://github.com/c3lang/tilde-backend |
| `RealNeGate/Simple` (Sea-of-Nodes showcase fork), `RealNeGate/ssa` (Lua) | SoN/SSA refs | RealNeGate | 2★ each | no | https://github.com/RealNeGate/Simple , https://github.com/RealNeGate/ssa |
| **PR #6839 `core:rexcode`** | ISA+IR library | dotbmp / gingerBill | merged 2026-07-17 | yes | https://github.com/odin-lang/Odin/pull/6839 |
| **PR #6654 `-bedrock`** | restricted-subset mode | gingerBill | merged 2026-06-24 (`+676 / -440`) | yes — `build_settings.cpp` `bool bedrock` | https://github.com/odin-lang/Odin/pull/6654 |
| **PR #7850 `-backend:fast`** | non-LLVM backend | bbodi | closed unmerged 2026-10-09 | no | https://github.com/odin-lang/Odin/pull/7850 |
| LLVM backend perf PRs #7720 / #7729 | keep LLVM fast | gingerBill | merged 2026-10 | yes | https://github.com/odin-lang/Odin/pull/7720 , /pull/7729 |
| "sea of nodes" in issue tracker | — | — | **0 results** (repo search) | — | — |
| `-backend:*` flag | — | — | **does not exist** in the fork (grep `src/` = none) | no | — |

**Finding.** The Odin repo has **no committed IR/backend work** in dev-2026-10
beyond `core:rexcode/ir`'s structural model and the removed Tilde. The only
mergeable direction upstream is: keep LLVM (#7720/#7729), extend `rexcode`, and
use `-bedrock` for restricted targets. The one attempt at a real alternative
backend (#7850) was rejected on maintainability grounds.

### Ginger Bill's recorded statements on these PRs (direction)

| PR | Comment | URL |
|---|---|---|
| #7850 (`-backend:fast`) | "No. This is not maintainable." | https://github.com/odin-lang/Odin/pull/7850#issuecomment-6085338974 |
| #6839 (`core:rexcode`) | (on the author's ability) "He does have a good understanding, that's why I am accepting it. I have been discussing with him directly on this." | https://github.com/odin-lang/Odin/pull/6839#issuecomment-4702339597 |
| #6839 (WASM) | "WASM is a stack-machine rather than a register machine … might not work as intended." | https://github.com/odin-lang/Odin/pull/6839#issuecomment-4706953103 |
| #6483 (Tilde removal) | "Our plan is to just write out own backend instead. It means we have full control over everything." (forum) | https://forum.odin-lang.org/t/tilde-backend-got-removed/1697 |

The general (X/Twitter) statements about wanting a Sea-of-Nodes alternative are
collected in `OC/docs/research/01-gingerbill-vision.md` and are not repeated here.

---

## 7. Tokenizer/parser alternatives faster than `core:odin/parser`

| Item | Kind | Author | Status | In dev-2026-10? | URL |
|---|---|---|---|---|---|
| `core:odin/tokenizer` + `core:odin/parser` | shipped Odin parser (~939 + 4502 lines) | odin-lang | shipped | yes | https://github.com/odin-lang/Odin/tree/master/core/odin/parser |
| `DanielGavin/ols` | **reuses** `core:odin/parser` (+ tokenizer/ast) — not a replacement | DanielGavin | active | no | https://github.com/DanielGavin/ols/blob/master/src/server/ast.odin |
| `tree-sitter-grammars/tree-sitter-odin` | editor grammar (JS/C, MIT) | tree-sitter-grammars | active, 40★ | no | https://github.com/tree-sitter-grammars/tree-sitter-odin |
| `laytan/odin-tree-sitter` | Odin **bindings** to tree-sitter | laytan | 2026-10, 31★ | no | https://github.com/laytan/odin-tree-sitter |
| `Platin21/odin-treesitter` | tree-sitter bindings | Platin21 | 6★ | no | https://github.com/Platin21/odin-treesitter |
| other tree-sitter Odin grammars (`lucypero`, `MineBill`, `kalsprite/Yggdrasil`, …) | grammars | various | low★ | no | https://github.com/lucypero/tree-sitter-odin |

**Finding.** There is **no Odin-native parser faster than `core:odin/parser`**,
and `ols` (the tool most likely to have one) simply reuses it. The only
alternatives are **tree-sitter** grammars/bindings — incremental, editor-oriented,
no type information, and written in C/JS, so they are not a drop-in compiler
front end. Reusing/porting `core:odin/parser` remains the right path.

---

## 8. `laytan/*` and `RealNeGate/*` (explicitly requested)

| User/repo | Relevance | URL |
|---|---|---|
| `laytan/back` — "Backtraces for Odin" | runtime backtrace/unwind helper (not DWARF emission) | https://github.com/laytan/back |
| `laytan/pdb` — reads Microsoft PDB (CodeView) | Windows debug-info **reader** in Odin | https://github.com/laytan/pdb |
| `laytan/odin-tree-sitter` | tree-sitter bindings (see §7) | https://github.com/laytan/odin-tree-sitter |
| `laytan/ols` | fork of the language server | https://github.com/laytan/ols |
| `RealNeGate/Cuik` — modern C11 compiler (C) | host of Tilde; not Odin | https://github.com/RealNeGate/Cuik |
| `RealNeGate/Simple`, `RealNeGate/ssa` | Sea-of-Nodes / SSA references (not Odin) | https://github.com/RealNeGate/Simple , https://github.com/RealNeGate/ssa |
| `RealNeGate/disx86`, `RealNeGate/AsmSnake` | x86 disassembler / asm demo (not Odin) | https://github.com/RealNeGate/disx86 |

`odin-lang/examples` was searched (tree, 488 paths): it contains idiomatic
program examples only — **nothing** on ELF, DWARF, linking, encoders or
compilers. https://github.com/odin-lang/examples

---

## 9. What is already in dev-2026-10 (our fork) vs not

Confirmed by grepping `FORK` at `dev-2026-10-499-gea225db25`:

| Topic | In fork? | Evidence |
|---|---|---|
| `core:rexcode` (isa + ir) | **yes** | `core/rexcode/isa/x86/*`, `core/rexcode/ir/*` |
| x86 encoder (`encode`) | **yes** | `core/rexcode/isa/x86/encoder.odin` |
| `-bedrock` mode | **yes** | `src/build_settings.cpp:682` `bool bedrock`; `src/checker.cpp:1279` `ODIN_BEDROCK` |
| `radlink` linker option | **yes** | `src/build_settings.cpp:470,480`; `src/linker.cpp:523,846` (`bin\radlink`) |
| `core:odin/parser`/`tokenizer`/`ast` | **yes** | `core/odin/*` |
| ELF package in `core` | **no** | `core/encoding` has no `elf`; `core/debug` has only `pe`, `trace` |
| DWARF code in Odin | **no** | DWARF only via LLVM (`src/llvm_backend_debug.cpp`); no `core`/`base` DWARF |
| Odin type checker | **no** | `core/odin` has no checker |
| Tilde backend | **no** | PR #6483 removed it |
| `-backend:*` flag | **no** | grep `src/` = none; PR #7850 rejected |

---

## 10. Reuse / adopt / ignore

### Reuse (already merged, in dev-2026-10 — import or adapt directly)

1. **`core:rexcode/isa/x86`** (+ `core:rexcode/isa/{labels,label_infer}`,
   `reloc.odin`) — the x64 encoder. Table-driven, REX/VEX/EVEX, LLVM-verified,
   zero-allocation. This is the biggest, most concrete win; `OC/src/x64/encode.odin`
   duplicates a subset of it (`OC/docs/research/04-reuse-survey.md` §2.2).
   https://pkg.odin-lang.org/core/rexcode/isa/x86/
2. **`core:odin/{tokenizer,ast,parser}`** — the authoritative Odin grammar
   encoding; adapt the node kinds and procedure structure (index-based storage),
   per `OC/docs/research/04-reuse-survey.md` §1.1.
   https://pkg.odin-lang.org/core/odin/parser/
3. **`core:debug/pe`** — if/when Windows COFF is targeted (Linux-first today).
   https://pkg.odin-lang.org/core/debug/pe/

### Adopt (patterns/ideas, not code we can import)

4. **`core:rexcode/ir`** vocabulary (`Id`/`Ref`/`Ref_Space`/`Symbol_Table`, a
   module-level `Type`/`Type_Ref` table, `Module→Function→Block→Operation`) as
   the *naming/shape* baseline for our IR; not its scheduler (there is none).
   https://pkg.odin-lang.org/core/rexcode/ir/
5. **rexcode's verification model** (round-trip against `llvm-mc`/external
   assemblers; `docs/cross_arch_design.md`) — mirror this discipline for our
   encoder and IR (differential/round-trip tests).
6. **`Spaceghost/Bor`** — the clearest precedent for architecting an Odin-subset
   compiler in Odin: reuse `core:odin/parser`, own sema + MIR, verify before
   claiming. Useful as a design comparison, not as code.
   https://github.com/Spaceghost/Bor
7. **`ols`'s split** — a partial analyzer layered on `core:odin/parser`/`ast`,
   with *full* diagnostics delegated to the real compiler. A good model for
   keeping our checker honest and for any tooling we build.
   https://github.com/DanielGavin/ols
8. **`radlink`** as the pragmatic Windows linker choice (it is what Odin now
   defaults to); do **not** try to reimplement it — it is C and PE/COFF-only.
   https://github.com/EpicGames/raddebugger

### Ignore (do not build on)

9. **PR #7850 (`-backend:fast`)** — closed unmerged; Ginger Bill: "not
   maintainable". Its 32k-line scope is a cautionary data point, not a base.
   https://github.com/odin-lang/Odin/pull/7850
10. **Community ELF/DWARF readers** (`colrdavidson/elflib`, `colrdavidson/peel`,
    `Koliras/odin-dwarf`, `djnnvx/draugr`, `bradcypert/elfinspect`) — tiny,
    stale, unofficial, read-only. Use only as a sparse format cross-check.
11. **`kalsprite/ojitsu`** and **`sheganinans/fasm-odin`** — an alternative x86
    encoder and an external-assembler binding; `core:rexcode` supersedes both for
    our purpose.
12. **tree-sitter Odin grammars/bindings** (`tree-sitter-grammars/tree-sitter-odin`,
    `laytan/odin-tree-sitter`, …) — editor tooling; no type info, not a compiler
    front end.
13. **Toy Odin compilers** (`monkey-odin`, `codin`, `odinlox`, `goc`, `oasm`, …) —
    unrelated to Odin-the-language; no reusable component.
14. **RealNeGate/Cuik, c3lang/tilde-backend, RealNeGate/Simple, RealNeGate/ssa** —
    not Odin code; Sea-of-Nodes **design** context only (already covered by
    `OC/docs/research/02-backend-ir-landscape.md`).

---

## 11. Sources (all URLs cited above are verified)

- GitHub REST API (repos, issues/PR search): https://api.github.com
- odin-lang/Odin — https://github.com/odin-lang/Odin
- Odin package docs (core listing incl. `rexcode`, `odin/parser`, `debug/pe`): https://pkg.odin-lang.org/
- `core:rexcode` docs: https://pkg.odin-lang.org/core/rexcode/ and https://pkg.odin-lang.org/core/rexcode/ir/
- Key PRs/issues: [#6483](https://github.com/odin-lang/Odin/pull/6483),
  [#6654](https://github.com/odin-lang/Odin/pull/6654),
  [#6839](https://github.com/odin-lang/Odin/pull/6839),
  [#7739](https://github.com/odin-lang/Odin/pull/7739),
  [#7850](https://github.com/odin-lang/Odin/pull/7850),
  [#7858](https://github.com/odin-lang/Odin/issues/7858),
  [#7681](https://github.com/odin-lang/Odin/issues/7681)
- Community: https://github.com/DanielGavin/ols , https://github.com/Spaceghost/Bor ,
  https://github.com/dotbmp/rexcode , https://github.com/colrdavidson/elflib ,
  https://github.com/colrdavidson/peel , https://github.com/Koliras/odin-dwarf ,
  https://github.com/kalsprite/ojitsu , https://github.com/sheganinans/fasm-odin ,
  https://github.com/laytan/back , https://github.com/laytan/pdb ,
  https://github.com/tree-sitter-grammars/tree-sitter-odin ,
  https://github.com/RealNeGate/Cuik , https://github.com/c3lang/tilde-backend
- RAD Linker: https://github.com/EpicGames/raddebugger
- Odin FAQ (self-hosting after 1.0): https://odin-lang.org/docs/faq/
- Forum, "Tilde backend got removed": https://forum.odin-lang.org/t/tilde-backend-got-removed/1697

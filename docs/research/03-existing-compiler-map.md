# 03 — Existing Odin Compiler: Architecture Map

Read-only survey of the C++ Odin compiler source. All paths are relative to
`/home/su3h7am/Projects/Odin/src` unless another root is given. Line numbers are
from the files as checked out at the time of writing; sizes are `wc -l` counts
and are approximate.

**Source revision**

- Repo root: `/home/su3h7am/Projects/Odin` (a *fork* of upstream Odin, not vanilla).
- Git HEAD: `ea225db2582cedc2c940d93ea093b8b49d8f1c49`
- `git describe`: `dev-2026-10-499-gea225db25` (i.e. `dev-2026-10`, 499 commits past the tag)
- Compiler version string is injected at build time; `src/build_settings.cpp:152`
  defaults `ODIN_VERSION_RAW` to `"dev-unknown-unknown"` and `ODIN_VERSION` is set
  from it (`build_settings.cpp:156`).
- LLVM: C API, `build_odin.sh:4-6` supports LLVM **17–23**, suggested **23**,
  minimum **17**.
- Fork emphasis (visible in the headers): native Linux x64 / `no_crt` runtime,
  syscall migration, owned-vs-managed provider selection. The most fork-specific
  file is `no_crt_selection.cpp` (see §10).

> **Important finding up front:** there is **no Tilde / TB backend in this tree.**
> A case-insensitive search for `tilde` across `src/` returns nothing, and the only
> `TB_` hits are ELF symbol-binding constants (`STB_GLOBAL`/`STB_WEAK`) in
> `no_crt_selection.cpp`. All code generation is the LLVM backend described in §5.

---

## 1. Source file inventory

The compiler is a **unity build**: `main.cpp` `#include`s every other `.cpp`
(`main.cpp:2-81`). Files listed below are translation-unit fragments, not
separately compiled objects. There is no `src/` build manifest; `build_odin.sh`
compiles `src/main.cpp` plus the vendored libraries.

### 1.1 Driver, build settings, diagnostics

| File | Lines | Purpose |
| --- | --- | --- |
| `main.cpp` | 5065 | `main()`, CLI arg parsing, `BuildContext` wiring, top-level pipeline (`main.cpp:4198`), thread-pool init, `run` subprocess. |
| `build_settings.cpp` | 2776 | `BuildContext`, target OS/arch/subtarget enums, `CommandKind` (`build_settings.cpp:212-228`), `BuildMode_*` (`202-207`), flag table, path/triplet normalization, sanitizer flags. |
| `build_settings_microarch.cpp` | 2851 | Generated per-LLVM-version micro-architecture/feature tables (`target_microarch_list`, `target_microarch_counts`). Guarded by `LLVM_VERSION_MAJOR` (top of file). |
| `bug_report.cpp` | 700 | `odin report` diagnostics bundle. |
| `cached.cpp` | 495 | Build cache: `try_cached_build`, `write_cached_build`. |
| `docs.cpp` / `docs_format.cpp` / `docs_writer.cpp` | 421 / 294 / 1286 | `odin doc` documentation generation (JSON/HTML/text). |
| `semantics_writer.cpp` | 762 | `-export-semantics` graph dump. |
| `timings.cpp` | 251 | `TIME_SECTION` / `MAIN_TIME_SECTION`, timing export (JSON/CSV). |
| `error.cpp` | 1339 | Error collector, `error()`, `compiler_error()`, de-duplication, print. |
| `bundle_command.cpp` | 216 | Android/macOS app bundling. |
| `microsoft_craziness.h` | 803 | Jonathan Blow's Windows SDK/library-path locator (`#include`s `wtypesbase.h`; finds MSVC/Windows Kits folders for linking). Header only, Windows-only. |

### 1.2 Core utilities / data structures

| File | Lines | Purpose |
| --- | --- | --- |
| `common.cpp` | 1162 | Global helpers, string/format helpers, `is_arch_*`, allocator typedefs, `LIT` macro, common includes. |
| `common_memory.cpp` | 881 | Compiler-owned `memcpy`/`memmove`/`memset` helpers and native Linux x64 size-class fast paths (fork work). |
| `gb/gb.h` | 6504 | Vendored Ginger Bill `gb` single-header: allocators, dynamic arrays, file I/O, `gbString`, `gb_printf`, OS layer. |
| `threading.cpp` | 1075 | Futexes, mutexes, semaphores, conditions, `Thread`, `Parker`, `Wait_Signal`, `MPMC` queue. |
| `thread_pool.cpp` | 478 | `ThreadPool`, `TaskGroup`, `WorkerTaskProc`, work-stealing/spin-then-sleep worker. Header-style (no separate `.hpp`). |
| `array.cpp` | 527 | Bounds-checked `Array<T>` helpers. |
| `ptr_map.cpp` / `ptr_set.cpp` | 882 / 277 | Pointer-keyed hash map/set. |
| `string_map.cpp` / `string_set.cpp` / `string16_map.cpp` / `string_interner.cpp` | 598 / 251 / 537 / 233 | String containers and interning. |
| `string.cpp` | 1565 | `String`/`gbString` operations, path splicing, formatting. |
| `queue.cpp` / `priority_queue.cpp` / `sort.cpp` / `range_cache.cpp` | 242 / 86 / 417 / 70 | Containers and sorting. |
| `path.cpp` | 580 | Path normalization, collections (`ODIN_ROOT`, `core:`, `base:`, `vendor:`), `path_to_full_path`. |
| `json.cpp` | 385 | Minimal JSON writer used by docs/timings/bug-report. |
| `unicode.cpp` / `utf8proc/*` | 168 / 750+14385+689 | Rune classification; vendored utf8proc. |
| `ucg/ucg.c` + `ucg_tables.h` | 686 / 2629 | Vendored Unicode general-category tables. |
| `big_int.cpp` / `big_rat.cpp` / `libtommath.cpp` + `libtommath/` | 729 / 227 / 158 / (162 files, ~8171 lines) | Arbitrary-precision integers/rationals for constant folding. |
| `exact_value.cpp` | 1470 | `ExactValue` compile-time constants (ints, floats, strings, compound literals). |
| `name_canonicalization.cpp` + `.hpp` | 1116 / 130 | Odin identifier/link-name canonicalization and `@(link_name)` mangling. |
| `range_cache.cpp`, `asm_tables*.cpp` | 70; 86 + 2420 + 2972 + 1099 | Cached file ranges; generated disassembly/asm tables for amd64/arm64/riscv. |
| `build_cpuid.cpp` | 34 | Host CPU feature probing. |

### 1.3 Front end (lex → parse)

| File | Lines | Purpose |
| --- | --- | --- |
| `tokenizer.cpp` | 1239 | Lexer: `Token_*` kinds (`tokenizer.cpp:2+`), `init_tokenizer_with_data`, `tokenizer_get_token`. |
| `parser.hpp` | 1044 | AST/`AstFile`/`AstPackage`, `Ast` node kinds, `ProcCallingConvention` enum (`parser.hpp:323-341`). |
| `parser.cpp` | 7878 | Recursive-descent parser + **package/import loader** (`parse_packages`, `parser.cpp:7791`) and per-file parse worker (`6500`). |
| `parser_pos.cpp` | 446 | Token-position / line-column bookkeeping for diagnostics. |
| `odin.ebnf` (repo root) | 15438 B | Grammar reference. |

### 1.4 Semantic analysis ("checker")

| File | Lines | Purpose |
| --- | --- | --- |
| `checker.hpp` | 1089 | `Checker`, `CheckerInfo`, `CheckerContext`, `Scope`, `Operand`, `EntityState`. |
| `checker.cpp` | 8574 | Checker driver, `check_parsed_files` (`checker.cpp:8220`), scopes, builtin types, global constants, and the parallel entity collection/import/scope-usage workers (see §4). Also `#include`s the `check_*.cpp` fragments (`checker.cpp:5223-5230`, `6666`). |
| `entity.cpp` | 667 | `Entity` construction/kind tag (`Entity_Procedure`, `Entity_Variable`, `Entity_Constant`, `Entity_TypeName`, `Entity_ProcGroup`, `Entity_LibraryName`, `Entity_ImportName`, …; `entity.cpp:428-582`). |
| `types.cpp` | 5970 | Type system: `Type` kinds (26 `TYPE_KIND` entries incl. `BitSet` at `289`, `BitField` at `310`, `Matrix`), type construction, canonicalization, size/align/hash, `Type_Info` runtime descriptors. |
| `check_expr.cpp` | 14933 | Expression checking (largest file); operator/compound-literal/type-assert semantics; runtime-package dependency injection (e.g. map calls `check_expr.cpp:334-365`, dynamic-array `12171-12172`). |
| `check_builtin.cpp` | 9173 | Builtin procedure checking + **intrinsics** namespace (`intrinsics.*`, SIMD/atomic/objc/etc). |
| `checker_builtin_procs.hpp` | 826 | `BuiltinProcId` enum (313 `BuiltinProc_*` entries), incl. `BuiltinProc__simd_begin…` SIMD ops (`checker_builtin_procs.hpp:156+`). |
| `check_type.cpp` | 5574 | Type expressions, polymorphic record/procedure checking and monomorphization helper (`determine_type_from_polymorphic` `check_type.cpp:2`; polymorphic-record gen-types `307-395`). |
| `check_decl.cpp` | 2668 | Declarations, attributes, calling-convention resolution (`check_decl.cpp:1714-1720`). |
| `check_stmt.cpp` | 3129 | Statements (if/for/switch/defer/return/using). |
| `check_escape.cpp` | 5564 | Reference/escape analysis of pointers and captures. |
| `check_atomics.cpp` | 1970 | `sync.atomic` family checking. |
| `check_asm.cpp` / `check_asm_cfg.cpp` | 3445 / 1057 | Inline assembly checking and control-flow validation. |
| `checker_global.cpp` | 2558 | Global-entity ordering, dependency graph, initialization order (`check_all_global_entities` `checker_global.cpp:1703`). |

### 1.5 Back end (LLVM) — see §5

| File | Lines | Purpose |
| --- | --- | --- |
| `llvm_backend.hpp` | 868 | `lbGenerator`, `lbModule`, `lbProcedure`, `lbValue`/`lbAddr`, calling-convention mapping. |
| `llvm_backend.cpp` | 4531 | Backend driver, target init, `lb_generate_code` (`3803`), module/procedure scheduling, object emission, `main.cpp`-visible `lb_init_generator`. Includes all other `llvm_backend_*.cpp`. |
| `llvm_abi.cpp` | 2776 | ABI lowering: function type construction, `lb_calling_convention_kind` (`llvm_abi.cpp:153`), parameter/attribute classification. |
| `llvm_backend_general.cpp` | 4866 | General emission, CFG blocks, defer scope closing, foreign/link handling. |
| `llvm_backend_expr.cpp` | 7274 | Expression codegen (calls, members, slicing, runtime calls `6590`, 6611). |
| `llvm_backend_stmt.cpp` | 3725 | Statement codegen, defer execution (`lb_close_scope` `368`, `lb_emit_defer_stmts`). |
| `llvm_backend_proc.cpp` | 5625 | Procedure/function emission, calling conv application (`522`), implicit-context parameter (`534-540`), multiple-return ABI (`667-826`). |
| `llvm_backend_type.cpp` | 1194 | LLVM type lowering; `Type_Info`/`typeid` (`lb_typeid` `28`), SOA (`634`, `886`), matrix (`1019`). |
| `llvm_backend_const.cpp` | 2453 | Constant/global emission and LLVM `Constant*` handling. |
| `llvm_backend_utility.cpp` | 3562 | Math/memory/atomic/SIMD intrinsic helpers (`lb_call_intrinsic`, e.g. `46`, `195-219`). |
| `llvm_backend_debug.cpp` | 2022 | DWARF debug info (`-debug`), `llvm_backend_debug`/codeview. |
| `llvm_backend_asm.cpp` | 1834 | LLVM IR / assembly textual emission. |
| `llvm_backend_opt.cpp` | 1416 | Per-function/optimization setup. |
| `llvm_backend_passes.cpp` | 1922 | LLVM pass-pipeline orchestration and module verification. |

### 1.6 Linking / platform

| File | Lines | Purpose |
| --- | --- | --- |
| `linker.cpp` | 1458 | `linker_stage` (`linker.cpp:402`), platform link command construction, `system_exec_msvc_linker_app`, verified inline-asm assembling (`276`), owned/managed switch (`96`). |
| `no_crt_selection.cpp` | 1768 | **Fork-specific**: automatic owned (`ODIN_NO_CRT`) vs managed provider selection for native Linux amd64; provenance classification of the reachable foreign graph. Explicitly documented at top of file (`no_crt_selection.cpp:1-40`). |
| `llvm-c/` | 31 headers, ~12297 lines | Vendored LLVM C API headers (`Core.h`, `Target.h`, `DebugInfo.h`, `Transforms/PassBuilder.h`, …). |

---

## 2. Unity build / include graph

`main.cpp` is the only compiled TU. Include order (`main.cpp:2-81`):

```
common.cpp, timings.cpp, tokenizer.cpp, big_int.cpp, big_rat.cpp,
exact_value.cpp, build_settings.cpp,
[thread-pool helpers defined inline: main.cpp:16-70]
parser.hpp, checker.hpp,
asm_tables.cpp,
parser.cpp, checker.cpp, docs.cpp, semantics_writer.cpp,
cached.cpp,
linker.cpp, bundle_command.cpp,
llvm_backend.cpp,
no_crt_selection.cpp,
bug_report.cpp
```

- `checker.cpp` in turn includes `entity.cpp`, `types.cpp` (`checker.cpp:3-4`) and
  `check_expr.cpp`, `check_builtin.cpp`, `check_type.cpp`, `name_canonicalization.cpp`,
  `check_decl.cpp`, `check_stmt.cpp`, `check_escape.cpp`, `check_atomics.cpp`
  (`checker.cpp:5223-5230`), plus `checker_global.cpp` (`6666`).
- `llvm_backend.cpp` includes `llvm_abi.cpp`, `llvm_backend_opt.cpp`,
  `llvm_backend_general.cpp`, `llvm_backend_debug.cpp`, `llvm_backend_const.cpp`,
  `llvm_backend_type.cpp`, `llvm_backend_utility.cpp`, `llvm_backend_expr.cpp`,
  `llvm_backend_stmt.cpp`, `llvm_backend_proc.cpp`, `llvm_backend_asm.cpp`
  (`llvm_backend.cpp:22-32`).

Consequence: "compilation pipeline stages" are ordinary function calls in `main()`,
and every helper is `gb_internal` (unity-build internal linkage). A new backend
(e.g. a Tilde/TB backend) would slot in next to `llvm_backend.cpp` and be selected
at the `lb_init_generator` / `lb_generate_code` seam in `main.cpp:4941-4986`.

---

## 3. Compilation pipeline (stages and order)

Driven from `main()` at `main.cpp:4198`. Order, with the anchor calls:

1. **CLI / BuildContext** — arg parsing and `build_context` setup; target
   features validated (`main.cpp:4728-4756`).
2. **Init thread pool** — `init_global_thread_pool()` (`main.cpp:4769`); worker
   count from `build_context.thread_count` (`main.cpp:16-20`; defaults set in
   `build_settings.cpp:1829-1830`).
3. **Init universal** — `init_universal()` (`main.cpp:4779`): builtin types,
   `runtime`/`intrinsics` pseudo-packages.
4. **Init asm tables** — `init_asm_tables()` (`main.cpp:4787`).
5. **Parse** — `MAIN_TIME_SECTION("parse files")` (`main.cpp:4792`);
   `init_parser` (`4794`); `parser->package_parsed_proc =
   check_collect_package_entities_worker_proc` (`4798`); `parse_packages(...)`
   (`4802`). Errors bail out (`4807-4810`).
6. **Optional pre-check cached-build fast path** (`main.cpp:4821-4826`).
7. **Type check** — `MAIN_TIME_SECTION("type check")`;
   `check_parsed_files(checker)` (`main.cpp:4828-4829`).
8. **Owned-first provider finalization** (fork) — recheck/managed fallback and
   `classify_reachable_requirements` (`main.cpp:4836-4855`).
9. **Defineables / semantics export / warnings** (`main.cpp:4856-4872`).
10. **Docs** — `generate_documentation` (`main.cpp:4892-4908`); **`-no-output`**
    early exit (`4910-4929`).
11. **Post-check cached build** (`main.cpp:4931-4938`).
12. **Backend codegen** — `lb_init_generator` (`4942`); `lb_generate_code(gen)`
    (`4952`); on success **link** via `linker_stage(gen)` (`4957`); temp object
    cleanup (`4972-4988`).
13. **Dependency/semantics export, cache write, timings** (`5000-5022`).
14. **`run`** — execute the produced executable unless `-keep-executable`
    (`main.cpp:5024-5063`).

Within the checker, `check_parsed_files` (`checker.cpp:8220`) runs a fixed
sub-sequence: collect entities per package (parallel) → export entities → add
imports → type-alias correction → directives → inline-asm → global entity ordering
(`check_all_global_entities` `checker.cpp:8292`) → scope-usage checks
(`checker.cpp:8366-8367`).

Within the backend, `lb_generate_code` (`llvm_backend.cpp:3803`) runs: LLVM target
initialization per arch (`3826-3872`) → target machine creation (`3891`) →
per-module procedure/type generation (`2846-2859`, `3181-3223`) → debug-info
finalization (`3239`) → optimization passes (`3250-3276`) → verification (`3113`,
`3793`) → object emission (`3383-3428`).

---

## 4. Package loading and parallelization

**Model:** a single global `ThreadPool` (`thread_pool.cpp:16-19`) with a
`TaskGroup` join primitive (`thread_pool.cpp:42-44`). Worker count defaults to
the host CPU count (`build_settings.cpp:1829-1830`, overridable with
`-thread-count`; `main.cpp:1205-1207`).

**Loading (parser, `parser.cpp`):**

- `parse_packages` (`parser.cpp:7791`) seeds `base:runtime` and the init file
  serially (`7832-7835`), plus extra/`core:testing` packages on demand
  (`7837-7858`), then `thread_pool_wait()` (`7861`) joins all parse tasks.
- Imports discovered during parse are queued with
  `parser_add_file_to_process` → `thread_pool_add_task(parser_worker_proc, …)`
  (`6508-6516`). `parser_worker_proc` calls `process_imported_file` then
  `parser_package_file_done` (`6500-6505`).
- Completion is reference-counted per package: `pkg->files_to_parse`
  (`parser_package_file_done`, `6494-6498`); when it hits zero the hook
  `package_parsed_proc` fires — which is `check_collect_package_entities_worker_proc`
  (wired in `main.cpp:4798`). This **overlaps checking with parsing**.
- `.S`/foreign sources load through `foreign_file_worker_proc` (`6518-6542`).
- Imported-file and package registration use mutexes
  (`MUTEX_GUARD_BLOCK`, e.g. `parser.cpp:6486`).

**Checking (checker.cpp + checker_global.cpp):**

- `check_collect_package_entities_worker_proc` (`checker.cpp:6597`) creates the
  package scope and fans out one `check_collect_entities_worker_proc` task per
  file (`6622`). Exported entities are drained from a per-package MPMC queue
  (`check_export_entities_worker_proc`, `6641-6662`).
- Parallel phases: `check_add_imports_worker_proc` (`6668-6757`),
  `correct_type_aliases_worker_proc` (`6680-6691`), `check_file_directives_worker_proc`
  (`6767-6788`), `check_proc_info_worker_proc` for procedure bodies incl. nested
  procs (`2800`, `7199`, `7338`, `7411`), and scope-usage checks
  (`start_check_all_scope_usages` `8163-8170`).
- Global-entity ordering constructs a dependency graph with `TaskGroup`s and
  workers (`checker_global.cpp:1314-1669`; `check_all_global_entities` `1703`).
- `check_parsed_files` orchestrates these under `TaskGroup` joins
  (`checker.cpp:8220-8367`).

**Backend parallelism:** enabled only when LLVM is multithreaded, modules are
separate, and there is more than one worker
(`do_threading`, `llvm_backend.cpp:3806-3809`). It parallelizes per-module
procedure generation (`2846-2859`, `3181-3223`), debug-info finalization
(`3239`), per-function and per-module passes (`3250-3276`), verification
(`3113`, `3793`), and object emission (`3383-3428`).

---

## 5. Where LLVM is used (and the backend's shape)

**Everything that lowers to machine code goes through LLVM's C API.** There is no
second code generator. Evidence:

- `llvm_backend.hpp:2-18` includes `<llvm-c/Core.h>`, `Target.h`, `Analysis.h`,
  `Object.h`, `BitWriter.h`, `DebugInfo.h`, `Transforms/PassBuilder.h`, plus
  `llvm-config.h` for version selection.
- Vendored headers live in `src/llvm-c/` (31 headers, ~12.3k lines).
- Backend is selected/instantiated in `main.cpp:4941-4945`
  (`lb_init_generator`) and run in `main.cpp:4952` (`lb_generate_code`).
- LLVM version compatibility macros (LLVM 17…23) are pervasive, e.g.
  `LLVM_VERSION_MAJOR` guards in `build_settings_microarch.cpp` top,
  `llvm_backend.cpp:3814`, `llvm_backend.hpp:164`.

**Module/procedure structures** (`llvm_backend.hpp`): `lbModule` (`139`),
`lbGenerator : LinkerData` (`242`) holding `PtrMap<void*, lbModule*> modules`
keyed by `AstPackage*` (`245`), `file_modules` (`247`), split `type_info_modules`
(`249`) and `debug_types_modules` (`255`), and `used_module_count` (`257`).

**Pipeline inside the backend:** per-arch LLVM target init → target machine →
per-module function/type emission → DWARF → passes → verification → object/asm/IR
emission, all orchestrated in `lb_generate_code` (`llvm_backend.cpp:3803-4450`).

**Output modes** are `BuildMode_Executable`, `_DynamicLibrary`, `_StaticLibrary`,
`_Object`, `_Assembly`, `_LLVM_IR` (`build_settings.cpp:202-207`). LLVM IR and
assembly text are emitted from `llvm_backend_asm.cpp`; objects are written by the
`lb_llvm_emit_worker_proc` path (`llvm_backend.cpp:3422-3428`).

### 5.1 Tilde / TB backend: **absent / not started**

- `grep -ri tilde src/` → no matches. `grep -rni "tilde" src/` → no matches.
- `grep -rl "TB_" src/` → only `no_crt_selection.cpp`, and the matches are ELF
  `STB_GLOBAL`/`STB_WEAK` binding comments/logic (`no_crt_selection.cpp:160-161,911`),
  unrelated to a backend.
- There is no `x86_64`/`arm64` self-contained encoder, no register allocator, no
  machine-IR, and no `odin build -backend:...` selection in the tree.

**So "how complete is Tilde?" is not answerable from this source: it does not
exist here.** The design implication for the docs set: a Tilde/TB backend must be
added wholesale, and the natural seam is the `lb_init_generator` /
`lb_generate_code` / `linker_stage` trio consumed at `main.cpp:4941-4957`, with
an equivalent of `lbGenerator`/`lbModule`/`lbProcedure` fed from the same
`CheckerInfo` + `AstPackage` graph.

---

## 6. Odin-unique features the backend must handle

These are the language/runtime features that make the backend non-trivial. All are
already implemented for LLVM; a new backend must reproduce them.

| Feature | Where handled today (anchor) |
| --- | --- |
| **Implicit context pointer** (`context`, `#no_context`) | `ProcCC_Odin` carries the context as the **last** parameter: `llvm_backend_proc.cpp:534-540`; pushed from implicit param `655`; looked up per-call `lb_find_or_generate_context_ptr` (`llvm_backend_proc.cpp:872,1243-1245`); diagnostics reference `runtime.default_context()` (`check_expr.cpp:9878,9885`). |
| **Calling conventions** `odin`, `contextless`, `c`, `stdcall`, `fastcall`, `naked`, `win64`, `sysv`, `preserve_none/most/all`, `inline_asm` | Enum `parser.hpp:323-341`; name table `checker.cpp:1451-1452`; LLVM mapping `lb_calling_convention_map` (`llvm_backend.hpp:782-801`) + `lb_calling_convention_kind` (`llvm_abi.cpp:153-161`, with Playdate→AAPCS_VFP and wasm→C overrides); applied at `llvm_backend_proc.cpp:522` and call sites `1116`. |
| **Multiple return values** (tuples) | Tuple ABI, `sret`/return-by-pointer, split returns: `llvm_backend_proc.cpp:667-826` (`multiple_return_original_type`, `lb_emit_tuple_ep`, `reduce_tuple_to_single_type`), attributes in `llvm_abi.cpp:171+`. |
| **Parametric polymorphism / monomorphization** | Checker-side specialization: `check_type.cpp:2`, `165-168`, `307-395` (polymorphic records / gen-types); procedurally instantiated per call site and emission in `llvm_backend_general.cpp`/`llvm_backend_proc.cpp`. LLVM weak-monomorphization toggles exist: `LLVM_WEAK_MONOMORPHIZATION` (`llvm_backend.cpp:14-16`). |
| **`defer`** | Scope-scoped defer stack and exit emission: `lb_close_scope` (`llvm_backend_stmt.cpp:368-370`), `lb_emit_defer_stmts` used at every scope exit/return (`llvm_backend_stmt.cpp:2644-2695`); optimization of defers in `llvm_backend_opt.cpp`. |
| **`#soa` / `#simd` / matrix types** | SOA: `Type_SoaPointer` + `Struct.soa_kind/soa_elem/soa_count` in `Type_Info` (`llvm_backend_type.cpp:634-638`, `886-894`); `intrinsics.soa_struct` (`check_builtin.cpp:5491-5521`); runtime `base/runtime/core_builtin_soa.odin`. Matrix: `Type_Matrix`, `matrix_type_stride_in_elems`, row-major flag (`llvm_backend_type.cpp:1019-1030`; kind `types.cpp`). SIMD ops: `BuiltinProc__simd_*` (`checker_builtin_procs.hpp:156-166`) lowered to LLVM vector ops in `llvm_backend_utility.cpp`. |
| **`any` / union / `typeid` RTTI** | `Type_Info` runtime descriptors and `typeid`: `lb_typeid`/`lb_type_info` (`llvm_backend_type.cpp:28-101`), `lb_typeid_kind` mapping every `Type_*` to `Typeid_*` (`llvm_backend_type.cpp:53-70`); `any`/union layout in `types.cpp`; type-info modules split for size (`llvm_backend.hpp:249`). |
| **`bit_set` / `bit_field`** | Dedicated type kinds `Type_BitSet` (`types.cpp:289,1315,1389`) and `Type_BitField` (`types.cpp:310,1240,1036`); lowering in `llvm_backend_type.cpp`/`llvm_backend_expr.cpp`. |
| **slices / dynamic arrays / maps runtime** | Implemented in **Odin** under `base/runtime/` (`dynamic_array_internal.odin`, `dynamic_map_internal.odin`, `core.odin`) and called from the backend/checker as runtime dependencies: map `check_expr.cpp:334-365` (`__dynamic_map_get/set/check_grow`, `map_desired_position`, `map_probe_distance`), dynamic array `check_expr.cpp:12171-12172` → `lb_emit_runtime_call("__dynamic_array_reserve"/"__dynamic_array_append")` (`llvm_backend_expr.cpp:6590,6611`). Slice = `{data, len}` value; map/slice headers are compiler-known `Type_*`. |
| **Built-in intrinsics** | `intrinsics.*` namespace checked in `check_builtin.cpp` (e.g. `check_builtin.cpp:5491`), plus math/memory/atomic/intrinsic helpers calling `llvm.*` in `llvm_backend_utility.cpp` (`lb_call_intrinsic`; e.g. `46`, `195-219` `llvm.minnum`/`llvm.maxnum`, `llvm.trap`). `BuiltinProcId` has 313 entries (`checker_builtin_procs.hpp`). |
| **Foreign imports / libraries** | `Entity_Procedure.is_foreign` consulted in backend (`llvm_backend_general.cpp:477`) and link-name resolution (`2614`); `Entity_LibraryName` accumulates `paths`/`extra_linker_flags` consumed by `linker_stage` (`linker.cpp:402+`). `@(link_name)` canonicalization in `name_canonicalization.cpp`. |
| **Procedure groups** (a value that is a set of procs) | `Entity_ProcGroup` (`entity.cpp:576`); `proc_group_entities` / `proc_group_entities_cloned` (`checker.cpp:3920-3933`); `proc_group_attribute` (`4359`). |
| **`or_else` / `or_return`** | Checker semantics in `check_expr.cpp`; backend lowering in `llvm_backend_expr.cpp` and `llvm_backend_utility.cpp`. |
| **Default/temp allocators & context allocator API** | `base/runtime/default_allocators_*.odin`, `default_temp_allocator_arena.odin`; `#optional_allocator_error` tag (`parser.hpp:320`). |
| **`using` / matrix swizzles / compound literals** | `check_decl.cpp`, `check_expr.cpp`, `llvm_backend_expr.cpp`. |
| **Inline assembly** | `check_asm.cpp` + `check_asm_cfg.cpp`; variables lowered in `llvm_backend_asm.cpp`; asm inputs assembled in `linker_assemble_asm_input` (`linker.cpp:276`). |
| **`-no-crt` / owned runtime (fork)** | `no_crt_selection.cpp` (whole file) + `linker_enable_system_library_linking` (`linker.cpp:96`); entry points in `base/runtime/entry_unix_no_crt_*.asm`. |

---

## 7. Linker invocation

- Entry point `linker_stage(LinkerData *gen)` at `linker.cpp:402`; `LinkerData`
  is the base of the backend's `lbGenerator` (`llvm_backend.hpp:242`), so the
  backend collects the object/lib inputs and the linker stage consumes them.
- All host commands are run through `system_exec_command_line_app` /
  `system_exec_msvc_linker_app` (`main.cpp:88+`, `linker.cpp:16-92`), i.e. the
  compiler shells out — it does **not** link in-process.
- Platform branches inside `linker_stage`:
  - **wasm**: `wasm-ld` (`linker.cpp:462-469`), with Orca SDK handling.
  - **Windows**: `lld-link` / `link.exe` (`linker.cpp:513-807`), response files
    with an MSVC-specific path (`16-92`), resource compiler (`754`).
  - **macOS**: `clang` driver, then `ld`/`ld64`, `dsymutil`, SDK discovery via
    `xcrun --show-sdk-path` (`linker.cpp:1233+`), `-fuse-ld=lld` (`1395`), plus
    `mold-link`/`ld-link` variants (`1399-1401`).
  - **Linux/ELF**: `clang`/`ld` with `-fuse-ld=lld`/`mold` where available.
- `BuildPath_Output` drives the output name (`linker.cpp:406`); a `BuildPath_Object`
  TODO is noted (`linker.cpp:408`).
- Verified inline assembly is assembled via `clang -c` / `as` (`linker.cpp:310-342`)
  and cached (`linker_verified_asm_*`, `linker.cpp:179-236`).

---

## 8. Sizes at a glance

- `src/*.cpp` + `*.hpp` + `*.h`: **~163,200 lines** across 84 top-level entries.
- Largest units: `check_expr.cpp` 14,933; `check_builtin.cpp` 9,173;
  `checker.cpp` 8,574; `parser.cpp` 7,878; `llvm_backend_expr.cpp` 7,274;
  `types.cpp` 5,970; `llvm_backend_proc.cpp` 5,625; `check_type.cpp` 5,574;
  `check_escape.cpp` 5,564; `main.cpp` 5,065; `llvm_backend_general.cpp` 4,866.
- Generated data dominates bytes elsewhere: `asm_tables_amd64.cpp` 2,420 lines
  (566 KB), `asm_tables_arm64.cpp` 2,972 lines (677 KB),
  `build_settings_microarch.cpp` 2,851 lines (**959 KB** — giant literal tables).
- Vendored: `gb/gb.h` 6,504; `utf8proc_data.c` 14,385; `libtommath/` 8,171 across
  162 files; `llvm-c/` 12,297 across 31 headers.

---

## 9. `/home/su3h7am/Projects/odin-compiler` (current workspace)

The session working directory is an **empty Jujutsu workspace**, not a checkout of
the compiler:

- `ls -a` → only `.git` and `.jj`.
- `jj status` → "The working copy has no changes"; `jj log -r @` shows an empty
  commit `tkkpprux 112c0127` whose parent is the root commit (`zzzzzzzz 00000000`).
- No `src/`, no `docs/` existed before this file; `docs/research/` was created to
  hold `03-existing-compiler-map.md`.

The actual compiler source lives at `/home/su3h7am/Projects/Odin`, whose own
working copy is a Jujutsu repo (`/home/su3h7am/Projects/Odin/.jj`) at
`@ yyzmztqt` (empty) on top of `kwzvrxvn … ea225db2`.

---

## 10. `/home/su3h7am/Projects/refs/rfcs/linux` (brief)

This is **not an RFC collection** despite the path. It is a fetched Linux reference
corpus used for the fork's native Linux work:

- `VERSION` → `7.2.8`.
- `kernel-docs/` → Linux **7.2.8** kernel documentation, `index.md` +
  `Documentation/` (3,989 reStructuredText files, unconverted by design per
  `kernel-docs/index.md`); also `memory-model/`.
- `man-pages/` → 208 Linux section-2/3 man pages as Markdown.
- `fetch-kernel-docs.sh`, `fetch-man-pages.sh`, `build_index.py` → the fetch/index
  tooling (and a `.cache` dir). No `README*` file is present in this directory.

Sibling reference checkouts that matter for a backend/runtime effort (from
`/home/su3h7am/Projects/refs/README-tls-clones.md`): `zig` (sparse `lib/std`), `go`
(sparse runtime/syscall/linker), `musl`, `c-ward`, `origin`, `relibc`, `bionic`
(sparse), plus `Odin-upstream` (a pristine upstream Odin checkout) — the last is
the natural comparison point for a from-scratch backend.

---

## 11. Notes / gaps

- The fork has diverged from upstream in the runtime/linking layer
  (`no_crt_selection.cpp`, `common_memory.cpp`, native-Linux syscall runtime under
  `base/runtime/`), which is the commit series visible in `git log`
  (`core:os: use 16 KiB first block for per-thread temp arenas`,
  `Speed up native Linux x64 memory helpers…`, etc.). A backend rewrite must
  preserve the owned-vs-managed provider contract documented at
  `no_crt_selection.cpp:1-40`.
- No `src/` build files list individual objects, so any new backend file must be
  added to the `main.cpp` include chain (and to whatever `build_odin.sh` uses,
  which is just `src/main.cpp`).
- `check_proc_info_worker_proc` and `check_collect_*` overlap parsing; the parser's
  `package_parsed_proc` hook (`main.cpp:4798`) is the concrete parsing→checking
  hand-off and a place a new front-end/back-end split must respect.
